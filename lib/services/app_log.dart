import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 日志级别。只有三档，够用且看得懂。
enum LogLevel {
  info,
  warn,
  error;

  /// 落盘用的单字符（省空间）
  String get code => switch (this) {
        LogLevel.info => 'i',
        LogLevel.warn => 'w',
        LogLevel.error => 'e',
      };

  static LogLevel parse(Object? v) => switch ('$v') {
        'e' => LogLevel.error,
        'w' => LogLevel.warn,
        _ => LogLevel.info,
      };

  String get label => switch (this) {
        LogLevel.info => '操作',
        LogLevel.warn => '提醒',
        LogLevel.error => '错误',
      };
}

/// 一条日志。
///
/// 字段名刻意用短名（t/lv/k/m/d）：一天几百条，按行存 JSON，
/// 名字短一点文件小一半，读回来也不影响可读性（有 [describe]）。
class LogEntry {
  LogEntry({
    required this.at,
    required this.level,
    required this.kind,
    required this.message,
    this.data,
  });

  final DateTime at;
  final LogLevel level;

  /// 事件类型，如 `play.start` / `page.view` / `error.network`
  final String kind;
  final String message;
  final Map<String, dynamic>? data;

  Map<String, dynamic> toJson() {
    // 取成局部变量：Dart 3 不会对 public 字段做 null 提升
    final d = data;
    return {
      't': at.millisecondsSinceEpoch,
      'lv': level.code,
      'k': kind,
      'm': message,
      if (d != null && d.isNotEmpty) 'd': d,
    };
  }

  static LogEntry fromJson(Map<String, dynamic> m) => LogEntry(
        at: DateTime.fromMillisecondsSinceEpoch(
          (m['t'] as num?)?.toInt() ?? 0,
        ),
        level: LogLevel.parse(m['lv']),
        kind: '${m['k'] ?? ''}',
        message: '${m['m'] ?? ''}',
        data: (m['d'] as Map?)?.cast<String, dynamic>(),
      );

  /// 给人看的一行
  String describe() {
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final ss = at.second.toString().padLeft(2, '0');
    final d = data;
    final extra = (d == null || d.isEmpty)
        ? ''
        : '  ${d.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    return '$hh:$mm:$ss  ${level.label}  $message$extra';
  }
}

/// 设备日志：操作、更新、错误，落盘 + 内存环形缓冲 + 待上报游标。
///
/// 设计取向：
/// - **不能出问题**。日志本身报错就静默吞掉，绝不影响播放。
/// - **不能长太大**。按天一个文件，只留 7 天，超过就删。
/// - **要能区分设备**。首次启动生成一个设备 ID，跟着 SharedPreferences 走，
///   多台手机回传的日志在服务器上按 ID 分目录。
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const _kDeviceId = 'ts_device_id';
  static const _kDeviceName = 'ts_device_name';

  /// 内存里留多少条给界面看
  static const _memLimit = 400;

  /// 本地保留天数
  static const _keepDays = 7;

  Directory? _dir;
  bool _ready = false;
  bool get ready => _ready;

  String _deviceId = '';
  String _deviceName = '';
  String _model = '';
  String _manufacturer = '';
  int _sdk = 0;
  String _versionName = '';
  int _versionCode = 0;

  String get deviceId => _deviceId;

  /// 家属能改的名字（"爷爷的手机"），没设过就用型号
  String get deviceName => _deviceName.isNotEmpty
      ? _deviceName
      : (_model.isNotEmpty ? _model : '未知设备');

  String get model => _model;
  String get manufacturer => _manufacturer;
  int get sdk => _sdk;
  String get versionName => _versionName;
  int get versionCode => _versionCode;

  final List<LogEntry> _mem = <LogEntry>[];
  List<LogEntry> get mem => List.unmodifiable(_mem);

  /// 启动时调用一次。失败不影响启动。
  Future<void> init() async {
    if (_ready) return;
    try {
      final sp = await SharedPreferences.getInstance();
      _deviceId = sp.getString(_kDeviceId) ?? '';
      if (_deviceId.isEmpty) {
        _deviceId = _newId();
        await sp.setString(_kDeviceId, _deviceId);
      }
      _deviceName = sp.getString(_kDeviceName) ?? '';

      // 版本与机型从原生拿：这里不引 device_info / package_info 两个新依赖，
      // 少一个依赖就少一份构建风险。
      final info = await _channel.invokeMapMethod<String, dynamic>('get');
      if (info != null) {
        _versionCode = (info['versionCode'] as num?)?.toInt() ?? 0;
        _versionName = '${info['versionName'] ?? ''}';
        _model = '${info['model'] ?? ''}';
        _manufacturer = '${info['manufacturer'] ?? ''}';
        _sdk = (info['sdk'] as num?)?.toInt() ?? 0;
      }

      final base = await getApplicationSupportDirectory();
      _dir = Directory('${base.path}/app_logs');
      if (!await _dir!.exists()) await _dir!.create(recursive: true);
      await _cleanOld();

      _ready = true;
      await _loadTodayToMem();
    } catch (e) {
      // 日志系统自己挂了不能拖累 App
      debugPrint('[log] init 失败：$e');
      _ready = true;
    }
  }

  static const _channel = MethodChannel('tingshu/app_info');

  String _newId() {
    final r = Random.secure();
    final bytes = List<int>.generate(6, (_) => r.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'd$hex';
  }

  Future<void> setDeviceName(String name) async {
    _deviceName = name.trim();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kDeviceName, _deviceName);
    } catch (_) {}
  }

  // ---------------- 写入 ----------------

  void event(String kind, String message, {Map<String, dynamic>? data}) {
    _add(LogEntry(
      at: DateTime.now(),
      level: LogLevel.info,
      kind: kind,
      message: message,
      data: data,
    ));
  }

  void warn(String kind, String message, {Map<String, dynamic>? data}) {
    _add(LogEntry(
      at: DateTime.now(),
      level: LogLevel.warn,
      kind: kind,
      message: message,
      data: data,
    ));
  }

  void error(String kind, String message, {Object? e, Map<String, dynamic>? data}) {
    final d = <String, dynamic>{...?data};
    if (e != null) {
      final s = '$e';
      d['err'] = s.length > 300 ? '${s.substring(0, 300)}…' : s;
    }
    _add(LogEntry(
      at: DateTime.now(),
      level: LogLevel.error,
      kind: kind,
      message: message,
      data: d,
    ));
  }

  void _add(LogEntry e) {
    _mem.add(e);
    if (_mem.length > _memLimit) {
      _mem.removeRange(0, _mem.length - _memLimit + 50);
    }
    unawaited(_append(e));
    // 界面（日志页）随时可能开着
    _notify();
  }

  final _listeners = <void Function()>[];
  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);
  void _notify() {
    for (final fn in List.of(_listeners)) {
      try {
        fn();
      } catch (_) {}
    }
  }

  Future<void> _append(LogEntry e) async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final f = File('${dir.path}/${_dayKey(e.at)}.jsonl');
      await f.writeAsString(
        '${jsonEncode(e.toJson())}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {}
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---------------- 读取 ----------------

  /// 读某一天的日志（默认今天）
  Future<List<LogEntry>> readDay([DateTime? day]) async {
    final d = day ?? DateTime.now();
    final dir = _dir;
    if (dir == null) return const [];
    final f = File('${dir.path}/${_dayKey(d)}.jsonl');
    if (!await f.exists()) return const [];
    try {
      final lines = await f.readAsLines();
      final out = <LogEntry>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          out.add(LogEntry.fromJson(
            (jsonDecode(line) as Map).cast<String, dynamic>(),
          ));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 最近 N 天的全部日志（新的在前）
  Future<List<LogEntry>> readDays(int days) async {
    final out = <LogEntry>[];
    final now = DateTime.now();
    for (var i = 0; i < days; i++) {
      out.addAll(await readDay(now.subtract(Duration(days: i))));
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  Future<void> _loadTodayToMem() async {
    final today = await readDay();
    if (today.isEmpty) return;
    _mem.addAll(today);
    if (_mem.length > _memLimit) {
      _mem.removeRange(0, _mem.length - _memLimit);
    }
    _notify();
  }

  /// 启动时清理过期文件
  Future<void> _cleanOld() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: _keepDays));
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.jsonl')) continue;
        final name = f.uri.pathSegments.last.replaceAll('.jsonl', '');
        final d = DateTime.tryParse(name);
        if (d != null && d.isBefore(DateTime(cutoff.year, cutoff.month, cutoff.day))) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ---------------- 导出 ----------------

  /// 纯文本导出：给人看、给 AI 分析
  Future<String> exportText({int days = 3}) async {
    final entries = await readDays(days);
    final b = StringBuffer()
      ..writeln('# 听评书 设备日志')
      ..writeln('设备：$deviceName（$manufacturer $model）')
      ..writeln('设备ID：$_deviceId')
      ..writeln('版本：$_versionName ($_versionCode)  Android SDK $_sdk')
      ..writeln('导出：${DateTime.now()}  共 ${entries.length} 条')
      ..writeln('----');
    for (final e in entries.reversed) {
      b.writeln('${_dayKey(e.at)} ${e.describe()}');
    }
    return b.toString();
  }

  /// 设备信息（上报、页面展示都用）
  Map<String, dynamic> deviceInfo() => {
        'deviceId': _deviceId,
        'deviceName': deviceName,
        'model': _model,
        'manufacturer': _manufacturer,
        'sdk': _sdk,
        'versionName': _versionName,
        'versionCode': _versionCode,
      };
}

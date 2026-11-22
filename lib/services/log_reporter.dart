import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// 服务器上的一台设备
class RemoteDevice {
  RemoteDevice({
    required this.deviceId,
    required this.deviceName,
    required this.model,
    required this.versionName,
    required this.lastAt,
    required this.count,
  });

  final String deviceId;
  final String deviceName;
  final String model;
  final String versionName;
  final DateTime? lastAt;
  final int count;

  static RemoteDevice fromJson(Map<String, dynamic> m) => RemoteDevice(
        deviceId: '${m['deviceId'] ?? ''}',
        deviceName: '${m['deviceName'] ?? ''}',
        model: '${m['model'] ?? ''}',
        versionName: '${m['versionName'] ?? ''}',
        lastAt: (m['lastAt'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((m['lastAt'] as num).toInt()),
        count: (m['count'] as num?)?.toInt() ?? 0,
      );
}

/// 日志上报 / 回读。
///
/// - **上报**：启动后把本地没发过的打包推上去，失败就等下次启动，不重试不打扰。
/// - **回读**：家属或 AI 想分析时，把服务器上某台设备的日志拉回来。
///
/// 地址和 token 写死在这里——这是**自建**的私有接口，不是公开服务。
/// 换自己的服务器要改 [base]，并把服务器端的 TS_LOG_TOKEN 设成同一个值。
class LogReporter {
  LogReporter._();
  static final LogReporter instance = LogReporter._();

  static const String base = 'https://ali.popcalico.top/tingshu-log';
  static const String token = 'tslog_9f3a7c21d84b6e5f0a1c';

  static const _kLastSent = 'ts_log_sent_at';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    headers: {'X-TS-Token': token},
    validateStatus: (s) => s != null && s < 500,
  ));

  int? _cursor;
  String? _lastError;
  DateTime? _lastOkAt;
  int _lastCount = 0;

  String? get lastError => _lastError;
  DateTime? get lastOkAt => _lastOkAt;
  int get lastCount => _lastCount;

  /// 把本地未上报的日志推到服务器。
  ///
  /// 返回 true 表示服务器收下了（游标已前移）。
  /// 任何失败都吞掉——日志上报不该影响用户。
  Future<bool> reportNow({int maxEntries = 800}) async {
    try {
      await AppLog.instance.init();
      if (!AppLog.instance.ready) return false;

      final since = await _readCursor();
      final all = await AppLog.instance.readDays(3);
      final pending = all
          .where((e) => e.at.millisecondsSinceEpoch > since)
          .toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (pending.isEmpty) {
        _lastOkAt = DateTime.now();
        _lastCount = 0;
        return true;
      }

      final batch = pending.length > maxEntries
          ? pending.sublist(pending.length - maxEntries)
          : pending;

      final res = await _dio.post<dynamic>(
        '$base/report',
        data: jsonEncode({
          ...AppLog.instance.deviceInfo(),
          'sentAt': DateTime.now().millisecondsSinceEpoch,
          'entries': batch.map((e) => e.toJson()).toList(),
        }),
      );
      final body = _asMap(res.data);
      if (res.statusCode == 200 && body != null && body['ok'] == true) {
        await _writeCursor(batch.last.at.millisecondsSinceEpoch);
        _lastOkAt = DateTime.now();
        _lastError = null;
        _lastCount = batch.length;
        return true;
      }
      _lastError = _explain(res.statusCode, body);
      return false;
    } catch (e) {
      _lastError = '$e';
      return false;
    }
  }

  Future<int> _readCursor() async {
    if (_cursor != null) return _cursor!;
    try {
      final sp = await SharedPreferences.getInstance();
      _cursor = sp.getInt(_kLastSent) ?? 0;
    } catch (_) {
      _cursor = 0;
    }
    return _cursor!;
  }

  Future<void> _writeCursor(int ms) async {
    _cursor = ms;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kLastSent, ms);
    } catch (_) {}
  }

  /// 服务器上都有哪些设备回传过
  Future<List<RemoteDevice>> listDevices() async {
    final res = await _dio.get<dynamic>('$base/list');
    final body = _asMap(res.data);
    if (body == null || body['ok'] != true) {
      throw Exception(_explain(res.statusCode, body));
    }
    final list = (body['devices'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => RemoteDevice.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 拉某台设备最近的日志（新的在前）
  Future<List<LogEntry>> fetchTail(String deviceId, {int limit = 300}) async {
    final res = await _dio.get<dynamic>(
      '$base/tail',
      queryParameters: {'device': deviceId, 'limit': limit},
    );
    final body = _asMap(res.data);
    if (body == null || body['ok'] != true) {
      throw Exception(_explain(res.statusCode, body));
    }
    final list = (body['entries'] as List?) ?? const [];
    final out = list
        .whereType<Map>()
        .map((e) => LogEntry.fromJson(e.cast<String, dynamic>()))
        .toList();
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  /// 整台设备的全量日志（纯文本，直接交给 AI 分析）
  Future<String> fetchExport(String deviceId) async {
    final res = await _dio.get<dynamic>(
      '$base/export',
      queryParameters: {'device': deviceId},
      options: Options(responseType: ResponseType.plain),
    );
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return '${res.data}';
  }

  static Map<String, dynamic>? _asMap(Object? data) {
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String) {
      try {
        final m = jsonDecode(data);
        if (m is Map) return m.cast<String, dynamic>();
      } catch (_) {}
    }
    return null;
  }

  String _explain(int? code, Map<String, dynamic>? body) {
    if (code == 401 || code == 403) return '鉴权失败（token 不对）';
    if (code == 404) return '服务器上没有这个接口（nginx 没配 /tingshu-log/）';
    if (body != null && body['error'] != null) return '${body['error']}';
    return 'HTTP $code';
  }
}

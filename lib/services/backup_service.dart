import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_wipe.dart';
import 'library.dart';
import 'update_service.dart';

/// 书架 + 设置的自动备份。
///
/// ## 为什么需要
///
/// 手机更新版本后出现过"书架空了、配置回到刚装好"的情况。
/// 应用自己的更新流程不删数据，但有些环境（典型是鸿蒙上的「卓易通」
/// 这类安卓兼容层）升级时会把整包重装，私有目录跟着清空——
/// 数据在用户眼里就是"更新完变新机"。
///
/// ## 放在哪
///
/// 公共下载目录 `下载/听评书/听评书-备份.json`（Android 10+ 用 MediaStore，
/// 不需要任何权限）。放公共目录的唯一原因就是**它能活过重装**。
///
/// ## 备份什么
///
/// 书架（含每本听到第几回、听到第几秒）、"听过"清单、
/// 首次配置是否完成、播放源、夸克选的书目录、更新通道。
///
/// **不备份夸克 Cookie**：那是账号凭证，落到公共目录等于把账号摆在明面上。
/// 重装后重新登录一次即可（书架和进度都还在）。
///
/// ## 什么时候恢复
///
/// 只在"本地磁盘上本来什么都没有"时自动恢复（`Library.hadStoredState == false`）。
/// 用户自己清空书架后不会被旧备份"复活"。
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const _ch = MethodChannel('tingshu/backup');

  /// 备份格式版本。以后加字段时靠它判断兼容性。
  static const _format = 1;

  /// 两次写盘的最小间隔。播放时进度几秒一存，不节流会把闪存写坏。
  static const _minInterval = Duration(minutes: 2);

  bool _busy = false;
  DateTime? _lastSave;
  bool _restored = false;

  DateTime? get lastSave => _lastSave;

  /// 这次启动是不是刚从备份恢复过（设置页用来给一句提示）
  bool get restoredThisLaunch => _restored;

  void init() {
    Library.instance.onPersisted = schedule;
  }

  /// 有变化就排一次备份；频率由 [_minInterval] 控制。
  void schedule() {
    if (AppWipe.wiping) return;
    final now = DateTime.now();
    final last = _lastSave;
    if (last != null && now.difference(last) < _minInterval) return;
    unawaited(saveNow());
  }

  /// 立刻写一份备份。返回 false 表示写失败（权限/存储满），不抛异常。
  Future<bool> saveNow() async {
    if (AppWipe.wiping) return false;
    // 还没配置完、书架也空，没东西可备份，别在公共目录留个空文件
    if (!Library.instance.setupDone && Library.instance.shelf.isEmpty) return false;
    // 书架现在是空的，而旧备份里还有书：**别覆盖**。
    // 这正是"数据被清空后第一次启动"的情形——一写就把唯一能救回书的备份抹掉。
    if (Library.instance.shelf.isEmpty) {
      final existing = await peek();
      if (existing != null && existing.books > 0) {
        debugPrint('[backup] 当前书架为空，保留已有备份（${existing.books} 部）');
        return false;
      }
    }
    if (_busy) return false;
    _busy = true;
    try {
      final payload = <String, dynamic>{
        'format': _format,
        'app': 'tingshu',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'version': UpdateService.instance.versionLabel,
        'channel': UpdateService.instance.channel.name,
        'library': Library.instance.exportState(),
      };
      final ok = await _ch.invokeMethod<bool>('write', {
        'text': jsonEncode(payload),
      }) ??
          false;
      if (ok) _lastSave = DateTime.now();
      debugPrint('[backup] 写入备份 ${ok ? "成功" : "失败"}');
      return ok;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }

  /// 公共备份的存在情况：有没有、什么时候写的。
  Future<({bool exists, DateTime? at})> info() async {
    try {
      final m = await _ch.invokeMethod<Map>('info');
      final exists = m?['exists'] == true;
      final ms = (m?['modified'] as num?)?.toInt() ?? 0;
      return (
        exists: exists,
        at: ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null,
      );
    } catch (_) {
      return (exists: false, at: null);
    }
  }

  /// 启动时调用：本地数据是空的、而公共目录里有备份，就恢复。
  ///
  /// 返回 true 表示恢复了。
  Future<bool> restoreIfFresh() => _restore(force: false);

  /// 设置页"从备份恢复"：用户明确要求，覆盖当前内容。
  Future<bool> restoreNow() => _restore(force: true);

  Future<bool> _restore({required bool force}) async {
    if (AppWipe.wiping) return false;
    // 本地本来有数据（哪怕书架是空的，只要配置标记在），一律不覆盖
    if (!force && Library.instance.hadStoredState) return false;

    String? raw;
    try {
      raw = await _ch.invokeMethod<String>('read');
      debugPrint('[backup] 读取公共备份：${raw == null ? "没有" : "${raw.length} 字节"}');
    } catch (e) {
      debugPrint('[backup] 读取失败：$e');
      return false;
    }
    if (raw == null || raw.trim().isEmpty) return false;

    Map<String, dynamic> map;
    try {
      map = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return false;
    }
    final libRaw = map['library'];
    if (libRaw is! Map) return false;
    final lib = libRaw.cast<String, dynamic>();

    // 备份里也没有实质内容（向导没走完、书架空），恢复它没有意义
    final shelf = lib['shelf'] as List? ?? const [];
    if (shelf.isEmpty && lib['setupDone'] != true) return false;

    try {
      await Library.instance.applyState(lib);
      final ch = map['channel'];
      if (ch == 'beta' || ch == 'stable') {
        await UpdateService.instance.setChannel(
          ch == 'beta' ? UpdateChannel.beta : UpdateChannel.stable,
        );
      }
      _restored = true;
      _lastSave = DateTime.now();
      return true;
    } catch (e) {
      debugPrint('[backup] 恢复失败：$e');
      return false;
    }
  }

  /// 瞄一眼备份里有多少部书（不恢复）。
  ///
  /// 用来在"书架是空的但备份里有书"时给用户一句提示——
  /// 这是数据丢失事故里最有用的那条线索。
  Future<({int books, DateTime? at})?> peek() async {
    String? raw;
    try {
      raw = await _ch.invokeMethod<String>('read');
    } catch (_) {
      return null;
    }
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final lib = (map['library'] as Map?)?.cast<String, dynamic>();
      final shelf = (lib?['shelf'] as List?) ?? const [];
      final ms = (map['savedAt'] as num?)?.toInt() ?? 0;
      return (
        books: shelf.length,
        at: ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// 删除公共目录里的备份（清除全部数据时用，否则清完又被恢复回来）
  Future<bool> deleteBackup() async {
    try {
      return await _ch.invokeMethod<bool>('delete') ?? false;
    } catch (_) {
      return false;
    }
  }
}

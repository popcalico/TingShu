import 'package:flutter/services.dart';

/// 清除全部本地数据（模拟新机）。
///
/// 给家属在设置页用：换人用、彻底重来、或者儿子把手机还给老人之前。
/// 清完原生会立刻重启进程，回到"第一次打开"的首次配置向导。
///
/// 清掉的是：书架、听到哪儿、已缓存的声音、夸克登录、更新设置、下载的安装包。
/// **不清**系统授权（通知、后台、安装未知应用），这些只能到系统设置里改。
class AppWipe {
  AppWipe._();

  static const _ch = MethodChannel('tingshu/wipe');

  /// 正在清除数据。
  ///
  /// 清除开始到界面重建之间，任何一次 SharedPreferences 写入都会把
  /// **内存里的旧数据整份写回磁盘**（Android 的 SharedPreferences 是整体序列化的），
  /// 结果就是"清完书架又回来了、设置项又变成已完成"。
  /// 所以清除期间把所有本地写入挡掉。
  static bool wiping = false;

  /// 返回 true 表示原生已开始清理并重建界面
  /// （正常情况下这个 Dart isolate 活不到下一帧）。
  /// 返回 false 表示原生侧失败，调用方要给出"去系统设置里清"的兜底提示。
  static Future<bool> clearAll() async {
    wiping = true;
    try {
      final ok = await _ch.invokeMethod<bool>('clearAll') ?? false;
      if (!ok) wiping = false;
      return ok;
    } catch (_) {
      wiping = false;
      return false;
    }
  }
}

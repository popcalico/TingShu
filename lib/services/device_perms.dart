import 'package:flutter/services.dart';

import 'notify_permission.dart';
import 'update_service.dart';

/// 装机时该配的权限，全部集中在这里查和申请。
///
/// **产品前提（很重要，改代码时别破坏）**：
/// 家人只在安装时配一次，之后老人独立使用。
/// 所以凡是需要系统授权的，必须在首次配置向导里一次问完，
/// 绝不能让老人后来自己去系统设置里翻——他们不会，也不敢。
///
/// 目前共三项：
/// 1. 通知权限（Android 13+）—— 锁屏和通知栏的播放控制全靠它
/// 2. 电池优化白名单 —— 不加的话锁屏几分钟就被系统杀后台
/// 3. 安装未知应用 —— 不加的话以后的自动更新装不上
class DevicePerms {
  DevicePerms._();

  static const _battery = MethodChannel('tingshu/battery');

  // ---------- 通知 ----------

  static Future<bool> notifyOk() => NotifyPermission.has();

  static Future<bool> requestNotify() => NotifyPermission.request();

  static Future<void> openNotifySettings() => NotifyPermission.openSettings();

  // ---------- 电池优化白名单 ----------

  static Future<bool> batteryOk() async {
    try {
      return await _battery.invokeMethod<bool>('isIgnoring') ?? false;
    } catch (_) {
      // 查不出来当作未允许，让用户在向导里点一次，最坏是多跳一次设置页
      return false;
    }
  }

  /// 弹系统"是否允许电池优化豁免"框。
  /// 这一步是系统页面，返回后要重新查 [batteryOk]。
  static Future<void> requestBattery() async {
    try {
      await _battery.invokeMethod('requestIgnore');
    } catch (_) {}
  }

  // ---------- 安装未知应用 ----------

  static Future<bool> installOk() => UpdateService.instance.canInstall();

  static Future<void> openInstallSettings() =>
      UpdateService.instance.openInstallPermission();

  // ---------- 汇总 ----------

  /// 三项是否都齐
  static Future<bool> allOk() async {
    final r = await Future.wait([notifyOk(), batteryOk(), installOk()]);
    return r.every((e) => e);
  }

  /// 还差几项（首页/设置页用来提示）
  static Future<int> missingCount() async {
    final r = await Future.wait([notifyOk(), batteryOk(), installOk()]);
    return r.where((e) => !e).length;
  }
}

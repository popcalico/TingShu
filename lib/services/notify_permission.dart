import 'package:flutter/services.dart';

/// 通知权限（Android 13 起是运行时权限）。
///
/// 这一项对老人特别关键：没授权时系统完全不显示通知，
/// 锁屏上也就没有任何播放控件，只能靠解锁进 App 才能暂停，
/// 而老人往往不知道怎么回来，会以为"坏了"。
class NotifyPermission {
  NotifyPermission._();

  static const _ch = MethodChannel('tingshu/notify');

  /// 是否已授权。Android 12 及以下恒为 true（不需要运行时授权）。
  static Future<bool> has() async {
    try {
      return await _ch.invokeMethod<bool>('has') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 弹系统授权框。返回授权后的真实状态。
  static Future<bool> request() async {
    try {
      return await _ch.invokeMethod<bool>('request') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 启动时调一次：没权限才申请，有权限立即返回，不打扰。
  static Future<void> requestOnce() async {
    if (await has()) return;
    await request();
  }

  /// 打开系统的本应用通知设置页。
  /// 用户第一次点了"不允许"之后，系统不再弹框，只能靠这条路径引导。
  static Future<void> openSettings() async {
    try {
      await _ch.invokeMethod('openSettings');
    } catch (_) {}
  }

  /// 发一条测试通知（和播放通知用同一个渠道）。
  ///
  /// 能看到 → 通知权限和渠道都正常，问题在媒体会话侧；
  /// 看不到 → 通知根本没被系统放出来，先解决权限/渠道/ROM 拦截。
  static Future<bool> sendTest() async {
    try {
      return await _ch.invokeMethod<bool>('test') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 媒体控件自检：返回系统版本、通知权限、通知总开关、
  /// "评书播放"这个通知类别是否被关掉。
  ///
  /// 通知栏/锁屏没有播放控制时，原因可能是四种里的一种：
  /// 通知权限没给、通知总开关被关、播放类别被关、系统把媒体控件藏了。
  /// 这里把前三种都查出来，剩下的才归到 ROM 身上。
  static Future<MediaCheckResult> diagnose() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('diagnose');
      if (r == null) return const MediaCheckResult.unknown();
      return MediaCheckResult(
        sdk: (r['sdk'] as num?)?.toInt() ?? 0,
        brand: '${r['brand'] ?? ''}',
        model: '${r['model'] ?? ''}',
        permission: r['permission'] == true,
        enabled: r['enabled'] == true,
        channelExists: r['channelExists'] == true,
        channelImportance: (r['channelImportance'] as num?)?.toInt() ?? -1,
      );
    } catch (_) {
      return const MediaCheckResult.unknown();
    }
  }
}

/// 自检结果。[channelImportance] 为 0（IMPORTANCE_NONE）表示类别被关。
class MediaCheckResult {
  const MediaCheckResult({
    required this.sdk,
    required this.brand,
    required this.model,
    required this.permission,
    required this.enabled,
    required this.channelExists,
    required this.channelImportance,
  });

  const MediaCheckResult.unknown()
      : sdk = 0,
        brand = '',
        model = '',
        permission = false,
        enabled = false,
        channelExists = false,
        channelImportance = -1;

  final int sdk;
  final String brand;
  final String model;
  final bool permission;
  final bool enabled;
  final bool channelExists;
  final int channelImportance;

  /// 三项都正常才算"就绪"：重要性低于 DEFAULT 时，很多国产 ROM
  /// 会在锁屏和通知栏上直接不给媒体按钮，所以也算没配好。
  bool get ok =>
      permission && enabled && (!channelExists || channelImportance >= 3);

  /// 渠道路重要性低于 DEFAULT(3) 时，国产 ROM 常把通知当"次要提示"：
  /// 锁屏不显示、通知栏不给按钮。这正是"媒体控件不好使"的常见原因。
  bool get channelLow => channelExists && channelImportance > 0 && channelImportance < 3;

  String get channelLevel {
    if (!channelExists) return '还没创建（放一次就会创建）';
    return switch (channelImportance) {
      0 => '已关闭',
      1 => '最低（基本不显示）',
      2 => '低（锁屏可能不显示）',
      3 => '默认',
      4 => '高',
      5 => '最高',
      _ => '未知',
    };
  }

  String get androidLabel {
    if (sdk == 0) return '未知';
    return 'Android $sdk';
  }

  String get deviceLabel {
    final s = '$brand $model'.trim();
    return s.isEmpty ? '未知机型' : s;
  }

  bool get channelBlocked => channelExists && channelImportance == 0;

  /// 给用户看的一句话结论
  String get advice {
    if (!permission) return '通知权限没打开，播放控制不会出现。点下面按钮去打开。';
    if (!enabled) return '本应用的通知总开关被关掉了，播放控制不会出现。点下面按钮去打开。';
    if (channelBlocked) return '“评书播放”这个通知类别被关掉了，请把它重新打开。';
    if (channelLow) {
      return '“评书播放”的通知重要性被设成了“低”，锁屏和通知栏可能不显示播放按钮。'
          '请到通知设置里把它调成“默认”或“高”。';
    }
    if (!ok) return '系统信息读取失败，可以点下面按钮看一眼通知设置。';
    return '通知权限正常。如果锁屏仍看不到播放控制，请在本机“通知管理 → 锁屏通知”里允许本应用，并把电池限制设为“不限制”。';
  }
}

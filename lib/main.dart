import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'core/network/bili_client.dart';
import 'core/theme/ting_theme.dart';
import 'pages/home_page.dart';
import 'pages/setup_page.dart';
import 'player/ting_audio_handler.dart';
import 'player/ting_player.dart';
import 'services/app_log.dart';
import 'services/backup_service.dart';
import 'services/log_reporter.dart';
import 'services/cache/cache_engine.dart';
import 'services/library.dart';
import 'services/nas/nas_source.dart';
import 'services/quark/quark_api.dart';
import 'services/update_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 日志要在一切之前起来：后面任何一处出错都要能记下来。
  // init 自己会吞掉所有异常，不会因为日志挂掉拖住启动。
  await AppLog.instance.init();
  _installErrorHandlers();
  AppLog.instance.event('app.start', 'App 启动', data: {
    'version': AppLog.instance.versionName,
    'code': AppLog.instance.versionCode,
    'model': AppLog.instance.model,
  });
  // 老人用手机几乎都是竖着拿，锁竖屏，避免画面转来转去
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  MediaKit.ensureInitialized();

  // 媒体会话必须在界面起来之前建好，且要包一层 AudioServiceWidget：
  // 通知栏/锁屏的控件全部挂在媒体会话上，会话建得晚，第一回播放就没有通知，
  // 点通知也回不到 App（这是"通知栏没内容"的两个直接原因）。
  final handler = await _initAudioService();
  runApp(AudioServiceWidget(child: TingApp(audioHandler: handler)));

  // 启动后 4 秒把上次没发出去的日志推上去。
  // 放延迟是为了不和启动抢网络/CPU——老人开机就想听书，不能被上报拖慢。
  unawaited(Future<void>.delayed(const Duration(seconds: 4), () async {
    final ok = await LogReporter.instance.reportNow();
    AppLog.instance.event('log.report', ok ? '启动上报完成' : '启动上报未成功');
  }));
}

/// 把崩溃记进日志。老人手机上出问题，光看"闪退了"没法定位，
/// 至少要留下异常栈的前几行。
void _installErrorHandlers() {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.instance.error(
      'crash.flutter',
      details.exceptionAsString(),
      data: {
        'stack': details.stack?.toString().split('\n').take(6).join(' | '),
        if (details.library != null) 'where': details.library,
      },
    );
    prev?.call(details);
  };

  WidgetsBinding.instance.platformDispatcher.onError = (e, st) {
    AppLog.instance.error(
      'crash.platform',
      '$e',
      data: {'stack': st.toString().split('\n').take(6).join(' | ')},
    );
    return true;
  };
}

/// 建立系统媒体会话。失败不阻断使用——前台照样能出声，只是锁屏没控件。
Future<BaseAudioHandler?> _initAudioService() async {
  try {
    final handler = await AudioService.init(
      builder: () => TingAudioHandler(),
      config: const AudioServiceConfig(
        // 渠道 ID 必须和 MainActivity.ensureAudioChannel() 里的一致。
        // 用 v2 是因为 v1 被插件建成了 IMPORTANCE_LOW，而 Android 不允许
        // 改已有渠道的重要性——只能换新渠道，否则永远升不上来。
        androidNotificationChannelId: 'cn.tingshu.audio.v2',
        androidNotificationChannelName: '评书播放',
        androidNotificationChannelDescription: '正在播放的评书，可暂停、上一回、下一回',
        // 必须是纯白剪影的单色图标，用彩色 launcher 图标在多数机型上会显示成白块
        androidNotificationIcon: 'drawable/ic_stat_tingshu',
        // 暂停时不退出前台服务：暂停后通知必须还在，老人才能一键继续。
        // （androidNotificationOngoing 要求 stopForegroundOnPause=true，
        //   那会让"暂停即消失通知"，对老人是倒退，所以不用 ongoing。）
        androidStopForegroundOnPause: false,
        androidNotificationClickStartsActivity: true,
        androidResumeOnClick: true,
        // 通知/锁屏封面压到 400px：B 站原图动辄两三千像素，
        // 低端机解码大图会直接 OOM 闪退。
        artDownscaleWidth: 400,
        artDownscaleHeight: 400,
        // 和播放页的 ±15 秒保持一致
        rewindInterval: Duration(seconds: 15),
        fastForwardInterval: Duration(seconds: 15),
      ),
    );
    TingPlayer.instance.attachHandler(handler);
    return handler;
  } catch (e) {
    debugPrint('[audio_service] 初始化失败：$e');
    return null;
  }
}

class TingApp extends StatelessWidget {
  const TingApp({super.key, this.audioHandler});

  final BaseAudioHandler? audioHandler;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '听评书',
      debugShowCheckedModeBanner: false,
      theme: buildTingTheme(),
      home: const BootPage(),
      builder: (context, child) {
        // 字号本身已经放大过，若系统再放大到 2 倍会把布局撑坏，
        // 这里把系统放大倍数限制在 1.25 以内
        final mq = MediaQuery.of(context);
        final scale = mq.textScaler.scale(1.0).clamp(1.0, 1.25);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(scale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

/// 启动页：把本地数据读起来再进首页。
///
/// 每一步都有超时和容错——任何一项失败都照常进首页，
/// 不能因为网络或某个存储读不出来就把老人卡在白屏上。
class BootPage extends StatefulWidget {
  const BootPage({super.key});

  @override
  State<BootPage> createState() => _BootPageState();
}

class _BootPageState extends State<BootPage> with WidgetsBindingObserver {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 本地数据如果比启动等待更晚读完，也要能自己刷出来——
    // 不能因为"那一刻还没读完"就把用户丢进首次配置向导。
    Library.instance.addListener(_onLibrary);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Library.instance.removeListener(_onLibrary);
    super.dispose();
  }

  void _onLibrary() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台/锁屏时立刻存进度，防止进程被系统回收丢位置
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      unawaited(TingPlayer.instance.saveNow());
      // 退到后台顺手把书架存一份到公共目录：进程随时可能被系统杀掉，
      // 这就是"最后一次可靠落盘"。
      unawaited(BackupService.instance.saveNow());
    }
  }

  Future<void> _boot() async {
    // 本地数据单独 await（带一次重试），不跟其它服务挤在一个总超时里。
    //
    // 之前是四件事一起 `Future.wait(...).timeout(8s)`：升级后第一次启动要
    // dexopt，很容易超过 8 秒。超时后界面判定"没配置过"，直接弹首次向导，
    // 用户一按"跳过"就把**还没读进来的空书架**写回磁盘——真数据就这么没了。
    // 现在：书架没读完就不往下走，`Library._save` 也加了 `_ready` 守卫。
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await Library.instance.load().timeout(const Duration(seconds: 10));
        if (Library.instance.ready) break;
      } catch (_) {}
    }

    try {
      await Future.wait([
        QuarkApi.instance.load(),
        NasSource.instance.load(),
        CacheEngine.instance.load(),
        UpdateService.instance.load(),
      ]).timeout(const Duration(seconds: 8));
    } catch (_) {}

    try {
      await BiliClient.instance.initLocal().timeout(const Duration(seconds: 5));
    } catch (_) {}

    // 书架/设置的备份：先挂上"有变化就存一份"的钩子，
    // 再看本地是不是空的（重装、换机、被清过）——是的话从公共目录恢复。
    // 恢复失败不影响启动，照常进首页/向导。
    BackupService.instance.init();
    try {
      await BackupService.instance
          .restoreIfFresh()
          .timeout(const Duration(seconds: 3));
    } catch (_) {}

    // 装完新版本第一次打开就补一份备份：万一这次升级把数据清了，
    // 用户还有下一份能恢复的东西（限频在服务里，一次启动最多写一次）。
    BackupService.instance.schedule();

    // 清掉旧版本留下的安装包（每个 36MB，不清理会越堆越多）。
    // 不 await，不阻塞启动。
    unawaited(UpdateService.instance.cleanupOldPacks());

    // 通知权限不再在这里静默申请——统一交给首次配置向导，
    // 让家属在同一页里把通知、后台、安装三项一次配完。

    if (!mounted) return;
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: TingColors.bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '听评书',
                style: TextStyle(
                  fontSize: 46,
                  fontWeight: FontWeight.w700,
                  color: TingColors.primary,
                  letterSpacing: 6,
                ),
              ),
              SizedBox(height: 30),
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3, color: TingColors.primary),
              ),
            ],
          ),
        ),
      );
    }
    // 数据还没读完就先留在启动页：这时候 setupDone 一定是 false，
    // 放进去等于把"还没读到"误判成"没配置过"。
    if (!Library.instance.ready) {
      return const Scaffold(
        backgroundColor: TingColors.bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '听评书',
                style: TextStyle(
                  fontSize: 46,
                  fontWeight: FontWeight.w700,
                  color: TingColors.primary,
                  letterSpacing: 6,
                ),
              ),
              SizedBox(height: 30),
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3, color: TingColors.primary),
              ),
            ],
          ),
        ),
      );
    }
    if (!Library.instance.setupDone) return const SetupPage();
    return const HomePage();
  }
}

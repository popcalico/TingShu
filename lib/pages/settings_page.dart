import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/ting_theme.dart';
import '../player/ting_player.dart';
import '../services/app_wipe.dart';
import '../services/backup_service.dart';
import '../services/cache/cache_engine.dart';
import '../services/device_perms.dart';
import '../services/library.dart';
import '../services/nas/nas_source.dart';
import '../services/notify_permission.dart';
import '../services/play_diagnose.dart';
import '../services/quark/quark_api.dart';
import '../services/update_service.dart';
import '../widgets/common.dart';
import 'add_page.dart';
import 'nas_settings_page.dart';
import 'quark_login_page.dart';
import 'setup_page.dart';
import '../widgets/update_prompt.dart';

/// 设置（家属用）：只在需要配置时进来一次，老人平时不会看到这一页。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    _refreshPerms();
    _refreshBackup();
  }

  /// 公共目录里那份备份：有没有、什么时候写的
  bool _backupExists = false;
  DateTime? _backupAt;

  Future<void> _refreshBackup() async {
    final info = await BackupService.instance.info();
    if (!mounted) return;
    setState(() {
      _backupExists = info.exists;
      _backupAt = info.at;
    });
  }

  String get _backupText {
    if (!_backupExists) return '还没备份';
    final at = _backupAt;
    if (at == null) return '已备份';
    final now = DateTime.now();
    final sameDay = now.year == at.year && now.month == at.month && now.day == at.day;
    final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return sameDay ? '今天 $hm' : '${at.month}月${at.day}日 $hm';
  }

  bool _ignoringBattery = false;
  bool _notifyOk = true;
  bool _installOk = true;

  /// 媒体控件自检结果（通知权限 / 总开关 / 播放类别）
  MediaCheckResult? _check;

  /// 三项系统权限统一从这里刷新，避免每个开关各查一遍、状态还不一致
  Future<void> _refreshPerms() async {
    final r = await Future.wait([
      DevicePerms.notifyOk(),
      DevicePerms.batteryOk(),
      DevicePerms.installOk(),
    ]);
    final check = await NotifyPermission.diagnose();
    if (!mounted) return;
    setState(() {
      _notifyOk = r[0];
      _ignoringBattery = r[1];
      _installOk = r[2];
      _check = check;
    });
  }

  /// 通知栏/锁屏没控件时，先把"是哪一环没开"查清楚，别让用户瞎试
  Future<void> _mediaCheck() async {
    final d = await NotifyPermission.diagnose();
    if (!mounted) return;
    setState(() => _check = d);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '媒体控件自检',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _checkLine('机型', '${d.deviceLabel} · ${d.androidLabel}'),
              _checkLine('通知权限', d.permission ? '已允许' : '未允许'),
              _checkLine('通知总开关', d.enabled ? '开着' : '被关掉了'),
              _checkLine(
                '“评书播放”类别',
                d.channelLevel,
              ),
              const SizedBox(height: 12),
              Text(
                d.advice,
                style: const TextStyle(fontSize: 16, height: 1.55, color: TingColors.muted),
              ),
              const SizedBox(height: 12),
              const Text(
                '如果是用「卓易通」在鸿蒙手机上运行本应用：系统控制中心不会显示'
                '安卓播放器，这是兼容层的限制，应用内改不了。'
                '这种情况下只能用应用内的播放页按钮。',
                style: TextStyle(fontSize: 15, height: 1.5, color: TingColors.muted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final sent = await NotifyPermission.sendTest();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(sent
                      ? '已经发了一条通知，看看通知栏有没有'
                      : '通知发不出去，说明系统把通知拦了'),
                ),
              );
            },
            child: const Text('发测试通知'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              DevicePerms.openNotifySettings();
            },
            child: const Text('去通知设置'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  Widget _checkLine(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 124,
              child: Text(k, style: const TextStyle(fontSize: 15, color: TingColors.muted)),
            ),
            Expanded(
              child: Text(
                v,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.3),
              ),
            ),
          ],
        ),
      );


  @override
  Widget build(BuildContext context) {
    final lib = Library.instance;
    final cache = CacheEngine.instance;
    // 测试版才显示调试项（清数据、控件自检、重做向导）。
    // 家里老人用的标准版不该看到这些——点错了就是灾难。
    final beta = UpdateService.instance.channel == UpdateChannel.beta;

    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([lib, cache]),
          builder: (context, _) {
            return Column(
              children: [
                const TingBar(title: '设置'),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 24),
                    children: [
                      _section('夸克网盘'),
                      BigRow(
                        title: '登录状态',
                        icon: Icons.account_circle_outlined,
                        value: QuarkApi.instance.hasLogin ? '已连接' : '未连接',
                        valueColor: QuarkApi.instance.hasLogin ? TingColors.done : TingColors.warn,
                        onTap: () async {
                          if (QuarkApi.instance.hasLogin) {
                            await QuarkApi.instance.logout();
                            setState(() {});
                          } else {
                            await Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const QuarkLoginPage()),
                            );
                            setState(() {});
                          }
                        },
                      ),
                      const SizedBox(height: 10),
                      BigRow(
                        title: '评书文件夹',
                        icon: Icons.folder_rounded,
                        value: lib.quarkConfigured ? _shortFolder(lib.quarkRootName) : '未选择',
                        onTap: () async {
                          if (!QuarkApi.instance.hasLogin) {
                            await Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const QuarkLoginPage()),
                            );
                            if (!mounted) return;
                          }
                          if (!QuarkApi.instance.hasLogin) return;
                          await pickQuarkFolder(context);
                          setState(() {});
                        },
                      ),
                      if (beta) ...[
                        const SizedBox(height: 22),
                        _section('家里的 NAS（测试版）'),
                        BigRow(
                          title: '连接状态',
                          icon: Icons.dns_rounded,
                          value: NasSource.instance.configured
                              ? '已设置 · ${NasSource.instance.rootName}'
                              : '未设置',
                          valueColor: NasSource.instance.configured
                              ? TingColors.done
                              : TingColors.warn,
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const NasSettingsPage()),
                            );
                            setState(() {});
                          },
                        ),
                      ],
                      const SizedBox(height: 22),

                      _section('手机存储'),
                      BigRow(
                        title: '听过的声音占空间',
                        icon: Icons.sd_storage_rounded,
                        value: '${fmtBytes(cache.usedBytes)} / 10 G',
                        onTap: () => _confirmClearCache(),
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: cache.usedRatio,
                            minHeight: 12,
                            backgroundColor: TingColors.line,
                            color: TingColors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '边听边存，最多存 10G。存满以后自动删掉最早听过的那几回，'
                          '最近听过的会留着，重听不用再下载。',
                          style: TextStyle(fontSize: 15, height: 1.5, color: TingColors.muted),
                        ),
                      ),
                      const SizedBox(height: 14),
                      BigRow(
                        title: '书架备份',
                        icon: Icons.backup_outlined,
                        value: _backupText,
                        valueColor: _backupExists ? TingColors.done : TingColors.muted,
                        onTap: _showBackup,
                      ),
                      const SizedBox(height: 22),

                      _section('版本与更新'),
                      BigRow(
                        title: '当前版本',
                        icon: Icons.info_outline_rounded,
                        value: UpdateService.instance.versionLabel,
                        onTap: () => _checkUpdate(),
                      ),
                      const SizedBox(height: 10),
                      BigRow(
                        title: '更新通道',
                        icon: Icons.swap_vert_rounded,
                        value: UpdateService.instance.channelLabel,
                        valueColor: UpdateService.instance.channel == UpdateChannel.beta
                            ? TingColors.primary
                            : TingColors.done,
                        onTap: () => _pickChannel(),
                      ),
                      const SizedBox(height: 10),
                      BigRow(
                        title: '更新地址',
                        icon: Icons.link_rounded,
                        value: UpdateService.instance.hasCustomUrl ? '手动设置' : '默认',
                        valueColor: UpdateService.instance.hasCustomUrl
                            ? TingColors.primary
                            : TingColors.done,
                        onTap: () => _editUpdateUrl(),
                      ),
                      const SizedBox(height: 10),
                      BigRow(
                        title: '打开时自动检查更新',
                        icon: Icons.system_update_alt_rounded,
                        value: UpdateService.instance.autoCheck ? '开' : '关',
                        onTap: () async {
                          await UpdateService.instance
                              .setAutoCheck(!UpdateService.instance.autoCheck);
                          setState(() {});
                        },
                      ),
                      const SizedBox(height: 22),

                      _section('锁屏后别被系统停掉'),
                      BigRow(
                        title: '通知栏显示播放控制',
                        icon: Icons.notifications_active_rounded,
                        value: _notifyOk ? '已允许' : '未允许',
                        valueColor: _notifyOk ? TingColors.done : TingColors.warn,
                        onTap: () async {
                          if (_notifyOk) {
                            await DevicePerms.openNotifySettings();
                          } else {
                            await DevicePerms.requestNotify();
                            await _refreshPerms();
                            // 拒过一次后系统不再弹框，只能带去设置页
                            if (!_notifyOk) await DevicePerms.openNotifySettings();
                            await _refreshPerms();
                          }
                        },
                      ),
                      if (beta) ...[
                        const SizedBox(height: 10),
                        BigRow(
                          title: '媒体控件自检',
                          icon: Icons.health_and_safety_outlined,
                          value: (_check?.ok ?? false) ? '正常' : '点一下检查',
                          valueColor: (_check?.ok ?? false) ? TingColors.done : TingColors.warn,
                          onTap: _mediaCheck,
                        ),
                      ],
                      const SizedBox(height: 10),
                      BigRow(
                        title: '允许后台一直播放',
                        icon: Icons.battery_saver_rounded,
                        value: _ignoringBattery ? '已允许' : '未设置',
                        valueColor: _ignoringBattery ? TingColors.done : TingColors.warn,
                        onTap: () async {
                          await DevicePerms.requestBattery();
                          await Future.delayed(const Duration(milliseconds: 600));
                          _refreshPerms();
                        },
                      ),
                      const SizedBox(height: 10),
                      BigRow(
                        title: '允许安装新版本',
                        icon: Icons.system_update_alt_outlined,
                        value: _installOk ? '已允许' : '未允许',
                        valueColor: _installOk ? TingColors.done : TingColors.warn,
                        onTap: () async {
                          await DevicePerms.openInstallSettings();
                          await Future.delayed(const Duration(milliseconds: 600));
                          _refreshPerms();
                        },
                      ),
                      if (beta) ...[
                        const SizedBox(height: 22),
                        _section('调试（只在测试版显示）'),
                        BigRow(
                          title: '重新做一遍初始设置',
                          icon: Icons.restart_alt_rounded,
                          value: Library.instance.setupDone ? '已配置' : '未完成',
                          onTap: () async {
                            await Library.instance.resetSetup();
                            if (!mounted) return;
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const SetupPage()),
                            );
                          },
                        ),
                        const SizedBox(height: 10),
                        BigRow(
                          title: '播放诊断',
                          icon: Icons.troubleshoot_rounded,
                          value: '点一下检查',
                          onTap: _diagnosePlay,
                        ),
                        const SizedBox(height: 10),
                        BigRow(
                          title: '清除全部数据',
                          icon: Icons.delete_forever_rounded,
                          value: '模拟新机',
                          valueColor: TingColors.warn,
                          onTap: _wipeAll,
                        ),
                      ],
                      const SizedBox(height: 30),

                      Center(
                        child: Text(
                          '听评书  ${UpdateService.instance.versionLabel}\n只为听评书做的',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.6,
                            color: TingColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _checkUpdate() async {
    final svc = UpdateService.instance;
    if (!svc.configured) {
      await _editUpdateUrl();
      if (!svc.configured) return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在检查更新…')));

    try {
      final info = await svc.fetchLatest();
      if (!mounted) return;
      if (info == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('服务器返回的内容看不懂，检查一下 version.json 格式')),
        );
        return;
      }
      if (info.versionCode <= svc.currentCode) {
        messenger.showSnackBar(
          SnackBar(content: Text('已经是最新版本 ${svc.currentName}')),
        );
        return;
      }
      await UpdatePrompt.show(context, info);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('检查失败：${'$e'.replaceFirst('Exception: ', '')}')),
      );
    }
  }

  /// 选版本线。
  ///
  /// 默认标准版——家里老人那台必须留在只推稳定版的线上。
  /// 自己的设备手动切测试版，改完就能收到。
  Future<void> _pickChannel() async {
    final svc = UpdateService.instance;
    final picked = await showDialog<UpdateChannel>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更新通道', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in [UpdateChannel.stable, UpdateChannel.beta])
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  c == UpdateChannel.beta ? '测试版' : '标准版',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  c == UpdateChannel.beta ? '改完就推，可能不稳。给自己手机用' : '只放验证过的版本。给家里老人用',
                  style: const TextStyle(fontSize: 15, height: 1.4),
                ),
                trailing: svc.channel == c
                    ? const Icon(Icons.check_circle_rounded, color: TingColors.primary, size: 26)
                    : null,
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
    if (picked == null || picked == svc.channel) return;
    await svc.setChannel(picked);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切到${picked == UpdateChannel.beta ? '测试版' : '标准版'}')),
    );
    // 切换后立刻查一次，省得用户还要手动点"当前版本"
    await _checkUpdate();
  }

  Future<void> _editUpdateUrl() async {
    final ctrl = TextEditingController(text: UpdateService.instance.manifestUrl);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更新地址', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '一般不用改。填了就会盖过"更新通道"，用这个地址。\n默认：${UpdateService.stableManifestUrl}',
              style: const TextStyle(fontSize: 15, height: 1.5, color: TingColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 3,
              minLines: 1,
              autocorrect: false,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 16),
              decoration: const InputDecoration(
                hintText: 'https://',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('恢复默认'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (saved == null) return;
    await UpdateService.instance.setManifestUrl(saved);
    if (mounted) setState(() {});
  }

  /// 网盘文件夹名可能极长（"(033)评书大全180G+10大名家+3714集"），
  /// 整串塞进设置行会把布局撑坏。这里保留头尾，中间省略。
  /// 完整名字在选文件夹的弹窗里能看到。
  String _shortFolder(String name) {
    if (name.length <= 16) return name;
    return '${name.substring(0, 9)}…${name.substring(name.length - 6)}';
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: TingColors.muted,
            letterSpacing: 1,
          ),
        ),
      );

  Future<void> _confirmClearCache() async {
    final cache = CacheEngine.instance;
    if (cache.usedBytes <= 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空已存的声音？', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        content: Text(
          '会删掉 ${fmtBytes(cache.usedBytes)} 已下载的声音，书和听到哪儿不会丢。',
          style: const TextStyle(fontSize: T.fontBody, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('不了')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: TingColors.warn)),
          ),
        ],
      ),
    );
    if (ok == true) await cache.clearAll();
  }

  // ---------- 播放诊断 ----------

  /// 挑一本"最可能是出问题的那本"：正在播的 → 最近听的 → 书架第一本。
  Future<void> _diagnosePlay() async {
    final p = TingPlayer.instance;
    var book = p.book;
    var chapter = p.chapter;
    if (book == null || chapter == null) {
      final shelf = Library.instance.shelf;
      ShelfItem? pick = Library.instance.current;
      if (pick == null || pick.book.chapters.isEmpty) {
        pick = null;
        for (final e in shelf) {
          if (e.book.chapters.isNotEmpty) {
            pick = e;
            break;
          }
        }
      }
      if (pick == null || pick.book.chapters.isEmpty) {
        _toast('书架上还没有书，先加一本再诊断');
        return;
      }
      book = pick.book;
      chapter = pick.chapter ?? pick.book.chapters.first;
    }

    final targetBook = book!;
    final targetChapter = chapter!;
    // 注意：这里不能 await——等待框要一直挂着，直到诊断跑完再手动 pop。
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在检查…', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        content: const SizedBox(
          height: 90,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    ));
    final text = await PlayDiagnose.run(targetBook, targetChapter);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('播放诊断', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('已复制，发给家人看')),
              );
            },
            child: const Text('复制'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------- 书架备份 ----------

  Future<void> _showBackup() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '书架备份',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '书架和"听到哪儿"会自动存一份到：\n'
          '文件管理 → 下载 → 听评书 → 听评书-备份.json\n\n'
          '上次备份：$_backupText\n\n'
          '手机重装、换新手机之后，会自动把书架和设置恢复回来。\n'
          '备份里没有账号密码，夸克要重新登录一次。',
          style: const TextStyle(fontSize: 17, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _restoreBackup();
            },
            child: const Text('从备份恢复', style: TextStyle(fontSize: 17)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await BackupService.instance.saveNow();
              await _refreshBackup();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(ok ? '已备份到 下载/听评书' : '备份失败，请检查存储空间')),
              );
            },
            child: const Text(
              '立即备份',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreBackup() async {
    final info = await BackupService.instance.info();
    if (!mounted) return;
    if (!info.exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没找到备份文件')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从备份恢复？', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        content: const Text(
          '会用备份里的书架和设置，覆盖这台手机现在的内容。\n'
          '现在书架上的书如果没有备份进去，会消失。\n\n'
          '确定恢复吗？',
          style: TextStyle(fontSize: 18, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定恢复', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await BackupService.instance.restoreNow();
    await _refreshBackup();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(done ? '已恢复，回首页看看书架' : '恢复失败，备份文件可能损坏')),
    );
  }

  /// 清除全部数据（模拟新机）。
  ///
  /// 两道确认：第一道讲清楚删什么、不删什么；第二道再问一次"没法撤销"。
  /// 这是设置页里唯一不可逆的操作，必须把误触概率压到最低。
  Future<void> _wipeAll() async {
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '清除全部数据？',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '会删掉：书架、听到哪儿、已缓存的声音、夸克登录、更新设置。\n\n'
          '书本身还在网盘和 B 站上，不会丢，重新添加就行。\n\n'
          '注意：通知、后台、安装这三项系统授权不会被重置。',
          style: TextStyle(fontSize: 17, height: 1.55),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (first != true || !mounted) return;

    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '真的清除吗？',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '清完 App 会自己重启，回到第一次打开的样子。\n这个操作没法撤销。',
          style: TextStyle(fontSize: 17, height: 1.55),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '确认清除',
              style: TextStyle(color: TingColors.warn, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (second != true || !mounted) return;

    // 先停下播放：清数据会把正在播的缓存文件删掉，
    // 让播放器先安静退出，避免删除瞬间报"这一回没放出来"。
    await TingPlayer.instance.stop();
    if (!mounted) return;

    // 遮罩：原生重建 Activity 前留 500ms，让这一帧先画出来
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(canPop: false, child: _WipeOverlay()),
    ));

    final ok = await AppWipe.clearAll();
    if (!ok) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('清除失败，请到 系统设置 → 应用 → 听评书 → 存储 里清除数据'),
        ),
      );
      return;
    }

    // 磁盘已经清空，Dart 侧的内存状态也必须归零：
    // SharedPreferences 每次写入都会把内存 map 整份序列化回磁盘，
    // 只要旧值还在内存里，下一次保存就会把刚删掉的数据复活
    // （实测表现：清完书架又长回来、向导又变成"已完成"）。
    try {
      await (await SharedPreferences.getInstance()).clear();
    } catch (_) {}
    Library.instance.resetForWipe();
    NasSource.instance.resetForWipe();
    CacheEngine.instance.resetForWipe();
    QuarkApi.instance.resetForWipe();
    UpdateService.instance.resetForWipe();
    AppWipe.wiping = false;

    if (!mounted) return;
    // 直接回到首次配置向导，等于新机
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SetupPage()),
      (route) => false,
    );
  }
}

/// 清除数据时的全屏遮罩：不可取消、拦掉返回键，避免清到一半被打断。
class _WipeOverlay extends StatelessWidget {
  const _WipeOverlay();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: TingColors.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(strokeWidth: 6, color: TingColors.primary),
            ),
            SizedBox(height: 26),
            Text(
              '正在清除…',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: TingColors.ink),
            ),
            SizedBox(height: 10),
            Text(
              '清完会自动重启',
              style: TextStyle(fontSize: 17, color: TingColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}


import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../services/device_perms.dart';
import '../services/backup_service.dart';
import '../services/library.dart';
import '../services/quark/quark_api.dart';
import '../widgets/common.dart';
import 'home_page.dart';
import 'quark_login_page.dart';

/// 首次配置向导：**所有需要系统授权的东西，一次问完**。
///
/// 产品前提：家人只在装机时守着手机配这一次，之后老人独立使用。
/// 所以这里刻意做成"一页走完"，而不是散落在设置页各处的开关——
/// 散着放的结果就是：家属装完就走了，老人过两天发现锁屏不能暂停、
/// 后台被系统杀掉、更新装不上，然后没人知道该怎么弄。
///
/// 设计约束：
/// - 每项都有"为什么需要"的一句话说明，家属看得懂才能判断要不要给
/// - 从系统页面返回时自动刷新状态（[didChangeAppLifecycleState]）
/// - 不允许静默跳过：没配齐时主按钮是灰的，跳过要点下面那行小字
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> with WidgetsBindingObserver {
  bool _notify = false;
  bool _battery = false;
  bool _install = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _checkBackup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置页/授权框回来时重新查一遍，否则状态永远是进页面时那一刻的
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final r = await Future.wait([
      DevicePerms.notifyOk(),
      DevicePerms.batteryOk(),
      DevicePerms.installOk(),
    ]);
    if (!mounted) return;
    setState(() {
      _notify = r[0];
      _battery = r[1];
      _install = r[2];
      _loading = false;
    });
  }

  int get _doneCount => [_notify, _battery, _install].where((e) => e).length;
  bool get _allDone => _doneCount == 3;

  /// 备份里有多少部书（0 表示没备份或备份是空的）
  int _backupBooks = 0;

  Future<void> _checkBackup() async {
    final b = await BackupService.instance.peek();
    if (!mounted) return;
    setState(() => _backupBooks = b?.books ?? 0);
  }

  Future<void> _restoreFromBackup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从备份恢复？', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        content: Text(
          '备份里有 $_backupBooks 部书，恢复后书架和"听到哪儿"都会回来。\n'
          '夸克网盘要重新登录一次（备份里不放账号密码）。',
          style: const TextStyle(fontSize: 18, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await BackupService.instance.restoreNow();
    if (!mounted) return;
    if (!done) {
      showTip(context, '恢复失败，备份可能损坏');
      return;
    }
    // 恢复完配置可能已经是"已完成"，直接进首页
    if (Library.instance.setupDone) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    } else {
      setState(() {});
      showTip(context, '书架已恢复，接着把 3 项设置配一下');
    }
  }

  Future<void> _finish() async {
    await Library.instance.markSetupDone();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: T.pagePad),
              child: Row(
                children: [
                  const Text(
                    '先设置 3 项',
                    style: TextStyle(
                      fontSize: T.fontHuge,
                      fontWeight: FontWeight.w700,
                      color: TingColors.ink,
                    ),
                  ),
                  const Spacer(),
                  if (!_loading)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: _allDone ? TingColors.doneSoft : TingColors.primarySoft,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Text(
                        '$_doneCount / 3',
                        style: TextStyle(
                          fontSize: T.fontSmall,
                          fontWeight: FontWeight.w700,
                          color: _allDone ? TingColors.done : TingColors.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(T.pagePad, 10, T.pagePad, 4),
              child: Text(
                '请家里年轻人帮忙做完这几步。\n做完以后，老人自己就能用了，不用再动手机设置。',
                style: TextStyle(
                  fontSize: T.fontSmall,
                  height: 1.6,
                  color: TingColors.muted,
                ),
              ),
            ),
            if (_backupBooks > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(T.pagePad, 10, T.pagePad, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: TingColors.primarySoft,
                    borderRadius: BorderRadius.circular(T.radius),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.backup_rounded, size: 30, color: TingColors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '找到一份备份，里面有 $_backupBooks 部书',
                          style: const TextStyle(fontSize: 17, color: TingColors.ink),
                        ),
                      ),
                      TextButton(
                        onPressed: _restoreFromBackup,
                        child: const Text(
                          '恢复',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(T.pagePad, 12, T.pagePad, 12),
                children: [
                  _PermCard(
                    icon: Icons.notifications_active_rounded,
                    title: '允许通知',
                    why: '锁屏上要能暂停、下一回。不给这个权限，锁屏就什么按钮都没有。',
                    ok: _notify,
                    onTap: () async {
                      if (_notify) {
                        await DevicePerms.openNotifySettings();
                      } else {
                        await DevicePerms.requestNotify();
                        await _refresh();
                        // 拒过一次后系统不再弹框，只能带去设置页
                        if (!_notify) await DevicePerms.openNotifySettings();
                        await _refresh();
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  _PermCard(
                    icon: Icons.battery_saver_rounded,
                    title: '允许后台运行',
                    why: '不加的话，锁屏没几分钟系统就把播放掐了。选"允许"或"不限制"。',
                    ok: _battery,
                    onTap: () async {
                      await DevicePerms.requestBattery();
                      // 系统页面是异步返回的，稍等一下再查
                      await Future.delayed(const Duration(milliseconds: 600));
                      await _refresh();
                    },
                  ),
                  const SizedBox(height: 12),
                  _PermCard(
                    icon: Icons.system_update_alt_rounded,
                    title: '允许安装新版本',
                    why: '以后有新版本会自动提示，一次装好之后再也不用连电脑传文件。',
                    ok: _install,
                    onTap: () async {
                      await DevicePerms.openInstallSettings();
                      await Future.delayed(const Duration(milliseconds: 600));
                      await _refresh();
                    },
                  ),
                  const SizedBox(height: 26),
                  Text(
                    '可选',
                    style: TextStyle(
                      fontSize: T.fontSmall,
                      fontWeight: FontWeight.w700,
                      color: TingColors.muted,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _PermCard(
                    icon: Icons.cloud_rounded,
                    title: '连接夸克网盘',
                    why: '连上以后，网盘里的评书能直接加进书架。不连也能用网络评书。',
                    ok: QuarkApi.instance.hasLogin,
                    okText: '已连接',
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const QuarkLoginPage()),
                      );
                      await _refresh();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(T.pagePad, 4, T.pagePad, 10),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: T.buttonHeight,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            _allDone ? TingColors.primary : TingColors.line,
                        foregroundColor:
                            _allDone ? Colors.white : TingColors.muted,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(T.radius),
                        ),
                      ),
                      onPressed: _allDone ? _finish : null,
                      child: Text(
                        _allDone ? '都设置好了，开始用' : '还差 ${3 - _doneCount} 项没配好',
                        style: const TextStyle(
                          fontSize: T.fontBody,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: _finish,
                    child: Text(
                      '先跳过，以后再说',
                      style: TextStyle(fontSize: T.fontSmall, color: TingColors.muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条权限卡片：图标 + 标题 + 为什么需要 + 状态/去设置
class _PermCard extends StatelessWidget {
  const _PermCard({
    required this.icon,
    required this.title,
    required this.why,
    required this.ok,
    required this.onTap,
    this.okText = '已允许',
  });

  final IconData icon;
  final String title;
  final String why;
  final bool ok;
  final String okText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TingColors.surface,
      borderRadius: BorderRadius.circular(T.radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(T.radius),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(T.radius),
            border: Border.all(
              color: ok ? TingColors.done.withValues(alpha: 0.45) : TingColors.line,
              width: ok ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: ok ? TingColors.doneSoft : TingColors.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  ok ? Icons.check_rounded : icon,
                  size: 28,
                  color: ok ? TingColors.done : TingColors.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: T.fontBody,
                        fontWeight: FontWeight.w700,
                        color: TingColors.ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      why,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.45,
                        color: TingColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (ok)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    okText,
                    style: const TextStyle(
                      fontSize: T.fontSmall,
                      fontWeight: FontWeight.w700,
                      color: TingColors.done,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: TingColors.primary,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: const Text(
                      '去设置',
                      style: TextStyle(
                        fontSize: T.fontSmall,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

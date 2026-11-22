import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../services/update_service.dart';

/// 更新提示：一个弹窗走完全程，中间不需要再点任何按钮。
///
/// 设计前提（很重要）：老人自己在家，身边没人指导。
/// 所以这里刻意**不做"提示 → 跳页面 → 再点开始更新"的二级流程**，
/// 那等于逼用户点三四次，中间任何一步被系统页打断就再也回不来。
///
/// 实际交互（用户只需要两次点击，且第二次是系统强制的）：
/// 1. 启动检测到新版本 → 弹窗，一个很大的「立即更新」+ 一行很小的「以后再说」
/// 2. 点「立即更新」→ 若缺安装权限，直接跳到系统授权页
/// 3. 从授权页返回 → **自动开始下载**，不需要再点
/// 4. 下载完 → 自动调起系统安装界面（这一步系统强制要点「安装」）
class UpdatePrompt extends StatefulWidget {
  const UpdatePrompt({super.key, required this.info});

  final UpdateInfo info;

  /// 弹出并等用户结束（更新完成、失败放弃、或点了以后再说）
  static Future<void> show(BuildContext context, UpdateInfo info) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdatePrompt(info: info),
    );
  }

  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

enum _Phase {
  /// 等用户点"立即更新"
  idle,

  /// 缺"安装未知应用"权限，已经把用户送到系统页了
  needPerm,

  downloading,
  installing,

  /// 下载完了，系统安装界面已弹出
  done,

  failed,
}

class _UpdatePromptState extends State<UpdatePrompt> with WidgetsBindingObserver {
  final _svc = UpdateService.instance;

  _Phase _phase = _Phase.idle;
  double _progress = 0;
  String? _error;

  /// 从授权页回来过几次（用来区分"第一次去开"和"回来还是没开"）
  int _permRounds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 关键：从系统授权页返回后自动接上，绝不让用户再点一次
    if (state == AppLifecycleState.resumed && _phase == _Phase.needPerm) {
      _afterPerm();
    }
  }

  Future<void> _afterPerm() async {
    final can = await _svc.canInstall();
    if (!mounted) return;
    if (can) {
      unawaited(_download());
    } else {
      setState(() => _permRounds++);
    }
  }

  /// 点"立即更新"
  Future<void> _start() async {
    final can = await _svc.canInstall();
    if (!mounted) return;
    if (!can) {
      setState(() => _phase = _Phase.needPerm);
      await _svc.openInstallPermission();
      // 有的机型跳过去不触发 pause，这里补一次检查，避免卡在 needPerm
      await Future.delayed(const Duration(seconds: 1));
      if (mounted && _phase == _Phase.needPerm) _afterPerm();
      return;
    }
    unawaited(_download());
  }

  Future<void> _download() async {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _error = null;
    });

    try {
      final path = await _svc.download(
        widget.info,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p < 0 ? 0 : p);
        },
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.installing);

      await _svc.install(path);
      if (!mounted) return;
      setState(() => _phase = _Phase.done);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _skip() async {
    await _svc.skipThisVersion(widget.info.versionCode);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final canSkip = !info.force && (_phase == _Phase.idle);

    return PopScope(
      // 下载中不允许返回键把弹窗关掉，否则用户会以为更新没了
      canPop: canSkip,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        backgroundColor: TingColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _body(info, canSkip),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(UpdateInfo info, bool canSkip) {
    switch (_phase) {
      case _Phase.idle:
        return [
          Text(
            '有新版本',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: T.fontSmall,
              fontWeight: FontWeight.w700,
              color: TingColors.muted,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            info.versionName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w700,
              color: TingColors.ink,
            ),
          ),
          if (info.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: TingColors.bg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                info.notes,
                style: const TextStyle(
                  fontSize: 17,
                  height: 1.6,
                  color: TingColors.muted,
                ),
              ),
            ),
          ],
          const SizedBox(height: 22),
          BigUpdateButton(label: '立即更新', onTap: _start),
          const SizedBox(height: 4),
          if (canSkip)
            Center(
              child: TextButton(
                onPressed: _skip,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: Text(
                  '以后再说',
                  style: TextStyle(fontSize: 15, color: TingColors.muted),
                ),
              ),
            ),
        ];

      case _Phase.needPerm:
        return [
          const Icon(Icons.touch_app_rounded, size: 56, color: TingColors.primary),
          const SizedBox(height: 16),
          const Text(
            '最后一步',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: T.fontTitle,
              fontWeight: FontWeight.w700,
              color: TingColors.ink,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _permRounds == 0
                ? '请在打开的页面里，把「允许安装未知应用」的开关打开。\n打开后返回，会自己开始更新。'
                : '开关还没打开。请打开后再返回，会自动继续。',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              height: 1.6,
              color: TingColors.muted,
            ),
          ),
          const SizedBox(height: 22),
          BigUpdateButton(
            label: '去打开',
            onTap: () async {
              await _svc.openInstallPermission();
              await Future.delayed(const Duration(seconds: 1));
              if (mounted) _afterPerm();
            },
          ),
        ];

      case _Phase.downloading:
        final pct = (_progress * 100).clamp(0, 100).round();
        final mb = (widget.info.size / 1048576);
        return [
          const Text(
            '正在下载新版本',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: T.fontTitle,
              fontWeight: FontWeight.w700,
              color: TingColors.ink,
            ),
          ),
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _progress <= 0 ? null : _progress,
              minHeight: 18,
              backgroundColor: TingColors.line,
              color: TingColors.primary,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            pct > 0
                ? '$pct%　共 ${mb.toStringAsFixed(0)} MB'
                : '正在连接，共 ${mb.toStringAsFixed(0)} MB',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: TingColors.primary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '下完会自动打开安装界面。\n这期间别关屏幕、别退出。',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, height: 1.5, color: TingColors.muted),
          ),
        ];

      case _Phase.installing:
        return [
          const SizedBox(height: 10),
          const Center(
            child: SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(strokeWidth: 4, color: TingColors.primary),
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            '正在打开安装界面…',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: T.fontTitle,
              fontWeight: FontWeight.w700,
              color: TingColors.ink,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '等一下会弹出系统的安装页面，点「安装」就行。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, height: 1.6, color: TingColors.muted),
          ),
        ];

      case _Phase.done:
        return [
          const Icon(Icons.check_circle_rounded, size: 62, color: TingColors.done),
          const SizedBox(height: 16),
          const Text(
            '更新包已备好',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: T.fontTitle,
              fontWeight: FontWeight.w700,
              color: TingColors.ink,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '在系统的安装页面点「安装」即可完成。\n书架和听到哪儿都不会变。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, height: 1.6, color: TingColors.muted),
          ),
          const SizedBox(height: 22),
          BigUpdateButton(
            label: '知道了',
            onTap: () => Navigator.of(context).pop(),
          ),
        ];

      case _Phase.failed:
        return [
          const Icon(Icons.cloud_off_rounded, size: 56, color: TingColors.warn),
          const SizedBox(height: 16),
          const Text(
            '没更新成功',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: T.fontTitle,
              fontWeight: FontWeight.w700,
              color: TingColors.ink,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _error ?? '网络不太好，过一会儿再试。',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, height: 1.6, color: TingColors.muted),
          ),
          const SizedBox(height: 22),
          BigUpdateButton(label: '再试一次', onTap: _start),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('先不更新', style: TextStyle(fontSize: 15, color: TingColors.muted)),
            ),
          ),
        ];
    }
  }
}

/// 全宽大按钮：老人手指按得住，视觉上也不会有第二个选择干扰
class BigUpdateButton extends StatelessWidget {
  const BigUpdateButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: TingColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.radius)),
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700, letterSpacing: 2),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../pages/add_page.dart';
import '../pages/player_page.dart';
import '../player/ting_player.dart';
import '../services/library.dart';
import '../services/recommend.dart';

/// 点"推荐一本"之后的完整流程：找书 → 入库 → 进播放页。
///
/// 为什么要有等待框而不只是转圈：这一步第一次可能要几十秒（网上搜 + 取回目），
/// 没有任何反馈的话老人会以为点坏了，然后连点。
Future<void> startRecommend(BuildContext context) async {
  final nav = Navigator.of(context);
  final rootNav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);

  final step = ValueNotifier<String>('正在找一本没听过的评书…');
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PickingDialog(step: step),
  ));

  RecommendPick? pick;
  var failed = false;
  try {
    pick = await RecommendService.instance
        .pick(onStep: (s) => step.value = s)
        .timeout(const Duration(seconds: 60));
  } catch (_) {
    failed = true;
  }
  step.dispose();
  if (rootNav.canPop()) rootNav.pop();

  if (pick == null) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed ? '找书时网络不太顺，让家里人帮你挑一本吧' : '没找到没听过的书，让家里人帮你挑一本吧',
          style: const TextStyle(fontSize: 17),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
    return;
  }

  // 入库——不然首页找不到它，进度也没地方存
  await Library.instance.put(pick.book);
  // 不 await：第一次要下载，等它会让按钮"点了没反应"
  unawaited(TingPlayer.instance.open(pick.book, pick.startIndex, positionMs: 0));
  nav.push(MaterialPageRoute(builder: (_) => const PlayerPage()));
}

/// 两个按钮：「推荐一本」大、「手动挑选」小。
///
/// 老人只要按上面那个；下面那个留给家属。
class PickBookButtons extends StatelessWidget {
  final bool compact;

  const PickBookButtons({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: compact ? 56 : 74,
          child: FilledButton(
            onPressed: () => startRecommend(context),
            child: Text(
              '推荐一本',
              style: TextStyle(
                fontSize: compact ? 22 : 28,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: compact ? 46 : 54,
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AddPage()),
            ),
            child: Text(
              '手动挑选',
              style: TextStyle(
                fontSize: compact ? 18 : 21,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PickingDialog extends StatelessWidget {
  final ValueNotifier<String> step;

  const _PickingDialog({required this.step});

  @override
  Widget build(BuildContext context) {
    // 找书过程中不许返回键关掉——关掉之后老人会以为按钮没反应
    return PopScope(
      canPop: false,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(strokeWidth: 4),
            ),
            const SizedBox(height: 22),
            ValueListenableBuilder<String>(
              valueListenable: step,
              builder: (_, text, __) => Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: T.fontBody,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                  color: TingColors.ink,
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '第一次要等几十秒，别着急',
              style: TextStyle(fontSize: T.fontSmall, color: TingColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

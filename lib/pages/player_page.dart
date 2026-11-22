import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../player/ting_player.dart';
import '../services/cache/cache_engine.dart';
import '../services/library.dart';
import '../widgets/common.dart';
import '../widgets/recommend_flow.dart';

/// 播放页：只有"上一回 / 播放 / 下一回"和一根进度条。
///
/// 老人不需要"播放器"，他们需要"一个能出声的开关"。
/// 所以中间那个播放键做到 148dp，屏幕再小也一按就中。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  @override
  void dispose() {
    // 离开播放页立刻落一次进度。
    // 进度定时器是 5 秒一次，若用户听了几秒就退回首页，
    // 首页那张"继续收听"卡片拿到的还是 0，点进去就会从头开始。
    unawaited(TingPlayer.instance.saveNow());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = TingPlayer.instance;
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([p, CacheEngine.instance]),
          builder: (context, _) {
            final book = p.book;
            final chapter = p.chapter;
            if (book == null) {
              return const Column(
                children: [
                  TingBar(title: '听评书'),
                  Expanded(
                    child: Center(
                      child: Text('还没有开始听', style: TextStyle(fontSize: T.fontBody)),
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                TingBar(title: book.title, subtitle: book.author),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: T.pagePad),
                    child: Column(
                      children: [
                        const Spacer(flex: 1),
                        _TitleBlock(
                          title: chapter?.numbered ?? '',
                          subtitle: book.title,
                        ),
                        const Spacer(flex: 2),
                        if (p.state == TingState.preparing)
                          _PreparingView(player: p)
                        else if (p.state == TingState.error)
                          _ErrorView(player: p)
                        else ...[
                          _ProgressBar(player: p),
                          const SizedBox(height: 26),
                          _PlayButton(player: p),
                        ],
                        const Spacer(flex: 2),
                        if (p.state == TingState.finished) _FinishedHint(),
                        _PrevNextRow(player: p),
                        const SizedBox(height: 4),
                        _SkipBookButton(player: p),
                        const SizedBox(height: 8),
                        _BottomTools(player: p),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  final String title;
  final String subtitle;

  const _TitleBlock({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 28,
            height: 1.35,
            fontWeight: FontWeight.w700,
            color: TingColors.ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: T.fontSmall, color: TingColors.muted),
        ),
      ],
    );
  }
}

class _PreparingView extends StatelessWidget {
  final TingPlayer player;

  const _PreparingView({required this.player});

  @override
  Widget build(BuildContext context) {
    final pct = (player.loadProgress * 100).clamp(0, 100).toStringAsFixed(0);
    return Column(
      children: [
        SizedBox(
          width: 132,
          height: 132,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 132,
                height: 132,
                child: CircularProgressIndicator(
                  value: player.loadProgress > 0 ? player.loadProgress : null,
                  strokeWidth: 10,
                  color: TingColors.primary,
                  backgroundColor: TingColors.line,
                ),
              ),
              Text(
                player.loadProgress > 0 ? '$pct%' : '',
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: TingColors.primary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          '正在打开这一回…',
          style: TextStyle(fontSize: T.fontBody, fontWeight: FontWeight.w600, color: TingColors.ink),
        ),
        const SizedBox(height: 6),
        const Text(
          '边听边存，不用等整回下完',
          style: TextStyle(fontSize: 15, color: TingColors.muted),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final TingPlayer player;

  const _ErrorView({required this.player});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Icon(Icons.cloud_off_rounded, size: 72, color: TingColors.warn),
        const SizedBox(height: 16),
        Text(
          player.error ?? '这一回没放出来',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: T.fontBody, height: 1.5, color: TingColors.ink),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: 240,
          child: FilledButton(
            onPressed: () => player.resumeOrOpenCurrent(),
            child: const Text('再试一次'),
          ),
        ),
      ],
    );
  }
}

class _ProgressBar extends StatefulWidget {
  final TingPlayer player;

  const _ProgressBar({required this.player});

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final max = p.duration.inMilliseconds.toDouble();
    final value = (_dragging ?? p.position.inMilliseconds.toDouble()).clamp(0.0, max <= 0 ? 1.0 : max);

    return Column(
      children: [
        SizedBox(
          height: 44,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 14,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 15),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 34),
            ),
            child: Slider(
              value: value,
              max: max <= 0 ? 1 : max,
              onChanged: max <= 0
                  ? null
                  : (v) => setState(() => _dragging = v),
              onChangeEnd: max <= 0
                  ? null
                  : (v) async {
                      await p.seek(Duration(milliseconds: v.toInt()));
                      setState(() => _dragging = null);
                    },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                fmtDuration(Duration(milliseconds: value.toInt())),
                style: const TextStyle(fontSize: T.fontBody, color: TingColors.muted),
              ),
              Text(
                fmtDuration(p.duration),
                style: const TextStyle(fontSize: T.fontBody, color: TingColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  final TingPlayer player;

  const _PlayButton({required this.player});

  @override
  Widget build(BuildContext context) {
    final playing = player.isPlaying;
    return GestureDetector(
      onTap: () => player.toggle(),
      child: Container(
        width: T.playButton,
        height: T.playButton,
        decoration: BoxDecoration(
          color: TingColors.primary,
          shape: BoxShape.circle,
        ),
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 84,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _PrevNextRow extends StatelessWidget {
  final TingPlayer player;

  const _PrevNextRow({required this.player});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SideButton(
            label: '上一回',
            icon: Icons.skip_previous_rounded,
            enabled: player.hasPrev,
            onTap: player.previous,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _SideButton(
            label: '下一回',
            icon: Icons.skip_next_rounded,
            enabled: player.hasNext,
            onTap: player.next,
          ),
        ),
      ],
    );
  }
}

class _SideButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _SideButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      // 上下回是老人用得最多的两个操作（广播评书一回三五分钟，
      // 一集接一集地往下听），所以做得比普通按钮更高、字更大。
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 84,
          decoration: BoxDecoration(
            color: TingColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: TingColors.line, width: 1.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 40, color: TingColors.ink),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: TingColors.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「不喜欢这本，换一本」：小一号、灰一点，别抢上一回/下一回的位置。
///
/// 老人拿去听的时候经常碰上"这本听不进去"，让他一键换掉，
/// 比让他退回书架再挑一本要省十几步。
class _SkipBookButton extends StatelessWidget {
  final TingPlayer player;

  const _SkipBookButton({required this.player});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () => _skipBook(context, player),
      style: TextButton.styleFrom(
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      icon: const Icon(Icons.swap_horiz_rounded, size: 24, color: TingColors.muted),
      label: const Text(
        '不喜欢这本，换一本',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: TingColors.muted),
      ),
    );
  }
}

/// 跳到书架里的下一本（到底了回到第一本）。
///
/// 不删书、不记黑名单：用户只是"这本听不进去"，换个方向而已，
/// 下次还想听随时能回来。
Future<void> _skipBook(BuildContext context, TingPlayer p) async {
  final cur = p.book;
  if (cur == null) return;

  final shelf = Library.instance.shelf;
  final at = shelf.indexWhere(
    (e) => e.book.id == cur.id && e.book.source == cur.source,
  );

  ShelfItem? next;
  if (at >= 0) {
    // 从当前这本往后找，绕过自己
    for (var k = 1; k < shelf.length; k++) {
      final cand = shelf[(at + k) % shelf.length];
      if (cand.book.id != cur.id || cand.book.source != cur.source) {
        next = cand;
        break;
      }
    }
  } else {
    // 当前这本不在书架里（比如从"推荐一本"直接放起来的），挑第一本别的
    for (final cand in shelf) {
      if (cand.book.id != cur.id || cand.book.source != cur.source) {
        next = cand;
        break;
      }
    }
  }

  if (next == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('书架里只有这一本，先添加别的书吧')),
    );
    return;
  }

  final chapters = next.book.chapters;
  final idx = chapters.isEmpty ? 0 : next.chapterIndex.clamp(0, chapters.length - 1);
  await p.open(next.book, idx, positionMs: next.positionMs);

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('换成了《${next.book.title}》')),
  );
}

/// 只在底部留一行缓存说明。
///
/// 原来这里还有「定时关闭」和「倍速」两个按钮，实际用不上——
/// 老人不会去调语速，定时关闭也从来没人开。占着屏幕最下面一行，
/// 反而把「上一回 / 下一回」挤小了。撤掉，把空间让给真正的操作。
class _BottomTools extends StatelessWidget {
  final TingPlayer player;

  const _BottomTools({required this.player});

  @override
  Widget build(BuildContext context) {
    final cache = CacheEngine.instance;
    final book = player.book;
    final cached = book == null ? 0 : cache.cachedCount(book.source, book.id);
    final total = book?.chapters.length ?? 0;
    if (total == 0) return const SizedBox.shrink();

    return Text(
      cache.busyKey != null ? '正在缓存 · 已存 $cached/$total 回' : '已存在手机里 $cached/$total 回',
      style: const TextStyle(fontSize: 15, color: TingColors.muted),
    );
  }
}

class _FinishedHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: TingColors.doneSoft,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: TingColors.done, size: 26),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '这部书听完了',
                    style: TextStyle(
                      fontSize: T.fontBody,
                      fontWeight: FontWeight.w600,
                      color: TingColors.done,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // 听完了直接给下一步，别把老人晾在这儿
            const PickBookButtons(compact: true),
          ],
        ),
      ),
    );
  }
}

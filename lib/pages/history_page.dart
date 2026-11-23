import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../models/ting.dart';
import '../player/ting_player.dart';
import '../services/history.dart';
import '../services/library.dart';
import '../widgets/common.dart';
import 'add_page.dart';
import 'player_page.dart';

/// 播放历史：最近听过哪些书、听到第几回。
///
/// 给谁看：家属（"老人这几天在听什么"）和老人自己（"上次那本还想接着听"）。
/// 所以只做两件事——看、点开接着听。删除收在右上角，且要二次确认。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TingColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            AnimatedBuilder(
              animation: PlayHistory.instance,
              builder: (context, _) {
                final list = PlayHistory.instance.entries;
                return TingBar(
                  title: '播放历史',
                  subtitle: list.isEmpty ? null : '${list.length} 本',
                  actions: [
                    if (list.isNotEmpty)
                      TextButton(
                        onPressed: () => _confirmClear(context),
                        child: const Text(
                          '清空',
                          style: TextStyle(fontSize: 17, color: TingColors.muted),
                        ),
                      ),
                  ],
                );
              },
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: PlayHistory.instance,
                builder: (context, _) {
                  final list = PlayHistory.instance.entries;
                  if (list.isEmpty) return const _EmptyHistory();
                  return _HistoryList(entries: list);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '清空播放历史？',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '只会清掉"听过哪些书"这个列表。\n'
          '书架里的书、听到哪儿、已经存下来的声音都不会动。',
          style: TextStyle(fontSize: 18, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '清空',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await PlayHistory.instance.clear();
    if (!context.mounted) return;
    showTip(context, '已清空播放历史');
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.history_rounded, size: 72, color: TingColors.line),
            SizedBox(height: 18),
            Text(
              '还没有播放记录',
              style: TextStyle(
                fontSize: T.fontTitle,
                fontWeight: FontWeight.w700,
                color: TingColors.ink,
              ),
            ),
            SizedBox(height: 8),
            Text(
              '听过的书会出现在这里，方便接着听',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, height: 1.6, color: TingColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.entries});

  final List<HistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    String? lastDay;
    for (final e in entries) {
      final day = _dayLabel(e.at);
      if (day != lastDay) {
        rows.add(_DayHeader(text: day));
        lastDay = day;
      }
      rows.add(_HistoryTile(entry: e));
      rows.add(const SizedBox(height: 10));
    }
    rows.add(const SizedBox(height: 16));

    return ListView(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 4, T.pagePad, 20),
      children: rows,
    );
  }

  /// 今天 / 昨天 / 11月21日
  static String _dayLabel(int ms) {
    if (ms <= 0) return '更早';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(t.year, t.month, t.day);
    final diff = today.difference(that).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: TingColors.muted,
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final time = _hhmm(e.at);
    final name = e.chapterName;
    final total = e.totalChapters > 0 ? '共 ${e.totalChapters} 回' : '';

    return InkWell(
      borderRadius: BorderRadius.circular(T.radius),
      onTap: () => _resume(context, e),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TingColors.surface,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: TingColors.line),
        ),
        child: Row(
          children: [
            CoverBox(book: e.asBook, size: 64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    e.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: TingColors.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    // 时间和"第几回"排在最前，长回目名不会把它挤掉
                    [e.chapterLabel, time].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, color: TingColors.muted),
                  ),
                  if (name.isNotEmpty || total.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        [name, total].where((s) => s.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, color: TingColors.muted),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.play_circle_outline_rounded, size: 34, color: TingColors.primary),
          ],
        ),
      ),
    );
  }

  static String _hhmm(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _resume(BuildContext context, HistoryEntry e) async {
    final item = Library.instance.find(e.source, e.bookId);
    if (item == null || item.book.chapters.isEmpty) {
      showTip(
        context,
        '《${e.title}》已经不在书架里了',
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '去添加',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AddPage()),
          ),
        ),
      );
      return;
    }

    final chapters = item.book.chapters;
    final idx = e.chapterIndex.clamp(0, chapters.length - 1);
    // 和书架上的进度是同一回 → 从上次停下的地方接着听；
    // 不是同一回（比如历史里的回被删了）→ 从这一回开头放。
    final sameChapter = item.chapterIndex == idx;
    final pos = sameChapter ? item.positionMs : 0;

    await TingPlayer.instance.open(item.book, idx, positionMs: pos);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlayerPage()),
    );
  }
}

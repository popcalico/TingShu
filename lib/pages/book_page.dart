import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../models/ting.dart';
import '../player/ting_player.dart';
import '../services/bili_source.dart';
import '../services/library.dart';
import '../services/nas/nas_source.dart';
import '../services/quark/quark_source.dart';
import '../widgets/common.dart';
import 'player_page.dart';

/// 回目列表。字要大、行要高、点哪回就听哪回。
class BookPage extends StatefulWidget {
  final TingBook book;

  const BookPage({super.key, required this.book});

  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
  late TingBook _book;
  final ScrollController _scroll = ScrollController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _ensureChapters();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ensureChapters() async {
    if (_book.chapters.isNotEmpty) {
      _jumpToCurrent();
      return;
    }
    setState(() => _loading = true);
    try {
      final full = switch (_book.source) {
        TingSource.bili => await BiliSource.instance.detail(_book),
        TingSource.quark => await QuarkSource.instance.detail(_book),
        TingSource.nas => await NasSource.instance.detail(_book),
      };
      await Library.instance.put(full);
      if (!mounted) return;
      setState(() {
        _book = full;
        _loading = false;
      });
      _jumpToCurrent();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  /// 打开就把列表滚到"上次听到的那一回"，省得老人自己找
  void _jumpToCurrent() {
    final item = Library.instance.find(_book.source, _book.id);
    final idx = item?.chapterIndex ?? 0;
    if (idx <= 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      const rowHeight = 92.0;
      final target = (idx * rowHeight) - 80;
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    });
  }

  /// 正在跳转中，挡住连点。
  ///
  /// 之前这里是 `await player.open(...)` 之后再 push：首次播放要等下载几十秒，
  /// 期间每点一次就挂一个 await，下载完一起恢复 → 一次性弹出一堆播放页。
  bool _opening = false;

  Future<void> _play(int index) async {
    if (_opening) return;
    _opening = true;

    final item = Library.instance.find(_book.source, _book.id);
    final resume = item != null && item.chapterIndex == index ? item.positionMs : 0;

    // 立刻开始准备，但不等它——播放页会显示下载进度，准备好自动出声
    unawaited(TingPlayer.instance.open(_book, index, positionMs: resume));

    if (!mounted) {
      _opening = false;
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlayerPage()));
    _opening = false;
  }

  @override
  Widget build(BuildContext context) {
    final item = Library.instance.find(_book.source, _book.id);
    final currentIndex = item?.chapterIndex ?? 0;
    final finished = item?.finished ?? <int>{};

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TingBar(
              title: _book.title,
              subtitle: _book.subtitle,
              actions: [
                IconButton(
                  iconSize: 30,
                  tooltip: '移出书架',
                  onPressed: () => _confirmRemove(),
                  icon: const Icon(Icons.delete_outline_rounded, color: TingColors.muted),
                ),
              ],
            ),
            if (_loading)
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: TingColors.primary),
                      SizedBox(height: 18),
                      Text('正在读取回目…', style: TextStyle(fontSize: T.fontBody, color: TingColors.muted)),
                    ],
                  ),
                ),
              )
            else if (_error != null)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: T.fontBody, color: TingColors.muted),
                        ),
                        const SizedBox(height: 20),
                        FilledButton(onPressed: _ensureChapters, child: const Text('再试一次')),
                      ],
                    ),
                  ),
                ),
              )
            else if (_book.chapters.isEmpty)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '这个文件夹里没有找到音频文件\n\n音频放在文件夹里，一回一个文件（mp3 等）',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: T.fontBody, height: 1.6, color: TingColors.muted),
                    ),
                  ),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 10),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _play(currentIndex),
                    icon: const Icon(Icons.play_arrow_rounded, size: 34),
                    label: Text(
                      (item?.positionMs ?? 0) > 0 ? '接着听第 ${currentIndex + 1} 回' : '从第 1 回开始听',
                      style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 20),
                  itemCount: _book.chapters.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final ch = _book.chapters[i];
                    final isCurrent = i == currentIndex;
                    final isDone = finished.contains(i);
                    return _ChapterRow(
                      chapter: ch,
                      isCurrent: isCurrent,
                      isDone: isDone,
                      onTap: () => _play(i),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出书架？', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        content: Text(
          '《${_book.title}》会从书架上移走，已经缓存的声音也会一起清掉。',
          style: const TextStyle(fontSize: T.fontBody, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不了', style: TextStyle(fontSize: T.fontBody)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出', style: TextStyle(fontSize: T.fontBody, color: TingColors.warn)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Library.instance.remove(_book.source, _book.id);
    if (mounted) Navigator.of(context).pop();
  }
}

class _ChapterRow extends StatelessWidget {
  final TingChapter chapter;
  final bool isCurrent;
  final bool isDone;
  final VoidCallback onTap;

  const _ChapterRow({
    required this.chapter,
    required this.isCurrent,
    required this.isDone,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isCurrent
        ? TingColors.primarySoft
        : isDone
            ? TingColors.doneSoft.withValues(alpha: 0.5)
            : TingColors.surface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 82),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isCurrent ? TingColors.primary : TingColors.line,
            width: isCurrent ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              child: Text(
                '${chapter.index + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: isCurrent ? TingColors.primary : TingColors.muted,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    chapter.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      height: 1.3,
                      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                      color: TingColors.ink,
                    ),
                  ),
                  if (chapter.durationText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        chapter.durationText,
                        style: const TextStyle(fontSize: 15, color: TingColors.muted),
                      ),
                    ),
                ],
              ),
            ),
            if (isDone)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.check_circle_rounded, color: TingColors.done, size: 26),
              ),
            if (isCurrent)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.volume_up_rounded, color: TingColors.primary, size: 26),
              ),
          ],
        ),
      ),
    );
  }
}

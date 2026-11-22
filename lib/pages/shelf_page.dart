import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../models/ting.dart';
import '../player/ting_player.dart';
import '../services/cache/cache_engine.dart';
import '../services/app_log.dart';
import '../services/library.dart';
import '../widgets/common.dart';
import '../widgets/recommend_flow.dart';
import 'add_page.dart';
import 'book_page.dart';

/// 全部书架：一部书一行，字大、行高，右边"接着听"。
///
/// 删除做成"第二层"：平时一个按钮都看不见，点右上角「编辑」才出现勾选框。
/// 老人自己翻书架时永远不会误删，家属要清理时也就两步。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  bool _editing = false;

  /// 选中项用 `来源:书id` 作键，跨来源也不会撞
  final Set<String> _selected = <String>{};

  String _keyOf(ShelfItem it) => '${it.book.source.id}:${it.book.id}';

  void _toggleEdit() {
    setState(() {
      _editing = !_editing;
      _selected.clear();
    });
  }

  void _toggleOne(ShelfItem it) {
    final k = _keyOf(it);
    setState(() {
      if (!_selected.remove(k)) _selected.add(k);
    });
  }

  Future<void> _deleteSelected() async {
    final targets = Library.instance.shelf
        .where((it) => _selected.contains(_keyOf(it)))
        .toList();
    if (targets.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          targets.length == 1 ? '删掉这本书？' : '删掉这 ${targets.length} 本？',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '${targets.map((e) => '《${e.book.title}》').take(5).join('\n')}'
          '${targets.length > 5 ? '\n…等 ${targets.length} 本' : ''}\n\n'
          '会从书架移除，手机里存的声音也一起删掉。\n'
          '书还在网盘/NAS 上，以后重新添加就能回来。',
          style: const TextStyle(fontSize: 17, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(fontSize: 18)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '删除',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TingColors.warn),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final player = TingPlayer.instance;
    final playingId = player.book?.id;
    final playingSource = player.book?.source;

    for (final it in targets) {
      await Library.instance.remove(it.book.source, it.book.id);
      // 只删这本的缓存文件；别的影响不到
      await CacheEngine.instance.deleteBook(it.book.source, it.book.id);
      // 删掉的正是正在听的那本：先停，否则播放页会拿着一个已删的书继续放
      if (playingId == it.book.id && playingSource == it.book.source) {
        await player.stop();
      }
      AppLog.instance.event('book.remove', '从书架删掉《${it.book.title}》');
    }

    if (!mounted) return;
    setState(() {
      _selected.clear();
      _editing = false;
    });
    showTip(context, '已删掉 ${targets.length} 本');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Library.instance,
          builder: (context, _) {
            final shelf = Library.instance.shelf;
            return Column(
              children: [
                TingBar(
                  title: _editing ? '选择要删的书' : '全部书架',
                  actions: [
                    if (shelf.isNotEmpty)
                      TextButton(
                        onPressed: _toggleEdit,
                        child: Text(
                          _editing ? '完成' : '编辑',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: _editing ? TingColors.muted : TingColors.primary,
                          ),
                        ),
                      ),
                  ],
                ),
                Expanded(
                  child: shelf.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(28),
                            child: Text(
                              '书架是空的\n\n点下面的"添加评书"，把网盘里的评书加进来',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: T.fontBody, height: 1.7, color: TingColors.muted),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 16),
                          // 编辑时不再显示"推荐一本"，免得误点
                          itemCount: shelf.length + (_editing ? 0 : 1),
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, i) {
                            if (!_editing && i == shelf.length) return const _RecommendRow();
                            final it = shelf[i];
                            return _row(it);
                          },
                        ),
                ),
                _bottomBar(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(ShelfItem it) {
    final picked = _selected.contains(_keyOf(it));

    return InkWell(
      borderRadius: BorderRadius.circular(T.radius),
      onTap: () {
        if (_editing) {
          _toggleOne(it);
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => BookPage(book: it.book)),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: picked ? TingColors.primarySoft : TingColors.surface,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(
            color: picked ? TingColors.primary : TingColors.line,
            width: picked ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            if (_editing) ...[
              Icon(
                picked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                size: 34,
                color: picked ? TingColors.primary : TingColors.muted,
              ),
              const SizedBox(width: 12),
            ],
            CoverBox(book: it.book, size: 76),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    it.book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: TingColors.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _progressText(it),
                    style: const TextStyle(fontSize: 16, color: TingColors.muted),
                  ),
                  if (it.bookProgress > 0) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: it.bookProgress,
                        minHeight: 7,
                        backgroundColor: TingColors.line,
                        color: TingColors.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!_editing)
              const Icon(Icons.chevron_right_rounded, size: 30, color: TingColors.muted),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    if (_editing) {
      final n = _selected.length;
      return Padding(
        padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 14),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _toggleEdit,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(T.buttonHeight),
                ),
                child: const Text('取消', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: n == 0 ? null : _deleteSelected,
                style: FilledButton.styleFrom(
                  backgroundColor: TingColors.warn,
                  minimumSize: const Size.fromHeight(T.buttonHeight),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 30),
                label: Text(
                  n == 0 ? '选要删的书' : '删除选中的 $n 本',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 14),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AddPage()),
          ),
          icon: const Icon(Icons.add_rounded, size: 34),
          label: const Text('添加评书', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  String _progressText(ShelfItem it) {
    if (it.chapter == null) return it.book.subtitle;
    final pct = (it.bookProgress * 100).round();
    return '听到第 ${it.chapterIndex + 1} 回　$pct%';
  }
}

/// 书架列表末尾的"推荐一本"。
class _RecommendRow extends StatelessWidget {
  const _RecommendRow();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(T.radius),
      onTap: () => startRecommend(context),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: TingColors.primarySoft,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: TingColors.primary.withValues(alpha: 0.4), width: 1.5),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 76,
              child: Icon(Icons.auto_awesome_rounded, size: 40, color: TingColors.primary),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '推荐一本',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: TingColors.primary,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '帮你找一部没听过的',
                    style: TextStyle(fontSize: 16, color: TingColors.muted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 30, color: TingColors.muted),
          ],
        ),
      ),
    );
  }
}

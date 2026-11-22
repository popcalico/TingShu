import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../models/ting.dart';
import '../services/bili_source.dart';
import '../services/library.dart';
import '../services/local_search.dart';
import '../widgets/common.dart';
import 'book_page.dart';

/// 搜索：先翻自己书架，再去网上找。
///
/// 顺序是刻意的——老人找书时十有八九是"我那本水浒传哪儿去了"，
/// 先给本地结果能立刻命中；只有本地没有才需要等网络。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctl = TextEditingController();

  bool _searching = false;
  String _keyword = '';
  List<LocalHit> _local = const [];
  List<TingBook> _remote = const [];
  String? _remoteError;

  /// 网络结果里正在加入书架的那本
  String? _addingId;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _run([String? raw]) async {
    final kw = (raw ?? _ctl.text).trim();
    if (kw.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _keyword = kw;
      _searching = true;
      _remoteError = null;
      _remote = const [];
      // 本地结果同步出，不用等网络——这是"优先本地"的关键
      _local = searchShelf(Library.instance.shelf, kw);
    });

    try {
      final list = await BiliSource.instance.search(kw);
      if (!mounted || _keyword != kw) return;
      setState(() {
        _remote = list;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || _keyword != kw) return;
      setState(() {
        _searching = false;
        _remoteError = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _openLocal(LocalHit hit) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BookPage(book: hit.item.book)),
    );
  }

  Future<void> _openRemote(TingBook b) async {
    final inShelf = Library.instance.find(b.source, b.id) != null;
    if (inShelf) {
      final full = Library.instance.find(b.source, b.id)!.book;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => BookPage(book: full)),
      );
      return;
    }

    setState(() => _addingId = b.id);
    try {
      final full = await BiliSource.instance.detail(b);
      await Library.instance.put(full);
      if (!mounted) return;
      setState(() => _addingId = null);
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => BookPage(book: full)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _addingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没打开：${'$e'.replaceFirst('Exception: ', '')}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const TingBar(title: '搜索评书'),
            _searchBox(),
            Expanded(child: _results()),
          ],
        ),
      ),
    );
  }

  Widget _searchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 4, T.pagePad, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: _run,
              style: const TextStyle(fontSize: 21, color: TingColors.ink),
              decoration: InputDecoration(
                hintText: '书名、演员，或"武松打虎"',
                hintStyle: const TextStyle(fontSize: 19, color: TingColors.muted),
                prefixIcon: const Icon(Icons.search_rounded, size: 30, color: TingColors.muted),
                suffixIcon: _ctl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 26, color: TingColors.muted),
                        onPressed: () {
                          _ctl.clear();
                          setState(() {
                            _keyword = '';
                            _local = const [];
                            _remote = const [];
                            _remoteError = null;
                          });
                        },
                      ),
                filled: true,
                fillColor: TingColors.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(T.radius),
                  borderSide: const BorderSide(color: TingColors.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(T.radius),
                  borderSide: const BorderSide(color: TingColors.line),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 62,
            width: 78,
            child: FilledButton(
              onPressed: () => _run(),
              child: const Text('搜', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _results() {
    if (_keyword.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            '想听什么？\n\n先在自己书架里找，找不到再去网上搜。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: T.fontBody, height: 1.7, color: TingColors.muted),
          ),
        ),
      );
    }

    final rows = <Widget>[];

    if (_local.isNotEmpty) {
      rows.add(_section('书架里 · ${_local.length} 个'));
      for (final hit in _local) {
        rows.add(_localTile(hit));
      }
    }

    rows.add(_section('网上 · 评书', trailing: _searching ? '正在搜…' : null));

    if (_searching && _remote.isEmpty) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
      ));
    } else if (_remoteError != null) {
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '网络搜索没成功：$_remoteError\n可以再点一次「搜」试试。',
          style: const TextStyle(fontSize: 16, height: 1.6, color: TingColors.muted),
        ),
      ));
    } else if (_remote.isEmpty) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '网上也没找到。换个说法试试，比如只输演员名。',
          style: TextStyle(fontSize: 16, height: 1.6, color: TingColors.muted),
        ),
      ));
    } else {
      for (final b in _remote) {
        rows.add(_remoteTile(b));
      }
    }

    if (_local.isEmpty && !_searching) {
      rows.insert(
        0,
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            '书架里没有，下面是从网上找的',
            style: TextStyle(fontSize: 16, color: TingColors.muted),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 24),
      children: rows,
    );
  }

  Widget _section(String title, {String? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: TingColors.ink),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            Text(trailing, style: const TextStyle(fontSize: 16, color: TingColors.muted)),
          ],
        ],
      ),
    );
  }

  Widget _localTile(LocalHit hit) {
    final it = hit.item;
    final ch = hit.chapter;
    final subtitle = ch != null
        ? '${ch.numbered}${ch.title.isEmpty ? '' : '　${ch.title}'}'
        : (it.chapter == null
            ? it.book.subtitle
            : '听到第 ${it.chapterIndex + 1} 回');

    return _tile(
      book: it.book,
      subtitle: subtitle,
      highlight: ch != null,
      trailing: const Icon(Icons.chevron_right_rounded, size: 30, color: TingColors.muted),
      onTap: () => _openLocal(hit),
    );
  }

  Widget _remoteTile(TingBook b) {
    final busy = _addingId == b.id;
    final inShelf = Library.instance.find(b.source, b.id) != null;
    return _tile(
      book: b,
      subtitle: b.subtitle,
      trailing: busy
          ? const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3, color: TingColors.primary),
            )
          : Icon(
              inShelf ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
              size: 32,
              color: inShelf ? TingColors.done : TingColors.primary,
            ),
      onTap: busy ? null : () => _openRemote(b),
    );
  }

  Widget _tile({
    required TingBook book,
    required String subtitle,
    required Widget trailing,
    VoidCallback? onTap,
    bool highlight = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(T.radius),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: highlight ? TingColors.primarySoft : TingColors.surface,
            borderRadius: BorderRadius.circular(T.radius),
            border: Border.all(color: TingColors.line),
          ),
          child: Row(
            children: [
              CoverBox(book: book, size: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: TingColors.ink,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.35,
                            color: highlight ? TingColors.primary : TingColors.muted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

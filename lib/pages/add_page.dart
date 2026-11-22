import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../models/ting.dart';
import '../services/bili_source.dart';
import '../services/app_log.dart';
import '../services/book_group.dart';
import '../services/library.dart';
import '../services/nas/nas_source.dart';
import '../services/quark/quark_api.dart';
import '../services/quark/quark_source.dart';
import '../services/update_service.dart';
import '../widgets/common.dart';
import 'book_page.dart';
import 'nas_settings_page.dart';
import 'quark_login_page.dart';

/// 添加评书（家属用）。两个来源：自己的夸克网盘、网络上的评书。
class AddPage extends StatefulWidget {
  const AddPage({super.key});

  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  TingSource _mode = TingSource.quark;

  bool _loading = false;
  String? _error;
  List<TingBook> _books = const [];

  /// 网盘扫描结果按"文件夹"分好的组（网络评书那次不用）
  List<BookGroup> _groups = const [];

  /// 收起来的组名。列表可能上百行，家属只想看某一组时能折叠。
  final Set<String> _collapsed = <String>{};

  /// 正在整组加入的那一组
  String? _busyGroup;

  /// 扫网盘时的进度文案（"正在翻第 12 个文件夹…"）。
  /// 网盘层级深，一次扫描几十秒，不给文字老人以为卡死了。
  String? _scanText;

  final TextEditingController _kw = TextEditingController();
  static const _masters = ['单田芳', '刘兰芳', '袁阔成', '田连元', '王玥波', '连丽如'];

  String? _addingId;

  @override
  void initState() {
    super.initState();
    _mode = Library.instance.source;
    // NAS 还是测试版功能：标准版里就算上次选过，也退回网盘页
    if (_mode == TingSource.nas &&
        UpdateService.instance.channel != UpdateChannel.beta) {
      _mode = TingSource.quark;
    }
    if (_mode == TingSource.quark) _loadQuark();
    if (_mode == TingSource.nas) _loadNas();
  }

  @override
  void dispose() {
    _kw.dispose();
    super.dispose();
  }

  Future<void> _loadQuark({bool force = false}) async {
    final api = QuarkApi.instance;
    if (!api.hasLogin) {
      setState(() {
        _books = const [];
        _groups = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    if (!Library.instance.quarkConfigured) {
      setState(() {
        _books = const [];
        _groups = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _scanText = '正在看网盘里有哪些书…';
    });
    try {
      final list = await QuarkSource.instance.listBooks(force: force, onProgress: (dirs, files) {
        if (!mounted) return;
        setState(() => _scanText = '正在翻第 $dirs 个文件夹，已找到 $files 个音频…');
      });
      if (!mounted) return;
      setState(() {
        _groups = groupBooks(list);
        _books = const [];
        _loading = false;
        _scanText = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _scanText = null;
        _error = _clean(e);
      });
    }
  }

  Future<void> _loadNas({bool force = false}) async {
    final nas = NasSource.instance;
    if (!nas.configured) {
      setState(() {
        _books = const [];
        _groups = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _scanText = '正在翻 NAS 里的文件夹…';
    });
    try {
      final list = await nas.listBooks(force: force, onProgress: (files) {
        if (!mounted) return;
        setState(() => _scanText = '已经翻到 $files 个文件…');
      });
      if (!mounted) return;
      setState(() {
        _groups = groupBooks(list);
        _books = const [];
        _loading = false;
        _scanText = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _scanText = null;
        _error = _clean(e);
      });
    }
  }

  /// 按来源取完整的书（回目）
  Future<TingBook> _detailOf(TingBook b) {
    switch (b.source) {
      case TingSource.bili:
        return BiliSource.instance.detail(b);
      case TingSource.quark:
        return QuarkSource.instance.detail(b);
      case TingSource.nas:
        return NasSource.instance.detail(b);
    }
  }

  Future<void> _searchBili(String kw) async {
    final q = kw.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _books = const [];
    });
    try {
      final list = await BiliSource.instance.search('$q 评书');
      if (!mounted) return;
      setState(() {
        _books = list;
        _loading = false;
        if (list.isEmpty) _error = '没搜到，换个说法试试（比如只输"单田芳"）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _clean(e);
      });
    }
  }

  Future<void> _add(TingBook b) async {
    setState(() => _addingId = b.id);
    try {
      final full = await _detailOf(b);
      await Library.instance.put(full);
      AppLog.instance.event('book.add', '加入书架《${full.title}》', data: {
        'src': full.source.id,
        'ch': full.chapters.length,
      });
      if (!mounted) return;
      setState(() => _addingId = null);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => BookPage(book: full)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _addingId = null;
        _error = _clean(e);
      });
    }
  }

  String _clean(Object e) => '$e'.replaceFirst('Exception: ', '');

  /// 整组加入书架。
  ///
  /// 不跳播放页——家属一次加十几本，每本都跳走会烦。
  /// 加完留在原地，可以接着加下一组。
  Future<void> _addGroup(BookGroup g) async {
    final pending = g.books
        .where((b) => Library.instance.find(b.source, b.id) == null)
        .toList();
    if (pending.isEmpty) {
      _toast('「${g.name}」里的书都已经在书架上了');
      return;
    }
    setState(() => _busyGroup = g.name);
    var ok = 0;
    for (final b in pending) {
      try {
        final full = await _detailOf(b);
        await Library.instance.put(full);
        ok++;
      } catch (_) {
        // 单本失败不打断整组，最后统一报数
      }
    }
    if (!mounted) return;
    setState(() => _busyGroup = null);
    _toast(ok == pending.length
        ? '已把「${g.name}」$ok 部加入书架'
        : '加入 $ok 部，${pending.length - ok} 部失败（网盘临时取不到）');
  }

  void _toast(String text) {
    showTip(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const TingBar(title: '添加评书'),
            _modeSwitch(),
            const SizedBox(height: 14),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _modeSwitch() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: T.pagePad),
      child: Row(
        children: [
          Expanded(
            child: _ModeButton(
              label: '我的网盘',
              active: _mode == TingSource.quark,
              onTap: () {
                // 已经在这个 Tab 上再点一次 = 重新扫描
                // （家属新存了几本书，不用等缓存过期就能看到）
                final again = _mode == TingSource.quark;
                setState(() => _mode = TingSource.quark);
                Library.instance.setSource(TingSource.quark);
                _loadQuark(force: again);
              },
            ),
          ),
          if (UpdateService.instance.channel == UpdateChannel.beta) ...[
            const SizedBox(width: 10),
            Expanded(
              child: _ModeButton(
                label: '家里的 NAS',
                active: _mode == TingSource.nas,
                onTap: () {
                  final again = _mode == TingSource.nas;
                  setState(() => _mode = TingSource.nas);
                  Library.instance.setSource(TingSource.nas);
                  _loadNas(force: again);
                },
              ),
            ),
          ],
          const SizedBox(width: 10),
          Expanded(
            child: _ModeButton(
              label: '网络评书',
              active: _mode == TingSource.bili,
              onTap: () {
                setState(() {
                  _mode = TingSource.bili;
                  _books = const [];
                  _groups = const [];
                  _error = null;
                });
                Library.instance.setSource(TingSource.bili);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_mode == TingSource.quark) {
      if (!QuarkApi.instance.hasLogin) return _needLogin();
      if (!Library.instance.quarkConfigured) return _needFolder();
    }
    if (_mode == TingSource.nas && !NasSource.instance.configured) {
      return _needNas();
    }
    return Column(
      children: [
        if (_mode == TingSource.bili) _biliSearch(),
        Expanded(child: _list()),
      ],
    );
  }

  Widget _needLogin() {
    return Padding(
      padding: const EdgeInsets.all(T.pagePad),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 64, color: TingColors.warn),
          const SizedBox(height: 16),
          const Text(
            '还没连接夸克网盘',
            style: TextStyle(fontSize: T.fontTitle, fontWeight: FontWeight.w700, color: TingColors.ink),
          ),
          const SizedBox(height: 8),
          const Text(
            '用你自己的夸克账号登录一次，\n以后打开就能直接听网盘里的评书。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: T.fontBody, height: 1.6, color: TingColors.muted),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const QuarkLoginPage()),
              );
              _loadQuark();
            },
            child: const Text('登录夸克网盘'),
          ),
        ],
      ),
    );
  }

  Widget _needFolder() {
    return Padding(
      padding: const EdgeInsets.all(T.pagePad),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.folder_open_rounded, size: 64, color: TingColors.primary),
          const SizedBox(height: 16),
          const Text(
            '选一个放评书的文件夹',
            style: TextStyle(fontSize: T.fontTitle, fontWeight: FontWeight.w700, color: TingColors.ink),
          ),
          const SizedBox(height: 8),
          const Text(
            '网盘里"一部评书一个文件夹，\n一回一个音频文件"这样放好，再选最外面那个文件夹。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: T.fontBody, height: 1.6, color: TingColors.muted),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              final ok = await pickQuarkFolder(context);
              if (ok) _loadQuark();
            },
            child: const Text('选择文件夹'),
          ),
        ],
      ),
    );
  }

  Widget _needNas() {
    return Padding(
      padding: const EdgeInsets.all(T.pagePad),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.dns_rounded, size: 64, color: TingColors.primary),
          const SizedBox(height: 16),
          const Text(
            '还没连接家里的 NAS',
            style: TextStyle(fontSize: T.fontTitle, fontWeight: FontWeight.w700, color: TingColors.ink),
          ),
          const SizedBox(height: 8),
          const Text(
            '填一次 NAS 的地址和账号，\n以后在家就能直接听 NAS 里的评书。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: T.fontBody, height: 1.6, color: TingColors.muted),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NasSettingsPage()),
              );
              if (!mounted) return;
              setState(() {});
              _loadNas();
            },
            child: const Text('去设置 NAS'),
          ),
        ],
      ),
    );
  }

  Widget _biliSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _kw,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _searchBili,
                  style: const TextStyle(fontSize: T.fontBody),
                  decoration: InputDecoration(
                    hintText: '输入书名或说书人',
                    hintStyle: const TextStyle(fontSize: T.fontBody, color: TingColors.muted),
                    filled: true,
                    fillColor: TingColors.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
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
                width: 84,
                height: 60,
                child: FilledButton(
                  onPressed: () => _searchBili(_kw.text),
                  style: FilledButton.styleFrom(minimumSize: const Size(84, 60)),
                  child: const Text('找'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 52,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _masters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) => ActionChip(
                label: Text(_masters[i], style: const TextStyle(fontSize: 17)),
                onPressed: () {
                  _kw.text = _masters[i];
                  _searchBili(_masters[i]);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: TingColors.primary),
              if (_scanText != null) ...[
                const SizedBox(height: 20),
                Text(
                  _scanText!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: T.fontBody, height: 1.5, color: TingColors.muted),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: T.fontBody, height: 1.6, color: TingColors.muted),
          ),
        ),
      );
    }
    if (_mode != TingSource.bili) {
      if (_groups.isEmpty) return _emptyHint('这个文件夹里还没有书');
      return _groupedList();
    }
    if (_books.isEmpty) return _emptyHint('搜一部评书试试，比如"单田芳"');

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 20),
      itemCount: _books.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _bookTile(_books[i]),
    );
  }

  Widget _emptyHint(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: T.fontBody, color: TingColors.muted),
        ),
      ),
    );
  }

  // ---------- 网盘：按文件夹分组 ----------

  Widget _groupedList() {
    final total = _groups.fold<int>(0, (s, g) => s + g.books.length);
    final chapters = _groups.fold<int>(0, (s, g) => s + g.chapterCount);
    // 只有一组时不必再套一层标题，直接列书
    final flat = _groups.length == 1;

    final rows = <Widget>[];
    if (!flat) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          '共 $total 部书、$chapters 个音频，按文件夹分成 ${_groups.length} 组。\n'
          '点书名加入一本，或点「整组加入」把这一组一次加完。',
          style: const TextStyle(fontSize: 15, height: 1.5, color: TingColors.muted),
        ),
      ));
    }
    for (final g in _groups) {
      if (!flat) rows.add(_groupHeader(g));
      if (flat || !_collapsed.contains(g.name)) {
        for (final b in g.books) {
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _bookTile(b),
          ));
        }
      }
    }
    rows.add(const SizedBox(height: 16));

    return ListView(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 20),
      children: rows,
    );
  }

  Widget _groupHeader(BookGroup g) {
    final open = !_collapsed.contains(g.name);
    final shelf = g.books.where((b) => Library.instance.find(b.source, b.id) != null).length;
    final allIn = shelf == g.books.length;
    final busy = _busyGroup == g.name;

    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: TingColors.surface,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: TingColors.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(T.radius),
                onTap: () => setState(() {
                  if (!_collapsed.remove(g.name)) _collapsed.add(g.name);
                }),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 12, 4, 12),
                  child: Row(
                    children: [
                      Icon(
                        open ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                        size: 30,
                        color: TingColors.muted,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              g.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: TingColors.ink,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              allIn
                                  ? '${g.books.length} 部 · 已全部在书架'
                                  : '${g.books.length} 部 · ${g.chapterCount} 回',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: allIn ? TingColors.done : TingColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 3, color: TingColors.primary),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextButton(
                  onPressed: allIn ? null : () => _addGroup(g),
                  child: Text(
                    allIn ? '已加入' : '整组加入',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bookTile(TingBook b) {
    final busy = _addingId == b.id;
    final inShelf = Library.instance.find(b.source, b.id) != null;
    return InkWell(
      borderRadius: BorderRadius.circular(T.radius),
      onTap: busy ? null : () => _add(b),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TingColors.surface,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: TingColors.line),
        ),
        child: Row(
          children: [
            CoverBox(book: b, size: 64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: TingColors.ink,
                    ),
                  ),
                  if (b.subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        b.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, color: TingColors.muted),
                      ),
                    ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 3, color: TingColors.primary),
              )
            else if (inShelf)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.check_circle_rounded, size: 30, color: TingColors.done),
              )
            else
              const Icon(Icons.add_circle_outline_rounded, size: 32, color: TingColors.primary),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ModeButton({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.radius),
      child: Container(
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? TingColors.primary : TingColors.surface,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: active ? TingColors.primary : TingColors.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : TingColors.ink,
          ),
        ),
      ),
    );
  }
}

/// 选夸克网盘里的"评书根目录"。只列文件夹，点进去可以继续往里选。
Future<bool> pickQuarkFolder(BuildContext context) async {
  var fid = '0';
  var stack = <(String, String)>[('0', '全部文件')];

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TingColors.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          final future = QuarkApi.instance.list(fid);
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.8,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      if (stack.length > 1)
                        IconButton(
                          iconSize: 30,
                          onPressed: () {
                            stack = stack.sublist(0, stack.length - 1);
                            fid = stack.last.$1;
                            setSheet(() {});
                          },
                          icon: const Icon(Icons.arrow_back_ios_new_rounded),
                        ),
                      Expanded(
                        child: Text(
                          stack.last.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: T.fontTitle,
                            fontWeight: FontWeight.w700,
                            color: TingColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<QuarkFile>>(
                    future: future,
                    builder: (ctx, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snap.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              '${snap.error}'.replaceFirst('Exception: ', ''),
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: T.fontBody, color: TingColors.muted),
                            ),
                          ),
                        );
                      }
                      final dirs = (snap.data ?? const <QuarkFile>[]).where((f) => f.isDir).toList();
                      if (dirs.isEmpty) {
                        return const Center(
                          child: Text('这里没有子文件夹', style: TextStyle(fontSize: T.fontBody, color: TingColors.muted)),
                        );
                      }
                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: dirs.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final d = dirs[i];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(vertical: 6),
                            leading: const Icon(Icons.folder_rounded, size: 34, color: TingColors.primary),
                            title: Text(
                              d.name,
                              style: const TextStyle(fontSize: T.fontBody, color: TingColors.ink),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  onPressed: () {
                                    fid = d.fid;
                                    stack = [...stack, (d.fid, d.name)];
                                    setSheet(() {});
                                  },
                                  child: const Text('进去'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('选它'),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          await Library.instance.setQuarkRoot(fid, stack.last.$2);
                          // 换了目录，旧的扫描结果必须作废，否则还显示上一个目录的书
                          QuarkSource.instance.invalidate();
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        },
                        child: Text('就用「${stack.last.$2}」'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
  return result == true;
}

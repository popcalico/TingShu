import '../models/ting.dart';
import 'bili_source.dart';
import 'cache/cache_engine.dart';
import 'library.dart';
import 'nas/scanner.dart';
import 'title_key.dart';

/// "推荐一本"的结果。
class RecommendPick {
  RecommendPick({
    required this.book,
    required this.startIndex,
    required this.fromLibrary,
    required this.reason,
  });

  final TingBook book;

  /// 从第几回开始放。推荐一律 0（从头开始）
  final int startIndex;

  /// true = 出自书架（本地已经有的），false = 刚从网上找的
  final bool fromLibrary;

  /// 给界面显示的一句原因
  final String reason;
}

/// 给"推荐一本"挑书。
///
/// 优先级（用户定的）：
/// 1. **本地**：书架上还没放过、回目齐全的书，从头开始；
///    已经缓存到手机里的优先（不费流量、点开就响）。
/// 2. **网络**：必须是评书、播放量高、没听过。
///
/// 去重一律走 [TitleKey]：《水浒传》听过一遍，另一个 UP 主的《水浒传》也不能再推。
class RecommendService {
  RecommendService._();
  static final RecommendService instance = RecommendService._();

  /// 明显不是评书的东西。
  ///
  /// 为什么必须这么狠：B 站上"播放量高的评书"这个位置，长期被郭德纲的单口相声
  /// 占着（播放量比任何评书高一个数量级）。实测第一次上线就直接推了
  /// 《郭德纲单口相声全集》，老人点开听到的是相声。
  static const _notPingshu = [
    '相声', '单口', '对口', '群口', '德云社', '郭德纲', '于谦', '岳云鹏',
    '小品', '脱口秀', '鬼故事', '儿歌', '歌曲', '音乐', '故事会',
    '广播剧', '有声小说', '游戏', '搞笑', '解说', '混剪', 'reaction', '直播回放',
  ];

  /// 只用于"推荐"的评书名家名单。
  ///
  /// 不能直接用 [NasScanner.knownActors]：那张表为了从目录名里认作者，
  /// 把相声演员（郭德纲、马三立、侯宝林…）也收进去了。
  /// 拿它去搜"评书 郭德纲"，搜回来的是相声。
  static const _pingshuActors = [
    '单田芳', '刘兰芳', '袁阔成', '田连元', '连丽如', '王玥波',
    '张少佐', '田战义', '孙一', '赵维莉', '石连君',
  ];

  /// 挑一本。返回 null 表示确实找不到（网络挂了、或者全都听过了）。
  Future<RecommendPick?> pick({void Function(String step)? onStep}) async {
    onStep?.call('看看书架里有没有还没听的…');
    final local = _pickLocal();
    if (local != null) return local;

    onStep?.call('书架里都听过了，正在网上找…');
    return _pickOnline(onStep: onStep);
  }

  // ---------------- 本地 ----------------

  RecommendPick? _pickLocal() {
    final lib = Library.instance;
    // 当前这本要排除掉：老人点"推荐一本"是想要**另一本**，
    // 如果把首页正在显示的那本又推回来，看起来就像按钮没反应。
    final current = lib.current;
    final cands = <ShelfItem>[];
    for (final it in lib.shelf) {
      if (it.book.chapters.isEmpty) continue; // 回目没加载的不算"完整"
      if (_played(it)) continue;
      if (current != null &&
          current.book.id == it.book.id &&
          current.book.source == it.book.source) {
        continue;
      }
      cands.add(it);
    }
    if (cands.isEmpty) return null;

    final cached = {for (final it in cands) it: _cachedCount(it)};
    cands.sort((a, b) {
      final ca = cached[a] ?? 0;
      final cb = cached[b] ?? 0;
      // 1) 整本都在手机里的优先——点开就出声，不依赖网络
      final wholeA = ca >= a.book.chapters.length ? 1 : 0;
      final wholeB = cb >= b.book.chapters.length ? 1 : 0;
      if (wholeA != wholeB) return wholeB.compareTo(wholeA);
      // 2) 缓存得多的优先
      if (ca != cb) return cb.compareTo(ca);
      // 3) 回目多的优先（更像一整部书，而不是零散几回）
      return b.book.count.compareTo(a.book.count);
    });

    final pick = cands.first;
    final whole = (cached[pick] ?? 0) >= pick.book.chapters.length;
    return RecommendPick(
      book: pick.book,
      startIndex: 0,
      fromLibrary: true,
      reason: whole ? '书架里的，已经存在手机上了' : '书架里还没听过的',
    );
  }

  /// 这本书算不算"已经听过"。
  ///
  /// 只"加入书架但一次没点开"不算听过——那正是我们要优先推荐的。
  bool _played(ShelfItem it) =>
      it.finished.isNotEmpty || it.positionMs > 0 || it.chapterIndex > 0;

  int _cachedCount(ShelfItem it) {
    final cache = CacheEngine.instance;
    var n = 0;
    for (final c in it.book.chapters) {
      if (cache.isCached(it.book.source, it.book.id, c.key)) n++;
    }
    return n;
  }

  // ---------------- 网络 ----------------

  Future<RecommendPick?> _pickOnline({void Function(String step)? onStep}) async {
    final bili = BiliSource.instance;
    try {
      await bili.init();
    } catch (_) {
      // 初始化失败也继续：search 内部还有一次机会
    }

    final lib = Library.instance;
    final heard = lib.heardKeys.toList();
    final onShelf = lib.shelf.map((e) => e.book.title).toList();

    // 为什么按演员名分多路搜，而不是只搜"评书"：
    // 只搜"评书"再按播放量排，前排全是相声/段子（播放量高得多）。
    // 按"评书 单田芳"这类词搜，结果的领域就干净了。
    final keywords = <String>[
      for (final a in _pingshuActors.take(6)) '评书 $a',
      '评书',
    ];

    final byId = <String, TingBook>{};
    final seen = <String>{};

    for (final kw in keywords) {
      onStep?.call('正在网上找评书…');
      List<TingBook> list;
      try {
        list = await bili.search(kw, order: 'click'); // 按播放量
      } catch (_) {
        continue;
      }

      for (final b in list) {
        if (b.title.isEmpty) continue;
        if (_isNot(b.title) || _isNot(b.author)) continue;

        final sig = TitleKey.of(b.title);
        if (sig.isEmpty) continue;
        // 听过的 / 已在书架的，跳过（同一部书的别的版本也会被这里挡住）
        if (heard.any((h) => TitleKey.same(h, b.title))) continue;
        if (TitleKey.anySame(onShelf, b.title)) continue;
        // 多路搜索之间、以及同一页里的重复
        if (!seen.add(sig)) continue;

        byId[b.id] = b;
      }
    }

    if (byId.isEmpty) return null;

    // 评书演员的书优先，其次按播放量
    final cands = byId.values.toList()
      ..sort((a, b) {
        final aa = _byActor(a) ? 1 : 0;
        final ab = _byActor(b) ? 1 : 0;
        if (aa != ab) return ab.compareTo(aa);
        return b.playCount.compareTo(a.playCount);
      });

    for (final b in cands.take(8)) {
      onStep?.call('正在看《${b.title}》有多少回…');
      try {
        final full = await bili.detail(b);
        if (full.chapters.isEmpty) continue;

        // 详情页的标题/UP 主/回目名常常比搜索结果更露馅
        // （搜索结果叫"全网最全"，详情里才看到"单口相声"）
        final text = '${full.title} ${full.author} '
            '${full.chapters.take(3).map((c) => c.title).join(' ')}';
        if (_isNot(text)) continue;

        // 评书得成规模：要么回目够多，要么单集够长（有些书一部一集）
        final longSingle =
            full.chapters.length <= 2 && full.chapters.first.durationSec >= 15 * 60;
        if (full.chapters.length < 3 && !longSingle) continue;

        return RecommendPick(
          // 网上的标题往往带「【听书-15岁】《评书 … 全集》」这类噪音，
          // 显示前统一洗一遍；洗空了会退回原标题。
          book: full.copyWith(title: TitleKey.display(full.title)),
          startIndex: 0,
          fromLibrary: false,
          reason: '网上播放量高的',
        );
      } catch (_) {
        // 这一本取不到详情，换下一本
        continue;
      }
    }
    return null;
  }

  bool _isNot(String text) {
    final t = text.toLowerCase();
    return _notPingshu.any((w) => t.contains(w.toLowerCase()));
  }

  bool _byActor(TingBook b) =>
      _pingshuActors.any((a) => b.author.contains(a) || b.title.contains(a));
}

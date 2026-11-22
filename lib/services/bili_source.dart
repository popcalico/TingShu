import '../core/network/api_config.dart';
import '../core/network/bili_client.dart';
import '../models/ting.dart';
import 'nas/scanner.dart';

/// B 站评书源。
///
/// 复用原工程已验证的取流链路：Client 负责 Cookie 预热 / buvid 激活 /
/// WBI 签名 / 风控退避，这里只保留「搜评书 → 取回目 → 取音频」三件事。
class BiliSource {
  BiliSource._();
  static final BiliSource instance = BiliSource._();

  final BiliClient _client = BiliClient.instance;

  /// 明显不是评书的标题特征词（解说、鬼畜、切片、预告…）
  static const _noise = [
    '解说', '合集预告', '花絮', '鬼畜', '混剪', '沙雕', '速看', 'reaction',
    '片段', '名场面', 'cut', '切片', 'reaction', '直播回放', '预告',
  ];

  /// 评书一回一般 20~30 分钟；低于 8 分钟的基本是切片/花絮
  static const _minSeconds = 8 * 60;

  Future<void> init() => _client.initLocal();

  /// 按关键词搜评书。老人用不到，但家属检索、以及"推荐一本"要用。
  ///
  /// [order]：`totalrank`（综合，搜索页默认）/ `click`（按播放量）。
  /// "推荐一本"用 `click`——用户要的是"播放量高的"，不是"综合排序靠前的"。
  Future<List<TingBook>> search(String keyword, {int page = 1, String order = 'totalrank'}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];

    final res = await _client.get(
      BiliEndpoints.searchType,
      query: {
        'search_type': 'video',
        'keyword': kw,
        'page': page,
        'page_size': 20,
        'platform': 'pc',
        'web_location': 1430654,
        'order': order,
      },
      useWbi: true,
      headers: {
        'origin': BiliEndpoints.searchHome,
        'referer': '${BiliEndpoints.searchHome}/video?keyword=${Uri.encodeComponent(kw)}',
      },
    );

    final data = (res.data as Map)['data'] as Map? ?? {};
    final list = data['result'] as List? ?? const [];

    final out = <TingBook>[];
    for (final item in list) {
      if (item is! Map) continue;
      final m = item.cast<String, dynamic>();
      final bvid = '${m['bvid'] ?? ''}';
      if (bvid.isEmpty) continue;

      final title = _clean('${m['title'] ?? ''}');
      if (title.isEmpty) continue;
      if (_noise.any((w) => title.toLowerCase().contains(w.toLowerCase()))) continue;

      final secs = _durationSeconds(m['duration']);
      if (secs > 0 && secs < _minSeconds) continue;

      out.add(TingBook(
        id: bvid,
        source: TingSource.bili,
        title: title,
        author: '${m['author'] ?? ''}',
        cover: _pic('${m['pic'] ?? ''}'),
        playCount: (m['play'] as num?)?.toInt() ?? 0,
      ));
    }
    return out;
  }

  /// 取回目（分P）。评书通常一部一个视频、每回一个分P，
  /// 也有一部分书按「一部一集」发布，这时整个视频就是一回。
  Future<TingBook> detail(TingBook book) async {
    final res = await _client.get(BiliEndpoints.view, query: {'bvid': book.id});
    final data = (res.data as Map)['data'];
    if (data is! Map) {
      throw BiliApiException(-404, '这部书可能已经下架了');
    }
    final m = data.cast<String, dynamic>();
    final owner = (m['owner'] as Map?) ?? const {};
    final pages = (m['pages'] as List?) ?? const [];

    final chapters = <TingChapter>[];
    if (pages.isEmpty) {
      chapters.add(TingChapter(
        index: 0,
        title: _clean('${m['title'] ?? book.title}'),
        key: '1',
        durationSec: (m['duration'] as num?)?.toInt() ?? 0,
      ));
    } else {
      for (var i = 0; i < pages.length; i++) {
        final p = (pages[i] as Map).cast<String, dynamic>();
        chapters.add(TingChapter(
          index: i,
          title: NasScanner.chapterTitle(_clean('${p['part'] ?? '第 ${i + 1} 回'}')),
          key: '${p['cid'] ?? 0}',
          durationSec: (p['duration'] as num?)?.toInt() ?? 0,
        ));
      }
    }

    return TingBook(
      id: book.id,
      source: TingSource.bili,
      title: _clean('${m['title'] ?? book.title}'),
      author: '${owner['name'] ?? book.author}',
      cover: _pic('${m['pic'] ?? book.cover}'),
      chapters: chapters,
      playCount: ((m['stat'] as Map?)?['view'] as num?)?.toInt() ?? book.playCount,
    );
  }

  /// 取这一回的音频地址。返回的地址必须带 Referer 才能下载。
  Future<ResolvedAudio> resolve(TingBook book, TingChapter chapter) async {
    BiliApiException? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 1500 * attempt));
      }
      try {
        final res = await _client.get(
          BiliEndpoints.playUrl,
          query: {
            'bvid': book.id,
            'cid': chapter.key,
            'qn': 80,
            'fnval': 4048,
            'fnver': 0,
            'fourk': 1,
            'try_look': 1,
            'gaia_source': 'prefer-ua',
          },
          useWbi: true,
        );
        final data = (res.data as Map)['data'];
        if (data is! Map) continue;
        final url = _pickAudioUrl(data.cast<String, dynamic>());
        if (url == null) {
          last = BiliApiException(-1, '没有取到声音');
          continue;
        }
        return ResolvedAudio(
          url,
          headers: {
            'Referer': 'https://www.bilibili.com/video/${book.id}',
            'User-Agent': BiliEndpoints.userAgent,
            'Origin': 'https://www.bilibili.com',
          },
          durationMs: ((data['timelength'] as num?)?.toInt()) ?? 0,
        );
      } on BiliApiException catch (e) {
        last = e;
        if (e.code != -412 && e.code != -352 && e.code != -509) rethrow;
      }
    }
    throw last ?? BiliApiException(-1, '取音频失败，请稍后再试');
  }

  /// dash.audio 里挑码率最高的一路
  String? _pickAudioUrl(Map<String, dynamic> data) {
    final dash = data['dash'] as Map?;
    if (dash != null) {
      final flac = (dash['flac'] as Map?)?['audio'] as Map?;
      final flacUrl = flac?['baseUrl'] as String?;
      if (flacUrl != null && flacUrl.isNotEmpty) return flacUrl;

      final audios = (dash['audio'] as List?) ?? const [];
      String? best;
      var bestBw = -1;
      for (final a in audios) {
        if (a is! Map) continue;
        final u = a['baseUrl'] as String?;
        final bw = (a['bandwidth'] as num?)?.toInt() ?? 0;
        if (u != null && u.isNotEmpty && bw > bestBw) {
          best = u;
          bestBw = bw;
        }
      }
      if (best != null) return best;
    }
    // 老接口兜底
    final durl = (data['durl'] as List?) ?? const [];
    if (durl.isNotEmpty && durl.first is Map) {
      return (durl.first as Map)['url'] as String?;
    }
    return null;
  }

  static String _clean(String s) => s
      .replaceAll('<em class="keyword">', '')
      .replaceAll('</em>', '')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .trim();

  static String _pic(String s) {
    final u = s.trim();
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://')) return 'https://${u.substring(7)}';
    return u;
  }

  static int _durationSeconds(Object? v) {
    if (v == null) return 0;
    if (v is num) return v.toInt();
    final s = '$v'.trim();
    if (s.isEmpty) return 0;
    final parts = s.split(':');
    if (parts.length >= 2) {
      var total = 0;
      for (final p in parts) {
        total = total * 60 + (int.tryParse(p.trim()) ?? 0);
      }
      return total;
    }
    return int.tryParse(s) ?? 0;
  }
}

/// 播放源：评书音频从哪里来。
enum TingSource {
  /// B 站公开视频的音频轨（原工程的数据源，评书分类）
  bili,

  /// 用户自己的夸克网盘
  quark,

  /// 家里的 NAS（走 WebDAV，局域网或内网穿透都行）
  nas,
}

extension TingSourceLabel on TingSource {
  String get label => switch (this) {
        TingSource.bili => '网络评书',
        TingSource.quark => '我的网盘',
        TingSource.nas => '家里的 NAS',
      };

  /// 存进本地/缓存索引用的稳定标识，**不要改**（改了老数据就对不上）
  String get id => switch (this) {
        TingSource.bili => 'bili',
        TingSource.quark => 'quark',
        TingSource.nas => 'nas',
      };

  static TingSource parse(String? s) {
    if (s == 'quark') return TingSource.quark;
    if (s == 'nas') return TingSource.nas;
    return TingSource.bili;
  }
}

/// 一回（一章）。
///
/// [key] 是播放源内部标识：B 站用 cid，夸克用文件 fid。
class TingChapter {
  final int index; // 0 起
  final String title;
  final int durationSec;
  final String key;
  final int sizeBytes; // 夸克源才有，用于预估下载时间

  const TingChapter({
    required this.index,
    required this.title,
    required this.key,
    this.durationSec = 0,
    this.sizeBytes = 0,
  });

  /// "第 12 回"——标题里已经有序号就不重复加
  String get numbered {
    if (RegExp(r'^\s*第\s*[0-9一二三四五六七八九十百零〇]+\s*[回集讲话章]').hasMatch(title)) {
      return title;
    }
    // 标题是纯数字（001 / 26）说明它本身就是回目号，
    // 别再叠一层变成"第 1 回　001"——通知栏和锁屏上这行字很短，重复一次就挤了。
    final pure = RegExp(r'^\s*0*(\d{1,4})\s*$').firstMatch(title);
    if (pure != null) {
      return '第 ${int.parse(pure.group(1)!)} 回';
    }
    return '第 ${index + 1} 回　$title';
  }

  String get durationText {
    if (durationSec <= 0) return '';
    final h = durationSec ~/ 3600;
    final m = (durationSec % 3600) ~/ 60;
    if (h > 0) return '$h 小时 $m 分';
    return '$m 分钟';
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'key': key,
        'durationSec': durationSec,
        'sizeBytes': sizeBytes,
      };

  factory TingChapter.fromJson(Map<String, dynamic> m) => TingChapter(
        index: (m['index'] as num?)?.toInt() ?? 0,
        title: m['title'] as String? ?? '',
        key: m['key'] as String? ?? '',
        durationSec: (m['durationSec'] as num?)?.toInt() ?? 0,
        sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
      );
}

/// 一本书（一部评书）。
class TingBook {
  final String id; // B 站 bvid / 夸克文件夹 fid
  final TingSource source;
  final String title;
  final String author; // 单田芳、刘兰芳…
  final String cover;
  final List<TingChapter> chapters;
  final int updatedAt;

  /// 播放量（B 站搜索才有，夸克为 0）。
  /// "推荐一本"要按播放量挑，不存这个字段就只能靠搜索结果顺序，容易被单条爆款带跑。
  final int playCount;

  const TingBook({
    required this.id,
    required this.source,
    required this.title,
    this.author = '',
    this.cover = '',
    this.chapters = const [],
    this.updatedAt = 0,
    this.playCount = 0,
  });

  int get count => chapters.length;

  /// 书架卡片副标题："单田芳 · 128 回"
  String get subtitle {
    final parts = <String>[];
    if (author.isNotEmpty) parts.add(author);
    if (count > 0) parts.add('$count 回');
    return parts.join(' · ');
  }

  TingBook copyWith({List<TingChapter>? chapters, String? title}) => TingBook(
        id: id,
        source: source,
        title: title ?? this.title,
        author: author,
        cover: cover,
        chapters: chapters ?? this.chapters,
        updatedAt: updatedAt,
        playCount: playCount,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source.id,
        'title': title,
        'author': author,
        'cover': cover,
        'updatedAt': updatedAt,
        'playCount': playCount,
        'chapters': chapters.map((e) => e.toJson()).toList(),
      };

  factory TingBook.fromJson(Map<String, dynamic> m) => TingBook(
        id: m['id'] as String? ?? '',
        source: TingSourceLabel.parse(m['source'] as String?),
        title: m['title'] as String? ?? '',
        author: m['author'] as String? ?? '',
        cover: m['cover'] as String? ?? '',
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        playCount: (m['playCount'] as num?)?.toInt() ?? 0,
        chapters: ((m['chapters'] as List?) ?? const [])
            .map((e) => TingChapter.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// 解析出的一路可播放音频。
class ResolvedAudio {
  final String url;
  final Map<String, String> headers;
  final int durationMs;

  const ResolvedAudio(this.url, {this.headers = const {}, this.durationMs = 0});
}

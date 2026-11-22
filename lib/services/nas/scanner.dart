import 'webdav_client.dart';

/// 扫描出来的"一回"（还没入库，只是待确认的草稿）
class NasChapterDraft {
  NasChapterDraft({
    required this.davPath,
    required this.size,
    required this.fileName,
    this.order = 0,
    this.title = '',
    this.part = 0,
  });

  final String davPath;
  final int size;
  final String fileName;

  /// 解析出的回目号，用于排序。解析不出来时用文件顺序兜底。
  int order;

  /// 去掉序号后的标题，可能为空（那就只显示"第 N 回"）
  String title;

  /// 这一回属于书里的第几"段"（直接摆在书目录里的算 0，上部/CD1/001-050
  /// 这类卷目录依次 1、2…）。
  ///
  /// 只在**回目号出现重复**时才拿它排序：有的网盘每一段都从 001 重新编号，
  /// 只按回目号排会把「上部第 1 回」和「下部第 1 回」穿插在一起。
  int part;
}

/// 扫描出来的"一本书"（草稿，等家属确认后才入库）
class NasBookDraft {
  NasBookDraft({
    required this.title,
    required this.author,
    required this.davDir,
    required this.chapters,
  });

  String title;
  String author;

  /// 这本书对应的 NAS 目录（分卷合并后取第一段）
  final String davDir;

  final List<NasChapterDraft> chapters;

  int get totalBytes => chapters.fold(0, (s, c) => s + c.size);
}

/// 从 WebDAV 目录树里认出"哪本书、第几回"。
///
/// 设计原则：**宁可多认错一次让人改，也不要悄悄入库一堆错书。**
/// 所以这里只做"尽量准的自动识别"，结果一律交给人工确认页，
/// 用户可以改书名、取消勾选、把没认出来的手动指定。
///
/// 纯函数，不碰网络，方便单测。
class NasScanner {
  NasScanner._();

  /// 常见评书演员。在路径任意一层出现就认作作者，并从书名里删掉。
  ///
  /// 只放"确定是评书演员"的名字，避免误伤书名（比如"刘兰芳"是作者，
  /// 但"白眉大侠"不能因为含"白"就被当成谁）。
  static const knownActors = <String>[
    '单田芳', '刘兰芳', '袁阔成', '田连元', '连丽如', '王玥波',
    '郭德纲', '于谦', '高峰', '张鹤伦', '曹云金', '何云伟',
    '李伯清', '刘宝瑞', '侯宝林', '马三立', '马季', '姜昆',
    '孙一', '赵维莉', '王刚', '张少佐', '赵本山', '郭鹤鸣',
    '田战义', '石连君', '宋丹丹', '巩宝生', '陈丽君', '王静',
  ];

  /// 书名里要剥掉的噪音词。
  ///
  /// **必须保守**：只删明确的"文件命名噪音"，不碰可能属于书名的词。
  /// 比如不能删"全"字——"全相三国志"是书名。
  static final _noise = RegExp(
    r'(全集|全本|完结|完结版|已完结|精校|精校版|修订版|完整版|无删减|高清|'
    r'典藏版|收藏版|打包|合辑|有声书|有声小说|评书|mp3|MP3|'
    r'超清|正版|经典版)',
  );

  /// 分卷后缀：「水浒传 上部」「三国 第2部分」「隋唐 卷一」
  /// 不剥掉的话，同一本书会被拆成两本
  static final _volumeSuffix = RegExp(
    r'[\s\-—_·]*(第?[上中下]部|[上中下]册|第[一二三四五六七八九十\d]+部分|卷[一二三四五六七八九十\d]*|part\s*\d+)\s*$',
    caseSensitive: false,
  );

  /// 形如（320回）(全120回)【共400集】的容量标注
  static final _countTag = RegExp(
    r'[（(【\[][^）)】\]]{0,6}?\d{1,4}\s*[回集讲章][^）)】\]]{0,6}[）)】\]]',
  );

  /// 第 12 回 / 第十二集 / 第12讲
  static final _cnChapter = RegExp(
    r'第\s*([0-9一二三四五六七八九十百千零〇两]+)\s*[回集讲章]',
  );

  /// 012-xxx / 012.xxx / 012_xxx / 012、xxx
  static final _leadingNum = RegExp(r'^\s*(\d{1,4})\s*[-_.、,，\s]');

  /// 纯数字文件名 012
  static final _pureNum = RegExp(r'^\s*(\d{1,4})\s*$');

  /// 文件名里任意位置的数字
  static final _anyNum = RegExp(r'(\d{1,4})');

  /// 纯数字目录名：`001`、`12` —— 通常是"第几段/第几张碟"
  static final _numDir = RegExp(r'^\s*0*\d{1,4}\s*$');

  /// 数字区间目录名：`001-050`、`1~50回`、`100—150`
  static final _rangeDir = RegExp(
    r'^\s*0*\d{1,4}\s*[-~—–至到]\s*0*\d{1,4}\s*[回集讲章]?\s*$',
  );

  /// 碟号目录名：CD1 / disc 2 / part03
  static final _discDir = RegExp(
    r'^\s*(cd|disc|disk|part|vol|volume)\s*[-_.\s]?\s*\d{1,3}\s*$',
    caseSensitive: false,
  );

  /// 「第12回」「第十二集」这类目录名（后面可能带回目名）
  static final _episodeDir = RegExp(
    r'^\s*第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[回集讲章]',
  );

  /// 主入口：把遍历到的条目变成书单草稿。
  ///
  /// 规则（按优先级）：
  /// 1. **装着音频文件的那个目录 = 一本书**（`水浒传/001.mp3`）；
  /// 2. 书被拆成若干"卷 / 碟 / 集号"子目录时（上部、CD1、001-050、第12回）
  ///    **合并成一本**——不合并的话，一部书会变成几十本"假书"，
  ///    家属在添加页看到的就是一排排分不清的音频；
  /// 3. 最后再按"同作者 + 同书名"合并一次（`水浒传`和`水浒传 下部`
  ///    摆在两个平级目录里的情况）。
  ///
  /// [rootName] 是用户选的那个文件夹名：音频直接摆在根目录时用它当书名。
  static List<NasBookDraft> scan(List<DavEntry> entries, {String rootName = ''}) {
    final root = _DirNode('');
    var hasAudio = false;
    for (final e in entries) {
      if (!e.isAudio) continue;
      hasAudio = true;
      final idx = e.path.lastIndexOf('/');
      final dirPath = idx <= 0 ? '/' : e.path.substring(0, idx);
      _nodeOf(root, dirPath).files.add(e);
    }
    if (!hasAudio) return const [];

    final drafts = <NasBookDraft>[];
    _collect(root, drafts, rootName);

    // 同名同作者（分卷跨目录）合并
    final merged = <String, NasBookDraft>{};
    for (final d in drafts) {
      final key = '${d.author}\u0000${d.title}';
      final exist = merged[key];
      if (exist != null) {
        exist.chapters.addAll(d.chapters);
      } else {
        merged[key] = d;
      }
    }

    final out = <NasBookDraft>[];
    for (final b in merged.values) {
      _sortChapters(b.chapters);
      final seen = <String>{};
      b.chapters.retainWhere((c) => seen.add(c.davPath));
      // 注意：**不要**把 order 重排成数组下标。
      // 解析出来的回目号是真实序号（"第 12 回"就该是 12），
      // 覆盖成 i+1 会让显示和排序全错。
      out.add(b);
    }

    out.sort((a, b) => a.title.compareTo(b.title));
    return out;
  }

  /// 章节排序 + 去重。
  ///
  /// 回目号全局唯一（上部 001-180、下部 181-360）时按号排，这是最准的。
  /// 出现重复号（每一段都从 001 重新编号）时改成先按"段"排，
  /// 否则上下部的第 1 回会穿插在一起。
  static void _sortChapters(List<NasChapterDraft> chapters) {
    final orders = chapters.map((c) => c.order).toList();
    final unique = orders.toSet().length == orders.length;
    chapters.sort((x, y) {
      if (!unique) {
        final p = x.part.compareTo(y.part);
        if (p != 0) return p;
      }
      final c = x.order.compareTo(y.order);
      return c != 0 ? c : x.fileName.compareTo(y.fileName);
    });
  }

  /// 把一棵目录树变成若干本书。
  static void _collect(_DirNode node, List<NasBookDraft> out, String rootName) {
    var directChapters = <NasChapterDraft>[];

    // ① 本目录直接摆着音频 → 它就是一本书
    if (node.files.isNotEmpty) {
      var part = 0;
      _addChapters(directChapters, node.files, part++);
      // 同一本书下面又分「CD1 / 上部 / 001-050」的，一并算进这本书
      for (final c in node.children.values) {
        if (_audioCount(c) == 0) continue;
        if (!_isPartDir(c, node, rootName)) continue;
        _addChapters(directChapters, _allFiles(c), part++);
      }
    } else {
      // ② 本目录没有音频，但所有含音频的子目录都是"卷/碟/集号"
      //    → 整个子树就是一本书（书目录层级高了一层的情况）
      final withAudio = node.children.values.where((c) => _audioCount(c) > 0).toList();
      if (_bookLike(node, rootName) &&
          withAudio.isNotEmpty &&
          withAudio.every((c) => _isPartDir(c, node, rootName))) {
        var part = 0;
        for (final c in withAudio) {
          _addChapters(directChapters, _allFiles(c), part++);
        }
      }
    }

    if (directChapters.isNotEmpty) {
      out.add(NasBookDraft(
        title: _titleFor(node, rootName),
        author: _findActor(_segs(node)),
        davDir: node.path,
        chapters: directChapters,
      ));
    }

    // ③ 其余子目录各自成书
    for (final c in node.children.values) {
      if (_audioCount(c) == 0) continue;
      // 已经并进上面那本书的卷目录，不再单独成书
      if (directChapters.isNotEmpty && _isPartDir(c, node, rootName)) continue;
      _collect(c, out, rootName);
    }
  }

  /// 这个目录名像不像"书名/作者名"？
  ///
  /// 只有像书名时，才敢把它的纯数字子目录当成"卷"合并——
  /// 否则 `武侠/01/`、`武侠/02/` 这种"数字目录本身就是一本书"的摆法
  /// 会被并成一本《武侠》。
  static bool _bookLike(_DirNode node, String rootName) {
    final raw = node.parent == null ? rootName : node.name;
    final t = _cleanTitle(raw);
    if (t.isEmpty) return false;
    if (knownActors.contains(t)) return false;
    return true;
  }

  /// 子目录是不是"同一个书里的卷第"。
  static bool _isPartDir(_DirNode child, _DirNode parent, String rootName) {
    final raw = child.name.trim();
    if (raw.isEmpty) return false;
    // 「上部 / 下册 / 卷一」这类：清洗后什么都不剩，一定不是独立书名
    if (_cleanTitle(raw).isEmpty) {
      // 但纯演员名（`袁阔成/`）清洗后同样是空——它是**作者目录**，
      // 不是卷目录。当成卷的话，作者下所有书会被并成一本《作者名》，
      // 一部几百回的书库就变成"一本书 800 回"，全乱。
      if (knownActors.contains(raw)) return false;
      return true;
    }
    // 纯数字 / 数字区间 / CD1：只有当父目录像书名时才当成卷
    if (!_bookLike(parent, rootName)) return false;
    return _numDir.hasMatch(raw) ||
        _rangeDir.hasMatch(raw) ||
        _discDir.hasMatch(raw) ||
        _episodeDir.hasMatch(raw);
  }

  /// 书目录往上找到的、能当书名的那个名字。
  static String _titleFor(_DirNode node, String rootName) {
    final own = _cleanTitle(node.name);
    if (own.isNotEmpty) return own;
    var p = node.parent;
    while (p != null) {
      final cand = _cleanTitle(p.name);
      if (cand.isNotEmpty) return cand;
      p = p.parent;
    }
    final rootTitle = _cleanTitle(rootName);
    if (rootTitle.isNotEmpty) return rootTitle;
    return node.name.isEmpty ? '未命名' : node.name;
  }

  static List<String> _segs(_DirNode node) {
    final out = <String>[];
    var n = node;
    while (n.parent != null) {
      out.insert(0, n.name);
      n = n.parent!;
    }
    return out;
  }

  static int _audioCount(_DirNode node) {
    final cached = node.audioCount;
    if (cached != null) return cached;
    var n = node.files.length;
    for (final c in node.children.values) {
      n += _audioCount(c);
    }
    node.audioCount = n;
    return n;
  }

  static List<DavEntry> _allFiles(_DirNode node) {
    final out = <DavEntry>[...node.files];
    for (final c in node.children.values) {
      out.addAll(_allFiles(c));
    }
    return out;
  }

  static _DirNode _nodeOf(_DirNode root, String dirPath) {
    var node = root;
    for (final seg in dirPath.split('/')) {
      if (seg.isEmpty) continue;
      node = node.children.putIfAbsent(seg, () => _DirNode(seg, node));
    }
    return node;
  }

  // ---------- 书名 / 作者 ----------

  static String _findActor(List<String> segs) {
    for (final s in segs) {
      for (final a in knownActors) {
        if (s.contains(a)) return a;
      }
    }
    return '';
  }

  /// 清洗目录名 → 书名。保守：只删确定是噪音的东西。
  static String _cleanTitle(String raw) {
    var s = raw;

    // 「单田芳 水浒传」这种作者打头的，去掉作者
    for (final a in knownActors) {
      if (s.startsWith(a)) {
        s = s.substring(a.length);
        break;
      }
    }

    s = s.replaceAll(_countTag, ' ');

    // 竖线分隔的取"最有可能是书名"的一段：
    // 形如「单田芳 | 长篇评书 | 全本 【水浒传】 | 64小时助眠」
    if (s.contains('|') || s.contains('｜')) {
      final parts = s
          .split(RegExp(r'[|｜]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (parts.length > 1) {
        // 优先选带书名号的一段
        final quoted = parts.firstWhere(
          (p) => p.contains('《') || p.contains('【') || p.contains('['),
          orElse: () => '',
        );
        s = quoted.isNotEmpty ? quoted : parts.reduce((a, b) => a.length >= b.length ? a : b);
      }
    }

    s = s.replaceAll(_noise, ' ');
    // 目录名前缀的编号：「01 水浒传」「07-隋唐演义」。
    // 不剥的话书名会带个没意义的序号，分组显示时一眼看不出是什么书。
    s = s.replaceFirst(RegExp(r'^\s*\d{1,4}\s*[-_.、,，\s]\s*'), '');
    // 反复剥分卷后缀，直到剥不动
    while (true) {
      final next = s.replaceFirst(_volumeSuffix, '');
      if (next == s) break;
      s = next;
    }
    s = s.replaceAll(RegExp(r'[《》【】\[\]]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 去掉首尾的标点/分隔符
    s = s.replaceAll(RegExp(r'^[\s\-—_·、,，。.]+'), '');
    s = s.replaceAll(RegExp(r'[\s\-—_·、,，。.]+$'), '');

    return s.trim();
  }

  // ---------- 章节 ----------

  /// 给外部（B 站分P名）复用同一套回目清洗。
  ///
  /// B 站分P名常是「001回-鞭督邮刘备走代州」「第12回 武松打虎」，
  /// 直接显示会和播放页自己加的"第 N 回"叠成「第 1 回　001回-鞭督邮…」。
  static String chapterTitle(String raw) {
    final base = _stripExt(raw.trim());
    if (base.isEmpty) return raw;
    final hit = _parseNumber(base);
    final t = _cleanChapterTitle(base, hit);
    return t.isEmpty ? base : t;
  }

  /// 把一批音频文件追加成回目草稿。
  ///
  /// [part] 是"第几段"：直接摆在书目录里的算 0，上部/CD1/001-050 依次往后。
  static void _addChapters(List<NasChapterDraft> out, List<DavEntry> files, int part) {
    // 先按文件名排序，作为"解析不出序号"时的兜底顺序
    final sorted = [...files]..sort((a, b) => a.name.compareTo(b.name));

    for (var i = 0; i < sorted.length; i++) {
      final f = sorted[i];
      final base = _stripExt(f.name);
      final parsed = _parseNumber(base);
      out.add(NasChapterDraft(
        davPath: f.path,
        size: f.size,
        fileName: f.name,
        order: parsed?.value ?? (i + 1),
        title: _cleanChapterTitle(base, parsed),
        part: part,
      ));
    }
  }

  static String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 从文件名里挖出回目号。命中即停，按"越明确越优先"的顺序。
  static _NumHit? _parseNumber(String base) {
    // 1) 第N回 / 第N集 —— 最明确
    final cn = _cnChapter.firstMatch(base);
    if (cn != null) {
      final v = _toInt(cn.group(1)!);
      if (v != null) return _NumHit(v, cn.start, cn.end);
    }
    // 2) 012-、012.
    final lead = _leadingNum.firstMatch(base);
    if (lead != null) {
      final v = int.tryParse(lead.group(1)!);
      if (v != null) return _NumHit(v, lead.start, lead.end);
    }
    // 3) 纯数字
    final pure = _pureNum.firstMatch(base);
    if (pure != null) {
      final v = int.tryParse(pure.group(1)!);
      if (v != null) return _NumHit(v, pure.start, pure.end);
    }
    // 4) 任意位置数字（水浒传012）
    final any = _anyNum.firstMatch(base);
    if (any != null) {
      final v = int.tryParse(any.group(1)!);
      if (v != null) return _NumHit(v, any.start, any.end);
    }
    return null;
  }

  static String _cleanChapterTitle(String base, _NumHit? hit) {
    var s = base;
    if (hit != null) {
      s = s.substring(0, hit.start) + s.substring(hit.end);
    }
    s = s.replaceAll(RegExp(r'^[\s\-_.、,，]+'), '');
    // 序号后面常跟一个「回 / 集 / 讲」（B 站分P名「001回-鞭督邮」）。
    // 只删数字会剩下「回-鞭督邮」，播放页再拼一次"第 N 回"就成了
    // 「第 1 回　回-鞭督邮」，很难看。
    s = s.replaceAll(RegExp(r'^第?\s*[回集讲章节]\s*[\-_.、,，:：]*\s*'), '');
    s = s.replaceAll(RegExp(r'^[\s\-_.、,，]+'), '');
    s = s.replaceAll(RegExp(r'[\s\-_.、,，]+$'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// 中文数字转整数。支持「十二」「一百零五」「两千」这类常见写法。
  static int? _toInt(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final direct = int.tryParse(s);
    if (direct != null) return direct;

    const digits = {
      '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    };
    const units = {'十': 10, '百': 100, '千': 1000};

    var total = 0;
    var current = 0;
    for (final ch in s.split('')) {
      if (digits.containsKey(ch)) {
        current = digits[ch]!;
      } else if (units.containsKey(ch)) {
        final u = units[ch]!;
        if (current == 0) current = 1;
        total += current * u;
        current = 0;
      } else {
        return null; // 出现不认识的字符，放弃
      }
    }
    total += current;
    return total == 0 ? null : total;
  }
}

/// 扫描用的目录节点。只装音频文件和子目录，不装普通文件。
class _DirNode {
  _DirNode(this.name, [this.parent]);

  final String name;
  final _DirNode? parent;
  final Map<String, _DirNode> children = <String, _DirNode>{};
  final List<DavEntry> files = <DavEntry>[];
  int? audioCount;

  String get path {
    if (parent == null) return '/';
    final base = parent!.path;
    return base == '/' ? '/$name' : '$base/$name';
  }
}

class _NumHit {
  _NumHit(this.value, this.start, this.end);
  final int value;
  final int start;
  final int end;
}

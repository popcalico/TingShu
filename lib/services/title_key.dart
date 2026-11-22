import 'nas/scanner.dart';

/// 书名指纹：判断"这两条到底是不是同一部书"。
///
/// 为什么需要它 —— 同一个《水浒传》在网盘和 B 站上会有一堆版本：
/// ```
/// 水浒传 单田芳 全360回
/// 【评书】水浒传（单田芳）高清
/// 水浒传 上部 001-180
/// 水浒全传
/// ```
/// 如果只按书名原字符串比较，这四条会被当成四本不同的书。
/// 结果就是：老人刚听完《水浒传》，点"推荐一本"，程序又给他推一遍水浒传。
///
/// 做法：把"装饰性信息"全部剥掉，只留下书名的骨架。
/// - 剥括号内容（【完结】、（单田芳）、(320回)）
/// - 剥演员名（单田芳、刘兰芳…，直接用扫描器那张表，不另建一份）
/// - 剥噪音词（评书、全集、高清、连播…）
/// - 剥回目号 / 容量标注 / 分卷后缀
/// - 去掉所有标点、空格、符号，转小写
///
/// 纯函数，不碰网络，方便单测。
class TitleKey {
  TitleKey._();

  /// 只放"确定是装饰"的词。别把可能属于书名的字放进来
  /// （比如"全"——"全相三国志"是书名）。
  static const _noiseWords = [
    '有声小说', '有声书', '评书', '听书', '音频', '录音', '原声', '现场版',
    '全集', '全本', '完整版', '未删减', '无删减', '完结', '连载', '连播',
    '高清', '超清', '蓝光', '正版', '免费', '合集', '长篇', '经典', '珍藏',
    'mp3', 'MP3', 'm4a',
  ];

  /// 括号及其内容：（单田芳）【完结】[320回]「上部」
  static final _bracket = RegExp(r'[（(【\[「『][^）)】\]」』]*[）)】\]」』]');

  /// 第 12 回 / 第十二集 / 第12讲
  static final _chapterTag = RegExp(r'第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[回集讲章]');

  /// 320回 / 全360集 / 共120讲
  static final _countTag = RegExp(r'[全共]?\s*[0-9]{1,4}\s*[回集讲章]');

  /// 上部 / 下册 / 第2部分 / 卷一 / Part 3
  static final _volumeTag = RegExp(
    r'第?[上中下]部|[上中下]册|第[一二三四五六七八九十0-9]+部分|卷[一二三四五六七八九十0-9]*|part\s*[0-9]+',
    caseSensitive: false,
  );

  /// 汉字、字母、数字以外的一律丢掉（标点、空格、书名号、竖线…）
  static final _junk = RegExp(r'[^\u4e00-\u9fa5a-zA-Z0-9]');

  /// 取指纹。空串表示这个标题没法用来判断（调用方应跳过）。
  static String of(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';

    // 去掉扩展名（从网盘文件直接来的标题）
    final dot = s.lastIndexOf('.');
    if (dot > 0 && s.length - dot <= 5) s = s.substring(0, dot);

    s = s.replaceAll(_bracket, ' ');

    // 演员名：和扫描器共用一张表，避免两处不一致
    for (final actor in NasScanner.knownActors) {
      s = s.replaceAll(actor, ' ');
    }

    for (final w in _noiseWords) {
      s = s.replaceAll(w, ' ');
    }

    s = s.replaceAll(_chapterTag, ' ');
    s = s.replaceAll(_countTag, ' ');
    s = s.replaceAll(_volumeTag, ' ');

    // 「水浒全传」和「水浒传」是同一部书的两种版本名，归一成「水浒传」。
    // 注意只动"全传"：'后传'/'续集'是另一部书，绝不能合并。
    s = s.replaceAll('全传', '传');

    s = s.replaceAll(_junk, '');

    return s.toLowerCase();
  }

  /// 给人看的书名：剥掉装饰，但保留正常的字和标点结构。
  ///
  /// 「【听书-15岁】《评书 三国演义 365回全集》」→「三国演义」
  /// 老人在通知栏/首页第一眼看到的应该是书名本身，不是 UP 主的标题党。
  /// 剥完为空就退回原文，宁可难看也不能显示空白。
  static String display(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return raw;

    s = s.replaceAll(_bracket, ' ');
    for (final actor in NasScanner.knownActors) {
      s = s.replaceAll(actor, ' ');
    }
    for (final w in _noiseWords) {
      s = s.replaceAll(w, ' ');
    }
    s = s.replaceAll(_countTag, ' ');
    s = s.replaceAll(_volumeTag, ' ');
    s = s.replaceAll(RegExp(r'[《》「」]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'^[\s\-—_·、,，。.]+'), ' ');
    s = s.replaceAll(RegExp(r'[\s\-—_·、,，。.]+$'), ' ').trim();

    return s.isEmpty ? raw : s;
  }

  /// 两个标题是不是同一部书。
  ///
  /// 除了指纹相等，还做一次"包含"判断：
  /// 「水浒传」和「水浒全传」既不相等也不互相包含，但「三国」和「三国演义」
  /// 这种一长一短的情况，包含关系能兜住。
  /// 宁可少推一本，也不要把听过的书再推一遍——对老人来说前者几乎无害，后者很烦。
  static bool same(String a, String b) {
    final x = of(a);
    final y = of(b);
    if (x.isEmpty || y.isEmpty) return false;
    if (x == y) return true;
    if (x.length >= 2 && y.length >= 2 && (x.contains(y) || y.contains(x))) return true;
    return false;
  }

  /// [titles] 里任意一条和 [title] 是同一部书
  static bool anySame(Iterable<String> titles, String title) {
    for (final t in titles) {
      if (same(t, title)) return true;
    }
    return false;
  }
}

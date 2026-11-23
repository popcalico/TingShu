import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ting.dart';
import 'app_wipe.dart';

/// 一条播放记录：一本书记到"最近一次听到哪儿"。
///
/// 为什么按**书**收，而不是按"每次播放"收：
/// 一部评书动辄两三百回，一晚上能连听十几回。按次记，历史列表很快就被
/// 同一本书刷满，家属翻两页也看不出"老人这几天在听什么"。
/// 所以同一本书只留最新一条，位置不断往前更新——这才是"播放历史"该有的样子。
class HistoryEntry {
  final String bookId;
  final TingSource source;
  final String title;
  final String author;
  final String cover;

  /// 最近听到第几回（0 起）
  final int chapterIndex;

  /// 那一回的显示文本（"第 12 回"），存下来是为了书被删掉后还能显示
  final String chapterTitle;

  /// 这本书一共多少回
  final int totalChapters;

  /// 最后一次播放的时间
  final int at;

  const HistoryEntry({
    required this.bookId,
    required this.source,
    required this.title,
    this.author = '',
    this.cover = '',
    this.chapterIndex = 0,
    this.chapterTitle = '',
    this.totalChapters = 0,
    required this.at,
  });

  /// 跨来源不会撞的键
  String get key => '${source.id}:$bookId';

  /// "第 2 回" 这一段：标题里带序号就用原标题里的写法
  String get chapterLabel {
    final m = _chapterNo.firstMatch(chapterTitle);
    if (m != null) return m.group(0)!.trim();
    return '第 ${chapterIndex + 1} 回';
  }

  /// 序号后面的故事名（"竖窑作乱董卓进京"）。
  ///
  /// 单独拆出来是因为原来把它和"第几回 · 几点"挤在一行，
  /// 长回目会把时间挤没——老人最需要看的恰恰是"什么时候听的"。
  String get chapterName {
    final m = _chapterNo.firstMatch(chapterTitle);
    if (m != null) return chapterTitle.substring(m.end).trim();
    return chapterTitle.trim();
  }

  static final _chapterNo = RegExp(r'^\s*第\s*[0-9一二三四五六七八九十百零〇]+\s*[回集讲话章]');

  /// 只给封面用：CoverBox 只要 title 和 cover，
  /// 不用把整本书（含几百回）重新构造出来。
  TingBook get asBook => TingBook(
        id: bookId,
        source: source,
        title: title,
        author: author,
        cover: cover,
      );

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'src': source.id,
        'title': title,
        'author': author,
        'cover': cover,
        'ch': chapterIndex,
        'chTitle': chapterTitle,
        'total': totalChapters,
        'at': at,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> m) => HistoryEntry(
        bookId: '${m['bookId'] ?? ''}',
        source: TingSourceLabel.parse(m['src'] as String?),
        title: '${m['title'] ?? ''}',
        author: '${m['author'] ?? ''}',
        cover: '${m['cover'] ?? ''}',
        chapterIndex: (m['ch'] as num?)?.toInt() ?? 0,
        chapterTitle: '${m['chTitle'] ?? ''}',
        totalChapters: (m['total'] as num?)?.toInt() ?? 0,
        at: (m['at'] as num?)?.toInt() ?? 0,
      );
}

/// 播放历史，存本地。
///
/// 只存"书名 / 作者 / 封面 / 第几回 / 时间"这几项——不存回目列表，
/// 否则 120 本书 × 365 回会让 SharedPreferences 里多出几 MB 的 JSON，
/// 每次保存都在主线程序列化，老人手机上是实打实的卡顿。
class PlayHistory extends ChangeNotifier {
  PlayHistory._();

  static final PlayHistory instance = PlayHistory._();

  static const _kHistory = 'ts_history';
  static const _max = 60;

  final List<HistoryEntry> _entries = [];

  /// 新的在前
  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  bool _ready = false;
  bool get ready => _ready;

  /// 同一本书在 [窗口] 内重复播放，只更新时间，不重复插一条
  static const window = Duration(minutes: 10);

  Future<void> load() async {
    if (_ready) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kHistory);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final e in list) {
            try {
              _entries.add(HistoryEntry.fromJson((e as Map).cast<String, dynamic>()));
            } catch (_) {
              // 单条坏了只跳过那一条，不影响其它历史
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[history] 读播放历史失败：$e');
    }
    _ready = true;
    notifyListeners();
  }

  /// 播放真正出声之后调一次。
  ///
  /// 不在点书的那一刻记：点了却因为网盘 403 没放出来，历史里会出现
  /// 一本"其实没听过"的书，家属看了会以为老人听过了。
  Future<void> record(
    TingBook book,
    int chapterIndex, {
    String chapterTitle = '',
    int totalChapters = 0,
  }) async {
    if (AppWipe.wiping) return;
    final now = DateTime.now().millisecondsSinceEpoch;

    _entries.removeWhere((e) => e.source == book.source && e.bookId == book.id);
    _entries.insert(
      0,
      HistoryEntry(
        bookId: book.id,
        source: book.source,
        title: book.title,
        author: book.author,
        cover: book.cover,
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        totalChapters: totalChapters > 0 ? totalChapters : book.chapters.length,
        at: now,
      ),
    );
    if (_entries.length > _max) {
      _entries.removeRange(_max, _entries.length);
    }
    await _save();
    notifyListeners();
  }

  /// 删除单条（家属清理用）
  Future<void> remove(String sourceId, String bookId) async {
    _entries.removeWhere((e) => e.source.id == sourceId && e.bookId == bookId);
    await _save();
    notifyListeners();
  }

  Future<void> clear() async {
    _entries.clear();
    await _save();
    notifyListeners();
  }

  /// 给书架备份用：导出历史（换手机时一起搬过去）
  List<Map<String, dynamic>> exportState() =>
      _entries.map((e) => e.toJson()).toList();

  /// 从备份恢复历史。逐条容错，一条坏了只跳过那一条。
  Future<void> applyState(List<dynamic> raw) async {
    if (!_ready) return;
    final parsed = <HistoryEntry>[];
    for (final e in raw) {
      try {
        parsed.add(HistoryEntry.fromJson((e as Map).cast<String, dynamic>()));
      } catch (_) {}
    }
    if (parsed.isEmpty) return;
    _entries
      ..clear()
      ..addAll(parsed.take(_max));
    await _save();
    notifyListeners();
  }

  /// 清除全部数据时一并清空（内存 + 磁盘都由原生清，这里只保证内存不残留）
  void resetForWipe() {
    _entries.clear();
    _ready = false;
    notifyListeners();
  }

  Future<void> _save() async {
    if (AppWipe.wiping) return;
    if (!_ready) return; // 还没读出来就写，会把别人的历史覆盖成空
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kHistory,
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[history] 保存播放历史失败：$e');
    }
  }
}

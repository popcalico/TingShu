import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/ting.dart';

/// 一条缓存记录（一回音频 = 一个文件）。
class CacheEntry {
  final String key;
  final String bookId;
  final String source;
  final String bookTitle;
  final String chapterTitle;
  final int index;
  int bytes;
  int lastUsedAt;

  /// 这一回是否已经听完。淘汰时优先删"已听完"的，
  /// 这样老人回头重听刚听过的内容不用重新下载。
  bool finished;

  CacheEntry({
    required this.key,
    required this.bookId,
    required this.source,
    required this.bookTitle,
    required this.chapterTitle,
    required this.index,
    required this.bytes,
    required this.lastUsedAt,
    this.finished = false,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'bookId': bookId,
        'source': source,
        'bookTitle': bookTitle,
        'chapterTitle': chapterTitle,
        'index': index,
        'bytes': bytes,
        'lastUsedAt': lastUsedAt,
        'finished': finished,
      };

  factory CacheEntry.fromJson(Map<String, dynamic> m) => CacheEntry(
        key: m['key'] as String? ?? '',
        bookId: m['bookId'] as String? ?? '',
        source: m['source'] as String? ?? 'bili',
        bookTitle: m['bookTitle'] as String? ?? '',
        chapterTitle: m['chapterTitle'] as String? ?? '',
        index: (m['index'] as num?)?.toInt() ?? 0,
        bytes: (m['bytes'] as num?)?.toInt() ?? 0,
        lastUsedAt: (m['lastUsedAt'] as num?)?.toInt() ?? 0,
        finished: m['finished'] == true,
      );
}

/// 音频缓存引擎：随听随缓 + 10G 上限 + 最久未听优先淘汰。
///
/// 为什么统一走"先落盘再播放"：夸克直链和 B 站音频地址都要求带 Referer/Cookie
/// 才能取，直接交给播放器容易 403；先下到本地再播，播放器只读本地文件，
/// 稳定得多，也顺便把缓存做完了。代价是某一回第一次听要等它下完
/// （评书 mp3 通常 10~20MB，几秒到二十几秒，界面上有进度提示）。
class CacheEngine extends ChangeNotifier {
  CacheEngine._();
  static final CacheEngine instance = CacheEngine._();

  /// 缓存上限：10GB
  static const int maxBytes = 10 * 1024 * 1024 * 1024;

  late Directory _dir;
  final Map<String, CacheEntry> _index = {};
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      followRedirects: true,
      validateStatus: (s) => s != null && s < 400,
    ),
  );

  /// 正在下载的任务（同一文件不重复下）
  final Map<String, Future<String>> _inflight = {};

  /// 预取队列：当前正在播的回之后的两三回
  final List<_PrefetchTask> _queue = [];
  bool _draining = false;
  String? _busyKey;

  int _usedBytes = 0;
  bool _ready = false;

  bool get ready => _ready;
  int get usedBytes => _usedBytes;
  int get limitBytes => maxBytes;

  double get usedRatio => (_usedBytes / maxBytes).clamp(0.0, 1.0);

  /// 当前正在缓存的那一回（用于播放页显示"正在缓存 第N回"）
  String? get busyKey => _busyKey;

  static String keyOf(TingSource source, String bookId, String chapterKey) =>
      sha1.convert(utf8.encode('${source.id}|$bookId|$chapterKey')).toString();

  Future<void> load() async {
    if (_ready) return;
    final base = await getExternalStorageDirectory() ?? await getApplicationSupportDirectory();
    _dir = Directory('${base.path}/ting_audio');
    if (!await _dir.exists()) await _dir.create(recursive: true);

    final idx = File('${_dir.path}/index.json');
    if (await idx.exists()) {
      try {
        final raw = jsonDecode(await idx.readAsString());
        for (final e in (raw as List)) {
          final entry = CacheEntry.fromJson((e as Map).cast<String, dynamic>());
          final f = File('${_dir.path}/${entry.key}.audio');
          if (await f.exists()) {
            entry.bytes = await f.length();
            _index[entry.key] = entry;
          }
        }
      } catch (_) {
        // 索引坏了不影响听书，重建即可
      }
    }
    _recount();
    _ready = true;
    notifyListeners();
  }

  void _recount() {
    _usedBytes = _index.values.fold(0, (s, e) => s + e.bytes);
  }

  /// 清除全部数据后把内存里的索引清空（磁盘文件已被原生删掉）。
  void resetForWipe() {
    _index.clear();
    _queue.clear();
    _usedBytes = 0;
    _busyKey = null;
    _ready = false;
    notifyListeners();
  }

  String _pathOf(String key) => '${_dir.path}/$key.audio';

  /// 已缓存的本地路径；没有就返回 null。
  ///
  /// 除了查索引，还要确认文件真的在：缓存目录可能被系统清理、
  /// 被用户在设置里清空、或者升级时换了目录，索引还在但文件没了。
  /// 这时候必须当作"没缓存"重新取，否则播放器会拿到一个不存在的路径，
  /// 表现为点开就报错。
  String? cachedPath(TingSource source, String bookId, String chapterKey) {
    final key = keyOf(source, bookId, chapterKey);
    if (!_index.containsKey(key)) return null;
    final path = _pathOf(key);
    if (!File(path).existsSync()) {
      _index.remove(key);
      _recount(); // 罕见路径（文件被外部删掉），顺手把占用统计修正
      return null;
    }
    return path;
  }

  bool isCached(TingSource source, String bookId, String chapterKey) =>
      cachedPath(source, bookId, chapterKey) != null;

  /// 取这一回的本地文件路径；没缓存就下载。
  ///
  /// [resolve] 由播放源提供，负责换出真实地址和需要带的请求头。
  /// [onProgress] 回调 0~1 的进度（total 未知时为 -1）。
  Future<String> obtain(
    TingBook book,
    TingChapter chapter, {
    required Future<ResolvedAudio> Function() resolve,
    void Function(double progress, int receivedBytes)? onProgress,
  }) async {
    await load();
    final key = keyOf(book.source, book.id, chapter.key);

    final existing = _index[key];
    if (existing != null) {
      final f = File(_pathOf(key));
      if (await f.exists() && await f.length() > 0) {
        existing.lastUsedAt = DateTime.now().millisecondsSinceEpoch;
        _persist();
        return f.path;
      }
      _index.remove(key);
    }

    final running = _inflight[key];
    if (running != null) return running;

    final task = _download(key, book, chapter, resolve, onProgress);
    _inflight[key] = task;
    try {
      return await task;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<String> _download(
    String key,
    TingBook book,
    TingChapter chapter,
    Future<ResolvedAudio> Function() resolve,
    void Function(double, int)? onProgress,
  ) async {
    final audio = await resolve();
    return _downloadFrom(key, book, chapter, audio, onProgress);
  }

  /// 边播边存：直链已经拿到了，播放器正在用它放，
  /// 这里在后台把整回补齐到本地。
  ///
  /// 不阻塞播放、失败也不影响听——最多是下次还得再下。
  Future<void> saveInBackground(
    TingBook book,
    TingChapter chapter,
    ResolvedAudio audio,
  ) async {
    await load();
    final key = keyOf(book.source, book.id, chapter.key);
    final existing = _index[key];
    if (existing != null) {
      final f = File(_pathOf(key));
      if (await f.exists() && await f.length() > 0) return;
    }
    if (_inflight.containsKey(key)) return;

    final task = _downloadFrom(key, book, chapter, audio, null);
    _inflight[key] = task;
    try {
      await task;
    } catch (e) {
      // 后台补存失败就失败，正在播的那一路不受影响
      debugPrint('[cache] 边播边存失败：$e');
    } finally {
      _inflight.remove(key);
    }
  }

  Future<String> _downloadFrom(
    String key,
    TingBook book,
    TingChapter chapter,
    ResolvedAudio audio,
    void Function(double, int)? onProgress,
  ) async {
    _busyKey = key;
    notifyListeners();

    final tmp = File('${_dir.path}/$key.part');
    final target = File(_pathOf(key));
    IOSink? sink;
    try {
      final res = await _dio.get<ResponseBody>(
        audio.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: audio.headers,
        ),
      );

      final total = int.tryParse(res.headers.value(Headers.contentLengthHeader) ?? '') ??
          chapter.sizeBytes;

      if (await tmp.exists()) await tmp.delete();
      sink = tmp.openWrite();
      var received = 0;
      final completer = Completer<void>();

      res.data!.stream.listen(
        (chunk) {
          sink!.add(chunk);
          received += chunk.length;
          if (onProgress != null) {
            onProgress(total > 0 ? (received / total).clamp(0.0, 1.0) : -1, received);
          }
        },
        onDone: () => completer.complete(),
        onError: (Object e, StackTrace s) => completer.completeError(e),
        cancelOnError: true,
      );
      await completer.future;
      await sink.flush();
      await sink.close();
      sink = null;

      if (received == 0) throw const _EmptyAudio();

      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);

      final entry = CacheEntry(
        key: key,
        bookId: book.id,
        source: book.source.id,
        bookTitle: book.title,
        chapterTitle: chapter.title,
        index: chapter.index,
        bytes: received,
        lastUsedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _index[key] = entry;
      _recount();
      await _persist();
      await evictIfNeeded(protectKey: key);
      return target.path;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      if (e is _EmptyAudio) {
        throw Exception('这一回没有取到声音，可能是源上文件有问题');
      }
      rethrow;
    } finally {
      _busyKey = null;
      notifyListeners();
    }
  }

  /// 超过上限就删——先删"已听完"的，再按最久未听排
  Future<void> evictIfNeeded({String? protectKey}) async {
    if (_usedBytes <= maxBytes) return;
    final victims = _index.values.where((e) => e.key != protectKey).toList()
      ..sort((a, b) {
        if (a.finished != b.finished) return a.finished ? -1 : 1;
        return a.lastUsedAt.compareTo(b.lastUsedAt);
      });

    for (final v in victims) {
      if (_usedBytes <= maxBytes * 0.85) break; // 一次多腾一点，避免每回都触发淘汰
      await _remove(v.key);
    }
    await _persist();
  }

  /// 一回播完，标记为已听完（淘汰时它最先进回收站）
  Future<void> markFinished(TingSource source, String bookId, String chapterKey) async {
    final e = _index[keyOf(source, bookId, chapterKey)];
    if (e == null) return;
    e.finished = true;
    await _persist();
  }

  Future<void> _remove(String key) async {
    final e = _index.remove(key);
    if (e == null) return;
    _usedBytes -= e.bytes;
    if (_usedBytes < 0) _usedBytes = 0;
    final f = File(_pathOf(key));
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> deleteOne(TingSource source, String bookId, String chapterKey) async {
    await _remove(keyOf(source, bookId, chapterKey));
    _recount();
    await _persist();
    notifyListeners();
  }

  /// 删掉一整本书的缓存
  Future<void> deleteBook(TingSource source, String bookId) async {
    final keys = _index.values
        .where((e) => e.bookId == bookId && e.source == source.id)
        .map((e) => e.key)
        .toList();
    for (final k in keys) {
      await _remove(k);
    }
    _recount();
    await _persist();
    notifyListeners();
  }

  Future<void> clearAll() async {
    final keys = _index.keys.toList();
    for (final k in keys) {
      await _remove(k);
    }
    _recount();
    await _persist();
    notifyListeners();
  }

  /// 一本书已缓存的回数
  int cachedCount(TingSource source, String bookId) => _index.values
      .where((e) => e.bookId == bookId && e.source == source.id)
      .length;

  Future<void> _persist() async {
    try {
      final f = File('${_dir.path}/index.json');
      await f.writeAsString(jsonEncode(_index.values.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  // ---------- 预取 ----------

  /// 把接下来几回排进预取队列（老人不爱等，趁这一回还在播就先下好）
  void prefetch(TingBook book, List<TingChapter> chapters,
      {required Future<ResolvedAudio> Function(TingChapter) resolve}) {
    for (final ch in chapters) {
      final key = keyOf(book.source, book.id, ch.key);
      if (_index.containsKey(key)) continue;
      if (_inflight.containsKey(key)) continue;
      if (_queue.any((t) => t.key == key)) continue;
      _queue.add(_PrefetchTask(key, book, ch, resolve));
    }
    _drain();
  }

  void cancelPrefetch() {
    _queue.clear();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final t = _queue.removeAt(0);
        if (_index.containsKey(t.key)) continue;
        try {
          await obtain(t.book, t.chapter, resolve: () => t.resolve(t.chapter));
        } catch (_) {
          // 预取失败不打扰用户，真要点开这一回时会再试一次并给出提示
        }
      }
    } finally {
      _draining = false;
    }
  }
}

class _PrefetchTask {
  final String key;
  final TingBook book;
  final TingChapter chapter;
  final Future<ResolvedAudio> Function(TingChapter) resolve;

  _PrefetchTask(this.key, this.book, this.chapter, this.resolve);
}

class _EmptyAudio implements Exception {
  const _EmptyAudio();
}

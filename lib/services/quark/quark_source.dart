import '../../models/ting.dart';
import '../library.dart';
import '../nas/scanner.dart';
import '../nas/webdav_client.dart' show DavEntry;
import 'quark_api.dart';

/// 扫描进度回调：已经翻了多少文件夹、认出多少音频。
typedef ScanProgress = void Function(int dirs, int files);

/// 夸克网盘评书源。
///
/// **网盘里的层级是人摆的，不是程序摆的。** 真实情况常常长这样：
/// ```
/// 评书/
///   └── 单田芳/               ← 作者层
///         └── 水浒传/          ← 书名层
///               ├── 上部/       ← 分卷层
///               │    ├── 001.mp3
///               │    └── 002.mp3
///               └── 下部/ ...
/// ```
/// 早先的实现只往下看一层（子目录当书 → 再列一层当回目）。
/// 碰到上面这种"作者 / 书名 / 分卷"三层嵌套，就会把**作者目录当成一本书**，
/// 点进去一个音频都找不到，界面卡在"没有回目"上——这就是用户说的"程序死掉"。
///
/// 现在改成：**递归把整棵树拉平，再复用 NAS 扫描器那套识别规则**
/// （装着音频的目录才算一本书、按演员表认作者、按"第N回"解析序号、分卷自动合并）。
/// 规则只维护一份，NAS 和网盘不会各跑一套、各错一处。
class QuarkSource {
  QuarkSource._();
  static final QuarkSource instance = QuarkSource._();

  final QuarkApi _api = QuarkApi.instance;

  /// 一次扫描的保护上限。宁可少认几本，也不能让界面无限转圈。
  static const _maxDepth = 8;
  static const _maxFiles = 30000;
  static const _maxDirs = 800;
  static const _maxDuration = Duration(seconds: 150);
  static const _concurrency = 4;

  /// scan 结果缓存。老人点"添加评书"不该每次都重新爬一遍网盘。
  static const _ttl = Duration(minutes: 10);
  List<TingBook>? _cache;
  DateTime _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  String get _root => Library.instance.quarkRoot;

  /// 把整个评书目录递归拉平，认出所有书（回目一起带回来，省一次往返）
  Future<List<TingBook>> listBooks({bool force = false, ScanProgress? onProgress}) async {
    final root = _root;
    if (root.isEmpty || root == '0') {
      throw Exception('还没选评书文件夹。请到 设置 → 评书文件夹 里选一下放评书的那个大文件夹');
    }
    if (!force && _cache != null && DateTime.now().difference(_cacheAt) < _ttl) {
      return _cache!;
    }

    final entries = <DavEntry>[];
    final fidOf = <String, String>{};
    final started = DateTime.now();

    var dirs = 0;
    var level = <_Node>[_Node(root, '', 0)];
    while (level.isNotEmpty) {
      if (DateTime.now().difference(started) > _maxDuration) break;
      if (entries.length >= _maxFiles || dirs >= _maxDirs) break;

      final next = <_Node>[];
      for (var i = 0; i < level.length; i += _concurrency) {
        final batch = level.skip(i).take(_concurrency).toList();
        // 一个文件夹读失败不该让整次扫描失败（网盘常有权限异常的残留目录）
        final lists = await Future.wait(batch.map((n) => _listSafe(n.fid)));
        for (var j = 0; j < batch.length; j++) {
          final node = batch[j];
          dirs++;
          for (final f in lists[j]) {
            final path = '${node.path}/${f.name}';
            if (f.isDir) {
              if (node.depth < _maxDepth) {
                next.add(_Node(f.fid, path, node.depth + 1));
              }
            } else {
              entries.add(DavEntry(path: path, name: f.name, isDir: false, size: f.size));
              fidOf[path] = f.fid;
            }
          }
          onProgress?.call(dirs, entries.length);
        }
      }
      level = next;
    }

    if (entries.isEmpty) {
      throw Exception('这个文件夹里没找到音频文件。确认选的是"放评书的那个大文件夹"，里面要有 mp3 之类');
    }

    final drafts = NasScanner.scan(entries, rootName: Library.instance.quarkRootName);
    final books = <TingBook>[];
    for (final d in drafts) {
      final chapters = <TingChapter>[];
      for (var i = 0; i < d.chapters.length; i++) {
        final c = d.chapters[i];
        final fid = fidOf[c.davPath];
        if (fid == null || fid.isEmpty) continue;
        chapters.add(TingChapter(
          index: chapters.length,
          // 扫描器已经把序号从标题里剥掉了；剩空标题就用序号当标题。
          // 用 order 而不是 i+1：分卷合并后顺序可能不是从 1 开始。
          title: c.title.isNotEmpty
              ? c.title
              : (c.order > 0 ? '第 ${c.order} 回' : '第 ${i + 1} 回'),
          key: fid,
          sizeBytes: c.size,
        ));
      }
      if (chapters.isEmpty) continue;

      // 根目录直接摆音频时，扫描器给的是空目录名，改用用户选的那个文件夹名
      final title = (d.davDir == '/' || d.title.isEmpty || d.title == '未命名')
          ? Library.instance.quarkRootName
          : d.title;

      books.add(TingBook(
        id: d.davDir, // 用路径当 id：分卷合并后可能跨目录，用 fid 会漂
        source: TingSource.quark,
        title: title,
        author: d.author,
        updatedAt: 0,
        chapters: chapters,
      ));
    }

    books.sort((a, b) => a.title.compareTo(b.title));
    _cache = books;
    _cacheAt = DateTime.now();
    return books;
  }

  /// 取一部书的回目。
  ///
  /// 扫描时已经把回目带回来了，这里直接返回；
  /// 万一调用方拿到的是一本没有回目的旧数据，就重扫一次找它。
  Future<TingBook> detail(TingBook book) async {
    if (book.chapters.isNotEmpty) return book;
    final all = await listBooks(force: true);
    for (final b in all) {
      if (b.id == book.id) return b;
    }
    return book;
  }

  /// 取这一回的临时直链（约 1 小时有效，缓存层每次都会重新取）
  Future<ResolvedAudio> resolve(TingBook book, TingChapter chapter) async {
    final url = await _api.downloadUrl(chapter.key);
    return ResolvedAudio(url, headers: _api.mediaHeaders);
  }

  /// 用户在设置里换了目录、或想让新加的文件立刻出现时调用
  void invalidate() {
    _cache = null;
    _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<List<QuarkFile>> _listSafe(String fid) async {
    try {
      return await _api.list(fid);
    } catch (_) {
      return const [];
    }
  }
}

class _Node {
  _Node(this.fid, this.path, this.depth);

  final String fid;

  /// 以 / 开头的完整路径（根是空串）
  final String path;

  final int depth;
}

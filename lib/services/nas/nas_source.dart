import 'package:shared_preferences/shared_preferences.dart';

import '../../models/ting.dart';
import 'scanner.dart';
import 'webdav_client.dart';

/// 家里的 NAS（WebDAV）。
///
/// 为什么单独做一个源、而不是并进夸克：
/// 两个地方的"书的边界"规则一样（复用 [NasScanner]），但**连接方式、
/// 鉴权、出错提示完全不同**。并在一起只会让两边都难改。
///
/// 目录约定和网盘一致：
/// ```
/// 评书/
///   └── 单田芳/
///         └── 水浒传/
///               ├── 001.mp3
///               └── 002.mp3
/// ```
/// 扫描时把整棵树拉平交给 [NasScanner]，所以手机和 NAS 上看到的书是同一套规则。
class NasSource {
  NasSource._();
  static final NasSource instance = NasSource._();

  static const _kUrl = 'ts_nas_url';
  static const _kUser = 'ts_nas_user';
  static const _kPass = 'ts_nas_pass';
  static const _kRoot = 'ts_nas_root';
  static const _kRootName = 'ts_nas_root_name';

  /// 一次扫描的上限。NAS 上几百部书、几万个文件很正常，
  /// 但界面不能无限转圈——到上限就先出结果，用户再点一次可以继续。
  static const _maxFiles = 40000;
  static const _maxDuration = Duration(seconds: 120);

  static const _ttl = Duration(minutes: 10);

  String _url = '';
  String _user = '';
  String _pass = '';
  String _root = '/';
  String _rootName = '根目录';

  String get url => _url;
  String get username => _user;
  String get password => _pass;
  String get rootPath => _root;
  String get rootName => _rootName;

  bool get configured => _url.isNotEmpty && _user.isNotEmpty;

  List<TingBook>? _cache;
  DateTime _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _url = sp.getString(_kUrl) ?? '';
    _user = sp.getString(_kUser) ?? '';
    _pass = sp.getString(_kPass) ?? '';
    _root = sp.getString(_kRoot) ?? '/';
    _rootName = sp.getString(_kRootName) ?? '根目录';
  }

  Future<void> saveConfig({
    String? url,
    String? user,
    String? pass,
    String? root,
    String? rootName,
  }) async {
    if (url != null) _url = url.trim();
    if (user != null) _user = user.trim();
    if (pass != null) _pass = pass;
    if (root != null) _root = root;
    if (rootName != null) _rootName = rootName;

    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUrl, _url);
    await sp.setString(_kUser, _user);
    await sp.setString(_kPass, _pass);
    await sp.setString(_kRoot, _root);
    await sp.setString(_kRootName, _rootName);
    invalidate();
  }

  WebDavClient client() => WebDavClient(
        baseUrl: _url,
        username: _user,
        password: _pass,
      );

  /// 连一下，返回一句人话；失败抛 [WebDavException]
  Future<String> testConnection() async {
    if (!configured) throw WebDavException('还没填 NAS 地址和账号');
    final c = client();
    await c.ping();
    final list = await c.list(_root);
    final dirs = list.where((e) => e.isDir).length;
    final audio = list.where((e) => e.isAudio).length;
    return '连接成功。$rootName 下有 $dirs 个文件夹、$audio 个音频';
  }

  /// 列出当前目录下的子目录（设置里"选评书文件夹"用）
  Future<List<DavEntry>> listDirs(String path) async {
    final list = await client().list(path);
    return list.where((e) => e.isDir).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// 扫描整个目录，认出书（回目一起带回来）
  Future<List<TingBook>> listBooks({
    bool force = false,
    void Function(int files)? onProgress,
  }) async {
    if (!configured) {
      throw WebDavException('还没设置 NAS。到 设置 → 家里的 NAS 里填地址和账号');
    }
    if (!force && _cache != null && DateTime.now().difference(_cacheAt) < _ttl) {
      return _cache!;
    }

    final c = client();
    final entries = <DavEntry>[];
    final started = DateTime.now();
    try {
      await for (final e in c.walk(_root)) {
        if (e.isDir) continue;
        // 交给扫描器前先"相对化"：不留用户选的那层根目录名，
        // 否则所有书都会归到「评书」这一个分组下（分组取路径第一段）。
        entries.add(DavEntry(
          path: _relativize(e.path),
          name: e.name,
          isDir: false,
          size: e.size,
          modified: e.modified,
        ));
        if (entries.length % 50 == 0) onProgress?.call(entries.length);
        if (entries.length >= _maxFiles) break;
        if (DateTime.now().difference(started) > _maxDuration) break;
      }
    } on WebDavException {
      rethrow;
    } catch (e) {
      // 单个目录读失败 walk 已经跳过；这里是整体失败（NAS 掉线）
      if (entries.isEmpty) throw WebDavException('NAS 上什么都没读到：$e');
    }
    onProgress?.call(entries.length);

    if (entries.isEmpty) {
      throw WebDavException('这个目录里没有音频文件。确认选的是"放评书的那个大文件夹"');
    }

    final drafts = NasScanner.scan(entries, rootName: _rootName);
    final books = <TingBook>[];
    for (final d in drafts) {
      final chapters = <TingChapter>[];
      for (var i = 0; i < d.chapters.length; i++) {
        final ch = d.chapters[i];
        if (ch.davPath.isEmpty) continue;
        chapters.add(TingChapter(
          index: chapters.length,
          title: ch.title.isNotEmpty
              ? ch.title
              : (ch.order > 0 ? '第 ${ch.order} 回' : '第 ${i + 1} 回'),
          // NAS 没有文件 id，用**完整路径**当 key（播放要拼 URL）；
          // 扫描器给的是相对根目录的路径，这里补回根前缀。
          key: _absolute(ch.davPath),
          sizeBytes: ch.size,
        ));
      }
      if (chapters.isEmpty) continue;

      final title = (d.davDir == '/' || d.title.isEmpty || d.title == '未命名')
          ? _rootName
          : d.title;

      books.add(TingBook(
        id: d.davDir,
        source: TingSource.nas,
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

  /// 扫描时已带回回目；旧数据没有回目时重扫一次
  Future<TingBook> detail(TingBook book) async {
    if (book.chapters.isNotEmpty) return book;
    final all = await listBooks(force: true);
    for (final b in all) {
      if (b.id == book.id) return b;
    }
    return book;
  }

  /// 播放地址：WebDAV 文件 URL + Basic 鉴权头。
  ///
  /// 播放器和"边听边存"都直接用这套头，不需要先下载整个文件。
  Future<ResolvedAudio> resolve(TingBook book, TingChapter chapter) async {
    final c = client();
    return ResolvedAudio(
      c.urlFor(chapter.key),
      headers: c.authHeaders,
    );
  }

  /// `/评书/单田芳/x.mp3` → `/单田芳/x.mp3`（去掉用户选的根目录）
  String _relativize(String path) {
    final root = _root.replaceAll(RegExp(r'/+$'), '');
    if (root.isEmpty || root == '/') return path;
    if (path == root) return '/';
    if (path.startsWith('$root/')) return path.substring(root.length);
    return path;
  }

  /// 相对路径补回根前缀，得到 WebDAV 上的真实路径
  String _absolute(String rel) {
    final root = _root.replaceAll(RegExp(r'/+$'), '');
    if (root.isEmpty || root == '/' || rel == '/') {
      return rel == '/' ? '/' : (root == '/' ? rel : '$root$rel');
    }
    return rel.startsWith('/') ? '$root$rel' : '$root/$rel';
  }

  void invalidate() {
    _cache = null;
    _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 清除全部数据时用
  void resetForWipe() {
    _url = '';
    _user = '';
    _pass = '';
    _root = '/';
    _rootName = '根目录';
    invalidate();
  }
}

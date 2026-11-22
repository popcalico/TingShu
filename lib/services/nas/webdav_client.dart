import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// WebDAV 上的一个条目（文件或目录）。
class DavEntry {
  const DavEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.size = 0,
    this.modified,
  });

  /// 相对根目录的完整路径，以 / 开头，例如 `/评书/水浒传/001.mp3`
  final String path;

  /// 最后一段名字，例如 `001.mp3`
  final String name;

  final bool isDir;
  final int size;
  final DateTime? modified;

  /// 音频文件判断。评书常见格式都在这里，要覆盖老资源里的 wma/ape。
  static const audioExts = {
    '.mp3', '.m4a', '.m4b', '.aac', '.wav', '.flac', '.ogg', '.wma', '.ape', '.amr',
  };

  bool get isAudio {
    final lower = name.toLowerCase();
    return !isDir && audioExts.any(lower.endsWith);
  }

  @override
  String toString() => '${isDir ? "D" : "F"} $path ($size)';
}

class WebDavException implements Exception {
  WebDavException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 最小可用的 WebDAV 客户端。
///
/// 为什么选 WebDAV 而不是 SMB：
/// 1. 一份代码同时覆盖"老人在家连局域网"和"你在外面连 frp 域名"；
/// 2. fnOS / 群晖 / 威联通 都原生支持，NAS 后台勾一下就行，不用装东西；
/// 3. 纯 HTTP，出问题好排查（curl 就能验）。
///
/// SMB 虽然快，但跨网基本做不到，Android 上的库对协议版本还很挑。
class WebDavClient {
  WebDavClient({
    required String baseUrl,
    required this.username,
    required this.password,
  }) : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      // NAS 列大目录可能要几十秒（几千个文件），给足
      receiveTimeout: const Duration(minutes: 2),
      validateStatus: (s) => s != null && s < 400,
      headers: {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      },
    ));
  }

  final String baseUrl;
  final String username;
  final String password;
  late final Dio _dio;

  static const _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>''';

  /// 某个相对路径的完整 URL（播放/下载用）
  String urlFor(String path) => _uri(path).toString();

  /// 访问文件时要带的请求头。播放器直接吃这套，和 PROPFIND 用的是同一份凭证。
  Map<String, String> get authHeaders => {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      };

  Uri _uri(String path) {
    final clean = path
        .split('/')
        .where((e) => e.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    // 保留结尾斜杠：WebDAV 的"目录"语义靠它区分。
    // 少了斜杠，fnOS/群晖 会返回 301 跳到 /book/，而 PROPFIND 这类自定义方法
    // HttpClient 不会自动跟随重定向 —— 结果是拿到一个空响应，被误判成空目录。
    final trailing = path.endsWith('/') && clean.isNotEmpty ? '/' : '';
    return Uri.parse('$baseUrl/$clean$trailing');
  }

  /// 连通性测试。失败会抛出带中文说明的 [WebDavException]。
  Future<void> ping() async {
    try {
      final res = await _dio.request<String>(
        _uri('/').toString(),
        data: _propfindBody,
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': '0', 'Content-Type': 'application/xml'},
          responseType: ResponseType.plain,
        ),
      );
      if (res.statusCode != 207 && res.statusCode != 200) {
        throw WebDavException('NAS 返回了 ${res.statusCode}，地址可能不对');
      }
    } on DioException catch (e) {
      throw WebDavException(_explain(e));
    }
  }

  /// 列一层目录（不含子目录内容）
  Future<List<DavEntry>> list(String path) async {
    final all = await _listRaw(path, depth: 1);
    // PROPFIND depth=1 会把目录自己也返回，去掉
    final self = path.replaceAll(RegExp(r'/+$'), '');
    return all.where((e) => e.path.replaceAll(RegExp(r'/+$'), '') != self).toList();
  }

  /// 递归遍历整个目录树。
  ///
  /// 大目录（几千个文件）会比较慢，所以边遍历边 yield，调用方可以显示进度。
  Stream<DavEntry> walk(String root) async* {
    final queue = <String>[root];
    final visited = <String>{};
    while (queue.isNotEmpty) {
      final dir = queue.removeAt(0);
      // 防止 NAS 上有软链/循环导致无限翻
      if (!visited.add(dir)) continue;
      List<DavEntry> children;
      try {
        children = await list(dir);
      } catch (e) {
        // 某一个子目录读不了（权限/特殊字符）跳过继续，不要整棵树失败；
        // 但要留痕，否则"什么都没有"时根本查不出原因。
        dev.log('跳过目录 $dir：$e', name: 'nas');
        continue;
      }
      for (final e in children) {
        yield e;
        if (e.isDir) queue.add(e.path);
      }
    }
  }

  Future<List<DavEntry>> _listRaw(String path, {required int depth}) async {
    // 列目录一定要带尾斜杠，否则部分 NAS 会 301 到带斜杠的地址，
    // 而 PROPFIND 不会被自动跟随重定向。
    final reqPath = path.endsWith('/') ? path : '$path/';
    try {
      final res = await _dio.request<String>(
        _uri(reqPath).toString(),
        data: _propfindBody,
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': '$depth', 'Content-Type': 'application/xml'},
          responseType: ResponseType.plain,
        ),
      );
      final code = res.statusCode ?? 0;
      // dio 的 validateStatus 把 3xx 也当"成功"，于是重定向会变成空响应。
      // 这里只认 207（Multi-Status）和 200，其余一律报错，绝不静默当空目录。
      if (code != 207 && code != 200) {
        throw WebDavException('NAS 返回了 $code（${Uri.decodeFull(reqPath)}）');
      }
      final body = res.data ?? '';
      if (body.trim().isEmpty) return const [];
      return _parseMultiStatus(body, reqPath);
    } on WebDavException {
      rethrow;
    } on DioException catch (e) {
      throw WebDavException(_explain(e));
    }
  }

  /// 解析 207 Multi-Status。
  ///
  /// 各大 NAS 的 XML 命名空间前缀不一样（d: / D: / 无前缀），
  /// 所以统一按 localName 匹配，不依赖前缀。
  List<DavEntry> _parseMultiStatus(String xml, String basePath) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } catch (e) {
      throw WebDavException('NAS 返回的目录内容看不懂（不是合法的 WebDAV 响应）');
    }

    final out = <DavEntry>[];
    final normBase = basePath.replaceAll(RegExp(r'/+$'), '');

    for (final el in doc.descendants.whereType<XmlElement>()) {
      if (el.localName != 'response') continue;

      String? href;
      int size = 0;
      DateTime? modified;
      bool isDir = false;

      for (final child in el.descendants.whereType<XmlElement>()) {
        switch (child.localName) {
          case 'href':
            href ??= child.innerText.trim();
          case 'getcontentlength':
            size = int.tryParse(child.innerText.trim()) ?? 0;
          case 'getlastmodified':
            modified = _parseHttpDate(child.innerText.trim());
          case 'collection':
            isDir = true;
        }
      }
      if (href == null || href.isEmpty) continue;

      var p = _hrefToPath(href);
      if (p.isEmpty) continue;

      // 去掉服务端返回的额外前缀，保证和我们请求的路径同一基准
      if (normBase.isNotEmpty && !p.startsWith(normBase)) {
        final idx = p.indexOf(normBase);
        if (idx >= 0) p = p.substring(idx + normBase.length);
      }
      if (!p.startsWith('/')) p = '/$p';
      if (p.length > 1) p = p.replaceAll(RegExp(r'/+$'), '');

      final name = p.split('/').last;
      if (name.isEmpty && p != '/') continue;

      out.add(DavEntry(
        path: p,
        // href 在 _hrefToPath 里已经解码过一遍，这里**不能再解码**：
        // 中文解不动倒还好，碰上文件名里带 `%` 的会直接抛
        // "Illegal percent encoding in URI"，整层目录就废了。
        // 保留 _safeDecode 只是兜住"以防上层没解码"的情况。
        name: name.contains('%') ? _safeDecode(name) : name,
        isDir: isDir,
        size: size,
        modified: modified,
      ));
    }
    return out;
  }

  /// href 可能是绝对 URL、也可能是编码过的绝对路径，统一成 /a/b 形式
  String _hrefToPath(String href) {
    var s = href;
    if (s.startsWith('http://') || s.startsWith('https://')) {
      try {
        s = Uri.parse(s).path;
      } catch (_) {}
    }
    try {
      s = Uri.decodeFull(s);
    } catch (_) {}
    // 去掉 WebDAV 挂载前缀（形如 /dav/... 或 /remote.php/dav/...）
    final baseUriPath = Uri.parse(baseUrl).path;
    if (baseUriPath.isNotEmpty && baseUriPath != '/') {
      final i = s.indexOf(baseUriPath);
      if (i >= 0) s = s.substring(i + baseUriPath.length);
    }
    return s;
  }

  /// 解码失败就原样返回：宁可显示成 %XX，也不能因为一个字符让整层目录消失。
  static String _safeDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (e) {
      dev.log('解码失败，保留原样：$s（$e）', name: 'nas');
      return s;
    }
  }

  DateTime? _parseHttpDate(String s) {
    try {
      return HttpDate.parse(s).toLocal();
    } catch (_) {
      return null;
    }
  }

  /// 下载单个文件到本地路径。支持 Range 续传（NAS 一般都会返回 206）。
  Future<void> download(
    String davPath,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final file = File(savePath);
    await file.parent.create(recursive: true);

    var have = 0;
    if (await file.exists()) have = await file.length();

    try {
      final res = await _dio.get<ResponseBody>(
        _uri(davPath).toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: have > 0 ? {'Range': 'bytes=$have-'} : null,
          // 大文件给足时间：NAS 慢的时候 30MB 可能要好几分钟
          receiveTimeout: const Duration(minutes: 10),
        ),
        cancelToken: cancelToken,
      );

      final total = int.tryParse(
            res.headers.value(Headers.contentLengthHeader) ?? '',
          ) ??
          0;

      final raf = await file.open(mode: have > 0 && res.statusCode == 206
          ? FileMode.append
          : FileMode.write);
      var received = have;
      try {
        await for (final chunk in res.data!.stream) {
          raf.writeFromSync(chunk);
          received += chunk.length;
          onProgress?.call(received, total + have);
        }
        await raf.flush();
      } finally {
        await raf.close();
      }
    } on DioException catch (e) {
      throw WebDavException(_explain(e));
    }
  }

  String _explain(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return '连不上 NAS（超时）。确认手机和 NAS 在同一个 WiFi，或检查地址端口';
      case DioExceptionType.receiveTimeout:
        return 'NAS 响应太慢（超时）。可能是文件太大或 NAS 在忙';
      case DioExceptionType.connectionError:
        return '连不上 NAS。检查地址和端口对不对、NAS 是否开机、'
            '以及 WebDAV 服务有没有开启';
      case DioExceptionType.badCertificate:
        // NAS 自带的 https 多半是自签证书，系统不认。
        return 'NAS 的证书不被信任（自签证书）。改成 http 的那个端口试试';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) return 'NAS 说用户名或密码不对（HTTP $code）';
        if (code == 404) return 'NAS 上找不到这个路径（HTTP 404），地址可能要带 /dav';
        if (code == 405) return '这个地址不支持 WebDAV（HTTP 405），确认填的是 WebDAV 地址';
        // 502/503/504 基本都是"前面的转发层通了，后面的服务没通"：
        // 家里 NAS 关机、WebDAV 没开、或者内网穿透那条隧道断了。
        if (code == 502 || code == 503 || code == 504) {
          return 'NAS 那边没响应（HTTP $code）。多半是 NAS 关机、WebDAV 服务没开，'
              '或者内网穿透的隧道断了';
        }
        return 'NAS 返回错误 HTTP $code';
      default:
        return '和 NAS 通信失败：${e.message ?? e.type.name}';
    }
  }
}

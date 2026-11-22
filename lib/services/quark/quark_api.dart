import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 夸克网盘文件条目。
class QuarkFile {
  final String fid;
  final String name;
  final bool isDir;
  final int size;
  final int updatedAt;

  const QuarkFile({
    required this.fid,
    required this.name,
    required this.isDir,
    this.size = 0,
    this.updatedAt = 0,
  });

  factory QuarkFile.fromMap(Map<String, dynamic> m) => QuarkFile(
        fid: '${m['fid'] ?? ''}',
        name: '${m['file_name'] ?? ''}',
        isDir: m['file'] != true,
        size: (m['size'] as num?)?.toInt() ?? 0,
        updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
      );

  /// 是否是能被播放器读的音频文件
  bool get isAudio {
    if (isDir) return false;
    final n = name.toLowerCase();
    const exts = ['.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.opus', '.wma', '.amr'];
    return exts.any(n.endsWith);
  }
}

class QuarkException implements Exception {
  final String message;
  final int? code;

  /// 登录态失效（Cookie 过期），需要家属重新登录
  final bool needLogin;

  QuarkException(this.message, {this.code, this.needLogin = false});

  @override
  String toString() => message;
}

/// 夸克网盘接口。
///
/// 夸克没有面向第三方 App 的开放 API，这里走的是网页版同一套接口
/// （与开源项目 OpenList 的 quark 驱动一致），靠登录后的 Cookie 鉴权。
/// 所有请求都带 `pr=ucpro&fr=pc`，响应里的 `__puus` 会在每次请求后刷新，
/// 必须回写，否则几十次请求后就会被判失效。
class QuarkApi {
  QuarkApi._();
  static final QuarkApi instance = QuarkApi._();

  static const _base = 'https://drive.quark.cn/1/clouddrive';
  static const _referer = 'https://pan.quark.cn';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
  static const _prefCookie = 'quark_cookie';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
      validateStatus: (_) => true,
    ),
  );

  String _cookie = '';

  String get cookie => _cookie;
  bool get hasLogin => _cookie.contains('__puus=') || _cookie.contains('__pus=');

  /// 直链请求必须带同样的 Cookie/Referer/UA，播放器下载时要用
  Map<String, String> get mediaHeaders => {
        'Cookie': _cookie,
        'Referer': _referer,
        'User-Agent': _ua,
      };

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _cookie = sp.getString(_prefCookie) ?? '';
  }

  Future<void> saveCookie(String raw) async {
    _cookie = _normalizeCookie(raw);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefCookie, _cookie);
  }

  Future<void> logout() async {
    _cookie = '';
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_prefCookie);
  }

  /// 清除全部数据后把登录态归零（磁盘上的 Cookie 已被删掉）
  void resetForWipe() {
    _cookie = '';
  }

  /// WebView 拿到的 Cookie 可能是 "a=1; b=2" 也可能没去重，统一整理一遍
  static String _normalizeCookie(String raw) {
    final map = <String, String>{};
    for (final part in raw.split(';')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final i = p.indexOf('=');
      if (i <= 0) continue;
      map[p.substring(0, i)] = p.substring(i + 1);
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Map<String, String> _headers() => {
        'Cookie': _cookie,
        'Referer': _referer,
        'User-Agent': _ua,
        'Accept': 'application/json, text/plain, */*',
      };

  /// 从 Set-Cookie 里挑出 __puus 回写（夸克会在响应中滚动刷新）
  void _absorb(Response res) {
    final raw = res.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    final map = <String, String>{};
    for (final part in _cookie.split(';')) {
      final p = part.trim();
      final i = p.indexOf('=');
      if (i > 0) map[p.substring(0, i)] = p.substring(i + 1);
    }
    var changed = false;
    for (final line in raw) {
      final first = line.split(';').first.trim();
      final i = first.indexOf('=');
      if (i <= 0) continue;
      final k = first.substring(0, i);
      final v = first.substring(i + 1);
      if (k == '__puus' || k == '__pus') {
        if (map[k] != v) changed = true;
        map[k] = v;
      }
    }
    if (changed) {
      _cookie = map.entries.map((e) => '${e.key}=${e.value}').join('; ');
      SharedPreferences.getInstance().then((sp) => sp.setString(_prefCookie, _cookie));
    }
  }

  /// 统一请求：解包 {code,message,data} 信封，返回 `data` 原样。
  ///
  /// **不要假定 data 一定是对象**：`/file/download` 返回的 data 是数组
  /// （`[{fid, download_url, ...}]`）。以前这里写死 `data['data'] as Map?`，
  /// 取直链时就会抛
  /// "type 'List<dynamic>' is not a subtype of type 'Map<dynamic,dynamic>?'"，
  /// 表现就是"网盘能解析、点开听不了"。
  Future<dynamic> _requestRaw(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  }) async {
    if (!hasLogin) {
      throw QuarkException('还没有登录夸克网盘', needLogin: true);
    }
    final res = await _dio.request<dynamic>(
      '$_base$path',
      data: body == null ? null : jsonEncode(body),
      queryParameters: {'pr': 'ucpro', 'fr': 'pc', ...?query},
      options: Options(
        method: method,
        headers: {..._headers(), if (body != null) 'Content-Type': 'application/json'},
      ),
    );
    _absorb(res);

    final data = res.data;
    if (data is! Map) {
      throw QuarkException('网盘返回异常（HTTP ${res.statusCode}）');
    }
    final code = (data['code'] as num?)?.toInt() ?? -1;
    final status = (data['status'] as num?)?.toInt() ?? 200;
    if (status == 401 || code == 31001 || code == 31023) {
      throw QuarkException('登录已过期，请家属重新登录夸克网盘', code: code, needLogin: true);
    }
    if (code != 0) {
      throw QuarkException('${data['message'] ?? '网盘请求失败'}（$code）', code: code);
    }
    return data['data'];
  }

  /// 需要"data 是对象"的接口用这个（列表、详情、成员信息）。
  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  }) async {
    final raw = await _requestRaw(path, method: method, query: query, body: body);
    if (raw is Map) return raw.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  /// 列目录。fid 传 '0' 表示根目录。
  Future<List<QuarkFile>> list(String fid) async {
    final out = <QuarkFile>[];
    var page = 1;
    const size = 100;
    while (true) {
      final data = await _request(
        '/file/sort',
        query: {
          'pdir_fid': fid,
          '_page': '$page',
          '_size': '$size',
          '_fetch_total': '1',
          'fetch_all_file': '1',
          '_sort': 'file_type:asc,file_name:asc',
        },
      );
      final list = (data['list'] as List?) ?? const [];
      for (final e in list) {
        if (e is Map) out.add(QuarkFile.fromMap(e.cast<String, dynamic>()));
      }
      final total = ((data['metadata'] as Map?)?['_total'] as num?)?.toInt() ??
          ((data['metadata'] as Map?)?['total'] as num?)?.toInt() ??
          0;
      if (list.isEmpty || page * size >= total) break;
      page++;
      if (page > 50) break; // 兜底，防止死循环
    }
    return out;
  }

  /// 取文件的临时直链（约 1 小时有效，过期需重新取）
  Future<String> downloadUrl(String fid) async {
    final raw = await _requestRaw(
      '/file/download',
      method: 'POST',
      body: {
        'fids': [fid]
      },
    );
    return extractDownloadUrl(raw);
  }

  /// 从 `/file/download` 的 `data` 里取出下载地址。
  ///
  /// 两种真实返回都见过：
  ///   data: [{fid, download_url}, ...]
  ///   data: {list: [{fid, download_url}, ...]}
  /// 以前只按第二种写，第一种会直接抛类型转换异常——网盘能解析、点开听不了。
  /// 抽成纯函数，单测两种形状都锁住。
  static String extractDownloadUrl(dynamic raw) {
    final List<dynamic> list;
    if (raw is List) {
      list = raw;
    } else if (raw is Map) {
      list = (raw['list'] as List?) ?? const [];
    } else {
      list = const [];
    }
    if (list.isEmpty) throw QuarkException('没有拿到下载地址');

    final first = list.first;
    final map = first is Map ? first : const {};
    final url = '${map['download_url'] ?? map['url'] ?? ''}';
    if (url.isEmpty) {
      final msg = '${map['message'] ?? ''}';
      throw QuarkException(msg.isEmpty ? '没有拿到下载地址' : msg);
    }
    return url;
  }

  /// 用户信息，用于设置页显示"已登录：xxx"
  Future<String> nickname() async {
    try {
      final data = await _request('/member');
      final name = '${data['nickname'] ?? data['member_name'] ?? ''}';
      return name.isEmpty ? '已登录' : name;
    } catch (_) {
      return '已登录';
    }
  }
}

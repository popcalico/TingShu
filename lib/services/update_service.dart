import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 服务器上 version.json 的内容。
///
/// ```json
/// {
///   "versionCode": 2002,
///   "versionName": "1.0.1",
///   "url": "https://你的域名/tingshu/tingshu.apk",
///   "size": 15800000,
///   "notes": "修复继续收听进度丢失",
///   "force": false
/// }
/// ```
class UpdateInfo {
  final int versionCode;
  final String versionName;
  final String url;
  final int size;
  final String notes;
  final bool force;

  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.url,
    this.size = 0,
    this.notes = '',
    this.force = false,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> m) => UpdateInfo(
        versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
        versionName: '${m['versionName'] ?? ''}',
        url: '${m['url'] ?? ''}',
        size: (m['size'] as num?)?.toInt() ?? 0,
        notes: '${m['notes'] ?? ''}',
        force: m['force'] == true,
      );
}

/// 版本线。
///
/// 分两条的理由：这个 App 改得勤，但推到老人手机上的必须是他能用的版本。
/// 自己设备走 beta 随便试，家里设备留在 stable 不动。
enum UpdateChannel { stable, beta }

/// 自动更新：从自己的服务器拉 version.json，比版本号，下载 APK，调系统安装器。
///
/// 为什么不走应用商店：本 App 含 B 站音频与网盘接口，不可能过审，只能侧载。
/// 所以更新只能自己做——用自己的服务器当"私有应用商店"。
class UpdateService extends ChangeNotifier {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const _kUrl = 'ts_update_url';
  static const _kChannel = 'ts_update_channel';
  static const _kSkip = 'ts_skip_code';
  static const _kAuto = 'ts_auto_update';

  static const _appInfo = MethodChannel('tingshu/app_info');
  static const _installer = MethodChannel('tingshu/installer');

  final Dio _dio = Dio(
    BaseOptions(
      // 更新请求可能走的是家用宽带 + 跨网到阿里云，15 秒太紧（真机实测会超时），
      // 45 秒才够用；下载大文件另有更长的独立超时
      connectTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(seconds: 45),
      validateStatus: (s) => s != null && s < 400,
    ),
  );

  SharedPreferences? _sp;
  bool _ready = false;

  int _currentCode = 0;
  String _currentName = '';

  /// 两条版本线（都是阿里云 ECS 上的静态文件）：
  ///
  /// - **标准版** `version.json`：给家里老人用的，只放验证过的稳定版本
  /// - **测试版** `version-beta.json`：给自己设备用的，改完就推
  ///
  /// 两个文件各自指向自己的 APK（`tingshu.apk` / `tingshu-beta.apk`），
  /// 所以两条线可以同时存在不同版本，互不影响。
  static const stableManifestUrl =
      'https://ali.popcalico.top/tingshu/version.json';
  static const betaManifestUrl =
      'https://ali.popcalico.top/tingshu/version-beta.json';

  /// 旧代码兼容用，等同标准版地址
  static const defaultManifestUrl = stableManifestUrl;

  /// 家属手填的自定义地址（一般用不到，留作后门）
  String _customUrl = '';
  UpdateChannel _channel = UpdateChannel.stable;
  bool _autoCheck = true;
  int _skipCode = 0;

  int get currentCode => _currentCode;
  String get currentName => _currentName;
  bool get autoCheck => _autoCheck;
  bool get ready => _ready;

  UpdateChannel get channel => _channel;
  String get channelLabel =>
      _channel == UpdateChannel.beta ? '测试版' : '标准版';
  String get channelHint => _channel == UpdateChannel.beta
      ? '改完就推，可能不稳'
      : '只放验证过的版本';

  /// 实际去拉清单的地址：手填地址优先，否则按通道取默认地址
  String get manifestUrl {
    if (_customUrl.trim().isNotEmpty) return _customUrl.trim();
    return _channel == UpdateChannel.beta ? betaManifestUrl : stableManifestUrl;
  }

  /// 有默认地址，所以永远可以检查
  bool get configured => true;

  bool get hasCustomUrl => _customUrl.trim().isNotEmpty;

  /// 设置页显示："1.0.0 (2001)"
  String get versionLabel =>
      _currentName.isEmpty ? '—' : '$_currentName ($_currentCode)';

  Future<void> load() async {
    if (_ready) return;
    _sp = await SharedPreferences.getInstance();
    _customUrl = _sp?.getString(_kUrl) ?? '';
    _channel = _sp?.getString(_kChannel) == 'beta'
        ? UpdateChannel.beta
        : UpdateChannel.stable;
    _autoCheck = _sp?.getBool(_kAuto) ?? true;
    _skipCode = _sp?.getInt(_kSkip) ?? 0;

    try {
      final info = await _appInfo.invokeMapMethod<String, dynamic>('get');
      _currentCode = (info?['versionCode'] as num?)?.toInt() ?? 0;
      _currentName = info?['versionName'] ?? '';
    } catch (_) {}

    _ready = true;
    notifyListeners();
  }

  Future<void> setManifestUrl(String url) async {
    _customUrl = url.trim();
    await _sp?.setString(_kUrl, _customUrl);
    notifyListeners();
  }

  /// 切换版本线。
  ///
  /// 同时清掉"跳过的版本号"：否则从标准版切到测试版后，
  /// 之前跳过过的那个 code 会继续生效，用户会以为切了没反应。
  Future<void> setChannel(UpdateChannel c) async {
    _channel = c;
    _skipCode = 0;
    await _sp?.setString(_kChannel, c.name);
    await _sp?.setInt(_kSkip, 0);
    notifyListeners();
  }

  Future<void> setAutoCheck(bool v) async {
    _autoCheck = v;
    await _sp?.setBool(_kAuto, v);
    notifyListeners();
  }

  /// 用户点了"这个版本先不更新"
  Future<void> skipThisVersion(int code) async {
    _skipCode = code;
    await _sp?.setInt(_kSkip, code);
  }

  /// 清除全部数据后把更新设置恢复成默认（通道回标准版、地址回默认）
  void resetForWipe() {
    _customUrl = '';
    _channel = UpdateChannel.stable;
    _autoCheck = true;
    _skipCode = 0;
    _sp = null;
    _ready = false;
    notifyListeners();
  }

  /// 启动时静默检查：只返回需要提示的版本，网络错误一律吞掉
  Future<UpdateInfo?> autoCheckOnStart() async {
    if (!configured || !_autoCheck) return null;
    try {
      final info = await fetchLatest();
      if (info == null) return null;
      if (info.versionCode <= _currentCode) return null;
      if (info.versionCode == _skipCode && !info.force) return null;
      return info;
    } catch (_) {
      return null;
    }
  }

  /// 拉 version.json。返回 null 表示 JSON 不合法。
  ///
  /// 弱网下第一次连接失败很常见（家用宽带、跨网、DNS 慢），
  /// 所以这里重试 3 次，并把底层英文异常翻译成人话。
  Future<UpdateInfo?> fetchLatest() async {
    if (!configured) return null;
    final base = manifestUrl;
    final url = '$base${base.contains('?') ? '&' : '?'}t=${DateTime.now().millisecondsSinceEpoch}';

    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final res = await _dio.get<String>(
          url,
          options: Options(responseType: ResponseType.plain),
        );
        final raw = res.data;
        if (raw == null || raw.trim().isEmpty) return null;
        final map = jsonDecode(raw);
        if (map is! Map) return null;
        return UpdateInfo.fromJson(map.cast<String, dynamic>());
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
    }
    throw Exception(_explain(lastError, url));
  }

  /// 把 Dio / Socket 的英文异常翻译成家属能照做的中文
  String _explain(Object? e, String url) {
    final dio = e is DioException ? e : null;
    switch (dio?.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return '连不上更新服务器（等太久了）。\n请检查手机网络，或确认地址能打开：\n$url';
      case DioExceptionType.receiveTimeout:
        return '服务器响应太慢。稍后再试一次。';
      case DioExceptionType.connectionError:
        return '连不上更新服务器。\n请确认服务器已启动、地址没写错：\n$url';
      case DioExceptionType.badResponse:
        final code = dio?.response?.statusCode;
        return '服务器返回 ${code ?? '异常'}。多半是 version.json 或安装包路径不对。';
      default:
        break;
    }
    final s = '$e';
    if (s.contains('SocketException') || s.contains('Failed host lookup')) {
      return '解析不了这个网址，可能写错了：\n$url';
    }
    return '检查更新失败：${s.replaceFirst('Exception: ', '')}';
  }

  /// 下载新版本到应用私有目录，返回本地路径。
  ///
  /// 做了两件容易被忽略但真机上很要命的事：
  /// 1. **已下好的不重下**（安装失败后重试时直接复用，省 36MB 流量）；
  /// 2. **支持 Range 的服务器断点续传**（Nginx 默认支持），断一次不用从 0 开始。
  Future<String> download(UpdateInfo info, {void Function(double)? onProgress}) async {
    final base = await getExternalStorageDirectory() ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/update');
    if (!await dir.exists()) await dir.create(recursive: true);

    final target = File('${dir.path}/tingshu-${info.versionCode}.apk');

    if (await target.exists()) {
      final len = await target.length();
      final complete = len > 1024 * 1024 && (info.size <= 0 || len == info.size);
      if (complete) {
        onProgress?.call(1);
        return target.path;
      }
    }

    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await _downloadOnce(info, target, onProgress);
        await _cleanOldPacks(dir, target);
        return target.path;
      } catch (e) {
        lastError = e;
        if (attempt >= 3) break;
        // 等一会儿再试；文件留着，下一轮带 Range 头续传
        await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
      }
    }
    throw Exception(_explain(lastError, info.url));
  }

  /// 删掉以前版本留下的安装包。
  ///
  /// 每个包 36MB，不清理的话每更新一次就多占一份，老人手机本来空间就紧张。
  /// 只保留 [keep] 指定的那个（本次要装的），其余全删。
  Future<void> _cleanOldPacks(Directory dir, File keep) async {
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.apk') && e.path != keep.path) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 启动时清一次。老版本升级上来的用户，目录里可能堆着好几个 36MB 的旧包，
  /// 而"下载后清理"的新逻辑要等这一版跑起来才生效，所以启动再兜一次。
  ///
  /// 保留最新修改的那个 apk：万一上次下载到一半被杀进程，那个半成品留着能续传。
  Future<void> cleanupOldPacks() async {
    try {
      final base = await getExternalStorageDirectory() ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/update');
      if (!await dir.exists()) return;

      final packs = <File>[];
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.apk')) packs.add(e);
      }
      if (packs.length <= 1) return;

      final stats = <MapEntry<File, DateTime>>[];
      for (final f in packs) {
        try {
          stats.add(MapEntry(f, (await f.stat()).modified));
        } catch (_) {}
      }
      stats.sort((a, b) => b.value.compareTo(a.value)); // 新的在前
      for (var i = 1; i < stats.length; i++) {
        try {
          await stats[i].key.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _downloadOnce(
    UpdateInfo info,
    File target,
    void Function(double)? onProgress,
  ) async {
    final existing = await target.exists() ? await target.length() : 0;

    final res = await _dio.get<ResponseBody>(
      info.url,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(minutes: 20),
        headers: existing > 0 ? {'range': 'bytes=$existing-'} : null,
      ),
    );

    // 只有服务器真的返回 206 才追加，否则（200 全量）必须重写，不然文件会坏
    final partial = res.statusCode == 206 && existing > 0;
    if (!partial && await target.exists()) await target.delete();

    final headLen = int.tryParse(res.headers.value(Headers.contentLengthHeader) ?? '') ?? 0;
    final total = headLen > 0
        ? (partial ? existing + headLen : headLen)
        : (info.size > 0 ? info.size : 0);
    final base = partial ? existing : 0;

    final sink = target.openWrite(mode: partial ? FileMode.append : FileMode.write);
    var received = 0;
    final done = Completer<void>();

    res.data!.stream.listen(
      (chunk) {
        sink.add(chunk);
        received += chunk.length;
        final now = base + received;
        onProgress?.call(total > 0 ? (now / total).clamp(0.0, 1.0) : -1);
      },
      onDone: () => done.complete(),
      onError: (Object e, StackTrace s) => done.completeError(e),
      cancelOnError: true,
    );

    try {
      await done.future;
    } finally {
      await sink.flush();
      await sink.close();
    }

    final len = await target.length();
    if (info.size > 0 && len < info.size) {
      throw Exception('下载不完整');
    }
    if (len < 1024) throw Exception('下载下来的文件不完整');
  }

  /// 是否已允许安装未知来源应用
  Future<bool> canInstall() async {
    try {
      return await _installer.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openInstallPermission() async {
    try {
      await _installer.invokeMethod('openInstallPermission');
    } catch (_) {}
  }

  Future<void> install(String path) async {
    await _installer.invokeMethod('install', {'path': path});
  }
}

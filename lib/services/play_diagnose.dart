import 'package:dio/dio.dart';

import '../models/ting.dart';
import 'quark/quark_api.dart';

/// 播放诊断：把"哪一步断了"查清楚。
///
/// 用户反馈"能解析、不能播"时，光看界面只有一句"没放出来"，
/// 分不清是：直链没取到 / 链接被 CDN 拒（403）/ 文件读不到 / 播放器打不开。
/// 这里按顺序把每一步的结果都测一遍，输出成一段可截图的文字。
///
/// 只读诊断，不改任何状态。
class PlayDiagnose {
  PlayDiagnose._();

  static Future<String> run(TingBook book, TingChapter chapter) async {
    final out = <String>[];
    out.add('书：${book.title}');
    out.add('来源：${book.source.label}');
    out.add('回目：${chapter.numbered}');
    out.add('文件标识：${chapter.key.isEmpty ? '空（明显异常）' : '有（${chapter.key.length} 位）'}');
    out.add('文件大小：${chapter.sizeBytes > 0 ? '${(chapter.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB' : '未知'}');

    if (book.source != TingSource.quark) {
      out.add('');
      out.add('网络评书走 B 站，这里只诊断网盘。');
      return out.join('\n');
    }

    final api = QuarkApi.instance;
    out.add('夸克登录：${api.hasLogin ? '已登录' : '未登录（先重新登录）'}');
    if (!api.hasLogin) return out.join('\n');

    if (chapter.key.isEmpty) {
      out.add('');
      out.add('结论：这一回没有文件标识，说明添加书架时没把文件 id 存进来，需要重新扫描添加。');
      return out.join('\n');
    }

    final sw = Stopwatch()..start();
    String url;
    try {
      url = await api.downloadUrl(chapter.key);
      out.add('取直链：成功（${sw.elapsedMilliseconds} ms）');
    } catch (e) {
      out.add('取直链：失败 —— $e');
      out.add('');
      final es = '$e';
      if (es.contains('type ') || es.contains('cast')) {
        out.add('结论：客户端解析网盘返回时出错了（1.1.19 及以前的老 bug），'
            '更新到 1.1.20 及以上就能播。');
      } else {
        out.add('结论：网盘那边没给下载地址。多半是登录过期或文件被移动/删除。');
      }
      return out.join('\n');
    }

    final uri = Uri.tryParse(url);
    out.add('直链域名：${uri?.host ?? '无法解析'}');
    out.add('直链参数：${uri == null ? '-' : (uri.query.isEmpty ? '没有（可能是裸链）' : '有 ${uri.queryParameters.length} 个')}');

    // 真的发一次请求，看 CDN 认不认这套 Cookie/UA/Referer
    sw.reset();
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: true,
      ));
      final res = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {...api.mediaHeaders, 'Range': 'bytes=0-2047'},
          validateStatus: (_) => true,
        ),
      );
      out.add('HTTP 状态：${res.statusCode}（${sw.elapsedMilliseconds} ms）');
      out.add('内容类型：${res.headers.value('content-type') ?? '无'}');
      final len = res.headers.value('content-length');
      out.add('内容长度：${len ?? '无'}');
      out.add('支持分段：${res.headers.value('accept-ranges') ?? '无'}');

      var got = 0;
      final stream = res.data?.stream;
      if (stream != null) {
        final sub = stream.listen(
          (chunk) {
            got += chunk.length;
          },
          onError: (_) {},
          cancelOnError: true,
        );
        // 最多等 5 秒，读到 2KB 就够证明"内容能取"
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (got < 2048 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await sub.cancel();
      }
      out.add('实际读到：$got 字节');

      out.add('');
      if (res.statusCode == 206 || res.statusCode == 200) {
        if (got > 0) {
          out.add('结论：直链能取到内容。问题在播放器这一侧（解码/容器格式），'
              '把这段发我，我按格式调播放参数。');
        } else {
          out.add('结论：服务器回了 ${res.statusCode} 但读不到内容，多数是被限流或链接刚过期。再点一次播放试试。');
        }
      } else if (res.statusCode == 403 || res.statusCode == 401) {
        out.add('结论：网盘拒绝访问（${res.statusCode}）。重新登录夸克网盘再试；'
            '还不行就是会员/分享限制，需要换一个文件夹里的文件试。');
      } else if (res.statusCode == 404) {
        out.add('结论：文件已经不在网盘这个位置了，重新扫描添加一次。');
      } else {
        out.add('结论：网盘返回 ${res.statusCode}，把这段发我。');
      }
    } catch (e) {
      out.add('请求直链：失败 —— $e');
      out.add('');
      out.add('结论：连不上网盘的文件服务器。先确认手机能上网，再试一次。');
    }

    return out.join('\n');
  }
}

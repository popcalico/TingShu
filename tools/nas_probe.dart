// 用 App 里同一套 WebDAV 代码直连真实 NAS，定位"扫描不到音频"的原因。
//
// 跑法：
//   export TS_NAS_URL=https://your-nas/dav
//   export TS_NAS_USER=xxx TS_NAS_PASS=yyy
//   dart run tools/nas_probe.dart
import 'dart:io';

import 'package:tingshu/services/nas/scanner.dart';
import 'package:tingshu/services/nas/webdav_client.dart';

Future<void> main(List<String> args) async {
  final base = args.isNotEmpty ? args[0] : (Platform.environment['TS_NAS_URL'] ?? '');
  final user = args.length > 1 ? args[1] : (Platform.environment['TS_NAS_USER'] ?? '');
  final pass = args.length > 2 ? args[2] : (Platform.environment['TS_NAS_PASS'] ?? '');
  if (base.isEmpty || user.isEmpty || pass.isEmpty) {
    stderr.writeln('缺少参数：设置 TS_NAS_URL / TS_NAS_USER / TS_NAS_PASS，'
        '或直接传三个命令行参数');
    exit(2);
  }

  final c = WebDavClient(baseUrl: base, username: user, password: pass);
  print('base = $base');
  print('urlFor("/")      = ${c.urlFor('/')}');
  print('urlFor("/book")  = ${c.urlFor('/book')}');
  print('urlFor("/book/") = ${c.urlFor('/book/')}');
  print('urlFor("/book/袁阔成/") = ${c.urlFor('/book/袁阔成/')}');

  print('\n--- ping ---');
  try {
    await c.ping();
    print('ping OK');
  } catch (e) {
    print('ping FAIL: $e');
  }

  for (final p in ['/', '/book', '/book/袁阔成']) {
    print('\n--- list("$p") ---');
    try {
      final l = await c.list(p);
      print('count=${l.length}');
      for (final e in l) {
        print('  ${e.isDir ? "D" : "F"} ${e.path}  name=${e.name}');
      }
    } catch (e, st) {
      print('list FAIL: $e');
      print(st.toString().split('\n').take(6).join('\n'));
    }
  }

  print('\n--- walk("/") 前 30 条 ---');
  var n = 0;
  try {
    await for (final e in c.walk('/')) {
      print('${e.isDir ? "D" : "F"} ${e.path} audio=${e.isAudio}');
      if (++n >= 30) break;
    }
  } catch (e) {
    print('walk FAIL: $e');
  }
  await scanCheck(c, '/book');
  exit(0);
}

// ---- 追加：用真实数据跑一遍"识别成书" ----
Future<void> scanCheck(WebDavClient c, String root) async {
  final files = <DavEntry>[];
  await for (final e in c.walk(root)) {
    if (e.isDir) continue;
    final rel = e.path.startsWith('$root/')
        ? e.path.substring(root.length)
        : e.path;
    files.add(DavEntry(path: rel, name: e.name, isDir: false, size: e.size));
  }
  print('\n=== scanCheck root=$root 文件数=${files.length} ===');
  final drafts = NasScanner.scan(files, rootName: 'book');
  print('识别出 ${drafts.length} 本书');
  for (final d in drafts) {
    print('  《${d.title}》 作者=${d.author}  ${d.chapters.length} 回');
  }
}

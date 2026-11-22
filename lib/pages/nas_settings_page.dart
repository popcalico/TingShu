import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../services/nas/nas_source.dart';
import '../services/nas/webdav_client.dart';
import '../widgets/common.dart';

/// 家里的 NAS 设置页（家属用，只在测试版出现）。
///
/// 三件事：地址、账号、评书文件夹。填完点"测试连接"能立刻知道
/// 是地址错、账号错，还是 NAS 上根本没开 WebDAV。
class NasSettingsPage extends StatefulWidget {
  const NasSettingsPage({super.key});

  @override
  State<NasSettingsPage> createState() => _NasSettingsPageState();
}

class _NasSettingsPageState extends State<NasSettingsPage> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  bool _busy = false;
  String? _msg;
  bool _msgOk = false;

  @override
  void initState() {
    super.initState();
    final nas = NasSource.instance;
    _url.text = nas.url;
    _user.text = nas.username;
    _pass.text = nas.password;
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  String _clean(Object e) => '$e'.replaceFirst('Exception: ', '');

  /// 把输入框里的内容先落盘，再测——否则测的是旧配置
  Future<void> _applyInputs() async {
    await NasSource.instance.saveConfig(
      url: _normalizeUrl(_url.text),
      user: _user.text,
      pass: _pass.text,
    );
    // 规范化后的地址回填，让家属看见"实际会用的地址"
    final saved = NasSource.instance.url;
    if (saved.isNotEmpty && _url.text != saved) _url.text = saved;
  }

  /// 地址容错。
  ///
  /// 家属填地址时最常见的几种错法：漏 `http://`、结尾多个 `/`、
  /// 明明该用 http 却写成域名（被判成 https）。这里统一补齐。
  ///
  /// 判断"http 还是 https"的规则：
  /// - IPv6 字面量（`[2409:...]:5005`）、纯 IPv4、带明文端口的 → http
  /// - 只有一个光秃秃的域名 → https（内网穿透一般挂证书）
  ///
  /// 注意**不自动补 `/dav`**：局域网直连 WebDAV 端口是不带路径的，
  /// 自动补反而会把好地址改坏；少路径时的报错里已经点明了。
  static String _normalizeUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      final isIpv6 = s.startsWith('[');
      final isIp = RegExp(r'^\d{1,3}(\.\d{1,3}){3}').hasMatch(s);
      // NAS 的 WebDAV 明文端口：飞牛 5005、群晖 5005、威联通 5000/8080
      final plainPort = RegExp(r':(5005|5666|8080|5000)(/|$)').hasMatch(s);
      s = '${(isIpv6 || isIp || plainPort) ? 'http' : 'https'}://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<void> _test() async {
    await _applyInputs();
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final text = await NasSource.instance.testConnection();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _msgOk = true;
        _msg = text;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _msgOk = false;
        _msg = _clean(e);
      });
    }
  }

  Future<void> _pickFolder() async {
    await _applyInputs();
    if (!NasSource.instance.configured) {
      setState(() {
        _msgOk = false;
        _msg = '先填地址和用户名';
      });
      return;
    }
    final picked = await _pickNasFolder(context);
    if (!mounted || picked == null) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final nas = NasSource.instance;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const TingBar(title: '家里的 NAS'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 24),
                children: [
                  const Text(
                    '在 NAS 上开一个 WebDAV（飞牛/群晖/威联通都有），'
                    '填好地址和账号，手机在家就能直接听。',
                    style: TextStyle(fontSize: 16, height: 1.6, color: TingColors.muted),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '在家填局域网地址（如 http://192.168.1.10:5005）；'
                    '在外面填穿透地址（如 https://nas.popcalico.top/dav）；'
                    '手机有 IPv6 时也可以直连（http://域名:5005）。\n'
                    '地址里的端口要填 NAS 的 WebDAV 端口，不是网页端口。',
                    style: TextStyle(fontSize: 15, height: 1.55, color: TingColors.muted),
                  ),
                  const SizedBox(height: 18),
                  _field(
                    label: '地址',
                    controller: _url,
                    hint: 'http://192.168.1.10:5005',
                    keyboard: TextInputType.url,
                  ),
                  const SizedBox(height: 14),
                  _field(label: '用户名', controller: _user, hint: 'book'),
                  const SizedBox(height: 14),
                  _field(
                    label: '密码',
                    controller: _pass,
                    hint: 'NAS 的密码',
                    obscure: true,
                  ),
                  const SizedBox(height: 20),
                  BigRow(
                    title: '评书文件夹',
                    icon: Icons.folder_rounded,
                    value: nas.rootName,
                    onTap: _pickFolder,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy ? null : _test,
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 60)),
                          child: _busy
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                                )
                              : const Text('测试连接', style: TextStyle(fontSize: 19)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            await _applyInputs();
                            NasSource.instance.invalidate();
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已保存')),
                            );
                            Navigator.of(context).pop();
                          },
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 60)),
                          child: const Text('保存', style: TextStyle(fontSize: 19)),
                        ),
                      ),
                    ],
                  ),
                  if (_msg != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _msgOk ? TingColors.doneSoft : TingColors.warnSoft,
                        borderRadius: BorderRadius.circular(T.radius),
                      ),
                      child: Text(
                        _msg!,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.55,
                          color: _msgOk ? TingColors.done : TingColors.warn,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String hint = '',
    TextInputType? keyboard,
    bool obscure = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: TingColors.ink),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          obscureText: obscure,
          style: const TextStyle(fontSize: 18),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 17, color: TingColors.muted),
            filled: true,
            fillColor: TingColors.surface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.radius),
              borderSide: const BorderSide(color: TingColors.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.radius),
              borderSide: const BorderSide(color: TingColors.line),
            ),
          ),
        ),
      ],
    );
  }
}

/// 选 NAS 上的"评书根目录"：只列文件夹，点进去可以继续往里选。
Future<String?> _pickNasFolder(BuildContext context) async {
  var path = NasSource.instance.rootPath;
  var stack = <(String, String)>[(path, NasSource.instance.rootName)];

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TingColors.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          final future = NasSource.instance.listDirs(path);
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.8,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      if (stack.length > 1)
                        IconButton(
                          iconSize: 30,
                          onPressed: () {
                            stack = stack.sublist(0, stack.length - 1);
                            path = stack.last.$1;
                            setSheet(() {});
                          },
                          icon: const Icon(Icons.arrow_back_ios_new_rounded),
                        ),
                      Expanded(
                        child: Text(
                          stack.last.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: T.fontTitle,
                            fontWeight: FontWeight.w700,
                            color: TingColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<DavEntry>>(
                    future: future,
                    builder: (ctx, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snap.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              '${snap.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: T.fontBody, color: TingColors.muted),
                            ),
                          ),
                        );
                      }
                      final dirs = snap.data ?? const <DavEntry>[];
                      if (dirs.isEmpty) {
                        return const Center(
                          child: Text(
                            '这里没有子文件夹',
                            style: TextStyle(fontSize: T.fontBody, color: TingColors.muted),
                          ),
                        );
                      }
                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: dirs.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final d = dirs[i];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(vertical: 6),
                            leading: const Icon(Icons.folder_rounded, size: 34, color: TingColors.primary),
                            title: Text(
                              d.name,
                              style: const TextStyle(fontSize: T.fontBody, color: TingColors.ink),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  onPressed: () {
                                    path = d.path;
                                    stack = [...stack, (d.path, d.name)];
                                    setSheet(() {});
                                  },
                                  child: const Text('进去'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, d.path),
                                  child: const Text('选它'),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          await NasSource.instance.saveConfig(
                            root: stack.last.$1,
                            rootName: stack.last.$2,
                          );
                          if (ctx.mounted) Navigator.pop(ctx, stack.last.$1);
                        },
                        child: Text('就用「${stack.last.$2}」'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

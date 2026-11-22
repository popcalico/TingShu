import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/ting_theme.dart';
import '../services/quark/quark_api.dart';
import '../widgets/common.dart';

/// 夸克网盘登录。
///
/// 登录页是原生 WebView（见 QuarkLoginActivity）——夸克的关键 Cookie 是
/// HttpOnly，网页脚本读不到，只能由系统 CookieManager 取出来交给 Dart 保存。
class QuarkLoginPage extends StatefulWidget {
  const QuarkLoginPage({super.key});

  @override
  State<QuarkLoginPage> createState() => _QuarkLoginPageState();
}

class _QuarkLoginPageState extends State<QuarkLoginPage> {
  static const _channel = MethodChannel('tingshu/quark_login');

  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cookie = await _channel.invokeMethod<String>('login');
      if (!mounted) return;
      if (cookie == null || cookie.isEmpty) {
        setState(() {
          _busy = false;
          _error = '还没登录成功。请在打开的页面里用手机号登录，再点右上角「我登好了」。';
        });
        return;
      }

      await QuarkApi.instance.saveCookie(cookie);
      // 存下来不代表能用，真发一次请求验证
      try {
        await QuarkApi.instance.list('0');
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = '$e'.replaceFirst('Exception: ', '');
        });
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? '打开登录页失败';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TingColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const TingBar(title: '连接夸克网盘'),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: T.pagePad),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.cloud_queue_rounded, size: 88, color: TingColors.primary),
                    const SizedBox(height: 24),
                    const Text(
                      '用你的夸克账号登录一次',
                      style: TextStyle(
                        fontSize: T.fontTitle,
                        fontWeight: FontWeight.w700,
                        color: TingColors.ink,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '登录后 App 才能读到你网盘里的评书。\n账号密码只交给夸克，App 只保存登录凭证。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: T.fontBody, height: 1.7, color: TingColors.muted),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: TingColors.warnSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(fontSize: 16, height: 1.5, color: TingColors.warn),
                        ),
                      ),
                    ],
                    const SizedBox(height: 34),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : _login,
                        child: _busy
                            ? const SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                              )
                            : const Text('去登录'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '登录凭证通常会保存一两个月，之后要是提示过期，回来再登一次就行。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, height: 1.6, color: TingColors.muted),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

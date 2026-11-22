import 'dart:async';

import 'package:flutter/services.dart';

/// 音频焦点 + 拔耳机事件。
///
/// 老人听评书常常一放一下午，来电话必须自动停、挂电话接着放，
/// 拔耳机要停（否则声音从喇叭里炸出来）。
class AudioFocus {
  AudioFocus._();
  static final AudioFocus instance = AudioFocus._();

  static const _method = MethodChannel('tingshu/focus');
  static const _events = EventChannel('tingshu/focus_events');

  Stream<String>? _stream;
  bool _granted = false;

  /// gained / interrupted / ducked / lost / noisy
  Stream<String> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((e) => '$e')
      .handleError((_) {})
      .cast<String>();

  Future<bool> request() async {
    if (_granted) return true;
    try {
      _granted = await _method.invokeMethod<bool>('request') ?? false;
    } catch (_) {
      _granted = false;
    }
    return _granted;
  }

  Future<void> abandon() async {
    if (!_granted) return;
    try {
      await _method.invokeMethod('abandon');
    } catch (_) {}
    _granted = false;
  }
}

import 'package:audio_service/audio_service.dart';

import 'ting_player.dart';

/// 系统媒体会话桥接：锁屏和通知栏上的大按钮直接控制播放。
///
/// 老人经常锁屏后从口袋里摸手机，通知栏能暂停/继续比什么都重要，
/// 所以这里保留"上一回 / 后退15秒 / 播放暂停 / 前进15秒 / 下一回"五个键。
class TingAudioHandler extends BaseAudioHandler {
  TingAudioHandler() {
    playbackState.add(PlaybackState(
      controls: const [MediaControl.play],
      systemActions: const {MediaAction.play, MediaAction.pause, MediaAction.stop},
      processingState: AudioProcessingState.idle,
      playing: false,
      updatePosition: Duration.zero,
    ));
  }

  TingPlayer get _p => TingPlayer.instance;

  @override
  Future<void> play() => _p.resumeOrOpenCurrent();

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> seek(Duration position) => _p.seek(position);

  @override
  Future<void> skipToNext() => _p.next();

  @override
  Future<void> skipToPrevious() => _p.previous();

  @override
  Future<void> fastForward() => _p.seekRelative(15);

  @override
  Future<void> rewind() => _p.seekRelative(-15);

  @override
  Future<void> stop() => _p.stop();
}

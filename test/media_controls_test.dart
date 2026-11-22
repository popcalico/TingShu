import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu/player/ting_player.dart';

/// 这组测试锁死一个曾经导致真机闪退的 bug：
///
/// 通知折叠视图的按钮索引原来写死为 [0, 2, 4]，但 controls 是动态的——
/// 第一回没有"上一回"、最后一回没有"下一回"时只有 3~4 项，
/// 索引 4 越界，Android 12 及以下构建媒体通知时抛
/// IndexOutOfBoundsException，整台手机上的 App 直接闪退。
void main() {
  group('通知折叠视图索引', () {
    test('中间回：五个键，折叠选快退/播放暂停/快进', () {
      final controls = <MediaControl>[
        MediaControl.skipToPrevious,
        MediaControl.rewind,
        MediaControl.pause,
        MediaControl.fastForward,
        MediaControl.skipToNext,
      ];
      expect(compactActionIndices(controls, MediaControl.pause), [1, 2, 3]);
    });

    test('第一回（没有上一回）：索引要跟着前移', () {
      final controls = <MediaControl>[
        MediaControl.rewind,
        MediaControl.play,
        MediaControl.fastForward,
        MediaControl.skipToNext,
      ];
      final r = compactActionIndices(controls, MediaControl.play);
      expect(r, [0, 1, 2]);
      expect(r.every((i) => i < controls.length), isTrue);
    });

    test('最后一回（没有下一回）：不能出现索引 4', () {
      final controls = <MediaControl>[
        MediaControl.skipToPrevious,
        MediaControl.rewind,
        MediaControl.pause,
        MediaControl.fastForward,
      ];
      final r = compactActionIndices(controls, MediaControl.pause);
      expect(r, [1, 2, 3]);
      expect(r.contains(4), isFalse);
    });

    test('整本书只有一回：三个键也合法', () {
      final controls = <MediaControl>[
        MediaControl.rewind,
        MediaControl.pause,
        MediaControl.fastForward,
      ];
      expect(compactActionIndices(controls, MediaControl.pause), [0, 1, 2]);
    });

    test('穷举 8 种状态组合：索引永不越界，且中间一定是播放/暂停', () {
      for (final hasPrev in [false, true]) {
        for (final hasNext in [false, true]) {
          for (final playing in [false, true]) {
            final playPause = playing ? MediaControl.pause : MediaControl.play;
            final controls = <MediaControl>[
              if (hasPrev) MediaControl.skipToPrevious,
              MediaControl.rewind,
              playPause,
              MediaControl.fastForward,
              if (hasNext) MediaControl.skipToNext,
            ];
            final r = compactActionIndices(controls, playPause);

            expect(r, isNotEmpty);
            expect(r.length, lessThanOrEqualTo(3));
            for (final i in r) {
              expect(
                i,
                lessThan(controls.length),
                reason: '越界会闪退：hasPrev=$hasPrev hasNext=$hasNext playing=$playing',
              );
            }
            // 折叠视图里必须能按到播放/暂停，否则老人锁屏后停不下来
            expect(controls[r[1]], playPause);
          }
        }
      }
    });
  });
}

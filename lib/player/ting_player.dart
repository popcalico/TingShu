import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../core/theme/ting_theme.dart';
import '../models/ting.dart';
import '../services/audio_focus.dart';
import '../services/bili_source.dart';
import '../services/cache/cache_engine.dart';
import '../services/library.dart';
import '../services/nas/nas_source.dart';
import '../services/quark/quark_api.dart';
import '../services/quark/quark_source.dart';

enum TingState {
  idle, // 还没开始
  preparing, // 正在下载这一回
  playing,
  paused,
  finished, // 全书听完
  error,
}

/// 听书播放器。
///
/// 一次只放一回，播完自动接下一回——老人不需要知道"播放列表"是什么。
/// 音频一律先落到本地缓存再播（见 CacheEngine 的说明），所以断网也能重听。
class TingPlayer extends ChangeNotifier {
  TingPlayer._();
  static final TingPlayer instance = TingPlayer._();

  final Player _mp = Player();
  final CacheEngine _cache = CacheEngine.instance;
  final Library _lib = Library.instance;

  BaseAudioHandler? _handler;

  ShelfItem? _item;
  int _index = 0;
  TingState _state = TingState.idle;
  String? _error;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _loadProgress = 0;
  int _preparingIndex = -1;

  double _speed = 1.0;

  int _sleepEndAt = 0; // 毫秒时间戳，0 表示没开
  Timer? _sleepTicker;

  Timer? _saveTicker;
  bool _advancing = false;
  int _openToken = 0;

  /// mpv 报错次数。流播时一旦报错（403/链接过期/格式不支持），
  /// 立刻转"下载完再播"，不用干等 8 秒。
  int _mediaErrorCount = 0;
  String? _lastMediaError;

  // ---- 对外只读状态 ----

  ShelfItem? get item => _item;
  TingBook? get book => _item?.book;
  int get index => _index;
  TingChapter? get chapter {
    final b = book;
    if (b == null || _index < 0 || _index >= b.chapters.length) return null;
    return b.chapters[_index];
  }

  TingState get state => _state;
  bool get isPlaying => _state == TingState.playing;
  bool get isPreparing => _state == TingState.preparing;
  String? get error => _error;
  Duration get position => _position;
  Duration get duration => _duration;
  double get loadProgress => _loadProgress;
  int get preparingIndex => _preparingIndex;
  double get speed => _speed;
  bool get hasNext => book != null && _index + 1 < book!.chapters.length;
  bool get hasPrev => book != null && _index > 0;

  int get sleepRemainMinutes {
    if (_sleepEndAt == 0) return 0;
    final left = _sleepEndAt - DateTime.now().millisecondsSinceEpoch;
    return left <= 0 ? 0 : (left / 60000).ceil();
  }

  bool get sleepOn => _sleepEndAt != 0;

  void attachHandler(BaseAudioHandler handler) {
    _handler = handler;
    _mp.stream.position.listen(_onPosition);
    _mp.stream.duration.listen((d) {
      if (d.inMilliseconds > 0) {
        _duration = d;
        _pushState(force: true);
      }
    });
    _mp.stream.playing.listen((_) {
      _pushState(force: true);
    });
    _mp.stream.completed.listen((done) {
      if (done) _onCompleted();
    });
    _mp.stream.error.listen((e) {
      // 本地文件读不出来才算错；单集失败不该让整个应用报错，
      // 但要把次数记下来，让"边播边存"的兜底逻辑尽快接管。
      debugPrint('[player] media error: $e');
      _lastMediaError = '$e';
      _mediaErrorCount++;
    });
    AudioFocus.instance.events.listen(_onFocusEvent);
  }

  /// 来电话、导航播报、拔耳机：该停就停，该续就续
  bool _pausedByFocus = false;
  double _volumeBeforeDuck = 1.0;

  Future<void> _onFocusEvent(String event) async {
    switch (event) {
      case 'interrupted':
        if (_state != TingState.playing) return;
        _pausedByFocus = true;
        await _mp.pause();
        _state = TingState.paused;
        notifyListeners();
        _pushState(force: true);
        break;
      case 'gained':
        if (_pausedByFocus) {
          _pausedByFocus = false;
          await _mp.play();
          _state = TingState.playing;
          notifyListeners();
          _pushState(force: true);
        } else {
          await _mp.setVolume(_volumeBeforeDuck);
        }
        break;
      case 'ducked':
        _volumeBeforeDuck = _mp.state.volume;
        await _mp.setVolume(_volumeBeforeDuck * 0.3);
        break;
      case 'lost':
      case 'noisy':
        _pausedByFocus = false;
        if (_state == TingState.playing) await pause();
        break;
    }
  }

  /// 退出 App 前手动存一次进度
  Future<void> saveNow() => _saveProgress();

  // ---- 播放控制 ----

  /// 打开一本书的某一回并开始播放。
  ///
  /// [positionMs] 传上次听到的位置，实现精确到秒的续播。
  ///
  /// 两种情况直接复用当前播放，**不重新加载**：
  /// 1. 点的就是正在放（或刚暂停）的同一回 —— 否则从首页进来会"从第 1 秒重头开始"；
  /// 2. 同一回正在准备中 —— 避免重复下载、重复 open。
  Future<void> open(TingBook book, int index, {int positionMs = 0}) async {
    final idx = book.chapters.isEmpty ? 0 : index.clamp(0, book.chapters.length - 1);

    final sameAsNow = _item != null &&
        _item!.book.id == book.id &&
        _item!.book.source == book.source &&
        _index == idx &&
        (_state == TingState.playing ||
            _state == TingState.paused ||
            _state == TingState.preparing);

    // 先把状态同步好：调用方会立刻跳播放页，
    // 播放页第一帧就要能拿到书名/回目，否则会闪一下"还没有开始听"
    _item = _lib.find(book.source, book.id) ?? ShelfItem(book: book);
    _index = idx;
    _error = null;

    if (sameAsNow) {
      if (_state == TingState.paused) {
        await _mp.play();
        _state = TingState.playing;
      }
      notifyListeners();
      _pushState(force: true);
      return;
    }

    _state = TingState.preparing;
    _loadProgress = 0;
    _preparingIndex = idx;
    notifyListeners();
    _pushState(force: true);

    final item = await _lib.put(book);
    _item = item;
    await _playCurrent(positionMs: positionMs);
  }

  Future<void> resumeOrOpenCurrent() async {
    final it = _item ?? _lib.current;
    if (it == null) return;
    _item = it;
    if (_state == TingState.paused) {
      await _mp.play();
      _state = TingState.playing;
      notifyListeners();
      return;
    }
    if (_state == TingState.playing || _state == TingState.preparing) return;
    _index = it.chapterIndex.clamp(0, (it.book.chapters.length - 1).clamp(0, 1 << 30));
    await _playCurrent(positionMs: it.positionMs);
  }

  Future<void> toggle() async {
    if (_state == TingState.playing) {
      await pause();
    } else {
      await resumeOrOpenCurrent();
    }
  }

  Future<void> pause() async {
    await _mp.pause();
    _state = TingState.paused;
    await _saveProgress();
    notifyListeners();
    _pushState(force: true);
  }

  Future<void> next() async {
    if (!hasNext) return;
    _index++;
    await _playCurrent();
  }

  Future<void> previous() async {
    if (!hasPrev) return;
    _index--;
    await _playCurrent();
  }

  /// 跳到指定回（回目列表里点选）
  Future<void> jumpTo(int index) async {
    final b = book;
    if (b == null || index < 0 || index >= b.chapters.length) return;
    _index = index;
    await _playCurrent();
  }

  Future<void> seek(Duration p) async {
    await _mp.seek(p);
    _position = p;
    notifyListeners();
  }

  Future<void> seekRelative(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> setSpeed(double v) async {
    _speed = v;
    await _mp.setRate(v);
    notifyListeners();
  }

  Future<void> stop() async {
    // 注意：这里不把 _item 清掉。
    // stop() 会被"通知被滑走 / 点了通知上的停止"触发，
    // 清掉 _item 会让首页的"继续收听"跟着消失，老人以为书没了。
    // 停的是声音，记住的位置要留着。
    await _saveProgress();
    await _mp.stop();
    _state = TingState.idle;
    _position = Duration.zero;
    notifyListeners();
    _pushState(force: true);
  }

  /// 睡眠定时：到点自动暂停（老人常听着睡着）
  void setSleepTimer(int minutes) {
    _sleepTicker?.cancel();
    if (minutes <= 0) {
      _sleepEndAt = 0;
      notifyListeners();
      return;
    }
    _sleepEndAt = DateTime.now().millisecondsSinceEpoch + minutes * 60 * 1000;
    _sleepTicker = Timer.periodic(const Duration(seconds: 20), (_) {
      final left = _sleepEndAt - DateTime.now().millisecondsSinceEpoch;
      if (left <= 0) {
        _sleepTicker?.cancel();
        _sleepEndAt = 0;
        _fadeOutAndPause();
      }
      notifyListeners();
    });
    notifyListeners();
  }

  /// 音量渐弱再暂停，避免"突然没声"把人惊醒
  Future<void> _fadeOutAndPause() async {
    final base = _mp.state.volume;
    for (var i = 10; i >= 0; i--) {
      await _mp.setVolume(base * i / 10);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await pause();
    await _mp.setVolume(base);
  }

  // ---- 内部 ----

  Future<void> _playCurrent({int positionMs = 0}) async {
    final b = book;
    if (b == null || b.chapters.isEmpty) return;
    final ch = b.chapters[_index];
    final token = ++_openToken;

    _state = TingState.preparing;
    _error = null;
    _loadProgress = 0;
    _preparingIndex = _index;
    _position = Duration(milliseconds: positionMs);
    _duration = Duration.zero;
    notifyListeners();
    _pushState(force: true);

    try {
      // 已经存过：本地文件秒开
      final cachedPath = _cache.cachedPath(b.source, b.id, ch.key);
      if (cachedPath != null) {
        await _mp.open(Media(cachedPath), play: false);
      } else {
        // 没存过：拿到直链立刻开播，边听边把整回存到本地。
        //
        // 以前是"整回下载完才开播"，长一点的（一集四五十分钟、几百 MB）
        // 要转圈半分钟甚至更久，老人以为坏了就退出了。
        // 现在先出声，存盘在后台慢慢做；下次听这一回就是本地秒开，
        // 断网也能重听。
        final audio = await _resolve(b, ch);
        if (token != _openToken) return;
        // 基线要在 open 之前取：mpv 有时在 open 过程中就报错了
        final errBase = _mediaErrorCount;
        await _mp.open(
          Media(audio.url, httpHeaders: audio.headers),
          play: false,
        );
        unawaited(_cache.saveInBackground(b, ch, audio));
        // 后台盯着：万一这条直链根本流不动（不支持分段 / 已过期 / 403），
        // 会自动退回"下载完再播"，不用老人自己发现没声音。
        unawaited(_watchStreamFallback(token, b, ch, errBase));
      }
      if (token != _openToken) return; // 用户已经切到别的回了

      await _mp.setRate(_speed);
      if (positionMs > 1000) {
        await _seekAfterReady(positionMs, token);
      }
      if (token != _openToken) return;
      await AudioFocus.instance.request();
      await _mp.play();
      _state = TingState.playing;
      notifyListeners();
      _pushState(force: true);

      await _lib.saveProgress(b.source, b.id, chapterIndex: _index);
      _startSaveTicker();
      _prefetchNext();
    } on QuarkException catch (e) {
      if (token != _openToken) return;
      _state = TingState.error;
      _error = e.message;
      notifyListeners();
    } catch (e) {
      if (token != _openToken) return;
      _state = TingState.error;
      _error = _friendly(e);
      notifyListeners();
    }
  }

  /// 边播边存的兜底。
  ///
  /// 8 秒还没读出时长，说明这条直链根本流不动（不支持分段、链接过期、
  /// 或者被 CDN 掐了），这时自动退回"整回下载完再播"。
  /// 后台补存那一路已经在下载同一个文件了，这里 await 的是同一个任务，
  /// 不会再重复耗一遍流量。
  Future<void> _watchStreamFallback(
    int token,
    TingBook b,
    TingChapter ch,
    int errorBaseline,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (token != _openToken) return;
      if (_mp.state.duration.inMilliseconds > 0) return; // 流得动，正常
      // mpv 已经明确报错了：别等满 8 秒，直接转下载
      if (_mediaErrorCount != errorBaseline) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (token != _openToken) return;

    final resumeAt = _position;
    final wasPlaying = _state == TingState.playing;
    _state = TingState.preparing;
    _loadProgress = 0;
    notifyListeners();
    _pushState(force: true);

    try {
      final path = await _cache.obtain(
        b,
        ch,
        resolve: () => _resolve(b, ch),
        onProgress: (p, _) {
          if (token != _openToken) return;
          _loadProgress = p;
          notifyListeners();
        },
      );
      if (token != _openToken) return;
      await _mp.open(Media(path), play: false);
      await _mp.setRate(_speed);
      if (resumeAt.inMilliseconds > 1000) {
        await _seekAfterReady(resumeAt.inMilliseconds, token);
      }
      if (token != _openToken) return;
      if (wasPlaying) {
        await _mp.play();
        _state = TingState.playing;
      } else {
        _state = TingState.paused;
      }
      notifyListeners();
      _pushState(force: true);
    } catch (e) {
      if (token != _openToken) return;
      _state = TingState.error;
      _error = _friendly(e);
      notifyListeners();
    }
  }

  /// 续播定位：必须等播放器把文件读出来再 seek。
  ///
  /// media_kit（mpv）在 open() 刚返回时还没解析完文件头，
  /// 这会儿 seek 会被**静默忽略**——用户看到的现象就是"进度没接上，从头开始"。
  /// 这里是 bug 1 的第二个根因，光靠上层传对 positionMs 不够。
  Future<void> _seekAfterReady(int positionMs, int token) async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(deadline)) {
      if (token != _openToken) return;
      if (_mp.state.duration.inMilliseconds > 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (token != _openToken) return;

    final target = Duration(milliseconds: positionMs);
    await _mp.seek(target);

    // 再确认一次：个别文件 seek 后会被重新归零
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (token != _openToken) return;
    final actual = _mp.state.position;
    if ((actual.inMilliseconds - positionMs).abs() > 5000) {
      await _mp.seek(target);
    }
  }

  String _friendly(Object e) {
    final s = '$e';
    if (s.contains('SocketException') || s.contains('connection')) {
      return '网络好像断了，连上网再点一次';
    }
    if (s.contains('403') || s.contains('401')) {
      return '这一回的地址被网盘拒了，再点一次；还不行就到设置里重新登录夸克';
    }
    if (s.contains('404')) return '这一回的文件在网盘里找不到了，重新扫描添加一次';
    if (s.contains('QuarkException')) {
      return s.replaceFirst('Exception: ', '').replaceFirst('QuarkException: ', '');
    }
    return '这一回没放出来，再点一次试试';
  }

  Future<ResolvedAudio> _resolve(TingBook b, TingChapter ch) {
    switch (b.source) {
      case TingSource.bili:
        return BiliSource.instance.resolve(b, ch);
      case TingSource.quark:
        return QuarkSource.instance.resolve(b, ch);
      case TingSource.nas:
        return NasSource.instance.resolve(b, ch);
    }
  }

  /// 预取后面两回：老人听到一半切下一回时不用等下载
  void _prefetchNext() {
    final b = book;
    if (b == null) return;
    final from = _index + 1;
    final to = (_index + 3).clamp(from, b.chapters.length);
    if (from >= b.chapters.length) return;
    _cache.prefetch(b, b.chapters.sublist(from, to), resolve: (ch) => _resolve(b, ch));
  }

  void _startSaveTicker() {
    _saveTicker?.cancel();
    _saveTicker = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
  }

  Future<void> _saveProgress() async {
    final b = book;
    if (b == null) return;
    await _lib.saveProgress(
      b.source,
      b.id,
      chapterIndex: _index,
      positionMs: _position.inMilliseconds,
      chapterDurationMs: _duration.inMilliseconds,
    );
  }

  void _onPosition(Duration p) {
    _position = p;
    // 进度每 500ms 来一次，但界面按秒刷就够——
    // 首页也挂在这个 notifier 上，刷太勤会让老机器掉帧
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_state == TingState.playing && now - _lastPosNotify > 900) {
      _lastPosNotify = now;
      notifyListeners();
    }
    // 进度这条走节流：系统会用 updatePosition + updateTime 自己插值，
    // 不需要每秒推十几次
    _pushState();
  }

  int _lastPosNotify = 0;

  Future<void> _onCompleted() async {
    if (_advancing) return;
    final b = book;
    if (b == null) return;
    _advancing = true;
    try {
      _position = _duration;
      await _lib.markFinished(b.source, b.id, _index);
      await _cache.markFinished(b.source, b.id, b.chapters[_index].key);
      if (hasNext) {
        _index++;
        await _playCurrent();
      } else {
        _state = TingState.finished;
        _saveTicker?.cancel();
        notifyListeners();
        _pushState(force: true);
      }
    } finally {
      _advancing = false;
    }
  }

  /// 封面地址归一化：B 站返回的是 `//i0.hdslb.com/...`，没有协议头，
  /// 直接丢给系统会被当成相对路径而加载失败。
  /// 统一升到 https——Android 9+ 默认禁止明文加载图片。
  Uri? _coverUri(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    var u = s;
    if (u.startsWith('//')) {
      u = 'https:$u';
    } else if (u.startsWith('http://')) {
      u = 'https://${u.substring(7)}';
    }
    if (!u.startsWith('https://') && !u.startsWith('file://')) return null;
    return Uri.tryParse(u);
  }

  /// 上一次真正推给系统的时间戳 / 回目，用来节流
  int _lastPushAt = 0;
  String? _lastMediaItemId;
  int _lastMediaItemDurationMs = -1;

  /// 把状态同步到通知栏 / 锁屏
  ///
  /// [force] = true 用于播放/暂停/切回这些必须立刻反馈的动作；
  /// 播放进度那种高频调用一律走节流，否则通知每秒重建十几次，
  /// 系统媒体控件会不停闪、按钮点了没反应，低端机还会 ANR。
  void _pushState({bool force = false}) {
    final h = _handler;
    if (h == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastPushAt < 800) return;
    _lastPushAt = now;

    final ch = chapter;
    final b = book;
    if (ch == null || b == null) {
      h.playbackState.add(PlaybackState(
        controls: const [MediaControl.play],
        processingState: AudioProcessingState.idle,
        playing: false,
      ));
      return;
    }

    // 回目只在真的换了的时候才推：MediaItem 一变，audio_service 就要
    // 重新下载封面、重建通知，比推播放状态贵得多。
    //
    // 但 force（播放/暂停/切回）时必须重发：有些机型在服务重建后
    // 会把媒体元数据清空，只有重新 setMediaItem 才会恢复——
    // 不重发就会出现"通知栏只剩按钮、没有书名"。
    final itemId = '${b.source.id}:${b.id}:${ch.key}';
    final durMs = _duration.inMilliseconds;
    if (force || itemId != _lastMediaItemId || durMs != _lastMediaItemDurationMs) {
      _lastMediaItemId = itemId;
      _lastMediaItemDurationMs = durMs;
      h.mediaItem.add(MediaItem(
        id: itemId,
        // 通知栏和锁屏的折叠视图里只有 title 和 artist 两行可见，
        // 老人最想先看到"是哪本书"，所以书名放第一行、回目放第二行。
        // （反过来放的话，锁屏上只能看到"第 2 回"和一个 UP 主名，认不出书）
        title: b.title,
        artist: ch.numbered,
        album: b.author.isEmpty ? '听评书' : b.author,
        duration: durMs == 0 ? null : _duration,
        // 封面：老人一眼看出在听哪本。
        // B 站图床对没有 Referer 的请求返回 403，通知栏就会是一块空白，
        // 所以这里必须带上来源头。
        artUri: _coverUri(b.cover),
        artHeaders: b.source == TingSource.bili
            ? const {'Referer': 'https://www.bilibili.com/'}
            : null,
      ));
    }

    final playPause = isPlaying ? MediaControl.pause : MediaControl.play;
    final controls = <MediaControl>[
      if (hasPrev) MediaControl.skipToPrevious,
      MediaControl.rewind,
      playPause,
      MediaControl.fastForward,
      if (hasNext) MediaControl.skipToNext,
    ];

    // 折叠视图（Android 12 及以下的紧凑通知）只放三个键：快退 / 播放暂停 / 快进。
    // 索引必须从上面这份 controls 现算——原来写死 [0, 2, 4]，在第一回
    // （没有"上一回"）或最后一回（没有"下一回"）时只有 3~4 个元素，
    // 索引 4 越界，Android 12 及以下构建通知会抛 IndexOutOfBoundsException，
    // 直接闪退。这里顺带过滤掉不存在的键，保证永远不越界。
    final compact = compactActionIndices(controls, playPause);

    h.playbackState.add(PlaybackState(
      controls: controls,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
      },
      androidCompactActionIndices: compact,
      processingState: switch (_state) {
        TingState.preparing => AudioProcessingState.loading,
        TingState.idle => AudioProcessingState.idle,
        TingState.finished => AudioProcessingState.completed,
        _ => AudioProcessingState.ready,
      },
      playing: isPlaying,
      updatePosition: _position,
      bufferedPosition: _position,
      speed: _speed,
    ));
  }
}

/// 供 UI 用的语速档位（老人默认 1.0，慢一点更清楚）
const kSpeedOptions = <double>[0.75, 1.0, 1.25, 1.5];

/// 计算通知折叠视图（Android 12 及以下的紧凑样式）要放哪三个键。
///
/// **每个返回值都必须小于 [controls].length**：越界会让
/// `NotificationCompat.MediaStyle.setShowActionsInCompactView` 在构建通知时
/// 抛 IndexOutOfBoundsException，整台手机上的 App 直接闪退。
/// 这不是理论风险——第一回没有"上一回"、最后一回没有"下一回"时，
/// controls 只有 3~4 项，写死索引 4 必然踩中。
///
/// 单独抽成顶层函数是为了能在 test/ 里锁死这个约束。
List<int> compactActionIndices(List<MediaControl> controls, MediaControl playPause) {
  final out = <int>[
    controls.indexOf(MediaControl.rewind),
    controls.indexOf(playPause),
    controls.indexOf(MediaControl.fastForward),
  ].where((i) => i >= 0 && i < controls.length).toList();
  // 保险：最多三项（audio_service 的断言也要求 <=3）
  return out.length > 3 ? out.sublist(0, 3) : out;
}

/// 播放页配色沿用主题
const kPlayerAccent = TingColors.primary;

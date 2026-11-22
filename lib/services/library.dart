import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ting.dart';
import 'app_wipe.dart';
import 'title_key.dart';

/// 书架上的一本书 + 听到哪儿了。
class ShelfItem {
  TingBook book;

  /// 听到第几回（0 起）
  int chapterIndex;

  /// 这一回听到了第几毫秒
  int positionMs;

  /// 这一回的总时长（毫秒），用于算百分比
  int chapterDurationMs;

  int updatedAt;

  /// 已经听完的回（index），用于回目列表打勾
  Set<int> finished;

  ShelfItem({
    required this.book,
    this.chapterIndex = 0,
    this.positionMs = 0,
    this.chapterDurationMs = 0,
    int? updatedAt,
    Set<int>? finished,
  })  : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        finished = finished ?? <int>{};

  TingChapter? get chapter =>
      chapterIndex >= 0 && chapterIndex < book.chapters.length ? book.chapters[chapterIndex] : null;

  /// 整本听完的比例
  double get bookProgress {
    if (book.chapters.isEmpty) return 0;
    final done = finished.length;
    final inChapter = chapterDurationMs > 0 ? (positionMs / chapterDurationMs).clamp(0.0, 1.0) : 0.0;
    return ((done + inChapter) / book.chapters.length).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'book': book.toJson(),
        'chapterIndex': chapterIndex,
        'positionMs': positionMs,
        'chapterDurationMs': chapterDurationMs,
        'updatedAt': updatedAt,
        'finished': finished.toList(),
      };

  factory ShelfItem.fromJson(Map<String, dynamic> m) => ShelfItem(
        book: TingBook.fromJson((m['book'] as Map).cast<String, dynamic>()),
        chapterIndex: (m['chapterIndex'] as num?)?.toInt() ?? 0,
        positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
        chapterDurationMs: (m['chapterDurationMs'] as num?)?.toInt() ?? 0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        finished: ((m['finished'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toSet(),
      );
}

/// 书架 + 设置 + 播放进度，统一存本地。
///
/// 全部是同步内存读写 + 异步落盘，界面读取不用 await，老人点开就是内容。
class Library extends ChangeNotifier {
  Library._();
  static final Library instance = Library._();

  static const _kShelf = 'ts_shelf';
  static const _kSource = 'ts_source';
  static const _kQuarkRoot = 'ts_quark_root';
  static const _kQuarkRootName = 'ts_quark_root_name';
  static const _kSleepMinutes = 'ts_sleep_minutes';
  static const _kWifiOnly = 'ts_wifi_only';
  static const _kSetupDone = 'ts_setup_done';
  static const _kHeard = 'ts_heard';
  static const _kRestoreDeclined = 'ts_restore_declined';

  final List<ShelfItem> _shelf = [];
  List<ShelfItem> get shelf => List.unmodifiable(_shelf);

  TingSource _source = TingSource.quark;
  TingSource get source => _source;

  /// 夸克网盘里"评书"所在的文件夹
  String _quarkRoot = '0';
  String _quarkRootName = '全部文件';
  String get quarkRoot => _quarkRoot;
  String get quarkRootName => _quarkRootName;
  bool get quarkConfigured => _quarkRoot != '0';

  int _sleepMinutes = 0;
  int get sleepMinutes => _sleepMinutes;

  bool _wifiOnly = true;
  bool get wifiOnly => _wifiOnly;

  /// 首次配置向导是否走完。
  ///
  /// 这个标记的意义：家人只在装机时配一次，之后老人独立使用。
  /// 没走完就每次启动都进向导，逼着把权限配齐，别让老人后来自己面对系统设置页。
  bool _setupDone = false;
  bool get setupDone => _setupDone;

  SharedPreferences? _sp;
  bool _ready = false;
  bool get ready => _ready;

  /// 打开应用时磁盘上**本来就有**书架/配置。
  ///
  /// 用来区分"真的是第一次装"和"数据被清空了"：
  /// 只有前者才允许从公共备份恢复，否则用户手动清空书架后，
  /// 下次启动会把旧书架又变回来。
  bool _hadStoredState = false;
  bool get hadStoredState => _hadStoredState;

  /// 本地写入完成后的回调（备份服务挂在这里）
  void Function()? onPersisted;

  /// 用户已经明确说过"不用恢复"。
  ///
  /// 没有这个标记的话，只要书架是空的，每次启动都会弹"要恢复吗"，
  /// 对已经决定不要那份备份的人是骚扰。
  bool _restoreDeclined = false;
  bool get restoreDeclined => _restoreDeclined;

  /// 听过的书名指纹（[TitleKey.of] 算出来的）。
  ///
  /// 为什么不直接用书架上的书判断"听过没有"：
  /// 老人听完一本可能会把它从书架删掉，删掉之后"推荐一本"又会推同一本。
  /// 所以这里单独记一份**只增不减**的清单，最多留 500 条（够听很多年了）。
  final Set<String> _heardKeys = <String>{};
  Set<String> get heardKeys => Set.unmodifiable(_heardKeys);

  /// 最近在听的一本（首页那个大按钮）
  ShelfItem? get current {
    if (_shelf.isEmpty) return null;
    return (_shelf.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))).first;
  }

  Future<void> load() async {
    if (_ready) return;
    try {
      _sp = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('[library] 打开本地存储失败：$e');
      _sp = null;
    }
    final sp = _sp;
    if (sp == null) {
      // 连存储都打不开：不能把用户锁在启动页。
      // 但 _sp 为 null 时 _save 不会写盘，所以不会拿空书架覆盖别人的数据。
      _ready = true;
      notifyListeners();
      return;
    }

    // 逐项读、逐项容错。
    //
    // 以前是一个 try 包住整个函数：任何一项类型不对（比如老版本把某个 key
    // 存成了别的类型）都会让 load 中途抛异常 → _ready 一直 false →
    // 界面判定"没配置过"弹首次向导 → 用户一按跳过，空书架就被写回磁盘。
    // 用户看到的就是"更新完版本变成全新安装"。所以这里每一项都要兜住。
    try {
      _hadStoredState =
          sp.containsKey(_kSetupDone) || sp.containsKey(_kShelf);

      final raw = _readString(sp, _kShelf);
      if (raw != null && raw.isNotEmpty) {
        final parsed = <ShelfItem>[];
        try {
          for (final e in jsonDecode(raw) as List) {
            parsed.add(ShelfItem.fromJson((e as Map).cast<String, dynamic>()));
          }
          _shelf.addAll(parsed);
        } catch (e) {
          // 书架 JSON 坏了：把原文另存一份再去用空的，
          // 至少还有机会人工/从备份捞回来，也不会卡住后面的读取。
          debugPrint('[library] 书架数据损坏，已另存 ts_shelf_broken：$e');
          try {
            await sp.setString('ts_shelf_broken', raw);
          } catch (_) {}
        }
      }

      _source = TingSourceLabel.parse(_readString(sp, _kSource));
      _quarkRoot = _readString(sp, _kQuarkRoot) ?? '0';
      _quarkRootName = _readString(sp, _kQuarkRootName) ?? '全部文件';
      _sleepMinutes = _readInt(sp, _kSleepMinutes);
      _wifiOnly = _readBool(sp, _kWifiOnly, true);
      _setupDone = _readBool(sp, _kSetupDone, false);
      _heardKeys.addAll(_readStringList(sp, _kHeard));
      _restoreDeclined = _readBool(sp, _kRestoreDeclined, false);
    } catch (e) {
      debugPrint('[library] 读本地数据失败：$e');
    }

    _ready = true;
    notifyListeners();
  }

  static String? _readString(SharedPreferences sp, String key) {
    try {
      return sp.getString(key);
    } catch (_) {
      return null;
    }
  }

  static int _readInt(SharedPreferences sp, String key) {
    try {
      return sp.getInt(key) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static bool _readBool(SharedPreferences sp, String key, bool def) {
    try {
      return sp.getBool(key) ?? def;
    } catch (_) {
      return def;
    }
  }

  static List<String> _readStringList(SharedPreferences sp, String key) {
    try {
      return sp.getStringList(key) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// 首页"要不要从备份恢复"点了"不用了"
  Future<void> declineRestore() async {
    _restoreDeclined = true;
    await _sp?.setBool(_kRestoreDeclined, true);
  }

  Future<void> setSource(TingSource s) async {
    _source = s;
    await _sp?.setString(_kSource, s.id);
    onPersisted?.call();
    notifyListeners();
  }

  Future<void> setQuarkRoot(String fid, String name) async {
    _quarkRoot = fid;
    _quarkRootName = name;
    await _sp?.setString(_kQuarkRoot, fid);
    await _sp?.setString(_kQuarkRootName, name);
    onPersisted?.call();
    notifyListeners();
  }

  Future<void> setSleepMinutes(int m) async {
    _sleepMinutes = m;
    await _sp?.setInt(_kSleepMinutes, m);
    onPersisted?.call();
    notifyListeners();
  }

  Future<void> setWifiOnly(bool v) async {
    _wifiOnly = v;
    await _sp?.setBool(_kWifiOnly, v);
    onPersisted?.call();
    notifyListeners();
  }

  /// 首次配置向导走完（或家属主动跳过）。之后不再自动弹。
  Future<void> markSetupDone() async {
    _setupDone = true;
    await _sp?.setBool(_kSetupDone, true);
    onPersisted?.call();
    notifyListeners();
  }

  /// 设置页里"重新做一遍配置向导"用
  Future<void> resetSetup() async {
    _setupDone = false;
    await _sp?.setBool(_kSetupDone, false);
    notifyListeners();
  }

  /// 清除全部数据后把内存状态归零。
  ///
  /// 磁盘上的文件已经删了，但单例还活着、SharedPreferences 实例里也还留着
  /// 旧 map。不重置的话，下一次写入会把旧数据整份序列化回去，
  /// 表现就是"清完书架又长回来了、向导又变成已完成"。
  /// 导出可备份的状态。
  ///
  /// **故意不含夸克 Cookie**：备份写在公共下载目录，任何能翻文件的人都能看到，
  /// 账号凭证不能落到那儿。恢复后重新登录一次即可。
  Map<String, dynamic> exportState() => {
        'shelf': _shelf.map((e) => e.toJson()).toList(),
        'heard': _heardKeys.toList(),
        'setupDone': _setupDone,
        'source': _source.id,
        'quarkRoot': _quarkRoot,
        'quarkRootName': _quarkRootName,
        'sleepMinutes': _sleepMinutes,
        'wifiOnly': _wifiOnly,
      };

  /// 用备份覆盖本地状态（备份恢复、换手机时用）。
  ///
  /// 逐条容错：备份里某一条坏了只跳过那一条，不让整次恢复失败。
  Future<void> applyState(Map<String, dynamic> m) async {
    _sp ??= await SharedPreferences.getInstance();
    final sp = _sp!;

    _shelf.clear();
    for (final e in (m['shelf'] as List?) ?? const []) {
      try {
        _shelf.add(ShelfItem.fromJson((e as Map).cast<String, dynamic>()));
      } catch (_) {}
    }
    _heardKeys
      ..clear()
      ..addAll(((m['heard'] as List?) ?? const []).whereType<String>());

    _setupDone = m['setupDone'] == true;
    _source = TingSourceLabel.parse(m['source'] as String?);
    _quarkRoot = (m['quarkRoot'] as String?) ?? '0';
    _quarkRootName = (m['quarkRootName'] as String?) ?? '全部文件';
    _sleepMinutes = (m['sleepMinutes'] as num?)?.toInt() ?? 0;
    _wifiOnly = m['wifiOnly'] != false;

    await sp.setString(_kShelf, jsonEncode(_shelf.map((e) => e.toJson()).toList()));
    await sp.setStringList(_kHeard, _heardKeys.toList());
    await sp.setBool(_kSetupDone, _setupDone);
    await sp.setString(_kSource, _source.id);
    await sp.setString(_kQuarkRoot, _quarkRoot);
    await sp.setString(_kQuarkRootName, _quarkRootName);
    await sp.setInt(_kSleepMinutes, _sleepMinutes);
    await sp.setBool(_kWifiOnly, _wifiOnly);

    _restoreDeclined = false;
    try {
      await sp.remove(_kRestoreDeclined);
    } catch (_) {}

    _ready = true;
    _hadStoredState = true;
    notifyListeners();
  }

  void resetForWipe() {
    _shelf.clear();
    _heardKeys.clear();
    _source = TingSource.quark;
    _quarkRoot = '0';
    _quarkRootName = '全部文件';
    _sleepMinutes = 0;
    _wifiOnly = true;
    _setupDone = false;
    _sp = null;
    _ready = false;
    notifyListeners();
  }

  ShelfItem? find(TingSource source, String bookId) {
    for (final s in _shelf) {
      if (s.book.id == bookId && s.book.source == source) return s;
    }
    return null;
  }

  /// 加入书架（已在则更新书信息，保留进度）
  Future<ShelfItem> put(TingBook book) async {
    final exist = find(book.source, book.id);
    if (exist != null) {
      // 章节列表可能变了（网盘加了新回），但不要覆盖已听进度
      if (book.chapters.isNotEmpty) exist.book = book;
      await _save();
      notifyListeners();
      return exist;
    }
    final item = ShelfItem(book: book);
    _shelf.add(item);
    if (_restoreDeclined) {
      _restoreDeclined = false;
      await _sp?.remove(_kRestoreDeclined);
    }
    await _save();
    notifyListeners();
    return item;
  }

  Future<void> remove(TingSource source, String bookId) async {
    _shelf.removeWhere((s) => s.book.id == bookId && s.book.source == source);
    await _save();
    notifyListeners();
  }

  /// 记录进度（播放中每几秒调一次，退出前也会调）
  Future<void> saveProgress(
    TingSource source,
    String bookId, {
    int? chapterIndex,
    int? positionMs,
    int? chapterDurationMs,
  }) async {
    final item = find(source, bookId);
    if (item == null) return;
    if (chapterIndex != null) item.chapterIndex = chapterIndex;
    if (positionMs != null) item.positionMs = positionMs;
    if (chapterDurationMs != null) item.chapterDurationMs = chapterDurationMs;
    item.updatedAt = DateTime.now().millisecondsSinceEpoch;
    // 听过 3 秒就算"听过"，记进指纹库。
    // "推荐一本"要靠它避开重复书目，删了书架也不该再推。
    if (item.positionMs > 3000) await noteHeard(item.book.title);
    await _save();
  }

  /// 记一条"听过"的书名指纹。已经记过就不重复落盘。
  Future<void> noteHeard(String title) async {
    final key = TitleKey.of(title);
    if (key.isEmpty) return;
    if (!_heardKeys.add(key)) return;
    if (_heardKeys.length > 500) {
      // 留最新的（Set 是插入序），老的丢掉
      final keep = _heardKeys.toList().sublist(_heardKeys.length - 400);
      _heardKeys
        ..clear()
        ..addAll(keep);
    }
    await _sp?.setStringList(_kHeard, _heardKeys.toList());
  }

  /// 一回听完
  Future<void> markFinished(TingSource source, String bookId, int index) async {
    final item = find(source, bookId);
    if (item == null) return;
    item.finished.add(index);
    item.positionMs = 0;
    item.chapterDurationMs = 0;
    item.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await noteHeard(item.book.title);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    // 清除全部数据的过程中一律不写盘：
    // SharedPreferences 每次写入都会把内存里的整份数据序列化回去，
    // 这一写就会把刚删掉的"已完成配置""书架"重新变出来。
    if (AppWipe.wiping) return;
    // 本地数据还没读完就说"存"？这时候内存里是空书架，
    // 写下去等于把用户的真数据覆盖成空。等读完再存。
    if (!_ready) return;
    final raw = jsonEncode(_shelf.map((e) => e.toJson()).toList());
    await _sp?.setString(_kShelf, raw);
    onPersisted?.call();
  }
}

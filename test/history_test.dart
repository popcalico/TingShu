import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tingshu/models/ting.dart';
import 'package:tingshu/services/history.dart';

TingBook book(String id, String title, {int chapters = 3}) => TingBook(
      id: id,
      source: TingSource.quark,
      title: title,
      author: '单田芳',
      chapters: [
        for (var i = 0; i < chapters; i++)
          TingChapter(index: i, title: '第 ${i + 1} 回', key: 'k$i'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlayHistory.instance.resetForWipe();
    await PlayHistory.instance.load();
  });

  group('播放历史', () {
    test('同一本书听下一回，只留一条并更新到最新回', () async {
      final b = book('/a', '水浒传');
      await PlayHistory.instance.record(b, 0, chapterTitle: '第 1 回');
      await PlayHistory.instance.record(b, 1, chapterTitle: '第 2 回');

      final list = PlayHistory.instance.entries;
      expect(list.length, 1, reason: '一本书一行，不能按回目刷屏');
      expect(list.first.chapterIndex, 1);
      expect(list.first.chapterTitle, '第 2 回');
    });

    test('第二本书排到最前面', () async {
      await PlayHistory.instance.record(book('/a', '水浒传'), 0);
      await PlayHistory.instance.record(book('/b', '三国演义'), 2);

      final list = PlayHistory.instance.entries;
      expect(list.length, 2);
      expect(list.first.title, '三国演义');
      expect(list.last.title, '水浒传');
    });

    test('同名不同来源不会互相覆盖', () async {
      final quark = book('/x', '水浒传');
      final bili = TingBook(
        id: 'BV1xx',
        source: TingSource.bili,
        title: '水浒传',
        chapters: const [TingChapter(index: 0, title: '第 1 回', key: 'c1')],
      );
      await PlayHistory.instance.record(quark, 0);
      await PlayHistory.instance.record(bili, 0);

      expect(PlayHistory.instance.entries.length, 2);
    });

    test('超过上限时丢掉最老的', () async {
      for (var i = 0; i < 70; i++) {
        await PlayHistory.instance.record(book('/b$i', '书$i'), 0);
      }
      final list = PlayHistory.instance.entries;
      expect(list.length, 60);
      expect(list.first.title, '书69');
      expect(list.any((e) => e.title == '书0'), isFalse);
    });

    test('落盘后重新加载还在（重启不丢）', () async {
      await PlayHistory.instance.record(book('/a', '水浒传'), 2, chapterTitle: '第 3 回');

      PlayHistory.instance.resetForWipe();
      await PlayHistory.instance.load();

      final list = PlayHistory.instance.entries;
      expect(list.length, 1);
      expect(list.first.title, '水浒传');
      expect(list.first.chapterIndex, 2);
      expect(list.first.source, TingSource.quark);
    });

    test('清空后列表为空且重启不复活', () async {
      await PlayHistory.instance.record(book('/a', '水浒传'), 0);
      await PlayHistory.instance.clear();

      PlayHistory.instance.resetForWipe();
      await PlayHistory.instance.load();
      expect(PlayHistory.instance.entries, isEmpty);
    });

    test('备份导出/恢复：换手机后历史跟着回来', () async {
      await PlayHistory.instance.record(book('/a', '水浒传'), 1, chapterTitle: '第 2 回');
      await PlayHistory.instance.record(book('/b', '三国演义'), 0);
      final snapshot = PlayHistory.instance.exportState();

      await PlayHistory.instance.clear();
      expect(PlayHistory.instance.entries, isEmpty);

      await PlayHistory.instance.applyState(snapshot);
      final list = PlayHistory.instance.entries;
      expect(list.length, 2);
      expect(list.first.title, '三国演义');
      expect(list.last.chapterIndex, 1);
    });

    test('老版本备份里字段缺失也不崩', () async {
      await PlayHistory.instance.applyState([
        {'title': '只剩书名'},
        {'src': 'nas', 'bookId': '/n', 'title': 'NAS 书', 'at': 1},
      ]);
      final list = PlayHistory.instance.entries;
      expect(list.length, 2);
      expect(list.last.source, TingSource.nas);
      expect(list.first.chapterIndex, 0);
    });

    test('回目拆成"第几回"和"故事名"，长标题不会把时间挤掉', () {
      const e = HistoryEntry(
        bookId: '/a',
        source: TingSource.bili,
        title: '三国演义',
        chapterIndex: 1,
        chapterTitle: '第 2 回　竖窑作乱董卓进京',
        at: 1,
      );
      expect(e.chapterLabel, '第 2 回');
      expect(e.chapterName, '竖窑作乱董卓进京');

      const plain = HistoryEntry(
        bookId: '/b',
        source: TingSource.nas,
        title: '水浒传',
        chapterIndex: 2,
        chapterTitle: '武松打虎',
        at: 1,
      );
      expect(plain.chapterLabel, '第 3 回', reason: '标题没有序号就用真实回目号');
      expect(plain.chapterName, '武松打虎');

      const empty = HistoryEntry(
        bookId: '/c',
        source: TingSource.quark,
        title: '白眉大侠',
        chapterIndex: 0,
        at: 1,
      );
      expect(empty.chapterLabel, '第 1 回');
      expect(empty.chapterName, '');
    });

    test('封面/作者存下来，书被删出书架也能显示', () async {
      final b = TingBook(
        id: '/c',
        source: TingSource.nas,
        title: '白眉大侠',
        author: '单田芳',
        cover: 'http://example.com/c.jpg',
        chapters: const [TingChapter(index: 0, title: '第 1 回', key: 'a')],
      );
      await PlayHistory.instance.record(b, 0);

      final e = PlayHistory.instance.entries.first;
      expect(e.author, '单田芳');
      expect(e.cover, 'http://example.com/c.jpg');
      expect(e.asBook.title, '白眉大侠');
    });
  });
}

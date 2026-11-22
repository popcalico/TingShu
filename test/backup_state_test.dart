import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tingshu/models/ting.dart';
import 'package:tingshu/services/library.dart';

TingBook demoBook() => TingBook(
      id: '/单田芳/水浒传',
      source: TingSource.quark,
      title: '水浒传',
      author: '单田芳',
      chapters: const [
        TingChapter(index: 0, title: '武松打虎', key: 'f1', sizeBytes: 100),
        TingChapter(index: 1, title: '潘金莲', key: 'f2', sizeBytes: 100),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Library.instance.resetForWipe();
    await Library.instance.load();
  });

  group('备份额度：书架状态导出 / 恢复', () {
    test('重装后从备份恢复：书架、进度、配置都回来', () async {
      await Library.instance.put(demoBook());
      await Library.instance.saveProgress(
        TingSource.quark,
        '/单田芳/水浒传',
        chapterIndex: 1,
        positionMs: 42000,
      );
      await Library.instance.markSetupDone();
      await Library.instance.setQuarkRoot('fid-root', '评书');

      final snapshot = Library.instance.exportState();

      // 模拟"数据被清空了"
      Library.instance.resetForWipe();
      expect(Library.instance.shelf, isEmpty);
      expect(Library.instance.setupDone, isFalse);

      await Library.instance.applyState(snapshot);

      expect(Library.instance.setupDone, isTrue);
      expect(Library.instance.shelf.length, 1);
      expect(Library.instance.quarkRoot, 'fid-root');
      expect(Library.instance.quarkRootName, '评书');
      final item = Library.instance.shelf.first;
      expect(item.book.title, '水浒传');
      expect(item.book.chapters.length, 2);
      expect(item.chapterIndex, 1);
      expect(item.positionMs, 42000);
    });

    test('备份里坏了一条只跳过那一条，其余照常恢复', () async {
      await Library.instance.put(demoBook());
      final snapshot = Library.instance.exportState();
      snapshot['shelf'] = [
        {'bad': 'shape'},
        ...(snapshot['shelf'] as List),
      ];
      await Library.instance.applyState(snapshot);
      expect(Library.instance.shelf.length, 1);
      expect(Library.instance.shelf.first.book.title, '水浒传');
    });

    test('exportState 里不含夸克 Cookie（备份在公共目录，不能放账号凭证）', () async {
      final snapshot = Library.instance.exportState();
      expect(snapshot.keys, isNot(contains('cookie')));
      expect(snapshot.toString().contains('quarkCookie'), isFalse);
    });
  });
}

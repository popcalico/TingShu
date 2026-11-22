import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu/models/ting.dart';
import 'package:tingshu/services/library.dart';
import 'package:tingshu/services/local_search.dart';

ShelfItem item(String title, {String author = '', List<String> chapters = const []}) {
  return ShelfItem(
    book: TingBook(
      id: title,
      source: TingSource.bili,
      title: title,
      author: author,
      chapters: [
        for (var i = 0; i < chapters.length; i++)
          TingChapter(index: i, title: chapters[i], key: 'k$i'),
      ],
    ),
  );
}

void main() {
  group('书架内搜索', () {
    final shelf = [
      item('水浒传', author: '单田芳', chapters: ['武松打虎', '潘金莲']),
      item('白眉大侠', author: '单田芳', chapters: ['徐良出世']),
      item('三国演义', author: '袁阔成'),
    ];

    test('按书名搜', () {
      final r = searchShelf(shelf, '水浒');
      expect(r.length, 1);
      expect(r.first.item.book.title, '水浒传');
      expect(r.first.chapter, isNull);
    });

    test('按演员搜：同一个人名下所有书都出来', () {
      final r = searchShelf(shelf, '单田芳');
      expect(r.map((e) => e.item.book.title).toList(), containsAll(['水浒传', '白眉大侠']));
      expect(r.length, 2);
    });

    test('按回目标题搜：老人记得"武松打虎"但想不起哪本书', () {
      final r = searchShelf(shelf, '武松');
      expect(r.length, 1);
      expect(r.first.item.book.title, '水浒传');
      expect(r.first.chapter?.title, '武松打虎');
    });

    test('整本命中排在回目命中前面', () {
      final s = [
        item('武松外传', chapters: ['第一回']),
        item('水浒传', chapters: ['武松打虎']),
      ];
      final r = searchShelf(s, '武松');
      expect(r.length, 2);
      expect(r.first.item.book.title, '武松外传', reason: '书名直接命中的应该排第一');
      expect(r.last.chapter?.title, '武松打虎');
    });

    test('大小写不敏感', () {
      final s = [item('MP3 合集')];
      expect(searchShelf(s, 'mp3').length, 1);
    });

    test('空关键词不返回任何东西（避免一进搜索页就刷满屏）', () {
      expect(searchShelf(shelf, '   '), isEmpty);
    });

    test('搜不到就是空，不要瞎凑', () {
      expect(searchShelf(shelf, '郭德纲'), isEmpty);
    });

    test('一本书只算一条（多个回目命中不重复列）', () {
      final s = [item('水浒传', chapters: ['武松打虎', '武松醉打蒋门神'])];
      final r = searchShelf(s, '武松');
      expect(r.length, 1);
    });
  });
}

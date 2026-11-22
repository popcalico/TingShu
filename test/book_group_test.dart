import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu/models/ting.dart';
import 'package:tingshu/services/book_group.dart';

TingBook book(String id, String title, {String author = '', int chapters = 10}) {
  return TingBook(
    id: id,
    source: TingSource.quark,
    title: title,
    author: author,
    chapters: List.generate(
      chapters,
      (i) => TingChapter(index: i, title: '第 ${i + 1} 回', key: '$id#$i', sizeBytes: 100),
    ),
  );
}

void main() {
  group('按网盘文件夹分组', () {
    test('作者目录下的书归到作者名下', () {
      final groups = groupBooks([
        book('/单田芳/水浒传/上部', '水浒传', author: '单田芳'),
        book('/单田芳/三国演义', '三国演义', author: '单田芳'),
        book('/刘兰芳/岳飞传', '岳飞传', author: '刘兰芳'),
      ]);
      expect(groups.length, 2);
      // 组之间按名字排序（中文按码位，不强求拼音序），这里只校验归属
      final dan = groups.firstWhere((g) => g.name == '单田芳');
      expect(dan.books.length, 2);
      expect(dan.chapterCount, 20);
      expect(groups.map((g) => g.name).toList(), containsAll(['单田芳', '刘兰芳']));
    });

    test('按分类摆的（武侠/历史）用分类当组名', () {
      final groups = groupBooks([
        book('/武侠/水浒传', '水浒传'),
        book('/武侠/三侠五义', '三侠五义'),
        book('/历史/三国演义', '三国演义'),
      ]);
      expect(groups.map((g) => g.name).toList(), ['历史', '武侠']);
    });

    test('书目录本身在根下（水浒传/上部）：不当成一组的名字', () {
      final groups = groupBooks([
        book('/水浒传/上部', '水浒传'),
      ]);
      expect(groups.single.name, kUngroupedName);
    });

    test('多部分卷合并且 id 取第一卷时，仍然归到作者组', () {
      final groups = groupBooks([
        book('/单田芳/水浒传/上部', '水浒传', author: '单田芳'),
      ]);
      expect(groups.single.name, '单田芳');
    });

    test('「未分组」排最后，不会挤在中间', () {
      final groups = groupBooks([
        book('/', '直接摆在根目录的书'),
        book('/单田芳/白眉大侠', '白眉大侠', author: '单田芳'),
      ]);
      expect(groups.last.name, kUngroupedName);
    });

    test('空列表不崩', () {
      expect(groupBooks(const []), isEmpty);
    });
  });
}

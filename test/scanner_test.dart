import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu/services/nas/scanner.dart';
import 'package:tingshu/services/nas/webdav_client.dart';

/// 造目录树的小工具
List<DavEntry> tree(List<String> files, {int size = 30 * 1024 * 1024}) {
  return files
      .map((p) => DavEntry(path: p, name: p.split('/').last, isDir: false, size: size))
      .toList();
}

void main() {
  group('一本书的边界', () {
    test('标准结构：作者目录下每本书一个文件夹', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/水浒传/001.mp3',
        '/评书/单田芳/水浒传/002.mp3',
        '/评书/单田芳/三国演义/001.mp3',
      ]));

      expect(books.length, 2);
      final sh = books.firstWhere((b) => b.title.contains('水浒'));
      expect(sh.author, '单田芳');
      expect(sh.chapters.length, 2);
    });

    test('作者目录本身不含音频，不会被误当成书', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/水浒传/001.mp3',
      ]));
      // 只有一本，不是两本（不能把「单田芳」也算成书）
      expect(books.length, 1);
      expect(books.first.title.contains('单田芳'), isFalse);
    });

    test('作者和书名挤在一个目录名里', () {
      final books = NasScanner.scan(tree([
        '/评书/刘兰芳 岳飞传/01 岳飞出世.mp3',
        '/评书/刘兰芳 岳飞传/02 枪挑小梁王.mp3',
      ]));
      expect(books.length, 1);
      expect(books.first.author, '刘兰芳');
      expect(books.first.title, '岳飞传');
      expect(books.first.chapters.first.title, '岳飞出世');
    });
  });

  group('书名清洗', () {
    test('B站式超长标题取书名号里的那段', () {
      final books = NasScanner.scan(tree([
        '/单田芳 | 长篇评书 | 全本 【水浒传】 | 64小时助眠/001.mp3',
      ]));
      expect(books.first.title, '水浒传');
      expect(books.first.author, '单田芳');
    });

    test('去掉容量标注和噪音词', () {
      final books = NasScanner.scan(tree([
        '/评书/白眉大侠（320回）全/001.mp3',
      ]));
      expect(books.first.title.contains('320'), isFalse);
      expect(books.first.title.startsWith('白眉大侠'), isTrue);
    });

    test('不能把书名里的字误删（全相三国志）', () {
      final books = NasScanner.scan(tree([
        '/评书/全相三国志/001.mp3',
      ]));
      expect(books.first.title, contains('三国'));
    });
  });

  group('章节号解析', () {
    test('纯数字文件名', () {
      final b = NasScanner.scan(tree(['/书/001.mp3', '/书/002.mp3'])).first;
      expect(b.chapters.map((c) => c.order).toList(), [1, 2]);
    });

    test('中文数字「第十二回」', () {
      final b = NasScanner.scan(tree(['/书/第十二回 武松打虎.mp3'])).first;
      expect(b.chapters.first.order, 12);
      expect(b.chapters.first.title, '武松打虎');
    });

    test('「第100回」这种三位数', () {
      final b = NasScanner.scan(tree(['/书/第100回 大结局.mp3'])).first;
      expect(b.chapters.first.order, 100);
    });

    test('序号前缀带分隔符', () {
      final b = NasScanner.scan(tree(['/书/012-武松打虎.mp3'])).first;
      expect(b.chapters.first.order, 12);
      expect(b.chapters.first.title, '武松打虎');
    });

    test('排序按数字不按字符串（10 不能排在 2 前面）', () {
      final b = NasScanner.scan(tree([
        '/书/10.mp3', '/书/2.mp3', '/书/1.mp3',
      ])).first;
      expect(b.chapters.map((c) => c.order).toList(), [1, 2, 10]);
    });

    test('没有序号时用文件顺序兜底，不会全部乱序', () {
      final b = NasScanner.scan(tree([
        '/书/开场.mp3', '/书/正文.mp3',
      ])).first;
      expect(b.chapters.length, 2);
      expect(b.chapters.every((c) => c.order > 0), isTrue);
    });
  });

  group('混乱结构', () {
    test('分卷目录合并成一本书', () {
      final books = NasScanner.scan(tree([
        '/水浒传 上部/001.mp3',
        '/水浒传 上部/002.mp3',
        '/水浒传 下部/161.mp3',
        '/水浒传 下部/162.mp3',
      ]));
      expect(books.length, 1);
      expect(books.first.chapters.length, 4);
    });

    test('所有音频平铺在根目录 → 当成一本未命名书', () {
      final books = NasScanner.scan(tree([
        '/001.mp3', '/002.mp3',
      ]));
      expect(books.length, 1);
      expect(books.first.chapters.length, 2);
    });

    test('非音频文件被忽略', () {
      final books = NasScanner.scan([
        const DavEntry(path: '/书/001.mp3', name: '001.mp3', isDir: false, size: 100),
        const DavEntry(path: '/书/封面.jpg', name: '封面.jpg', isDir: false, size: 100),
        const DavEntry(path: '/书/说明.txt', name: '说明.txt', isDir: false, size: 100),
      ]);
      expect(books.first.chapters.length, 1);
    });

    test('空输入不崩', () {
      expect(NasScanner.scan(const []), isEmpty);
    });
  });

  group('总量统计', () {
    test('totalBytes 是各回之和', () {
      final b = NasScanner.scan(tree(['/书/1.mp3', '/书/2.mp3'], size: 1000)).first;
      expect(b.totalBytes, 2000);
    });
  });

  group('网盘那种多层嵌套（夸克实测会遇到的真实结构）', () {
    test('作者/书名/分卷三层：合并成一本，回目不断号', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/水浒传/上部/001.mp3',
        '/评书/单田芳/水浒传/上部/002.mp3',
        '/评书/单田芳/水浒传/下部/181.mp3',
        '/评书/单田芳/水浒传/下部/182.mp3',
      ]));

      expect(books.length, 1, reason: '作者层和分卷层都不能各自算成一本书');
      expect(books.first.title, '水浒传');
      expect(books.first.author, '单田芳');
      expect(books.first.chapters.length, 4);
      // 排序后回目号仍按文件名里的真实序号，不是数组下标
      expect(books.first.chapters.map((c) => c.order).toList(), [1, 2, 181, 182]);
    });

    test('书名层下再套一层「音频」之类的杂物目录也能认', () {
      final books = NasScanner.scan(tree([
        '/评书/袁阔成/三国演义/音频/001.mp3',
        '/评书/袁阔成/三国演义/音频/002.mp3',
      ]));

      expect(books.length, 1);
      // 目录名是「音频」这种无意义词时，书名会退化成它——这是扫描器的已知取舍，
      // 确认页允许家属改名。这里只保证"不会一本书都认不出来"。
      expect(books.first.chapters.length, 2);
    });

    test('同一部书散在两个目录（全集 + 补充回）：合并成一本', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/白眉大侠/001.mp3',
        '/评书/单田芳/白眉大侠 下部/181.mp3',
      ]));

      expect(books.length, 1);
      expect(books.first.chapters.length, 2);
    });

    test('根目录直接摆音频（没有子文件夹）：整目录当一本', () {
      final books = NasScanner.scan(tree([
        '/评书/001.mp3',
        '/评书/002.mp3',
      ]));

      expect(books.length, 1);
      expect(books.first.chapters.length, 2);
    });
  });

  group('书被拆成一层层子文件夹（夸克最常见的"套集数"）', () {
    test('每集一个文件夹：并成一本，不按文件夹算书', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/水浒传/001/001.mp3',
        '/评书/单田芳/水浒传/002/002.mp3',
        '/评书/单田芳/水浒传/003/003.mp3',
      ]));
      expect(books.length, 1, reason: '三个数字目录不能被当成三本书');
      expect(books.first.title, '水浒传');
      expect(books.first.chapters.length, 3);
    });

    test('按回数区间分文件夹（001-050 / 051-100）', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/水浒传/001-050/001.mp3',
        '/评书/单田芳/水浒传/001-050/002.mp3',
        '/评书/单田芳/水浒传/051-100/051.mp3',
      ]));
      expect(books.length, 1);
      expect(books.first.chapters.length, 3);
      expect(books.first.chapters.map((c) => c.order).toList(), [1, 2, 51]);
    });

    test('按碟号分文件夹（CD1 / CD2），每张碟从头编号也不乱序', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/白眉大侠/CD1/001.mp3',
        '/评书/单田芳/白眉大侠/CD1/002.mp3',
        '/评书/单田芳/白眉大侠/CD2/001.mp3',
        '/评书/单田芳/白眉大侠/CD2/002.mp3',
      ]));
      expect(books.length, 1);
      expect(books.first.chapters.length, 4);
      // 先第一张碟的两回，再第二张碟的两回
      expect(
        books.first.chapters.map((c) => c.davPath).toList(),
        [
          '/评书/单田芳/白眉大侠/CD1/001.mp3',
          '/评书/单田芳/白眉大侠/CD1/002.mp3',
          '/评书/单田芳/白眉大侠/CD2/001.mp3',
          '/评书/单田芳/白眉大侠/CD2/002.mp3',
        ],
      );
    });

    test('「第N回」当文件夹名也能并回一本书', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/水浒传/第1回 武松打虎/audio.mp3',
        '/评书/单田芳/水浒传/第2回 潘金莲/audio.mp3',
      ]));
      expect(books.length, 1);
      expect(books.first.title, '水浒传');
      expect(books.first.chapters.length, 2);
    });

    test('编号当书名的目录（01 水浒传 / 02 三国）不能被并成一本', () {
      final books = NasScanner.scan(tree([
        '/评书/武侠/01 水浒传/001.mp3',
        '/评书/武侠/02 三国演义/001.mp3',
      ]));
      expect(books.length, 2);
      expect(books.map((b) => b.title).toList(), containsAll(['水浒传', '三国演义']));
    });

    test('用户选的根目录本身就是一本书（下面只剩集号目录）', () {
      final books = NasScanner.scan(
        tree(['/001/001.mp3', '/002/002.mp3']),
        rootName: '水浒传（320回）',
      );
      expect(books.length, 1);
      expect(books.first.title, '水浒传');
      expect(books.first.chapters.length, 2);
    });
  });

  group('真机 NAS 的真实摆法（作者_书名）', () {
    test('作者目录下多本「作者_书名」：各自成书，不能被并成一本', () {
      final books = NasScanner.scan(tree([
        '/book/袁阔成/袁阔成_三国演义/三国演义1.mp3',
        '/book/袁阔成/袁阔成_三国演义/三国演义2.mp3',
        '/book/袁阔成/袁阔成_三气周瑜/三气周瑜1.mp3',
        '/book/袁阔成/袁阔成_古城会/古城会1.mp3',
      ]), rootName: 'book');
      expect(books.length, 3, reason: '纯演员名目录是作者，不是"卷"，不能把整层并成一本');
      expect(
        books.map((b) => b.title).toList(),
        containsAll(['三国演义', '三气周瑜', '古城会']),
      );
      expect(books.every((b) => b.author == '袁阔成'), isTrue);
      expect(books.firstWhere((b) => b.title == '三国演义').chapters.length, 2);
    });

    test('根目录本身就是作者名（家属直接选了作者文件夹）', () {
      final books = NasScanner.scan(tree([
        '/袁阔成_三国演义/三国演义1.mp3',
        '/袁阔成_三气周瑜/三气周瑜1.mp3',
      ]), rootName: '袁阔成');
      expect(books.length, 2);
      expect(books.map((b) => b.title).toList(), containsAll(['三国演义', '三气周瑜']));
    });

    test('演员名下多本 + 每本再分上下部，仍按书拆开', () {
      final books = NasScanner.scan(tree([
        '/评书/单田芳/水浒传/上部/001.mp3',
        '/评书/单田芳/水浒传/下部/181.mp3',
        '/评书/单田芳/白眉大侠/上部/001.mp3',
      ]));
      expect(books.length, 2);
      expect(books.map((b) => b.title).toList(), containsAll(['水浒传', '白眉大侠']));
      expect(books.firstWhere((b) => b.title == '水浒传').chapters.length, 2);
    });
  });

  group('B 站分P名清洗', () {
    test('「001回-xxx」不再剩下「回-」', () {
      expect(NasScanner.chapterTitle('001回-鞭督邮刘备走代州'), '鞭督邮刘备走代州');
      expect(NasScanner.chapterTitle('012-三顾茅庐'), '三顾茅庐');
    });

    test('「第12回 武松打虎」剥掉序号只留标题', () {
      expect(NasScanner.chapterTitle('第12回 武松打虎'), '武松打虎');
    });

    test('只有序号时保留原文，别显示空白', () {
      expect(NasScanner.chapterTitle('第 1 回'), '第 1 回');
    });
  });
}

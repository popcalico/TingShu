import '../models/ting.dart';

/// 扫描结果里的一个"组"：网盘里同一个大文件夹下的若干部书。
///
/// 为什么要分组：家属的网盘通常按"演员"或"分类"摆，
/// 一次扫描可能认出一两百部书。平铺成一长列，根本找不到想加的那本，
/// 也没法"把这个人的都加上"。
class BookGroup {
  BookGroup({required this.name, required this.books});

  /// 组名：一般是根目录下的第一层文件夹名，取不到时用作者名
  final String name;

  final List<TingBook> books;

  int get chapterCount => books.fold(0, (s, b) => s + b.count);

  int get sizeBytes => books.fold(
        0,
        (s, b) => s + b.chapters.fold<int>(0, (x, c) => x + c.sizeBytes),
      );
}

/// 没归到任何文件夹的书放这里（直接摆在根目录的、单本成书的）
const kUngroupedName = '未分组';

/// 把扫描出来的书按"文件夹"分组（网盘和 NAS 共用）。
///
/// 纯函数，方便单测：书的 [TingBook.id] 是它所在目录的完整路径
/// （`/单田芳/水浒传/上部`），第一段就是家属自己分的那个大类。
List<BookGroup> groupBooks(List<TingBook> books) {
  final map = <String, List<TingBook>>{};
  for (final b in books) {
    map.putIfAbsent(_groupOf(b), () => []).add(b);
  }

  final groups = map.entries
      .map((e) => BookGroup(
            name: e.key,
            books: e.value..sort((a, b) => a.title.compareTo(b.title)),
          ))
      .toList();

  groups.sort((a, b) {
    // 「未分组」永远放最后，别把真正分好类的挤下去
    if (a.name == kUngroupedName) return 1;
    if (b.name == kUngroupedName) return -1;
    return a.name.compareTo(b.name);
  });
  return groups;
}

String _groupOf(TingBook b) {
  final segs = b.id.split('/').where((s) => s.trim().isNotEmpty).toList();
  if (segs.length >= 2) {
    final g = segs.first.trim();
    // `水浒传/上部` 这种：第一段就是书名本身，不是"组"
    if (_norm(g) != _norm(b.title)) return g;
  }
  if (b.author.isNotEmpty) return b.author;
  return kUngroupedName;
}

/// 只用来比较"是不是同一个名字"，去掉标点空格和大小写差异
String _norm(String s) => s
    .replaceAll(RegExp(r'''[\s《》【】\[\]（）()·\-—_、,，。.'"!！?？:：]'''), '')
    .toLowerCase();

import '../models/ting.dart';
import 'library.dart';

/// 本地搜索命中的一条。
///
/// [chapter] 为空表示整本书命中（书名/作者），
/// 不为空表示命中的是这一回的小标题（"武松打虎"这种）。
class LocalHit {
  LocalHit(this.item, [this.chapter]);

  final ShelfItem item;
  final TingChapter? chapter;
}

/// 在书架里搜。
///
/// 三处都搜：书名、作者、每一回的小标题。
/// 老人常记着"武松打虎"却想不起是哪本书，只搜书名会让他以为"没有"。
/// 先整本命中排前面，回目命中排后面。
List<LocalHit> searchShelf(List<ShelfItem> shelf, String keyword) {
  final q = keyword.trim().toLowerCase();
  if (q.isEmpty) return const [];

  final whole = <LocalHit>[];
  final byChapter = <LocalHit>[];

  for (final it in shelf) {
    final title = it.book.title.toLowerCase();
    final author = it.book.author.toLowerCase();
    if (title.contains(q) || author.contains(q)) {
      whole.add(LocalHit(it));
      continue;
    }
    for (final ch in it.book.chapters) {
      final t = '${ch.numbered} ${ch.title}'.toLowerCase();
      if (t.contains(q)) {
        byChapter.add(LocalHit(it, ch));
        break;
      }
    }
  }

  return [...whole, ...byChapter];
}

import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu/services/title_key.dart';

/// 书名指纹的回归测试。
///
/// 这块的错会直接表现为"刚听完的书又被推一遍"，而这种事只有老人用了几天
/// 才会发现。所以规则一改就必须跑这里的用例。
void main() {
  group('指纹：把装饰信息剥干净', () {
    test('演员名 + 回数 + 高清', () {
      expect(TitleKey.of('水浒传 单田芳 全360回'), '水浒传');
      expect(TitleKey.of('【评书】水浒传（单田芳）高清'), '水浒传');
      expect(TitleKey.of('水浒传 单田芳 高清 完整版'), '水浒传');
    });

    test('分卷后缀', () {
      expect(TitleKey.of('水浒传 上部'), '水浒传');
      expect(TitleKey.of('水浒传 下册'), '水浒传');
      expect(TitleKey.of('三国演义 第2部分'), '三国演义');
    });

    test('容量标注与括号内容', () {
      expect(TitleKey.of('三国演义（320回）'), '三国演义');
      expect(TitleKey.of('三国演义[全120集]'), '三国演义');
      expect(TitleKey.of('《白眉大侠》'), '白眉大侠');
    });

    test('回目号不参与书名比较', () {
      expect(TitleKey.of('第12回 武松打虎'), '武松打虎');
      expect(TitleKey.of('第 3 集 秦琼卖马'), '秦琼卖马');
    });

    test('扩展名要剥掉', () {
      expect(TitleKey.of('隋唐演义.mp3'), '隋唐演义');
      expect(TitleKey.of('隋唐演义.m4a'), '隋唐演义');
    });

    test('空标题返回空串，调用方应跳过', () {
      expect(TitleKey.of('   '), '');
      expect(TitleKey.of('（单田芳）'), '');
    });
  });

  group('去重：同一部书的不同版本必须认成一本', () {
    test('同书不同 UP 主 / 不同写法', () {
      expect(TitleKey.same('水浒传 单田芳', '【评书】水浒传(单田芳) 高清'), isTrue);
      expect(TitleKey.same('水浒传 全360回', '水浒传'), isTrue);
      expect(TitleKey.same('白眉大侠 上部', '白眉大侠 下部'), isTrue);
      expect(TitleKey.same('三国演义（320回）', '三国演义'), isTrue);
    });

    test('包含关系兜住一长一短', () {
      expect(TitleKey.same('三国', '三国演义'), isTrue);
      expect(TitleKey.same('水浒传', '水浒全传'), isTrue);
    });

    test('不同的书不能混为一谈', () {
      expect(TitleKey.same('水浒传', '三国演义'), isFalse);
      expect(TitleKey.same('白眉大侠', '三侠五义'), isFalse);
      expect(TitleKey.same('隋唐演义', '说唐'), isFalse);
    });

    test('anySame 用于一批已听书名', () {
      final heard = ['水浒传', '三国演义', '白眉大侠'];
      expect(TitleKey.anySame(heard, '【评书】水浒传 高清'), isTrue);
      expect(TitleKey.anySame(heard, '岳飞传'), isFalse);
    });
  });

  group('显示用书名（老人第一眼看到的那行字）', () {
    test('标题党要剥掉', () {
      expect(TitleKey.display('【听书-15岁】《评书 三国演义 365回全集》'), '三国演义');
      expect(TitleKey.display('《水浒传》单田芳 全360回 高清'), '水浒传');
    });

    test('剥空了退回原文，不能显示空白', () {
      expect(TitleKey.display('评书'), '评书');
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu/widgets/common.dart';

/// 设置行的布局回归。
///
/// 起因：真机上"评书文件夹"这一行，值是一个超长文件夹名
/// `(033)评书大全180G+10大名家+3714集`，把标题挤成**每行一个字**（竖着排），
/// 值本身还溢出到卡片外面。老人看到一列竖字会以为软件坏了。
void main() {
  testWidgets('超长值不会把标题压成竖排，也不溢出卡片', (tester) async {
    // 按真机截图的比例：1080x2400 / 3x
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: BigRow(
              title: '评书文件夹',
              icon: Icons.folder_rounded,
              value: '(033)评书大全180G+10大名家+3714集',
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 有 RenderFlex 溢出的话这里会拿到异常
    expect(tester.takeException(), isNull);

    final titleSize = tester.getSize(find.text('评书文件夹'));
    // 竖排时宽度只剩一个字宽（约 20），这里要求它至少有 3 个字宽
    expect(titleSize.width, greaterThan(60));
    // 也不该被压成很高的竖条
    expect(titleSize.height, lessThan(80));

    // 值的宽度必须被限制住（不能无限伸展）
    final valueSize = tester.getSize(find.text('(033)评书大全180G+10大名家+3714集'));
    expect(valueSize.width, lessThanOrEqualTo(240));
  });
}

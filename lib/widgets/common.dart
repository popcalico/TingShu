import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../models/ting.dart';

/// 统一的顶部栏：左边一个超大的返回键，中间大字标题。
///
/// 不用 AppBar 默认的小箭头——老人手指粗、眼神花，24dp 的箭头很难点中。
class TingBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool showBack;
  final List<Widget> actions;

  const TingBar({
    super.key,
    required this.title,
    this.subtitle,
    this.showBack = true,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
      child: Row(
        children: [
          if (showBack)
            SizedBox(
              width: 64,
              height: 64,
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                iconSize: 38,
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: TingColors.ink),
                tooltip: '返回',
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: T.fontTitle,
                    fontWeight: FontWeight.w700,
                    color: TingColors.ink,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: T.fontSmall, color: TingColors.muted),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 书封：有封面图就显示，没有就用书名首字做个色块，永远不会空着。
class CoverBox extends StatelessWidget {
  final TingBook book;
  final double size;

  const CoverBox({super.key, required this.book, this.size = 64});

  static const _palette = [
    Color(0xFFFAC775),
    Color(0xFFEF9F27),
    Color(0xFFF0997B),
    Color(0xFF5DCAA5),
    Color(0xFF85B7EB),
    Color(0xFFAFA9EC),
  ];

  Color get _bg {
    if (book.title.isEmpty) return _palette[0];
    final c = book.title.codeUnits.fold<int>(0, (a, b) => a + b);
    return _palette[c % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.12);
    if (book.cover.isNotEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: CachedNetworkImage(
          imageUrl: book.cover,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => _placeholder(radius),
          placeholder: (_, __) => _placeholder(radius),
        ),
      );
    }
    return _placeholder(radius);
  }

  Widget _placeholder(BorderRadius radius) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: _bg, borderRadius: radius),
      alignment: Alignment.center,
      child: Text(
        book.title.isEmpty ? '书' : book.title.substring(0, 1),
        style: TextStyle(
          fontSize: size * 0.44,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF3A2A00),
        ),
      ),
    );
  }
}

/// 一行"标题 + 右侧说明"的设置项，整行可点。
class BigRow extends StatelessWidget {
  final String title;
  final String? value;
  final VoidCallback? onTap;
  final IconData? icon;
  final Color? valueColor;

  const BigRow({
    super.key,
    required this.title,
    this.value,
    this.onTap,
    this.icon,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.radius),
      child: Container(
        constraints: const BoxConstraints(minHeight: 76),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: TingColors.surface,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: TingColors.line),
        ),
        // 右侧的值必须限宽。
        // 不限的话，遇到超长文件夹名（比如 "(033)评书大全180G+10大名家+3714…"）
        // 会把标题挤成每行一个字（竖着排），值本身还会溢出卡片边缘。
        // 适老化最忌讳这种：老人看到一列竖排的字，会以为软件坏了。
        child: LayoutBuilder(
          builder: (context, c) {
            final maxValue = c.maxWidth * 0.45;
            return Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 30, color: TingColors.primary),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: T.fontBody,
                      fontWeight: FontWeight.w600,
                      color: TingColors.ink,
                    ),
                  ),
                ),
                if (value != null)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxValue),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        value!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: T.fontSmall,
                          color: valueColor ?? TingColors.muted,
                        ),
                      ),
                    ),
                  ),
                if (onTap != null)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.chevron_right_rounded, size: 30, color: TingColors.muted),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 时间格式：把毫秒变成 "12:30" 或 "1:02:30"
String fmtDuration(Duration d) {
  if (d.inMilliseconds <= 0) return '0:00';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

String fmtBytes(int bytes) {
  if (bytes <= 0) return '0';
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} G';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} M';
  return '${(bytes / 1024).toStringAsFixed(0)} K';
}

import 'package:flutter/material.dart';

/// 适老化设计常量。
///
/// 全部尺寸按「老人一眼看清、一按就中」标准定：正文字号不低于 20sp，
/// 可点击区域不低于 64dp（官方建议 48dp，这里刻意放大 1.3 倍以上）。
class T {
  T._();

  // 字号
  static const double fontHuge = 34; // 首页大标题、播放页书名
  static const double fontTitle = 26; // 页面标题、书封标题
  static const double fontBody = 21; // 正文、按钮文字
  static const double fontSmall = 17; // 次要信息（回数、时长）

  // 间距与控件
  static const double gap = 16;
  static const double pagePad = 20;
  static const double buttonHeight = 72; // 主按钮，方便手指
  static const double buttonHeightSmall = 64;
  static const double radius = 16;
  static const double playButton = 140; // 播放页中央按钮直径
}

/// 高对比浅色主题：白底深字，阳光下也能看清。
///
/// 刻意不用深色模式——老人白天在客厅、院子里听书，浅底深字对比度更高；
/// 也不用灰色小字、不用阴影和渐变，减少视觉噪音。
class TingColors {
  TingColors._();

  static const bg = Color(0xFFF7F6F3); // 页面底色（比纯白柔和，不刺眼）
  static const surface = Color(0xFFFFFFFF); // 卡片
  static const ink = Color(0xFF1A1A1A); // 主文字（近黑，非纯黑，减少拖影）
  static const muted = Color(0xFF55534E); // 次要文字（仍保证 7:1 对比度）
  static const primary = Color(0xFF16558F); // 主色（深蓝，白字对比 7.4:1）
  static const primarySoft = Color(0xFFE6F1FB); // 主色浅底
  static const line = Color(0xFFD8D5CC); // 描边
  static const done = Color(0xFF2F6B2F); // 已听（深绿，白字可读）
  static const doneSoft = Color(0xFFEAF3DE);
  static const warn = Color(0xFF8A4B00); // 提示（深琥珀）
  static const warnSoft = Color(0xFFFAEEDA);
}

ThemeData buildTingTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: TingColors.primary,
      brightness: Brightness.light,
      surface: TingColors.bg,
    ),
    scaffoldBackgroundColor: TingColors.bg,
    splashFactory: NoSplash.splashFactory, // 老人容易误触，去掉水波纹的"闪一下"
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: TingColors.ink,
      displayColor: TingColors.ink,
    ),
    // 统一文字样式：所有 Text 都基于这里，避免各处写死字号
    primaryTextTheme: base.primaryTextTheme.apply(
      bodyColor: TingColors.ink,
      displayColor: TingColors.ink,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: TingColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      iconTheme: IconThemeData(color: TingColors.ink, size: 32),
      titleTextStyle: TextStyle(
        color: TingColors.ink,
        fontSize: T.fontTitle,
        fontWeight: FontWeight.w600,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: TingColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(T.buttonHeight),
        textStyle: const TextStyle(fontSize: T.fontBody, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.radius)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: TingColors.ink,
        minimumSize: const Size.fromHeight(T.buttonHeightSmall),
        side: const BorderSide(color: TingColors.line, width: 1.5),
        textStyle: const TextStyle(fontSize: T.fontBody, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.radius)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: TingColors.primary,
        minimumSize: const Size(64, 56),
        textStyle: const TextStyle(fontSize: T.fontBody, fontWeight: FontWeight.w500),
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 12,
      activeTrackColor: TingColors.primary,
      inactiveTrackColor: TingColors.line,
      thumbColor: TingColors.primary,
      overlayColor: TingColors.primary.withValues(alpha: 0.12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 16),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 32),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? TingColors.primary : TingColors.line,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: TingColors.ink,
      contentTextStyle: TextStyle(fontSize: T.fontBody, color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
    dividerTheme: const DividerThemeData(color: TingColors.line, thickness: 1),
  );
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const brandGreen = Color(0xFF07B75D);

abstract final class AppSpacing {
  static const small = 8.0;
  static const medium = 12.0;
  static const large = 16.0;
  static const page = 20.0;
  static const section = 24.0;
}

abstract final class AppTypography {
  static const title = 20.0;
  static const conversationTitle = 18.0;
  static const body = 16.0;
  static const secondary = 14.0;
  static const compact = 13.0;
  static const caption = 12.0;
  static const metadata = 11.0;
}

abstract final class AppControls {
  static const touch = 48.0;
  static const desktop = 40.0;
}

abstract final class AppCorners {
  static const radius = 6.0;
  static const border = BorderRadius.all(Radius.circular(radius));
}

abstract final class ChatMetrics {
  static const messageFontSize = AppTypography.body;
  static const messageLineHeight = 1.5;
  static const bubbleRadius = 8.0;
  static const bubbleTailWidth = 5.0;
  static const imageWidthDesktop = 300.0;
  static const imageHeightDesktop = 320.0;
  static const imageWidthMobile = 260.0;
  static const imageHeightMobile = 300.0;
  static const bubblePadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 8,
  );
  static const rowGap = 12.0;
}

class ChatPalette extends ThemeExtension<ChatPalette> {
  const ChatPalette(this.dark, {double? blend}) : _blend = blend;
  final bool dark;
  final double? _blend;
  double get blend => _blend ?? (dark ? 1 : 0);
  static ChatPalette of(BuildContext context) =>
      Theme.of(context).extension<ChatPalette>() ??
      ChatPalette(Theme.of(context).brightness == Brightness.dark);
  Color _color(int light, int dark) =>
      Color.lerp(Color(light), Color(dark), blend)!;
  Color get text => _color(0xFF202A27, 0xFFE5EBE8);
  Color get muted => _color(0xFF626F67, 0xFFA2AEA7);
  Color get canvas => _color(0xFFF6F8F7, 0xFF191E1C);
  Color get surface => _color(0xFFFFFFFF, 0xFF252D28);
  Color get editor => surface;
  Color get sidebar => _color(0xFFF0F4F1, 0xFF202823);
  Color get rail => _color(0xFFE8EFEB, 0xFF1B231E);
  Color get selected => _color(0xFFDDEDE3, 0xFF2F4939);
  Color get divider => _color(0xFFE0E7E2, 0xFF343F38);
  Color get outgoing => _color(0xFFD5F0C3, 0xFF246B4A);
  Color get outgoingText => _color(0xFF16251B, 0xFFEDFFF3);
  Color get outgoingLink => _color(0xFF174F6E, 0xFFBCE7FF);
  Color get link => _color(0xFF245D91, 0xFF8AB9E6);
  Color get fileBadge => _color(0xFFEABF64, 0xFF98702E);
  Color get videoBadge => _color(0xFF668BA6, 0xFF426B89);
  Color get unreadBadge => const Color(0xFFD93340);
  Color get menu => surface;
  Color get warning => _color(0xFF91651C, 0xFFE4BB70);
  Color get searchHighlight => _color(0xFFFFE39A, 0xFF725720);
  Color get onSearchHighlight => _color(0xFF372707, 0xFFFFF5D8);

  Color conversationColor(int? value) {
    if (value == null) return sidebar;
    final color = Color(value);
    final light = Color.alphaBlend(
      color.withValues(alpha: .65),
      const Color(0xFFF0F4F1),
    );
    final dark = HSLColor.fromColor(
      color,
    ).withSaturation(.48).withLightness(.25).toColor();
    return Color.lerp(light, dark, blend)!;
  }

  @override
  ChatPalette copyWith({bool? dark, double? blend}) =>
      ChatPalette(dark ?? this.dark, blend: blend ?? this.blend);

  @override
  ChatPalette lerp(covariant ChatPalette? other, double t) => other == null
      ? this
      : ChatPalette(
          t < .5 ? dark : other.dark,
          blend: blend + (other.blend - blend) * t,
        );
}

ThemeData chatTheme(Brightness brightness, {TargetPlatform? platform}) {
  platform ??= defaultTargetPlatform;
  final controlHeight = platform == TargetPlatform.windows
      ? AppControls.desktop
      : AppControls.touch;
  final p = ChatPalette(brightness == Brightness.dark);
  final scheme = ColorScheme.fromSeed(
    seedColor: brandGreen,
    brightness: brightness,
    primary: p.dark ? const Color(0xFF53D68B) : const Color(0xFF16864A),
    surface: p.surface,
    onSurface: p.text,
    onPrimary: p.dark ? const Color(0xFF103820) : Colors.white,
    outlineVariant: p.divider,
  );
  return ThemeData(
    platform: platform,
    useMaterial3: true,
    extensions: [p],
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.canvas,
    fontFamily: switch (platform) {
      TargetPlatform.windows => 'Segoe UI',
      TargetPlatform.iOS || TargetPlatform.macOS => 'PingFang SC',
      _ => 'Roboto',
    },
    fontFamilyFallback: platform == TargetPlatform.windows
        ? ['Microsoft YaHei', 'Microsoft YaHei UI', 'Segoe UI Emoji']
        : ['Noto Sans CJK SC', 'Noto Sans SC', 'sans-serif'],
    textSelectionTheme: TextSelectionThemeData(
      selectionColor: const Color(0xFF4285D4).withValues(alpha: .32),
      cursorColor: scheme.primary,
      selectionHandleColor: scheme.primary,
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(
        fontSize: AppTypography.body,
        height: 1.5,
        letterSpacing: 0,
        color: p.text,
      ),
      titleSmall: TextStyle(
        fontSize: AppTypography.secondary,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        color: p.text,
      ),
      labelLarge: TextStyle(
        fontSize: AppTypography.secondary,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        color: p.text,
      ),
      labelMedium: TextStyle(
        fontSize: AppTypography.caption,
        letterSpacing: 0,
        color: p.muted,
      ),
      labelSmall: TextStyle(
        fontSize: AppTypography.metadata,
        letterSpacing: 0,
        color: p.muted,
      ),
      bodyMedium: TextStyle(
        fontSize: AppTypography.secondary,
        color: p.text,
        height: 1.5,
        letterSpacing: 0,
      ),
      bodySmall: TextStyle(
        fontSize: AppTypography.caption,
        color: p.muted,
        height: 1.5,
        letterSpacing: 0,
      ),
      titleMedium: TextStyle(
        fontSize: AppTypography.body,
        fontWeight: FontWeight.w500,
        color: p.text,
      ),
      titleLarge: TextStyle(
        fontSize: AppTypography.title,
        fontWeight: FontWeight.w500,
        color: p.text,
      ),
    ),
    iconTheme: IconThemeData(color: p.muted, size: 22),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.muted,
        disabledForegroundColor: p.muted.withValues(alpha: .4),
        hoverColor: p.selected,
        shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.menu,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: .28),
      shape: RoundedRectangleBorder(
        borderRadius: AppCorners.border,
        side: BorderSide(
          color: p.dark ? const Color(0xFF414141) : const Color(0xFFD7D7D7),
        ),
      ),
      textStyle: TextStyle(fontSize: AppTypography.secondary, color: p.text),
    ),
    dividerColor: p.divider,
    chipTheme: ChipThemeData(
      shape: const RoundedRectangleBorder(borderRadius: AppCorners.border),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(borderRadius: AppCorners.border),
    ),
    snackBarTheme: const SnackBarThemeData(
      shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
    ),
    dividerTheme: DividerThemeData(color: p.divider, thickness: .6, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.canvas,
      hintStyle: TextStyle(color: p.muted, fontWeight: FontWeight.normal),
      border: OutlineInputBorder(
        borderRadius: AppCorners.border,
        borderSide: BorderSide(color: p.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppCorners.border,
        borderSide: BorderSide(color: p.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppCorners.border,
        borderSide: BorderSide(color: scheme.primary, width: 1.3),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppCorners.border,
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppCorners.border,
        borderSide: BorderSide(color: scheme.error, width: 1.3),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: Size(64, controlHeight),
        shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(64, controlHeight),
        shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
        minimumSize: Size(48, controlHeight),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.menu, borderRadius: AppCorners.border),
      textStyle: TextStyle(color: p.text, fontSize: AppTypography.caption),
    ),
  );
}

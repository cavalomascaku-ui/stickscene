import 'package:flutter/material.dart';

/// One palette, used by every screen.
///
/// The app is dark by default because the canvas is a dark stage; the light
/// scheme exists for people who export on a bright background.
class AppPalette {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.accent,
    required this.accentSoft,
    required this.text,
    required this.textDim,
    required this.danger,
    required this.success,
  });

  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color accent;
  final Color accentSoft;
  final Color text;
  final Color textDim;
  final Color danger;
  final Color success;
}

const AppPalette darkPalette = AppPalette(
  background: Color(0xFF0E1014),
  surface: Color(0xFF171A21),
  surfaceAlt: Color(0xFF1F232C),
  border: Color(0xFF2A2F3A),
  accent: Color(0xFF4C8DFF),
  accentSoft: Color(0x334C8DFF),
  text: Color(0xFFE8EBF2),
  textDim: Color(0xFF9AA3B2),
  danger: Color(0xFFFF5C5C),
  success: Color(0xFF3ED598),
);

const AppPalette lightPalette = AppPalette(
  background: Color(0xFFF4F5F8),
  surface: Color(0xFFFFFFFF),
  surfaceAlt: Color(0xFFEDEFF4),
  border: Color(0xFFD9DDE6),
  accent: Color(0xFF2E6FE8),
  accentSoft: Color(0x332E6FE8),
  text: Color(0xFF151821),
  textDim: Color(0xFF5C6474),
  danger: Color(0xFFD33A3A),
  success: Color(0xFF1F9E6E),
);

AppPalette paletteOf(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? darkPalette
    : lightPalette;

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? darkPalette : lightPalette;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: p.accent,
      onPrimary: Colors.white,
      secondary: p.accent,
      onSecondary: Colors.white,
      error: p.danger,
      onError: Colors.white,
      surface: p.surface,
      onSurface: p.text,
    ),
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    dividerColor: p.border,
    textTheme: Typography.whiteMountainView.apply(
      bodyColor: p.text,
      displayColor: p.text,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: p.text,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        minimumSize: const Size(0, 48),
        side: BorderSide(color: p.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.accent, width: 2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surfaceAlt,
      contentTextStyle: TextStyle(color: p.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.accent,
      inactiveTrackColor: p.border,
      thumbColor: p.accent,
      overlayColor: p.accentSoft,
      trackHeight: 4,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : p.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.surfaceAlt,
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.textDim,
      textColor: p.text,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

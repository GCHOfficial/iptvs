import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens.
class AppColors {
  static const ink = Color(0xFF0E0F13); // app background
  static const panel = Color(0xFF16181F); // cards / surfaces
  static const panelHi = Color(0xFF1E212B); // hover / focus lift
  static const line = Color(0xFF262A36); // hairlines / borders
  static const textHi = Color(0xFFF2F4F8);
  static const textLo = Color(0xFF9AA3B2);
  static const accent = Color(0xFF7B6CF6); // brand / progress
  static const live = Color(0xFFFF4D6D); // "on air" signal
}

class AppRadius {
  static const tile = 14.0;
  static const control = 12.0;
}

class AppTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);

    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
    ).copyWith(
      surface: AppColors.ink,
      primary: AppColors.accent,
    );

    final text = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textHi,
      displayColor: AppColors.textHi,
    );

    // Space Grotesk for titles gives the type a little personality.
    TextStyle? display(TextStyle? s) =>
        GoogleFonts.spaceGrotesk(textStyle: s, fontWeight: FontWeight.w600);

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.ink,
      colorScheme: scheme,
      textTheme: text.copyWith(
        titleLarge: display(text.titleLarge),
        titleMedium: display(text.titleMedium),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: display(base.textTheme.titleLarge),
      ),
      dividerTheme: const DividerThemeData(
          color: AppColors.line, thickness: 1, space: 1),
      iconTheme: const IconThemeData(color: AppColors.textLo),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: AppColors.line,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: AppColors.panel,
        hintStyle: const TextStyle(color: AppColors.textLo),
        prefixIconColor: AppColors.textLo,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.panelHi,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control)),
      ),
      listTileTheme: const ListTileThemeData(iconColor: AppColors.textLo),
    );
  }
}
import 'package:flutter/material.dart';

/// Design tokens.
class AppColors {
  static const ink = Color(0xFF0E0F13); // app background
  static const panel = Color(0xFF16181F); // cards / surfaces
  static const panelHi = Color(0xFF272B36); // hover / focus lift
  static const line = Color(0xFF353B49); // hairlines / borders
  static const textHi = Color(0xFFF2F4F8);
  static const textLo = Color(0xFF9AA3B2);
  static const accent = Color(0xFF7B6CF6); // brand / progress
  static const live = Color(0xFFFF4D6D); // "on air" signal
}

class AppRadius {
  static const tile = 8.0;
  static const control = 8.0;
}

/// Width (logical px) at or above which the browsing UI uses the wide layout
/// (category side-pane + live preview panel). Shared by the channel list
/// screen and the live tab view so the breakpoint can't drift between them.
const double kWideLayoutMinWidth = 950;

class AppTheme {
  /// Text-button styling, exposed separately from [dark]. The
  /// focused state carries an accent ring + fill — the default overlay tint
  /// alone is invisible on dark dialog panels (the EPG programme dialog's
  /// "Close" looked unfocused on TV).
  static final TextButtonThemeData textButtonTheme = TextButtonThemeData(
    style:
        TextButton.styleFrom(
          foregroundColor: AppColors.textHi,
          minimumSize: const Size(44, 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        ).copyWith(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? const BorderSide(color: AppColors.accent, width: 2)
                : null,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? AppColors.accent.withValues(alpha: 0.22)
                : null,
          ),
          overlayColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? AppColors.accent.withValues(alpha: 0.16)
                : null,
          ),
        ),
  );

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);

    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
    ).copyWith(surface: AppColors.ink, primary: AppColors.accent);

    final text = base.textTheme.apply(
      fontFamily: 'Inter',
      bodyColor: AppColors.textHi,
      displayColor: AppColors.textHi,
    );

    TextStyle? display(TextStyle? s) =>
        s?.copyWith(fontFamily: 'Inter', fontWeight: FontWeight.w600);

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
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
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
        style:
            FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(44, 42),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ).copyWith(
              // A bright inner ring reads clearly against the purple fill when
              // focused via D-pad/keyboard (Material's default overlay alone is
              // nearly invisible here).
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? const BorderSide(color: Colors.white, width: 2)
                    : null,
              ),
              overlayColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? Colors.white.withValues(alpha: 0.12)
                    : null,
              ),
            ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              foregroundColor: AppColors.textHi,
              side: const BorderSide(color: AppColors.line),
              minimumSize: const Size(44, 42),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ).copyWith(
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? const BorderSide(color: AppColors.accent, width: 2)
                    : const BorderSide(color: AppColors.line),
              ),
              overlayColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? AppColors.accent.withValues(alpha: 0.16)
                    : null,
              ),
            ),
      ),
      textButtonTheme: textButtonTheme,
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          // Clear accent disc when an icon button (Edit/Delete, refresh) takes
          // D-pad focus.
          overlayColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? AppColors.accent.withValues(alpha: 0.22)
                : null,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.panelHi
                : AppColors.panel,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.textHi
                : AppColors.textLo,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.accent
                : AppColors.textLo,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.selected)
                  ? AppColors.accent
                  : AppColors.line,
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.panelHi,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
        ),
      ),
      listTileTheme: const ListTileThemeData(iconColor: AppColors.textLo),
    );
  }
}

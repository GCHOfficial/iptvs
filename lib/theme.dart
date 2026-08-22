import 'package:flutter/material.dart';

import 'data/device_class.dart';

/// Design tokens.
class AppColors {
  static const ink = Color(0xFF0E0F13); // app background
  static const panel = Color(0xFF16181F); // cards / surfaces
  static const panelHi = Color(0xFF272B36); // hover / focus lift
  static const line = Color(0xFF353B49); // hairlines / borders
  static const textHi = Color(0xFFF2F4F8);
  static const textLo = Color(0xFF9AA3B2);
  static const accent = Color(0xFF7B6CF6); // brand / progress / focus rings
  static const live = Color(0xFFFF4D6D); // "on air" signal

  /// [accent] darkened just enough that **white 14 px bold** — Material's
  /// default `labelLarge`, which every `FilledButton`/FAB here inherits —
  /// clears WCAG AA 4.5:1 against it (measured 4.64:1; plain [accent] is
  /// 3.95:1, and bold 14 px is below the 18.66 px large-text threshold that
  /// would have allowed 3:1).
  ///
  /// Deliberately *not* a replacement for [accent]: rings, progress and focus
  /// states sit on the dark [ink]/[panel] ground where the lighter hue reads
  /// better (4.85:1 vs 4.13:1), so the brand hue stays there. Use this one
  /// only where white text sits **on top of** the accent.
  static const accentFill = Color(0xFF6F5FEC);

  /// Semantic state colours. These exist because every screen that needed one
  /// previously hand-rolled it — the same red was written out at six call
  /// sites (plus a seventh as `Colors.redAccent`), and the amber and green
  /// once each. Reach for these instead of a literal.
  static const danger = Color(0xFFE5484D); // destructive / expired / error
  static const warning = Color(0xFFE5A23D); // needs attention
  static const success = Color(0xFF22C55E); // healthy / synced
}

/// Wraps [duration] so an animation collapses to nothing when the platform
/// reports the "remove animations" accessibility preference.
///
/// Flutter honours this flag for its own route transitions but **not** for
/// `AnimatedContainer`/`AnimatedOpacity` and friends, which is most of what
/// this app animates — so every explicit duration should go through here.
Duration appMotion(BuildContext context, Duration duration) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

class AppRadius {
  static const tile = 8.0;
  static const control = 8.0;
}

// ---------------------------------------------------------------------------
// Layout breakpoints.
//
// **Measure every one of these against `MediaQuery.sizeOf(context)` — the
// window — not against a `LayoutBuilder`'s `constraints.maxWidth`.** A body's
// own width is shrunk by `SafeArea` (the landscape nav-bar / cutout inset on
// Android), by sheet padding, and by any `maxWidth` cap above it, so the same
// number means different things at different points in the tree. The live tab
// documents at length what happened when one branch read constraints while
// every other branch read the window; see docs/tv-navigation.md.
// ---------------------------------------------------------------------------

/// Width at or above which the browsing UI uses the wide layout (category
/// side-pane + live preview panel). Shared by the channel list screen and the
/// live tab view so the breakpoint can't drift between them.
///
/// Compare through [isWideLayout], not directly — a television is wide
/// regardless of what this measures.
const double kWideLayoutMinWidth = 950;

/// Whether the browsing UI should use the wide (two-pane) layout.
///
/// **A television is always wide, whatever its logical width says.** Logical
/// width is physical pixels divided by the device pixel ratio, and on a 4K TV
/// that division is brutal: 3840 px reports 960 at dpr 4.0 and 873 at dpr 4.4,
/// so a set-top box lands either side of [kWideLayoutMinWidth] depending on a
/// density it chose, not on how much screen the viewer is looking at. A 4K
/// television rendering the phone layout — no category side-pane, no live
/// preview panel, and therefore no shared-engine preview path at all — was
/// exactly that, and it is silent: every branch agrees, it is just measuring
/// the wrong thing.
///
/// Lowering [kWideLayoutMinWidth] instead would hand the two-pane layout to
/// large phones in landscape, which is the band the number exists to exclude.
/// Ten-foot devices are a different question from narrow ones, so they are
/// asked separately ([isTelevision], resolved once at boot).
bool isWideLayout(Size size) =>
    isTelevision || size.width >= kWideLayoutMinWidth;

/// Width below which the channel-list toolbar stacks into two rows instead of
/// one. Purely a reflow — no focus target appears or disappears across it, so
/// unlike [kWideLayoutMinWidth] it carries no D-pad hazard.
const double kToolbarStackMaxWidth = 620;

/// Minimum window size for the movies/series **grid**; below either dimension
/// the media tab renders list rows instead. Height matters as much as width —
/// a 900x400 landscape phone has room for a list but not for a poster grid.
const double kMediaGridMinWidth = 600;
const double kMediaGridMinHeight = 500;

/// Target width of one poster tile. The media grid picks its column count by
/// dividing the available width by this, so tiles stay in a narrow size band
/// from a 600 px window to a 4K TV instead of stepping between two extremes.
const double kMediaPosterTargetWidth = 200;

/// Window width at or above which the media details sheet lays its header out
/// in two columns (poster beside metadata) rather than stacked.
const double kMediaSheetTwoColumnMinWidth = 560;

/// Width below which the sources list collapses its per-row action buttons.
const double kSourcesNarrowMaxWidth = 560;

/// Cap for running text and form fields on settings-style screens. Unbounded
/// forms stretch credential fields and paragraph copy edge-to-edge on a
/// maximised desktop window; this keeps a readable measure.
const double kSettingsMaxContentWidth = 640;

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
              // accentFill, not accent: white 14 px bold needs 4.5:1 and the
              // brand hue only reaches 3.95:1. See AppColors.accentFill.
              backgroundColor: AppColors.accentFill,
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
        backgroundColor: AppColors.accentFill,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
        ),
      ),
      listTileTheme: const ListTileThemeData(iconColor: AppColors.textLo),
    );
  }
}

import 'package:flutter/material.dart';

/// The "Projector-Resilient Commerce" design system, as exported from Stitch.
///
/// The bespoke tokens below exist because a conference projector is a hostile
/// display: [textHigh]/[textMedium] are darker than Material's defaults,
/// [borderProjector] is heavier than a hairline divider, and the `chaos*`
/// family deliberately clashes with the store so the fault panel can never be
/// mistaken for part of the shop.
class NimbusTokens {
  const NimbusTokens._();

  static const primary = Color(0xFF00236F);
  static const primaryContainer = Color(0xFF1E3A8A);
  static const onPrimary = Color(0xFFFFFFFF);
  static const secondary = Color(0xFF515F74);
  static const surface = Color(0xFFF8F9FC);
  static const surfaceStore = Color(0xFFF8F9FA);
  static const surfaceCard = Color(0xFFFFFFFF);
  static const surfaceContainer = Color(0xFFECEEF0);
  static const outline = Color(0xFF757682);
  static const error = Color(0xFFBA1A1A);

  static const textHigh = Color(0xFF111827);
  static const textMedium = Color(0xFF374151);
  static const borderProjector = Color(0xFFCBD5E1);
  static const successGreen = Color(0xFF15803D);

  /// The checkout block the SDK paints over before storing a screenshot. It
  /// needs a visible boundary so the redaction in Jira reads as deliberate
  /// rather than as a rendering fault.
  static const sensitiveSurface = Color(0xFFEFF6FF);
  static const sensitiveBorder = Color(0xFF3B82F6);

  static const chaosBg = Color(0xFF0F172A);
  static const chaosSurface = Color(0xFF1E293B);
  static const chaosBorder = Color(0xFF334155);
  static const chaosAmber = Color(0xFFF59E0B);
  static const chaosRed = Color(0xFFEF4444);
  static const chaosTextPrimary = Color(0xFFF8FAFC);
  static const chaosTextSecondary = Color(0xFF94A3B8);

  static const radius = 8.0;
}

/// Bundled rather than fetched: `google_fonts` downloads at runtime, and the
/// demo runs on a stage where the network is the least trustworthy component.
const _fontFamily = 'PublicSans';

ThemeData buildNimbusTheme() {
  const scheme = ColorScheme.light(
    primary: NimbusTokens.primary,
    onPrimary: NimbusTokens.onPrimary,
    primaryContainer: NimbusTokens.primaryContainer,
    onPrimaryContainer: NimbusTokens.onPrimary,
    secondary: NimbusTokens.secondary,
    onSecondary: NimbusTokens.onPrimary,
    surface: NimbusTokens.surface,
    onSurface: NimbusTokens.textHigh,
    onSurfaceVariant: NimbusTokens.textMedium,
    outline: NimbusTokens.outline,
    outlineVariant: NimbusTokens.borderProjector,
    error: NimbusTokens.error,
    onError: NimbusTokens.onPrimary,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: _fontFamily,
    scaffoldBackgroundColor: NimbusTokens.surfaceStore,
  );

  return base.copyWith(
    // Sizes are set here rather than per-widget: the app forces a 1.35x text
    // scale at runtime, so every size must survive being multiplied.
    textTheme: base.textTheme.copyWith(
      headlineMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: NimbusTokens.textHigh,
      ),
      headlineSmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: NimbusTokens.textHigh,
      ),
      titleLarge: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: NimbusTokens.textHigh,
      ),
      titleMedium: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: NimbusTokens.textHigh,
      ),
      bodyLarge: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w400,
        color: NimbusTokens.textHigh,
      ),
      bodyMedium: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: NimbusTokens.textMedium,
      ),
      // An explicit colour: a style without one inherits from whatever
      // DefaultTextStyle is in scope, which rendered this white on the
      // checkout screen's pale-blue panel. Buttons override it via
      // foregroundColor, so this only affects loose text.
      labelLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: NimbusTokens.textHigh,
      ),
    ),
    // A non-null titleTextStyle is used verbatim — AppBar only folds
    // `foregroundColor` into its *default* style — so the colour has to live
    // here, and a dark screen must override titleTextStyle, not just
    // foregroundColor. See ChaosPanelScreen.
    appBarTheme: const AppBarTheme(
      backgroundColor: NimbusTokens.surfaceCard,
      foregroundColor: NimbusTokens.primary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: NimbusTokens.primary,
      ),
    ),
    cardTheme: CardThemeData(
      color: NimbusTokens.surfaceCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NimbusTokens.radius * 1.5),
        side: const BorderSide(color: NimbusTokens.borderProjector),
      ),
      margin: const EdgeInsets.only(bottom: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NimbusTokens.primaryContainer,
        foregroundColor: NimbusTokens.onPrimary,
        // 56 rather than Material's 40: the presenter taps this while talking
        // and being watched.
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NimbusTokens.radius),
        ),
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      minVerticalPadding: 12,
    ),
    dividerTheme: const DividerThemeData(
      color: NimbusTokens.borderProjector,
      thickness: 1,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: NimbusTokens.surfaceCard,
      indicatorColor: NimbusTokens.primaryContainer.withValues(alpha: 0.12),
      height: 72,
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(
          fontFamily: _fontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

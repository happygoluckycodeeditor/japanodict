import 'package:flutter/material.dart';

/// The JapanoLearn colourway.
///
/// Every screen in this app draws from `Theme.of(context).colorScheme` rather
/// than naming colours itself, so the brand lives in exactly one place: the two
/// schemes below. The handful of widgets that genuinely need a fixed brand
/// colour (the badge pills, the favourite star) pull it from [BrandColors] so
/// they shift with the palette too instead of drifting out of step.
class BrandColors {
  const BrandColors._();

  /// Primary brand red, straight from the JapanoLearn wordmark.
  static const Color red = Color(0xFFFF5759);

  /// Brand yellow. Bright enough to sit *behind* dark text but far too light to
  /// be legible *as* text on a pale surface — use [gold] for that.
  static const Color yellow = Color(0xFFFDE265);

  /// A deepened [yellow] with enough contrast to be an icon or label colour on
  /// the light surfaces. Reads as the same accent, just weighted for foreground.
  static const Color gold = Color(0xFFDCA71B);

  /// The near-black plum the brand sets text in — warmer than a neutral grey,
  /// which matters against the cream surfaces.
  static const Color ink = Color(0xFF2A1B2E);

  /// The teal the brand uses for its one non-red call to action. Carried here
  /// as the tertiary role so kanji flashcard decks stay visually distinct from
  /// vocabulary decks.
  static const Color teal = Color(0xFF1F9E9B);
}

/// Light: warm cream surfaces, pastel red containers, brand red for accents.
const ColorScheme _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: BrandColors.red,
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFFFDDDC),
  onPrimaryContainer: Color(0xFF5F1315),
  secondary: BrandColors.yellow,
  onSecondary: Color(0xFF3D3000),
  secondaryContainer: Color(0xFFFFF3C2),
  onSecondaryContainer: Color(0xFF4A3B00),
  tertiary: BrandColors.teal,
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFC7EFED),
  onTertiaryContainer: Color(0xFF00201F),
  error: Color(0xFFB3261E),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF410E0B),
  surface: Color(0xFFF5F0EA),
  onSurface: BrandColors.ink,
  onSurfaceVariant: Color(0xFF6D5F66),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFFBF7F2),
  surfaceContainer: Color(0xFFF1EBE4),
  surfaceContainerHigh: Color(0xFFEBE4DC),
  surfaceContainerHighest: Color(0xFFE5DDD4),
  surfaceTint: BrandColors.red,
  outline: Color(0xFF897B82),
  outlineVariant: Color(0xFFD8CEC8),
  inverseSurface: Color(0xFF2F2530),
  onInverseSurface: Color(0xFFF7F0EA),
  inversePrimary: Color(0xFFFFB3B2),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

/// Dark: the same palette on a warm plum-black. The red is lifted to `#FF8F8E`
/// because brand red as a foreground on a dark surface falls under 4.5:1 —
/// containers keep the full-strength red instead, where it is a background.
const ColorScheme _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFFF8F8E),
  onPrimary: Color(0xFF5A1113),
  primaryContainer: Color(0xFF6E1F21),
  onPrimaryContainer: Color(0xFFFFDAD9),
  secondary: BrandColors.yellow,
  onSecondary: Color(0xFF3D3000),
  // Biased warm/brown rather than a straight darkening of the brand yellow —
  // yellow loses its red channel fastest as it darkens, so the obvious
  // `#574600` lands on olive, which is nowhere in the brand.
  secondaryContainer: Color(0xFF4C3712),
  onSecondaryContainer: Color(0xFFFFE9A6),
  tertiary: Color(0xFF5FD5D0),
  onTertiary: Color(0xFF003735),
  tertiaryContainer: Color(0xFF00504E),
  onTertiaryContainer: Color(0xFFB4F1EE),
  error: Color(0xFFF2B8B5),
  onError: Color(0xFF601410),
  errorContainer: Color(0xFF8C1D18),
  onErrorContainer: Color(0xFFF9DEDC),
  surface: Color(0xFF191316),
  onSurface: Color(0xFFEDE2DD),
  onSurfaceVariant: Color(0xFFC4B5AF),
  surfaceContainerLowest: Color(0xFF120D10),
  surfaceContainerLow: Color(0xFF211A1E),
  surfaceContainer: Color(0xFF251E22),
  surfaceContainerHigh: Color(0xFF30282C),
  surfaceContainerHighest: Color(0xFF3B3237),
  surfaceTint: Color(0xFFFF8F8E),
  outline: Color(0xFF9C8C93),
  outlineVariant: Color(0xFF50464B),
  inverseSurface: Color(0xFFEDE2DD),
  onInverseSurface: Color(0xFF362E32),
  inversePrimary: Color(0xFFC0393B),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

class AppTheme {
  const AppTheme._();

  static ThemeData get light => _build(_lightScheme);

  static ThemeData get dark => _build(_darkScheme);

  static ThemeData _build(ColorScheme scheme) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        // The app bars set their own pastel `primaryContainer` background, so a
        // drop shadow under them would read as a seam rather than a lift.
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
      ),
    );
  }

  /// The favourite star. Brand yellow is invisible against the cream surfaces,
  /// so light mode uses the deepened [BrandColors.gold] instead.
  static Color starColor(Brightness brightness) =>
      brightness == Brightness.dark ? BrandColors.yellow : BrandColors.gold;
}

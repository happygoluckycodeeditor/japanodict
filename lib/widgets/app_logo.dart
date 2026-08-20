import 'package:flutter/material.dart';

/// The JapanoDict mark, for the places inside the app that show it.
///
/// Wrapped in a widget rather than left as bare `Image.asset` calls so the
/// asset path lives in one place — the same artwork is also compiled into the
/// Android launcher icon and the launch window, and those copies are generated
/// from `applogo/japanodict_logo.png` by `scripts/build_app_icons.py`. Changing
/// the logo means re-running that script, not just swapping this asset.
///
/// The bitmap's rounded corners are transparent, so it drops onto the coloured
/// drawer header and onto the dark-mode surfaces without a white box behind it.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 48});

  static const String asset = 'assets/images/japanodict_logo.png';

  /// Edge of the (square) mark in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      // The asset is 512px and every use here is well under that, so it is
      // always being downscaled — the default `low` leaves the `{jd}` counters
      // visibly speckled at drawer size.
      filterQuality: FilterQuality.medium,
      // Decorative: the app's name is written next to it everywhere it appears.
      excludeFromSemantics: true,
    );
  }
}

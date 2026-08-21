import 'package:flutter/material.dart';

import '../services/favourites_service.dart';
import '../theme/app_theme.dart';

/// The star that saves one word or character to [FavouritesService].
///
/// A widget rather than an `IconButton` at each call site because the star has
/// to repaint when the *store* changes, not just when its own screen rebuilds:
/// the same word can be starred in the entry sheet and unstarred in a flashcard
/// session sitting behind it on the stack. Subscribing here keeps that listener
/// plumbing out of every screen that wants to show a star.
///
/// [favouriteKey] is `v:<sequence>` for a word and `k:<literal>` for a
/// character — the same keys `Flashcard.favouriteKey` builds, so a word starred
/// from search and the same word starred from a deck are one row, not two.
class FavouriteButton extends StatefulWidget {
  const FavouriteButton({super.key, required this.favouriteKey});

  final String favouriteKey;

  @override
  State<FavouriteButton> createState() => _FavouriteButtonState();
}

class _FavouriteButtonState extends State<FavouriteButton> {
  final FavouritesService _favourites = FavouritesService();

  @override
  void initState() {
    super.initState();
    // Cheap after the first call — the service shares one in-flight load, and
    // the set it fills is what `isFavourite` reads synchronously below.
    _favourites.load().ignore();
    _favourites.addListener(_onChanged);
  }

  @override
  void dispose() {
    _favourites.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFavourite = _favourites.isFavourite(widget.favouriteKey);

    return IconButton(
      onPressed: () => _favourites.toggle(widget.favouriteKey),
      icon: Icon(
        isFavourite ? Icons.star : Icons.star_border,
        color: isFavourite
            ? AppTheme.starColor(theme.brightness)
            : theme.colorScheme.onSurfaceVariant,
      ),
      tooltip:
          isFavourite ? 'Remove from favourites' : 'Add to favourites',
    );
  }
}

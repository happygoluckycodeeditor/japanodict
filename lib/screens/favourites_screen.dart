import 'package:flutter/material.dart';

import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
import '../services/favourites_service.dart';
import '../widgets/entry_badges.dart';
import '../widgets/entry_detail_sheet.dart';
import '../widgets/kanji_summary_card.dart';
import 'kanji_detail_screen.dart';

/// Everything the user has starred, in one browsable list.
///
/// [FavouritesService] has stored stars since the flashcard decks shipped, but
/// the only way to *make* one was inside a deck session, and the only way to
/// see them again was to run that deck. This screen is the other half: star a
/// word from search or a character from the kanji screen, and find it here.
///
/// The rows are read fresh from `jitendex.db` rather than cached in
/// `favourites.db`, because the store keeps upstream identifiers only
/// (`v:<sequence>`, `k:<literal>`) and not a copy of the entry. That is what
/// lets a star survive a dictionary rebuild — the text is re-resolved against
/// whatever the current database says.
///
/// **Names are deliberately absent.** `favourites.db` keys vocabulary as
/// `v:<sequence>` against *dictionary* sequences, so a JMnedict sequence in
/// that namespace would be looked up in the wrong table and resolve to an
/// unrelated word. Making names starrable needs a third key prefix first.
class FavouritesScreen extends StatefulWidget {
  const FavouritesScreen({super.key});

  @override
  State<FavouritesScreen> createState() => _FavouritesScreenState();
}

class _FavouritesScreenState extends State<FavouritesScreen> {
  final DatabaseService _db = DatabaseService();
  final FavouritesService _favourites = FavouritesService();

  /// The resolved list, held directly rather than as a `Future` behind a
  /// `FutureBuilder`.
  ///
  /// A `FutureBuilder` whose future is swapped on every change was tried first
  /// and does not refresh reliably here: the reload resolved with the right
  /// rows — verified on device — and the rebuilt list still showed the row that
  /// had just been deleted. Holding the result in plain state has no future
  /// identity or re-subscription to get wrong; `setState` is the only thing
  /// that moves the screen.
  _SavedItems? _items;

  /// Null until the first load finishes, which is the only time there is
  /// nothing to draw. A *reload* keeps the current list on screen rather than
  /// flashing a spinner to delete one row.
  bool get _loadedOnce => _items != null;

  @override
  void initState() {
    super.initState();
    _reload();
    _favourites.addListener(_onFavouritesChanged);
  }

  @override
  void dispose() {
    _favourites.removeListener(_onFavouritesChanged);
    super.dispose();
  }

  /// Re-resolves the list when the store changes while this screen is on top.
  void _onFavouritesChanged() => _reload();

  /// Opens [route] and reloads once it closes.
  ///
  /// The listener above is **not** enough on its own, and that is the whole
  /// reason this helper exists. Un-starring happens in a sheet or a screen
  /// opened *over* this one, so the notify arrives while this route is
  /// obscured and the rebuild it asks for does not reach the screen. Awaiting
  /// the route and reloading when it closes refreshes at the moment the list is
  /// visible again — `FlashcardsScreen._openDeck` does the same thing for the
  /// same reason.
  Future<void> _openAndRefresh(Future<void> route) async {
    await route;
    await _reload();
  }

  Future<void> _reload() async {
    try {
      final items = await _load();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      debugPrint('FavouritesScreen: load failed: $e');
      if (mounted) setState(() => _items = const _SavedItems.empty());
    }
  }

  Future<_SavedItems> _load() async {
    await _favourites.load();

    // Both refs come back newest-star-first, and both bulk lookups preserve the
    // order they were handed, so the list reads as a history of what was saved.
    //
    // They are then filtered through [FavouritesService.keys]. The refs are read
    // from the favourites *table*, which `toggle` writes to only after it has
    // notified — so a reload triggered by that first, optimistic notify can
    // still see a row that is on its way out, and redraw the card the user just
    // un-starred. `keys` is the in-memory set `toggle` updates synchronously, so
    // filtering through it makes the list correct whichever of the two notifies
    // this load is answering.
    final sequences = (await _favourites.vocabRefs())
        .where((s) => _favourites.isFavourite('v:$s'))
        .toList();
    final literals = (await _favourites.kanjiRefs())
        .where((l) => _favourites.isFavourite('k:$l'))
        .toList();

    final entries = await _db.getEntriesBySequence(sequences);
    final kanji = await _db.getKanjiByLiterals(literals);
    return _SavedItems(entries: entries, kanji: kanji);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favourites'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      ),
      body: _loadedOnce
          ? _buildList(context, _items!)
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildList(BuildContext context, _SavedItems items) {
    if (items.isEmpty) {
      return _buildMessage(
        context,
        icon: Icons.star_border,
        title: 'Nothing saved yet',
        body: 'Tap the star on a word or a kanji to keep it here — '
            'and to build your own flashcard deck.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        if (items.entries.isNotEmpty) ...[
          _sectionTitle(context, 'Words', items.entries.length),
          const SizedBox(height: 8),
          ...items.entries.map(_buildEntryCard),
          if (items.kanji.isNotEmpty) const SizedBox(height: 24),
        ],
        if (items.kanji.isNotEmpty) ...[
          _sectionTitle(context, 'Kanji', items.kanji.length),
          const SizedBox(height: 8),
          ...items.kanji.map(
            (k) => KanjiSummaryCard(
              kanji: k,
              onTap: () => _openAndRefresh(
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => KanjiDetailScreen(kanji: k),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String label, int count) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// Matches the density of the search results deliberately: the reading sits
  /// beside the term rather than under it, and long senses are clamped, so a
  /// saved list scans the same way the results list does.
  Widget _buildEntryCard(DictionaryEntry entry) {
    final theme = Theme.of(context);
    final reading = entry.reading;
    final hasReading = reading != null && reading.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => _openAndRefresh(showEntryDetailSheet(context, entry)),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      entry.term,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (hasReading) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        reading,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                  if (entry.isCommon) ...[
                    const SizedBox(width: 8),
                    const CommonBadge(),
                  ],
                  if (entry.jlpt != null) ...[
                    const SizedBox(width: 6),
                    JlptBadge(level: entry.jlpt!),
                  ],
                ],
              ),
              if (entry.glossList.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  entry.glossList.first,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessage(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
  }) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedItems {
  const _SavedItems({required this.entries, required this.kanji});

  const _SavedItems.empty() : entries = const [], kanji = const [];

  final List<DictionaryEntry> entries;
  final List<KanjiEntry> kanji;

  bool get isEmpty => entries.isEmpty && kanji.isEmpty;
}

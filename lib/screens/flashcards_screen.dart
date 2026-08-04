import 'package:flutter/material.dart';

import '../models/flashcard.dart';
import '../services/database_service.dart';
import '../services/favourites_service.dart';
import 'flashcard_session_screen.dart';

/// Deck picker: JLPT vocabulary decks, kanji decks by school grade, and
/// whatever the user has starred.
///
/// Counts are read from the database on open rather than hardcoded, so a
/// dictionary rebuild that changes deck sizes doesn't leave the picker lying.
class FlashcardsScreen extends StatefulWidget {
  const FlashcardsScreen({super.key});

  @override
  State<FlashcardsScreen> createState() => _FlashcardsScreenState();
}

class _FlashcardsScreenState extends State<FlashcardsScreen> {
  final DatabaseService _db = DatabaseService();
  final FavouritesService _favourites = FavouritesService();

  late Future<Map<String, int>> _counts;

  @override
  void initState() {
    super.initState();
    _counts = _db.getDeckCounts();
    _favourites.load().ignore();
    _favourites.addListener(_onFavouritesChanged);
  }

  @override
  void dispose() {
    _favourites.removeListener(_onFavouritesChanged);
    super.dispose();
  }

  void _onFavouritesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openDeck(Deck deck) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FlashcardSessionScreen(deck: deck)),
    );
    // A session can star or unstar cards, so the favourites tile is stale on
    // the way back.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flashcards'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      ),
      body: FutureBuilder<Map<String, int>>(
        future: _counts,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _buildError(context);
          }
          final counts = snapshot.data ?? const <String, int>{};
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _buildFavouritesTile(context),
              const SizedBox(height: 24),
              _sectionHeader(
                context,
                'Vocabulary',
                'JLPT levels, easiest first',
              ),
              const SizedBox(height: 8),
              ..._deckTiles(Deck.vocabDecks, counts),
              const SizedBox(height: 24),
              _sectionHeader(
                context,
                'Kanji',
                'By school grade — see the note below',
              ),
              const SizedBox(height: 8),
              ..._deckTiles(Deck.kanjiDecks, counts),
              const SizedBox(height: 16),
              _buildGradeNote(context),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _deckTiles(List<Deck> decks, Map<String, int> counts) {
    return decks
        .map((d) => d.withCount(counts[d.id] ?? 0))
        // A deck with no rows would open onto an empty session; hiding it is
        // better than offering a dead end if the database ever lacks a level.
        .where((d) => d.count > 0)
        .map((d) => _buildDeckTile(context, d))
        .toList();
  }

  Widget _sectionHeader(BuildContext context, String title, String subtitle) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildDeckTile(BuildContext context, Deck deck) {
    final theme = Theme.of(context);
    final isVocab = deck.kind == DeckKind.vocab;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _openDeck(deck),
        leading: CircleAvatar(
          backgroundColor: isVocab
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.tertiaryContainer,
          child: Icon(
            isVocab ? Icons.translate : Icons.brush_outlined,
            size: 20,
            color: isVocab
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onTertiaryContainer,
          ),
        ),
        title: Text(
          deck.title,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(deck.subtitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${deck.count}',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }

  Widget _buildFavouritesTile(BuildContext context) {
    final theme = Theme.of(context);
    final count = _favourites.count;
    const deck = Deck(
      id: Deck.favouritesId,
      kind: DeckKind.vocab,
      title: 'Favourites',
      subtitle: 'Cards you starred',
    );
    return Card(
      color: theme.colorScheme.secondaryContainer,
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: count == 0 ? null : () => _openDeck(deck),
        enabled: count > 0,
        leading: Icon(
          count == 0 ? Icons.star_border : Icons.star,
          color: theme.colorScheme.onSecondaryContainer,
        ),
        title: Text(
          'Favourites',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          count == 0
              ? 'Star a card to build your own deck'
              : '$count card${count == 1 ? '' : 's'} saved',
        ),
        trailing: count == 0 ? null : const Icon(Icons.chevron_right),
      ),
    );
  }

  /// Explains, in the UI, why kanji decks are grades and not N-levels — the
  /// question a learner will otherwise ask the moment they see this screen.
  Widget _buildGradeNote(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Kanji decks follow the Japanese school curriculum (KANJIDIC2 '
              'grades), not JLPT levels — there is no official per-character '
              'JLPT list. Vocabulary decks are JLPT N5–N1.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              "Couldn't load the decks",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => setState(() => _counts = _db.getDeckCounts()),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

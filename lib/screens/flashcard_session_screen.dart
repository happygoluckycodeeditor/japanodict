import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/dictionary_entry.dart';
import '../models/flashcard.dart';
import '../services/database_service.dart';
import '../services/favourites_service.dart';
import '../theme/app_theme.dart';
import '../widgets/stroke_order_diagram.dart';

/// A run through one deck: tap to flip, swipe (or use the buttons) to move on,
/// star to keep.
///
/// There is deliberately no scheduling, scoring or "did you know it?" here —
/// this is the plain flip-card pass. Anything spaced-repetition belongs in a
/// separate store on top of [FavouritesService], not woven into this screen.
class FlashcardSessionScreen extends StatefulWidget {
  const FlashcardSessionScreen({super.key, required this.deck});

  final Deck deck;

  @override
  State<FlashcardSessionScreen> createState() => _FlashcardSessionScreenState();
}

class _FlashcardSessionScreenState extends State<FlashcardSessionScreen> {
  final DatabaseService _db = DatabaseService();
  final FavouritesService _favourites = FavouritesService();
  final PageController _pageController = PageController();

  List<Flashcard> _cards = const [];
  bool _loading = true;
  Object? _error;
  int _index = 0;
  bool _shuffled = false;

  /// The unshuffled deck, kept so toggling shuffle off restores the original
  /// order instead of needing another database round trip.
  List<Flashcard> _ordered = const [];

  @override
  void initState() {
    super.initState();
    _load();
    _favourites.addListener(_onFavouritesChanged);
  }

  @override
  void dispose() {
    _favourites.removeListener(_onFavouritesChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _onFavouritesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cards = widget.deck.id == Deck.favouritesId
          ? await _loadFavourites()
          : await _loadDeck(widget.deck);
      if (!mounted) return;
      setState(() {
        _ordered = cards;
        _cards = cards;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<List<Flashcard>> _loadDeck(Deck deck) async {
    if (deck.kind == DeckKind.vocab) {
      final entries = await _db.getVocabDeck(deck.id);
      return entries.map(Flashcard.vocab).toList();
    }
    // Deck ids are 'grade:<n>'; the picker is the only source of these, so a
    // malformed id is a programming error rather than user input.
    final grade = int.parse(deck.id.split(':').last);
    final kanji = await _db.getKanjiDeck(grade);
    return kanji.map(Flashcard.kanji).toList();
  }

  Future<List<Flashcard>> _loadFavourites() async {
    await _favourites.load();
    final entries = await _db.getEntriesBySequence(await _favourites.vocabRefs());
    final kanji = await _db.getKanjiByLiterals(await _favourites.kanjiRefs());
    return [
      ...entries.map(Flashcard.vocab),
      ...kanji.map(Flashcard.kanji),
    ];
  }

  void _toggleShuffle() {
    setState(() {
      _shuffled = !_shuffled;
      _cards = _shuffled ? (List.of(_ordered)..shuffle(math.Random())) : _ordered;
      _index = 0;
    });
    // jumpTo rather than animateTo: after a reshuffle the intervening pages are
    // different cards, so scrolling through them means nothing.
    if (_pageController.hasClients) _pageController.jumpToPage(0);
  }

  void _move(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= _cards.length) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deck.title),
        backgroundColor: theme.colorScheme.primaryContainer,
        actions: [
          if (_cards.length > 1)
            IconButton(
              onPressed: _toggleShuffle,
              icon: const Icon(Icons.shuffle),
              tooltip: _shuffled ? 'Restore order' : 'Shuffle',
              color: _shuffled ? theme.colorScheme.primary : null,
            ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              "Couldn't load this deck",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_cards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'This deck is empty.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _cards.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) {
              final card = _cards[i];
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: _FlipCard(
                  // Keyed by the card, so swiping to a new page always starts
                  // face-down instead of inheriting the previous card's flip.
                  key: ValueKey(card.favouriteKey),
                  card: card,
                  isFavourite: _favourites.isFavourite(card.favouriteKey),
                  onToggleFavourite: () =>
                      _favourites.toggle(card.favouriteKey),
                ),
              );
            },
          ),
        ),
        _buildControls(context),
      ],
    );
  }

  Widget _buildControls(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: [
          LinearProgressIndicator(
            value: (_index + 1) / _cards.length,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton.filledTonal(
                onPressed: _index > 0 ? () => _move(-1) : null,
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Previous',
              ),
              Text(
                '${_index + 1} / ${_cards.length}',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              IconButton.filledTonal(
                onPressed: _index < _cards.length - 1 ? () => _move(1) : null,
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Next',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One card, face-down until tapped.
///
/// Only the visible face is built. That keeps the answer genuinely off-screen
/// (no reading to catch in a screenshot or an accessibility walk) and means a
/// kanji card's stroke-order animation starts when the card is turned over
/// rather than playing unseen behind it.
class _FlipCard extends StatefulWidget {
  const _FlipCard({
    super.key,
    required this.card,
    required this.isFavourite,
    required this.onToggleFavourite,
  });

  final Flashcard card;
  final bool isFavourite;
  final VoidCallback onToggleFavourite;

  @override
  State<_FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<_FlipCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  bool get _showingBack => _controller.value > 0.5;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _flip() {
    if (_controller.value >= 0.5) {
      _controller.reverse();
    } else {
      _controller.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _flip,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final angle = _controller.value * math.pi;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              // Perspective, so the card turns in depth rather than squashing.
              ..setEntry(3, 2, 0.001)
              ..rotateY(angle),
            child: _showingBack
                // Past the halfway point the card is facing away from us, so
                // the back has to be flipped again or it renders mirrored.
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateY(math.pi),
                    child: _buildFace(context, back: true),
                  )
                : _buildFace(context, back: false),
          );
        },
      ),
    );
  }

  Widget _buildFace(BuildContext context, {required bool back}) {
    final theme = Theme.of(context);
    return Card(
      elevation: 3,
      color: back ? theme.colorScheme.surfaceContainerHigh : theme.colorScheme.surface,
      child: SizedBox(
        width: double.infinity,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
              child: Center(
                child: SingleChildScrollView(
                  child: back ? _buildBack(context) : _buildFront(context),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                onPressed: widget.onToggleFavourite,
                icon: Icon(
                  widget.isFavourite ? Icons.star : Icons.star_border,
                  color: widget.isFavourite
                      ? AppTheme.starColor(theme.brightness)
                      : theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: widget.isFavourite
                    ? 'Remove from favourites'
                    : 'Add to favourites',
              ),
            ),
            if (!back)
              Positioned(
                bottom: 8,
                left: 0,
                right: 0,
                child: Text(
                  'Tap to reveal',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFront(BuildContext context) {
    final theme = Theme.of(context);
    final card = widget.card;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          card.front,
          textAlign: TextAlign.center,
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        // The reading is the answer on a vocabulary card, so the front shows
        // only the written form — no furigana giving it away.
        if (card.kind == DeckKind.kanji && card.kanji!.strokeCount != null) ...[
          const SizedBox(height: 12),
          Text(
            '${card.kanji!.strokeCount} strokes',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBack(BuildContext context) {
    return widget.card.kind == DeckKind.vocab
        ? _buildVocabBack(context, widget.card.entry!)
        : _buildKanjiBack(context, widget.card.kanji!);
  }

  Widget _buildVocabBack(BuildContext context, DictionaryEntry entry) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          entry.term,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        // Kana-only words store the reading identically to the term (あそこ /
        // あそこ), and printing it twice just looks like a bug.
        if (entry.reading != null &&
            entry.reading!.isNotEmpty &&
            entry.reading != entry.term)
          Text(
            entry.reading!,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        const SizedBox(height: 16),
        if (entry.partsOfSpeechList.isNotEmpty) ...[
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: entry.partsOfSpeechList
                .take(3)
                .map((pos) => _chip(context, pos))
                .toList(),
          ),
          const SizedBox(height: 12),
        ],
        // Capped at five senses: past that the card stops being glanceable and
        // the full entry is a search away.
        ...entry.glossList.take(5).map(
              (gloss) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  gloss,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ),
      ],
    );
  }

  Widget _buildKanjiBack(BuildContext context, KanjiEntry kanji) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildStrokeOrder(context, kanji),
        const SizedBox(height: 12),
        Text(
          kanji.meanings,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        // Kun before on, matching how kanji dictionaries print them.
        if (kanji.kunReadings != null)
          Text(
            kanji.kunReadings!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
        if (kanji.onReadings != null)
          Text(
            kanji.onReadings!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            if (kanji.strokeCount != null)
              _chip(context, '${kanji.strokeCount} strokes'),
            // Only grades 1–6 mean "taught in year N"; 8/9/10 are set
            // membership, so they'd be misleading rendered the same way.
            if (kanji.isKyoiku) _chip(context, 'grade ${kanji.grade}'),
            if (kanji.freq != null) _chip(context, 'freq #${kanji.freq}'),
          ],
        ),
      ],
    );
  }

  /// Stroke-order animation, falling back to the plain glyph while loading or
  /// when KanjiVG has no data for the character (it covers ~6,700 of
  /// KANJIDIC2's ~10,400, so gaps are normal).
  Widget _buildStrokeOrder(BuildContext context, KanjiEntry kanji) {
    const size = 120.0;
    return FutureBuilder<KanjiStrokes?>(
      future: DatabaseService().getStrokesFor(kanji.literal),
      builder: (context, snapshot) {
        final strokes = snapshot.data;
        if (strokes == null || strokes.outlines.isEmpty) {
          return SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Text(
                kanji.literal,
                style: Theme.of(context).textTheme.displayMedium,
              ),
            ),
          );
        }
        return StrokeOrderDiagram(strokes: strokes, size: size);
      },
    );
  }

  Widget _chip(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

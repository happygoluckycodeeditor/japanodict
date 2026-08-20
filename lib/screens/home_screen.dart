import 'dart:async';

import 'package:flutter/material.dart';
import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
import '../services/history_service.dart';
import '../services/text_lookup_service.dart';
import '../utils/jp_text.dart';
import '../utils/romaji.dart';
import 'credits_screen.dart';
import 'anki_decks_screen.dart';
import 'flashcards_screen.dart';
import 'ocr_screen.dart';
import '../widgets/app_logo.dart';
import '../widgets/entry_badges.dart';
import '../widgets/entry_detail_sheet.dart';
import '../widgets/kanji_draw_pad.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final DatabaseService _dbService = DatabaseService();
  final HistoryService _history = HistoryService();
  final TextLookupService _lookup = TextLookupService();

  Timer? _debounce;
  Timer? _historyIdle;
  List<DictionaryEntry> _results = [];

  /// Words found *inside* the query when the dictionary has no entry for the
  /// whole of it — 是正処置 → 是正 + 処置. Always rendered below [_results]
  /// and under their own heading, never mixed in: a partial match is not an
  /// answer to what was typed, it is the closest the dictionary can get.
  List<TokenMatch> _partials = const [];
  bool _isLoading = false;
  String _query = '';
  bool _showDrawPad = false;

  /// How long a query has to sit unchanged, with results on screen, before it
  /// counts as a search worth remembering. Longer than the 120ms search
  /// debounce on purpose: search should feel instant, history should not
  /// record every pause mid-word.
  static const Duration _historyIdleDelay = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _searchFocus.addListener(_onSearchFocusChanged);
    _history.addListener(_onHistoryChanged);
    unawaited(_history.load());
    // Start the (possibly first-run) database copy immediately rather than
    // on the first search, so it's more likely to be ready by the time the
    // user finishes typing.
    unawaited(_dbService.database);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _historyIdle?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.dispose();
    _history.removeListener(_onHistoryChanged);
    super.dispose();
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  /// The soft keyboard and the draw pad compete for the same screen space, so
  /// focusing the text field puts the pad away.
  void _onSearchFocusChanged() {
    if (_searchFocus.hasFocus && _showDrawPad) {
      setState(() => _showDrawPad = false);
    }
  }

  void _toggleDrawPad() {
    setState(() => _showDrawPad = !_showDrawPad);
    if (_showDrawPad) {
      // Dismiss the keyboard; the focus listener would otherwise immediately
      // close the pad we just opened.
      _searchFocus.unfocus();
    }
  }

  /// Appends a recognised character to the query. The controller's listener
  /// picks it up, so handwriting reuses the same debounced search path as
  /// typing rather than having its own.
  void _appendCharacter(String text) {
    _searchController.value = TextEditingValue(
      text: _searchController.text + text,
      selection: TextSelection.collapsed(
        offset: _searchController.text.length + text.length,
      ),
    );
  }

  /// Commits the current query to the recent-searches list.
  ///
  /// Called from the three points where a query has clearly stopped being a
  /// half-typed prefix: the user opened a result, submitted from the keyboard,
  /// or left a query with results on screen untouched for
  /// [_historyIdleDelay]. [HistoryService.record] collapses prefix runs, so
  /// the three firing in sequence still leaves one row.
  void _rememberQuery() {
    final text = _searchController.text.trim();
    if (text.isEmpty) return;
    unawaited(_history.record(text));
  }

  void _onSearchChanged() {
    final text = _searchController.text;
    _debounce?.cancel();
    _historyIdle?.cancel();

    if (text.trim().isEmpty) {
      setState(() {
        _query = '';
        _results = [];
        _partials = const [];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _query = text;
      _isLoading = true;
    });

    // Debounce so we don't hit the database on every keystroke. 60ms rather
    // than the original 120ms: the term/reading tier used to be a full table
    // scan (~37ms on desktop, several hundred on a low-end phone) and the
    // debounce was partly hiding it. Now that it plans as an index range scan
    // the query is ~0.02ms, so the debounce is the only delay left worth
    // feeling — it just needs to be long enough to skip intermediate
    // keystrokes, not long enough to absorb a scan.
    _debounce = Timer(const Duration(milliseconds: 60), () => _runSearch(text));
  }

  Future<void> _runSearch(String text) async {
    final query = text.trim();
    final results = await _dbService.searchEntries(query);
    if (!mounted || _searchController.text != text) return;

    // A Japanese query that matched nothing gets the second pass below, so the
    // spinner stays up over it. Otherwise "No results found" flashes on screen
    // for the query that is a moment away from being broken down into the
    // words it is made of.
    final decomposing = results.isEmpty && _decomposable(query, results) != null;
    setState(() {
      _results = results;
      _partials = const [];
      _isLoading = decomposing;
    });

    // Only a query that found something is worth remembering — a run of
    // no-result prefixes on the way to a real word isn't a search the user
    // would ever want to replay.
    _historyIdle?.cancel();
    if (results.isNotEmpty) _rememberQueryWhenSettled(text);

    unawaited(_findPartials(text, results));
  }

  /// Second pass for a query the dictionary can't match whole.
  ///
  /// Runs *after* the results are on screen rather than inside the search,
  /// because it costs a database round trip per word and the common case — a
  /// query that matched — throws the answer away. Making the results list wait
  /// on it would tax every keystroke to serve the few that need it.
  Future<void> _findPartials(
    String text,
    List<DictionaryEntry> results,
  ) async {
    final query = _decomposable(text.trim(), results);
    if (query == null) return;

    List<TokenMatch> matches;
    try {
      matches = await _lookup.decomposeQuery(query);
    } catch (e) {
      debugPrint('Query decomposition failed: $e');
      matches = const [];
    }
    if (!mounted || _searchController.text != text) return;

    // An all-kana query only gets to show a breakdown that accounts for the
    // whole of it. Greedy longest-match has no lookahead and, with no
    // ideographs to anchor a boundary, kana is where it is least reliable —
    // and a wrong split here doesn't look wrong, it looks like an answer:
    // every leftover fragment is a real word, so ち becomes 血 "blood" under
    // a heading that says this is what the query is made of. Leftovers are
    // the tell, so a breakdown that leaves any are dropped whole. Kanji input
    // keeps its partial breakdowns: 是正処置X still owes the user 是正 + 処置.
    if (!JpText.hasKanji(query) && !_coversWholeQuery(query, matches)) {
      matches = const [];
    }

    // Drop anything the results already show. Typing 楽 segments to 楽, and a
    // "partial matches" card repeating the card directly above it is noise.
    // Keyed by `sequence` to match the collapse `searchEntries` does, with the
    // id as the fallback for the few rows that have no sequence.
    final shown = {for (final e in results) e.sequence ?? -e.id};
    final partials = matches
        .where((m) => !shown.contains(m.best.sequence ?? -m.best.id))
        .toList();

    setState(() {
      _partials = partials;
      _isLoading = false;
    });

    // A query that only decomposed still answered the user, so it is still
    // worth remembering — 是正処置 is exactly the kind of word someone looks
    // up twice.
    if (results.isEmpty && partials.isNotEmpty) {
      _rememberQueryWhenSettled(text);
    }
  }

  /// True when [matches] account for every character of [query] that could
  /// belong to a word, leaving nothing skipped between or around them.
  bool _coversWholeQuery(String query, List<TokenMatch> matches) {
    if (matches.isEmpty) return false;
    var next = 0;
    for (final match in matches) {
      // Anything skipped on the way to this match had better not be a word
      // character — punctuation and spaces are fine to step over.
      if (JpText.nextWordStart(query.substring(next, match.start), 0) >= 0) {
        return false;
      }
      next = match.end;
    }
    return JpText.nextWordStart(query, next) < 0;
  }

  /// The text to break down, or null if this query shouldn't be.
  ///
  /// Japanese input is taken as typed. Romaji is converted first — "tabemono"
  /// is as unmatchable as 食べ物 was — but only once the search has come back
  /// empty, and that asymmetry is deliberate: the kana behind romaji is a
  /// *guess*, the same guess whose prefix matches `searchEntries` demotes
  /// below the gloss tier. "china" converts to ちな, a real word, so
  /// decomposing an English query that already found its answer would staple
  /// a Japanese word onto it that the user never asked about.
  String? _decomposable(String query, List<DictionaryEntry> results) {
    if (JpText.hasJapanese(query)) return query;
    if (results.isNotEmpty) return null;
    final folded = query.toLowerCase();
    if (!Romaji.looksLikeRomaji(folded)) return null;
    final kana = Romaji.toHiragana(folded);
    // Every character has to have converted. `toHiragana` is best-effort and
    // passes what it can't map straight through, so an English phrase comes
    // back as あcちおn cおrrecちゔぇ — which segments into a round trip per
    // character and can only ever confirm junk.
    if (kana == folded || !kana.runes.every(JpText.isWordChar)) return null;
    return kana;
  }

  /// Commits [text] to history once it has sat unchanged for
  /// [_historyIdleDelay].
  void _rememberQueryWhenSettled(String text) {
    _historyIdle?.cancel();
    _historyIdle = Timer(_historyIdleDelay, () {
      if (_searchController.text == text) _rememberQuery();
    });
  }

  /// Replays a remembered query. This only refills the field — the controller's
  /// listener runs the search, so history reuses the same debounced path as
  /// typing and handwriting rather than having its own.
  void _replayQuery(String query) {
    _searchController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _searchFocus.unfocus();
  }

  void _openScanner() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OcrScreen()),
    );
  }

  void _openFlashcards() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FlashcardsScreen()),
    );
  }

  void _openAnkiDecks() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AnkiDecksScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('JapanoDict'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      ),
      drawer: _buildDrawer(context),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _rememberQuery(),
                decoration: InputDecoration(
                  labelText: 'Search Japanese words, kanji, or English',
                  hintText: 'Try: こんにちは, 漢字, or hello',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_query.isNotEmpty)
                        IconButton(
                          onPressed: _searchController.clear,
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear',
                        ),
                      IconButton(
                        onPressed: _toggleDrawPad,
                        icon: const Icon(Icons.draw_outlined),
                        tooltip: 'Draw kanji',
                        color: _showDrawPad
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ],
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                // On a first launch (or after a _dbVersion bump) the dictionary
                // is still being unpacked and *nothing* can be searched yet.
                // Without this the screen looked idle and a typed query simply
                // hung on the awaited copy, which reads as the app being broken.
                child: ValueListenableBuilder<DbPreparation>(
                  valueListenable: DatabaseService.preparation,
                  builder: (context, prep, child) {
                    if (prep.copying) return _buildPreparing(context, prep);
                    return child!;
                  },
                  child: _query.isEmpty
                      ? _buildHome(context)
                      : _buildResults(context),
                ),
              ),
            ),
            if (_showDrawPad)
              SizedBox(
                // Roughly soft-keyboard height, so toggling between typing and
                // drawing doesn't make the results list jump around.
                height: (MediaQuery.sizeOf(context).height * 0.42)
                    .clamp(260.0, 380.0),
                child: KanjiDrawPad(
                  onCharacterSelected: _appendCharacter,
                  onClose: () => setState(() => _showDrawPad = false),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The empty-query surface: recent searches above, the two headline features
  /// below.
  ///
  /// The actions take a fixed slice off the bottom and history gets the rest,
  /// rather than the list sizing itself — a list that grew downwards would walk
  /// the buttons off the screen as history filled up. The slice is measured
  /// against the space actually available (not the window), so opening the draw
  /// pad shrinks it in step; the clamp keeps the tiles legible on a short
  /// screen and stops them ballooning on a tall one.
  Widget _buildHome(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionsHeight =
            (constraints.maxHeight * 0.20).clamp(112.0, 168.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _history.isEmpty
                  ? _buildWelcome(context)
                  : _buildHistory(context),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: actionsHeight,
              child: _buildQuickActions(context),
            ),
            const SizedBox(height: 12),
            _buildAnkiAction(context),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  Widget _buildHistory(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _history.entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.history,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              'Recent',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: _confirmClearHistory,
              child: const Text('Clear all'),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: entries.length,
            itemBuilder: (context, index) => _buildHistoryRow(entries[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryRow(String query) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => _replayQuery(query),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                query,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            IconButton(
              onPressed: () => _history.remove(query),
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Remove from history',
              visualDensity: VisualDensity.compact,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear search history?'),
        content: const Text('This removes every recent search. It can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _history.clear();
  }

  /// The two features that aren't reachable by typing. They keep the brand's
  /// red/yellow pairing rather than both taking `primaryContainer`, so the
  /// pair reads as two choices instead of one button split in half.
  Widget _buildQuickActions(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _buildActionTile(
            icon: Icons.document_scanner_outlined,
            label: 'Scan text',
            subtitle: 'Look up words in a photo',
            background: scheme.primaryContainer,
            foreground: scheme.onPrimaryContainer,
            onTap: _openScanner,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionTile(
            icon: Icons.style_outlined,
            label: 'Flashcards',
            subtitle: 'JLPT and kanji decks',
            background: scheme.secondaryContainer,
            foreground: scheme.onSecondaryContainer,
            onTap: _openFlashcards,
          ),
        ),
      ],
    );
  }

  /// The Anki tile sits *below* the pair above, full width, and outside their
  /// fixed-height box.
  ///
  /// Not a third column in that Row: three tiles across leaves each too narrow
  /// for its subtitle, and this is the one that needs explaining — "Anki
  /// decks" alone doesn't say what the app will do with them. It also can't go
  /// inside the sized box, because that height was measured for one row of
  /// tiles; sizing to its own content keeps the two independent.
  Widget _buildAnkiAction(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _buildActionTile(
      icon: Icons.inventory_2_outlined,
      label: 'Anki decks',
      subtitle: 'Look up the words in your own cards',
      background: scheme.tertiaryContainer,
      foreground: scheme.onTertiaryContainer,
      onTap: _openAnkiDecks,
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color background,
    required Color foreground,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: background,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26, color: foreground),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWelcome(BuildContext context) {
    return SingleChildScrollView(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AppLogo(size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Welcome to JapanoDict!',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Start typing above to search — results update as you type. '
                'Your recent searches will show up here.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shown while the bundled dictionary is being unpacked out of the APK.
  ///
  /// Deliberately says "Setting up" and not "Downloading": this is a local
  /// copy from the installed APK to app storage and needs no network at all,
  /// and the wrong word here would have people blaming their connection.
  ///
  /// The bar is determinate whenever the native side could report the asset's
  /// size, which is the normal case — a one-off wait of several seconds on a
  /// mid-range phone is exactly where a real percentage is worth the wiring.
  Widget _buildPreparing(BuildContext context, DbPreparation prep) {
    final theme = Theme.of(context);
    final fraction = prep.fraction;
    const mb = 1024 * 1024;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const AppLogo(size: 72),
          const SizedBox(height: 20),
          Text('Setting up the dictionary', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Unpacking the offline dictionary. This happens once.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          if (fraction != null) ...[
            const SizedBox(height: 12),
            Text(
              '${(fraction * 100).round()}%  ·  '
              '${(prep.copiedBytes / mb).toStringAsFixed(0)} of '
              '${(prep.totalBytes / mb).toStringAsFixed(0)} MB',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_isLoading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_results.isEmpty && _partials.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No results found for "$_query"',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Try different keywords or check your spelling',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    // Results, then the partial-match section as a heading plus its own cards
    // in the same scroll view. One list rather than two stacked ones: the
    // partials are the *tail* of the answer, and a separate pane for them
    // would either take space away from real results or need its own scrollbar
    // for what is usually two cards.
    final partialsStart = _results.length + 1;
    return ListView.builder(
      itemCount: _results.length + (_partials.isEmpty ? 0 : 1 + _partials.length),
      // Result cards are stateless — nothing in one is worth preserving when it
      // scrolls out of view — so the default keep-alive machinery is pure
      // overhead on a list that can be 50 cards long.
      addAutomaticKeepAlives: false,
      itemBuilder: (context, index) {
        if (index < _results.length) return _buildResultCard(_results[index]);
        if (index < partialsStart) return _buildPartialHeader(context);
        final match = _partials[index - partialsStart];
        return _buildResultCard(match.best, from: match);
      },
    );
  }

  /// Heading over the decomposition, so a partial match can never be read as
  /// an entry for what was actually typed.
  Widget _buildPartialHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: _results.isEmpty ? 4 : 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.call_split,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Partial matches',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _results.isEmpty
                  ? 'No entry for "$_query", but it is made of these words'
                  : 'Words found inside "$_query"',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }


  /// How many senses a result card shows before collapsing the rest into a
  /// "+N more" line. The detail sheet has the full list, so this only has to
  /// be enough to tell two similar entries apart.
  static const int _glossPreviewCount = 3;

  /// A search result, tuned for density — the whole point of live search is
  /// scanning a list, so a card that fits three to a screen is working against
  /// itself. Same information as before, laid out to cost fewer lines:
  ///
  /// - reading sits **beside** the term instead of under it, saving a line on
  ///   every card that has one (most of them);
  /// - parts of speech are a caption line rather than [Chip]s. Chips carry
  ///   ~48dp of Material tap-target height each for something that isn't
  ///   tappable, which was the single biggest waste in the old card.
  ///
  /// [from] marks the card as a *partial* match and names the piece of the
  /// query it came from — see [_buildPartialHeader]. The dictionary form stays
  /// the headword even then: what was typed is still in the search box a
  /// centimetre above, and leading with the surface (as the scan screen does,
  /// where there is no search box) crowded the reading and badges off the row.
  Widget _buildResultCard(DictionaryEntry entry, {TokenMatch? from}) {
    final theme = Theme.of(context);
    final reading = entry.reading;
    final hasReading = reading != null && reading.isNotEmpty;
    final glosses = entry.glossList;
    final hidden = glosses.length - _glossPreviewCount;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () {
          // Opening a result is the clearest signal that the query was a real
          // search and not a prefix on the way to one.
          _rememberQuery();
          showEntryDetailSheet(context, entry);
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                // Centred, not baseline-aligned: the badges are boxes with no
                // text baseline of their own, so baseline alignment drops them
                // onto their bottom edge and they sit low against the term.
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
              // Named only when it adds something: the surface is worth
              // spelling out when it is a conjugation (寒かった → 寒い) or a
              // slice of a longer query, but not when it is just the reading
              // already sitting beside the headword.
              if (from != null &&
                  from.surface != entry.term &&
                  (from.isInflected || from.surface != entry.reading))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    [
                      'from ${from.surface}',
                      ...from.reasons,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (entry.partsOfSpeechList.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    entry.partsOfSpeechList.take(3).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              ...glosses.take(_glossPreviewCount).map((gloss) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('• ', style: theme.textTheme.bodyMedium),
                      Expanded(
                        // A handful of entries have a paragraph-long sense;
                        // without a clamp one of them makes a card taller than
                        // the five around it put together.
                        child: Text(
                          gloss,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              if (hidden > 0)
                Text(
                  '+ $hidden more',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
            ),
            // Mark beside the wordmark rather than stacked above it: a
            // DrawerHeader is a fixed 160dp, and a stacked logo pushes the two
            // lines of text off the bottom as soon as the system text scale is
            // turned up.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const AppLogo(size: 56),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        'JapanoDict',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Japanese dictionary',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.document_scanner_outlined),
            title: const Text('Scan text'),
            subtitle: const Text('Look up words in a photo'),
            onTap: () {
              Navigator.pop(context);
              _openScanner();
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.style_outlined),
            title: const Text('Flashcards'),
            subtitle: const Text('JLPT vocabulary and kanji decks'),
            onTap: () {
              Navigator.pop(context);
              _openFlashcards();
            },
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Anki decks'),
            subtitle: const Text('Look up the words in your own cards'),
            onTap: () {
              Navigator.pop(context);
              _openAnkiDecks();
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.copyright_outlined),
            title: const Text('Credits & Licences'),
            subtitle: const Text('Dictionary data sources'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CreditsScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
import '../services/history_service.dart';
import 'credits_screen.dart';
import 'anki_decks_screen.dart';
import 'flashcards_screen.dart';
import 'ocr_screen.dart';
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

  Timer? _debounce;
  Timer? _historyIdle;
  List<DictionaryEntry> _results = [];
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
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _query = text;
      _isLoading = true;
    });

    // Debounce so we don't hit the database on every keystroke.
    _debounce = Timer(const Duration(milliseconds: 120), () => _runSearch(text));
  }

  Future<void> _runSearch(String text) async {
    final results = await _dbService.searchEntries(text.trim());
    if (!mounted || _searchController.text != text) return;
    setState(() {
      _results = results;
      _isLoading = false;
    });

    // Only a query that found something is worth remembering — a run of
    // no-result prefixes on the way to a real word isn't a search the user
    // would ever want to replay.
    _historyIdle?.cancel();
    if (results.isNotEmpty) {
      _historyIdle = Timer(_historyIdleDelay, () {
        if (_searchController.text == text) _rememberQuery();
      });
    }
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
                child: _query.isEmpty ? _buildHome(context) : _buildResults(context),
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
              Text(
                'Welcome to JapanoDict! 🇯🇵',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
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

  Widget _buildResults(BuildContext context) {
    if (_isLoading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_results.isEmpty) {
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

    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) => _buildResultCard(_results[index]),
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
  Widget _buildResultCard(DictionaryEntry entry) {
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

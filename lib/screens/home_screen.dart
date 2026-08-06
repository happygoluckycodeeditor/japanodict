import 'dart:async';

import 'package:flutter/material.dart';
import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
import 'credits_screen.dart';
import 'flashcards_screen.dart';
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

  Timer? _debounce;
  List<DictionaryEntry> _results = [];
  bool _isLoading = false;
  String _query = '';
  bool _showDrawPad = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _searchFocus.addListener(_onSearchFocusChanged);
    // Start the (possibly first-run) database copy immediately rather than
    // on the first search, so it's more likely to be ready by the time the
    // user finishes typing.
    unawaited(_dbService.database);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.dispose();
    super.dispose();
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

  void _onSearchChanged() {
    final text = _searchController.text;
    _debounce?.cancel();

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
                child: _query.isEmpty ? _buildWelcome(context) : _buildResults(context),
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
                'Start typing above to search — results update as you type.',
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

  Widget _buildResultCard(DictionaryEntry entry) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => showEntryDetailSheet(context, entry),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      entry.term,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
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
              if (entry.reading != null && entry.reading!.isNotEmpty)
                Text(
                  entry.reading!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
              const SizedBox(height: 8),
              if (entry.partsOfSpeechList.isNotEmpty)
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: entry.partsOfSpeechList.take(3).map((pos) {
                    return Chip(
                      label: Text(pos, style: const TextStyle(fontSize: 11)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    );
                  }).toList(),
                ),
              const SizedBox(height: 8),
              ...entry.glossList.take(3).map((gloss) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• ', style: TextStyle(fontSize: 16)),
                      Expanded(
                        child: Text(gloss, style: Theme.of(context).textTheme.bodyMedium),
                      ),
                    ],
                  ),
                );
              }),
              if (entry.glossList.length > 3)
                Text(
                  '+ ${entry.glossList.length - 3} more definitions',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
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
            leading: const Icon(Icons.style_outlined),
            title: const Text('Flashcards'),
            subtitle: const Text('JLPT vocabulary and kanji decks'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FlashcardsScreen()),
              );
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

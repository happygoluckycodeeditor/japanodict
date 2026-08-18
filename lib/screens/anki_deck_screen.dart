import 'dart:async';

import 'package:flutter/material.dart';

import '../models/anki_note.dart';
import '../services/anki_library_service.dart';
import 'anki_card_screen.dart';

/// The notes inside one imported deck.
///
/// Notes are paged in as the list is scrolled rather than loaded whole: shared
/// decks routinely run to tens of thousands of notes, and holding every field
/// of every one of them in memory to show a screenful of twelve is the kind of
/// thing that only shows up as a problem on someone else's phone.
class AnkiDeckScreen extends StatefulWidget {
  const AnkiDeckScreen({super.key, required this.deck});

  final AnkiDeck deck;

  @override
  State<AnkiDeckScreen> createState() => _AnkiDeckScreenState();
}

class _AnkiDeckScreenState extends State<AnkiDeckScreen> {
  static const int _pageSize = 60;

  final AnkiLibraryService _library = AnkiLibraryService();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();

  /// Matches the home screen's search debounce. Without it every keystroke
  /// fires a COUNT and a page query against a table that can hold tens of
  /// thousands of rows.
  static const Duration _debounce = Duration(milliseconds: 200);

  Timer? _filterTimer;

  final List<AnkiNote> _notes = <AnkiNote>[];
  int _matchCount = 0;
  bool _loading = true;
  bool _hasMore = true;

  /// Bumped on every new filter. A page that arrives after the query moved on
  /// belongs to the previous list and is dropped rather than appended — the
  /// same guard the home screen's debounced search needs, for the same reason.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _search.addListener(_onQueryChanged);
    _reload();
  }

  @override
  void dispose() {
    _filterTimer?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _filterTimer?.cancel();
    _filterTimer = Timer(_debounce, _reload);
  }

  void _onScroll() {
    if (!_hasMore || _loading) return;
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _notes.clear();
      _loading = true;
      _hasMore = true;
    });
    final query = _search.text;
    final count = await _library.noteCount(widget.deck.id, query: query);
    if (!mounted || generation != _generation) return;
    _matchCount = count;
    await _loadMore(generation: generation);
  }

  Future<void> _loadMore({int? generation}) async {
    final current = generation ?? _generation;
    if (mounted) setState(() => _loading = true);
    final page = await _library.notes(
      widget.deck.id,
      limit: _pageSize,
      offset: _notes.length,
      query: _search.text,
    );
    if (!mounted || current != _generation) return;
    setState(() {
      _notes.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  void _openNote(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnkiCardScreen(
          deck: widget.deck,
          notes: List<AnkiNote>.unmodifiable(_notes),
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtering = _search.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deck.leafName, overflow: TextOverflow.ellipsis),
        backgroundColor: theme.colorScheme.primaryContainer,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Find a card in this deck',
                  prefixIcon: const Icon(Icons.filter_list),
                  suffixIcon: filtering
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: _search.clear,
                        )
                      : null,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  filtering
                      ? '$_matchCount of ${widget.deck.noteCount} cards'
                      : '${widget.deck.noteCount} cards',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Expanded(child: _buildList(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_notes.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _search.text.trim().isEmpty
                ? 'This deck has no cards left in it.'
                : 'No card in this deck contains "${_search.text.trim()}".',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      // One extra row for the tail spinner while the next page is in flight.
      itemCount: _notes.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _notes.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _buildNoteTile(theme, _notes[index], index);
      },
    );
  }

  Widget _buildNoteTile(ThemeData theme, AnkiNote note, int index) {
    final subheading = note.subheading;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _openNote(index),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.heading,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (subheading.isNotEmpty)
                      Text(
                        subheading,
                        // Two lines, matching the search result cards: a few
                        // note types put a paragraph in a notes field, and one
                        // card taller than the five around it wrecks scanning.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (!note.hasJapanese)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.translate_outlined,
                    size: 18,
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

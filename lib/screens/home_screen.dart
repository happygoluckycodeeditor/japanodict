import 'dart:async';

import 'package:flutter/material.dart';
import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
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
            const Icon(Icons.search_off, size: 64, color: Colors.grey),
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
        onTap: () => _showEntryDetails(entry),
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
                    _commonBadge(context),
                  ],
                  if (entry.jlpt != null) ...[
                    const SizedBox(width: 6),
                    _jlptBadge(context, entry.jlpt!),
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

  void _showEntryDetails(DictionaryEntry entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return SingleChildScrollView(
              controller: scrollController,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            entry.term,
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                        if (entry.isCommon) ...[
                          const SizedBox(width: 10),
                          _commonBadge(context),
                        ],
                        if (entry.jlpt != null) ...[
                          const SizedBox(width: 6),
                          _jlptBadge(context, entry.jlpt!),
                        ],
                      ],
                    ),
                    if (entry.reading != null && entry.reading!.isNotEmpty)
                      Text(
                        entry.reading!,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    const SizedBox(height: 16),
                    if (entry.partsOfSpeechList.isNotEmpty) ...[
                      Text(
                        'Parts of Speech',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: entry.partsOfSpeechList.map((pos) => Chip(label: Text(pos))).toList(),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      'Definitions',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 8),
                    ...entry.glossList.asMap().entries.map((e) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${e.key + 1}. ',
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            Expanded(
                              child: Text(e.value, style: Theme.of(context).textTheme.bodyLarge),
                            ),
                          ],
                        ),
                      );
                    }),
                    _buildExamples(context, entry),
                    if (entry.tagsList.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Tags',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: entry.tagsList.map((tag) {
                          return Chip(
                            label: Text(tag),
                            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _commonBadge(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF8DC63F),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'common',
        style: TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _jlptBadge(BuildContext context, String level) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF909DC0),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        level.toLowerCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildExamples(BuildContext context, DictionaryEntry entry) {
    return FutureBuilder<List<ExampleSentence>>(
      future: _dbService.getExamples(entry.id),
      builder: (context, snapshot) {
        final examples = snapshot.data ?? const [];
        if (examples.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Text(
              'Examples',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...examples.map((ex) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ex.ja,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (ex.en.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          ex.en,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

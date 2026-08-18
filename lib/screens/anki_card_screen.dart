import 'package:flutter/material.dart';

import '../models/anki_note.dart';
import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
import '../services/text_lookup_service.dart';
import '../utils/jp_text.dart';
import '../widgets/entry_badges.dart';
import '../widgets/entry_detail_sheet.dart';
import 'kanji_detail_screen.dart';

/// One Anki note, with every dictionary word inside it broken out.
///
/// This is the point of the whole feature, and it is the OCR screen's second
/// half re-pointed at a different source of running text: [TextLookupService]
/// does not care whether a sentence came from a photograph or from somebody's
/// note field. Which means an Anki card gets the deinflection pass for free —
/// a card reading 昨日は寒かったです surfaces 寒い, not nothing.
///
/// A pushed route rather than a bottom sheet, deliberately: tapping a word
/// here opens the entry sheet, and that sheet's kanji panel pushes the kanji
/// screen, whose compound list opens another entry sheet. Stacking sheets on
/// sheets has no Back story; a route does.
class AnkiCardScreen extends StatefulWidget {
  const AnkiCardScreen({
    super.key,
    required this.deck,
    required this.notes,
    required this.initialIndex,
  });

  final AnkiDeck deck;

  /// The notes currently loaded by the deck screen, so the arrows can walk the
  /// deck without going back to the list. Bounded by what has been paged in —
  /// stepping past the end is simply not offered.
  final List<AnkiNote> notes;

  final int initialIndex;

  @override
  State<AnkiCardScreen> createState() => _AnkiCardScreenState();
}

class _AnkiCardScreenState extends State<AnkiCardScreen> {
  final TextLookupService _lookup = TextLookupService();
  final DatabaseService _db = DatabaseService();

  late int _index = widget.initialIndex;

  List<TokenMatch> _words = const [];
  List<KanjiEntry> _kanji = const [];
  bool _analyzing = true;

  /// Guards against a slow analysis for card 4 landing after the user has
  /// already stepped to card 5.
  int _generation = 0;

  AnkiNote get _note => widget.notes[_index];

  @override
  void initState() {
    super.initState();
    // `initial` because the reset below is a setState, and the first run
    // happens before this widget has ever built — the fields already hold
    // those values, so there is nothing to notify about.
    _analyze(initial: true);
  }

  Future<void> _analyze({bool initial = false}) async {
    final generation = ++_generation;
    if (!initial) {
      setState(() {
        _analyzing = true;
        _words = const [];
        _kanji = const [];
      });
    }

    final note = _note;
    final words = <TokenMatch>[];
    // A word can legitimately appear in the expression field and again in the
    // example sentence; the list is a vocabulary index for the card, so it
    // reads better as one entry per word than as a faithful transcript.
    final seen = <String>{};

    for (final field in note.lookupFields) {
      // Fields are segmented one at a time, and one line at a time inside
      // that: the longest-match pass has no concept of where the text it was
      // handed stops being one thought, so joining a heading onto a sentence
      // invites a match straddling the join.
      for (final line in field.value.split('\n')) {
        if (!JpText.hasJapanese(line)) continue;
        final matches = await _lookup.segment(line);
        if (generation != _generation) return;
        for (final match in matches) {
          if (seen.add('${match.surface}|${match.best.id}')) words.add(match);
        }
      }
    }

    final japanese = note.japaneseFields.map((f) => f.value).join();
    final kanji = await _db.getKanjiForTerm(japanese);

    if (!mounted || generation != _generation) return;
    setState(() {
      _words = words;
      _kanji = kanji;
      _analyzing = false;
    });
  }

  void _step(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.notes.length) return;
    setState(() => _index = next);
    _analyze();
  }

  Future<void> _lookupCharacter(String text, int index) async {
    final match = await _lookup.lookupAt(text, index);
    if (!mounted) return;
    if (match == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No entry starting at ${text[index]}.')),
      );
      return;
    }
    _openWord(match);
  }

  void _openWord(TokenMatch match) {
    if (match.entries.length == 1) {
      showEntryDetailSheet(context, match.best);
      return;
    }
    _showAlternatives(match);
  }

  /// Offers every entry a surface could be rather than committing to the
  /// top-ranked one — with no sentence context the segmenter genuinely cannot
  /// tell 今日は (こんにちは) from 今日 + は.
  void _showAlternatives(TokenMatch match) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(match.surface),
              subtitle: Text('${match.entries.length} possible words'),
              dense: true,
            ),
            const Divider(height: 1),
            for (final entry in match.entries)
              ListTile(
                title: Text(_termWithReading(entry)),
                subtitle: Text(
                  entry.glossList.isEmpty ? '' : entry.glossList.first,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  showEntryDetailSheet(context, entry);
                },
              ),
          ],
        ),
      ),
    );
  }

  static String _termWithReading(DictionaryEntry entry) {
    final reading = entry.reading;
    if (reading == null || reading == entry.term) return entry.term;
    return '${entry.term}  $reading';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = _note;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.deck.leafName, overflow: TextOverflow.ellipsis),
            Text(
              'Card ${_index + 1} of ${widget.notes.length}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
        backgroundColor: theme.colorScheme.primaryContainer,
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous card',
            onPressed: _index > 0 ? () => _step(-1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next card',
            onPressed:
                _index < widget.notes.length - 1 ? () => _step(1) : null,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            for (var i = 0; i < note.fields.length; i++)
              if (note.fields[i].trim().isNotEmpty) _buildField(theme, note, i),
            if (note.tagList.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final tag in note.tagList)
                    Chip(
                      label: Text(tag, style: theme.textTheme.bodySmall),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            _buildWordsSection(theme),
            if (_kanji.isNotEmpty) ...[
              const SizedBox(height: 24),
              _buildSectionTitle(theme, 'Kanji'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final kanji in _kanji) _buildKanjiChip(theme, kanji),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildField(ThemeData theme, AnkiNote note, int index) {
    final value = note.fields[index];
    final japanese = JpText.hasJapanese(value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            note.labelFor(index).toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          // Japanese is rendered a character at a time so a tap carries an
          // index; everything else is ordinary selectable text, because there
          // is nothing in it to look up.
          if (japanese)
            for (final line in value.split('\n'))
              if (line.trim().isNotEmpty) _buildTappableLine(theme, line)
              else const SizedBox(height: 8)
          else
            SelectableText(value, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }

  /// The field text, one tappable character at a time.
  ///
  /// Per character rather than as a selection, because the lookup needs the
  /// tapped *index* — and a tap target the size of one kanji is the whole
  /// interaction.
  Widget _buildTappableLine(ThemeData theme, String text) {
    return Wrap(
      children: [
        for (var i = 0; i < text.length; i++)
          InkWell(
            onTap: JpText.isWordChar(text.codeUnitAt(i))
                ? () => _lookupCharacter(text, i)
                : null,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
              child: Text(
                text[i],
                style: theme.textTheme.titleLarge?.copyWith(
                  color: JpText.isWordChar(text.codeUnitAt(i))
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWordsSection(ThemeData theme) {
    if (_analyzing) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_words.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          _note.hasJapanese
              ? 'No dictionary words were found in this card. Tap a character '
                  'above to look it up directly.'
              : 'This card has no Japanese in it.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(theme, 'Words in this card (${_words.length})'),
        const SizedBox(height: 4),
        for (final word in _words) _buildWordCard(theme, word),
      ],
    );
  }

  Widget _buildSectionTitle(ThemeData theme, String title) {
    return Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildWordCard(ThemeData theme, TokenMatch word) {
    final entry = word.best;
    final reading = entry.reading;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _openWord(word),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      word.surface,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // The dictionary form only when it differs, so the user can
                  // see that 寒かった was found via 寒い.
                  if (word.isInflected && entry.term != word.surface) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_right_alt,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(entry.term, style: theme.textTheme.titleMedium),
                    ),
                  ],
                  const SizedBox(width: 8),
                  if (entry.isCommon) const CommonBadge(),
                  if (entry.jlpt != null) ...[
                    const SizedBox(width: 4),
                    JlptBadge(level: entry.jlpt!),
                  ],
                ],
              ),
              if (reading != null && reading != entry.term)
                Text(
                  reading,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                entry.glossList.isEmpty ? '' : entry.glossList.first,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              if (word.isInflected)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    word.reasons.join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKanjiChip(ThemeData theme, KanjiEntry kanji) {
    return ActionChip(
      // The character goes in the label rather than `avatar`: an avatar is a
      // small fixed-size circle, which clips a full-width CJK glyph.
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(kanji.literal, style: theme.textTheme.titleMedium),
          const SizedBox(width: 6),
          Text(
            kanji.meaningList.isEmpty ? '' : kanji.meaningList.first,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => KanjiDetailScreen(kanji: kanji)),
        );
      },
    );
  }
}

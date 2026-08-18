import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/anki_note.dart';
import '../services/anki_import_service.dart';
import '../services/anki_library_service.dart';
import 'anki_deck_screen.dart';

/// The user's imported Anki decks, and the way in for new ones.
///
/// Deliberately a separate surface from [FlashcardsScreen] rather than another
/// row on it. The built-in decks are review sessions over dictionary data the
/// app owns; these are somebody else's notes, in fields the app has never
/// seen, and the only thing it offers to do with them is *look words up*.
/// Filing them together would promise a study mode that isn't there.
class AnkiDecksScreen extends StatefulWidget {
  const AnkiDecksScreen({super.key});

  @override
  State<AnkiDecksScreen> createState() => _AnkiDecksScreenState();
}

class _AnkiDecksScreenState extends State<AnkiDecksScreen> {
  final AnkiLibraryService _library = AnkiLibraryService();
  final AnkiImportService _importer = AnkiImportService();

  late Future<List<AnkiDeck>> _decks;

  /// Non-null while an import is running; holds the latest progress line.
  String? _status;

  @override
  void initState() {
    super.initState();
    _decks = _library.decks();
  }

  void _refresh() {
    // A block body, not an arrow: `() => _decks = _library.decks()` returns the
    // assignment's value, which is a Future, and setState rejects that. The
    // assignment still lands, so the symptom is not a broken list — it is a
    // thrown assertion that _import()'s catch reports as "that deck could not
    // be imported" over an import that in fact succeeded.
    setState(() {
      _decks = _library.decks();
    });
  }

  Future<void> _import() async {
    final FilePickerResult? picked;
    try {
      // FileType.any rather than custom + allowedExtensions: Android filters
      // by MIME type, and `.apkg` has no registered one, so a custom filter
      // resolves to nothing and can leave the picker showing an empty folder
      // with the file plainly sitting in it. Filtering is done below instead,
      // where a rejected file can be explained.
      picked = await FilePicker.pickFiles(withData: false);
    } catch (e) {
      _showMessage('Could not open the file picker: $e');
      return;
    }
    if (!mounted || picked == null || picked.files.isEmpty) return;

    final file = picked.files.first;
    final path = file.path;
    if (path == null) {
      _showMessage('That file could not be read from storage.');
      return;
    }

    final extension = p.extension(file.name).replaceFirst('.', '').toLowerCase();
    if (!AnkiImportService.supportedExtensions.contains(extension)) {
      _showMessage(
        'JapanoDict reads .apkg deck packages and plain-text exports — '
        '"${file.name}" is neither.',
      );
      return;
    }

    setState(() => _status = 'Opening ${file.name}…');
    try {
      final workDirectory = await getTemporaryDirectory();
      final parsed = await _importer.parse(
        path,
        fileName: file.name,
        workDirectory: workDirectory,
        onProgress: (status) {
          if (mounted) setState(() => _status = status);
        },
      );
      if (!mounted) return;

      // A package can hold a whole deck tree, and a .colpkg holds the user's
      // entire collection. Importing all of it unasked would bury the two
      // decks they actually wanted in fifty they didn't.
      final chosen = parsed.length == 1
          ? parsed
          : await _chooseDecks(parsed);
      if (!mounted || chosen == null || chosen.isEmpty) {
        setState(() => _status = null);
        return;
      }

      for (final deck in chosen) {
        await _library.saveDeck(
          deck,
          source: file.name,
          onProgress: (status) {
            if (mounted) setState(() => _status = '${deck.name}: $status');
          },
        );
      }
      if (!mounted) return;
      setState(() => _status = null);
      _refresh();
      final noteCount = chosen.fold<int>(0, (sum, d) => sum + d.notes.length);
      _showMessage(
        chosen.length == 1
            ? 'Imported ${chosen.first.name} — $noteCount notes.'
            : 'Imported ${chosen.length} decks — $noteCount notes.',
      );
    } on AnkiImportException catch (e) {
      if (!mounted) return;
      setState(() => _status = null);
      _showImportProblem(e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = null);
      _showMessage('That deck could not be imported: $e');
    }
  }

  /// Lets the user pick which of a multi-deck package to keep. Everything is
  /// ticked to begin with — the common case is a deck with subdecks, where
  /// wanting all of them is the norm.
  Future<List<ImportedDeck>?> _chooseDecks(List<ImportedDeck> decks) {
    final selected = decks.toSet();
    return showDialog<List<ImportedDeck>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Which decks?'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final deck in decks)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(deck),
                    title: Text(deck.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${deck.notes.length} notes'),
                    onChanged: (checked) => setDialogState(() {
                      if (checked ?? false) {
                        selected.add(deck);
                      } else {
                        selected.remove(deck);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                decks.where(selected.contains).toList(),
              ),
              child: const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }

  /// Import failures get a dialog rather than a snackbar: the useful ones
  /// carry an instruction ("re-export with…") that takes longer to read than a
  /// snackbar stays on screen.
  void _showImportProblem(AnkiImportException error) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Couldn\'t import that deck'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(error.message),
            if (error.detail != null) ...[
              const SizedBox(height: 12),
              Text(
                error.detail!,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(AnkiDeck deck) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${deck.leafName}?'),
        content: Text(
          '${deck.noteCount} notes will be removed from JapanoDict. Your Anki '
          'collection is not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _library.deleteDeck(deck.id);
    if (mounted) _refresh();
  }

  void _openDeck(AnkiDeck deck) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AnkiDeckScreen(deck: deck)),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final importing = _status != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Anki decks'),
        backgroundColor: theme.colorScheme.primaryContainer,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: importing ? null : _import,
        icon: const Icon(Icons.add),
        label: const Text('Import deck'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (importing) _buildProgress(theme),
            Expanded(
              child: FutureBuilder<List<AnkiDeck>>(
                future: _decks,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  // Distinguished from "no decks" on purpose: the empty state
                  // is an invitation to import, and showing it to someone whose
                  // library merely failed to open reads as data loss.
                  if (snapshot.hasError) return _buildError(theme);
                  final decks = snapshot.data ?? const <AnkiDeck>[];
                  if (decks.isEmpty) return _buildEmptyState(theme);
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    itemCount: decks.length,
                    itemBuilder: (context, index) =>
                        _buildDeckTile(theme, decks[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress(ThemeData theme) {
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _status ?? '',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeckTile(ThemeData theme, AnkiDeck deck) {
    final parent = deck.parentName;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _openDeck(deck),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.tertiaryContainer,
          child: Icon(
            Icons.inventory_2_outlined,
            color: theme.colorScheme.onTertiaryContainer,
          ),
        ),
        title: Text(deck.leafName),
        subtitle: Text(
          [
            if (parent != null) parent,
            '${deck.noteCount} notes',
            '${deck.source} · ${_formatDate(deck.importedAt)}',
          ].join('\n'),
          style: theme.textTheme.bodySmall,
        ),
        isThreeLine: true,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Remove deck',
          onPressed: () => _confirmDelete(deck),
        ),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Your imported decks could not be opened.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Nothing has been deleted — this is a problem reading the file, '
              'not the decks themselves.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _refresh,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 96),
      children: [
        Icon(
          Icons.inventory_2_outlined,
          size: 64,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Bring your own deck',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Import an Anki deck and JapanoDict will find the Japanese words in '
          'every card, so you can look one up without leaving the card.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Exporting from Anki',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _step(theme, '1', 'In Anki, right-click the deck → Export.'),
                _step(
                  theme,
                  '2',
                  'Choose "Anki Deck Package (.apkg)" and tick '
                      '"Support older Anki versions".',
                ),
                _step(
                  theme,
                  '3',
                  'Save it to this phone, then tap Import deck below.',
                ),
                const SizedBox(height: 12),
                Text(
                  'That checkbox matters: without it Anki compresses the deck '
                  'in a format JapanoDict can\'t open. A plain-text export '
                  '(.txt or .csv) always works too.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Cards are stored as text only — images and audio are skipped, and '
          'nothing is sent anywhere.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Widget _step(ThemeData theme, String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '$number.',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Hand-rolled rather than pulling in `intl` for one line of output.
  static String _formatDate(DateTime date) {
    return '${date.day} ${_months[date.month - 1]} ${date.year}';
  }
}

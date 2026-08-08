import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
import '../services/ocr_service.dart';
import '../services/text_lookup_service.dart';
import '../utils/jp_text.dart';
import '../widgets/entry_badges.dart';
import '../widgets/entry_detail_sheet.dart';
import 'kanji_detail_screen.dart';

/// Scan a photo and look up the Japanese in it.
///
/// Still images only — pick from the gallery or take one. There is
/// deliberately no live camera stream: a frozen frame is what makes the
/// tap-a-word interaction possible at all, and it keeps the screen off the
/// per-frame recognition budget entirely.
///
/// The screen splits into the photo with a tappable box per recognised line,
/// and a panel showing what the selected line contains. Words come from
/// [TextLookupService], not from ML Kit — see [OcrLine] for why the
/// recogniser's own sub-line boundaries can't be used.
class OcrScreen extends StatefulWidget {
  const OcrScreen({super.key});

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen> {
  final ImagePicker _picker = ImagePicker();
  final OcrService _ocr = OcrService();
  final TextLookupService _lookup = TextLookupService();
  final DatabaseService _db = DatabaseService();

  File? _image;
  ImageProvider? _provider;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  /// Pixel dimensions of the picked file. The OCR boxes are in this space, so
  /// nothing can be drawn until it's known.
  Size? _imageSize;

  OcrResult? _result;
  bool _recognizing = false;

  OcrLine? _selectedLine;
  List<TokenMatch> _words = const [];
  List<KanjiEntry> _kanji = const [];
  bool _analyzing = false;

  @override
  void dispose() {
    _detachImageStream();
    // Frees the native recogniser; it is rebuilt lazily on the next scan.
    _ocr.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: source,
        // Capping the long edge does two jobs: it bounds the decoded bitmap
        // (a 12MP phone photo is ~48MB in memory just to display), and it
        // makes image_picker re-encode the file so what ML Kit reads and what
        // Flutter draws are the same pixels in the same orientation. 2000px
        // is still far more resolution than text recognition needs.
        maxWidth: 2000,
        maxHeight: 2000,
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not open the ${source == ImageSource.camera ? 'camera' : 'gallery'}.');
      return;
    }
    if (picked == null || !mounted) return;

    setState(() {
      _image = File(picked!.path);
      _provider = FileImage(_image!);
      _imageSize = null;
      _result = null;
      _recognizing = true;
      _selectedLine = null;
      _words = const [];
      _kanji = const [];
    });

    _attachImageStream();

    final result = await _ocr.recognizeFile(picked.path);
    if (!mounted) return;
    setState(() {
      _result = result;
      _recognizing = false;
    });

    // With a single line there is nothing to choose between, so skip the
    // "now tap a box" step the user would only ever answer one way.
    final usable = result.lines.where((l) => JpText.hasJapanese(l.text)).toList();
    if (usable.length == 1) _selectLine(usable.first);
  }

  /// Reads the picked image's pixel size off the provider that will display
  /// it, so the file is decoded once rather than once for measurement and
  /// again for drawing.
  void _attachImageStream() {
    _detachImageStream();
    final provider = _provider;
    if (provider == null) return;

    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener((info, _) {
      final size = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
      if (!mounted) return;
      setState(() => _imageSize = size);
    }, onError: (Object error, StackTrace? stack) {
      if (!mounted) return;
      _showMessage('Could not read that image.');
    });
    stream.addListener(listener);
    _imageStream = stream;
    _imageListener = listener;
  }

  void _detachImageStream() {
    final stream = _imageStream;
    final listener = _imageListener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _imageStream = null;
    _imageListener = null;
  }

  Future<void> _selectLine(OcrLine line) async {
    setState(() {
      _selectedLine = line;
      _words = const [];
      _kanji = const [];
      _analyzing = true;
    });

    final words = await _lookup.segment(line.text);
    final kanji = await _db.getKanjiByLiterals(
      DatabaseService.extractKanji(line.text),
    );
    if (!mounted || _selectedLine != line) return;
    setState(() {
      _words = words;
      _kanji = kanji;
      _analyzing = false;
    });
  }

  /// Looks up the word starting at [index] of the selected line.
  ///
  /// The escape hatch for greedy segmentation: when [_words] splits 今日は as
  /// the greeting こんにちは, tapping the 今 finds 今日 instead.
  Future<void> _lookupCharacter(String text, int index) async {
    final match = await _lookup.lookupAt(text, index);
    if (!mounted) return;
    if (match == null) {
      _showMessage('No entry starting at ${text[index]}.');
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

  /// Offers every entry a surface could be, rather than silently committing to
  /// the top-ranked one — with no sentence context the scanner genuinely
  /// cannot tell 今日は (こんにちは) from 今日 + は.
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
                title: Text('${entry.term}${entry.reading != null && entry.reading != entry.term ? '  ${entry.reading}' : ''}'),
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan text'),
        actions: [
          if (_image != null)
            IconButton(
              icon: const Icon(Icons.photo_camera_outlined),
              tooltip: 'New photo',
              onPressed: () => _pick(ImageSource.camera),
            ),
        ],
      ),
      // top: false because the AppBar already handles the status bar. The
      // bottom inset is the one that matters: without it the last word card
      // sits underneath the system navigation bar and can't be read or
      // tapped.
      body: SafeArea(
        top: false,
        child: _image == null ? _buildEmptyState(theme) : _buildScanView(theme),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.document_scanner_outlined,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Look up the Japanese in a photo',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Point it at a sign, a menu or a page. Recognition runs on '
              'your phone — the photo is never uploaded.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _pick(ImageSource.camera),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Take a photo'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _pick(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Choose from gallery'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanView(ThemeData theme) {
    return Column(
      children: [
        Expanded(flex: 5, child: _buildImagePanel(theme)),
        const Divider(height: 1),
        Expanded(flex: 6, child: _buildResultsPanel(theme)),
      ],
    );
  }

  Widget _buildImagePanel(ThemeData theme) {
    final provider = _provider;
    final imageSize = _imageSize;
    if (provider == null) return const SizedBox.shrink();

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final box = Size(constraints.maxWidth, constraints.maxHeight);
          final lines = _result?.lines ?? const <OcrLine>[];
          return Stack(
            fit: StackFit.expand,
            children: [
              Image(image: provider, fit: BoxFit.contain),
              if (imageSize != null)
                for (final line in lines)
                  if (JpText.hasJapanese(line.text))
                    _buildLineBox(theme, line, imageSize, box),
              if (_recognizing)
                const ColoredBox(
                  color: Colors.black38,
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLineBox(
    ThemeData theme,
    OcrLine line,
    Size imageSize,
    Size boxSize,
  ) {
    final rect = _toDisplayRect(line.boundingBox, imageSize, boxSize);
    final selected = identical(line, _selectedLine);
    return Positioned.fromRect(
      rect: rect,
      child: GestureDetector(
        onTap: () => _selectLine(line),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.primary.withValues(alpha: 0.6),
              width: selected ? 2.5 : 1.5,
            ),
            color: theme.colorScheme.primary
                .withValues(alpha: selected ? 0.28 : 0.12),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }

  /// Maps a box from source-image pixels onto the widget, reproducing
  /// [BoxFit.contain] — the same fit the [Image] above uses. Getting this
  /// wrong doesn't fail loudly; the boxes just drift off the text.
  Rect _toDisplayRect(Rect rect, Size imageSize, Size boxSize) {
    final scale = math.min(
      boxSize.width / imageSize.width,
      boxSize.height / imageSize.height,
    );
    final dx = (boxSize.width - imageSize.width * scale) / 2;
    final dy = (boxSize.height - imageSize.height * scale) / 2;
    return Rect.fromLTWH(
      rect.left * scale + dx,
      rect.top * scale + dy,
      rect.width * scale,
      rect.height * scale,
    );
  }

  Widget _buildResultsPanel(ThemeData theme) {
    if (_recognizing) {
      return const Center(child: CircularProgressIndicator());
    }

    final result = _result;
    if (result != null &&
        !result.lines.any((l) => JpText.hasJapanese(l.text))) {
      return _buildHint(
        theme,
        Icons.search_off,
        'No Japanese text found',
        'Try a sharper photo, or one where the text is larger and level.',
      );
    }

    final line = _selectedLine;
    if (line == null) {
      return _buildHint(
        theme,
        Icons.touch_app_outlined,
        'Tap a highlighted line',
        'Each box is a line of text the scan found.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          'Tap any character to look up the word that starts there',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        _buildTappableLine(theme, line.text),
        const SizedBox(height: 16),
        if (_analyzing)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _buildSectionTitle(theme, 'Words'),
          if (_words.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No dictionary words matched this line.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final word in _words) _buildWordCard(theme, word),
          if (_kanji.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSectionTitle(theme, 'Kanji'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kanji in _kanji) _buildKanjiChip(theme, kanji),
              ],
            ),
          ],
        ],
      ],
    );
  }

  /// The recognised line, one tappable character at a time.
  ///
  /// Rendered per character rather than as selectable text because the
  /// lookup needs the tapped *index*, not a selection range — and because a
  /// tap target the size of one kanji is the whole interaction.
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
                style: theme.textTheme.headlineSmall?.copyWith(
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

  Widget _buildSectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
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
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      word.surface,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Show the dictionary form only when it differs, so the
                  // user can see that 話してはいけません was found via 話す.
                  if (word.isInflected && entry.term != word.surface) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_right_alt,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        entry.term,
                        style: theme.textTheme.titleMedium,
                      ),
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
      // The character goes in the label rather than `avatar`: an avatar is
      // laid out as a small fixed-size circle, which clips a full-width CJK
      // glyph (声 renders as 吉).
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

  Widget _buildHint(
    ThemeData theme,
    IconData icon,
    String title,
    String body,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => _pick(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Choose another image'),
            ),
          ],
        ),
      ),
    );
  }
}

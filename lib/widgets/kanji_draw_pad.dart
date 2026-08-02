import 'dart:async';

import 'package:flutter/material.dart';
import '../services/handwriting_service.dart';

/// Shirabe Jisho-style handwriting input: a square drawing canvas with a strip
/// of candidate characters above it.
///
/// The pad owns only the stroke capture and the candidate list — it never
/// touches the dictionary. Tapping a candidate fires [onCharacterSelected] and
/// the canvas clears, so the caller can append the character to the search
/// field and let the existing debounced search take over.
class KanjiDrawPad extends StatefulWidget {
  const KanjiDrawPad({
    super.key,
    required this.onCharacterSelected,
    required this.onClose,
  });

  /// Called with a single recognised character when the user taps a candidate.
  final ValueChanged<String> onCharacterSelected;

  /// Called when the user dismisses the pad.
  final VoidCallback onClose;

  @override
  State<KanjiDrawPad> createState() => _KanjiDrawPadState();
}

class _KanjiDrawPadState extends State<KanjiDrawPad> {
  final HandwritingService _handwriting = HandwritingService();

  /// Completed strokes, plus [_current] for the one being drawn right now.
  final List<List<InkPoint>> _strokes = [];
  List<InkPoint>? _current;

  List<String> _candidates = const [];
  Timer? _debounce;
  Size _canvasSize = Size.zero;

  /// Guards against a slow recognition call landing after the user has already
  /// drawn more strokes or cleared the pad.
  int _recognitionToken = 0;

  @override
  void initState() {
    super.initState();
    // Kick the download off as soon as the pad opens rather than making the
    // user draw first and then wait.
    _handwriting.ensureModel();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _current = [_point(details.localPosition)];
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final current = _current;
    if (current == null) return;
    setState(() {
      current.add(_point(details.localPosition));
    });
  }

  void _onPanEnd(DragEndDetails details) {
    final current = _current;
    if (current == null) return;
    setState(() {
      _strokes.add(current);
      _current = null;
    });
    _scheduleRecognition();
  }

  InkPoint _point(Offset offset) => InkPoint(
        offset.dx,
        offset.dy,
        DateTime.now().millisecondsSinceEpoch,
      );

  /// Recognise shortly after the pen lifts, so a multi-stroke character isn't
  /// re-recognised mid-way through every single stroke.
  void _scheduleRecognition() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _runRecognition);
  }

  Future<void> _runRecognition() async {
    if (_strokes.isEmpty) {
      setState(() => _candidates = const []);
      return;
    }

    final token = ++_recognitionToken;
    final results = await _handwriting.recognize(
      _strokes.map((stroke) => List<InkPoint>.unmodifiable(stroke)).toList(),
      _canvasSize == Size.zero ? const Size(300, 300) : _canvasSize,
    );

    if (!mounted || token != _recognitionToken) return;
    setState(() => _candidates = results);
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
    if (_strokes.isEmpty) {
      _recognitionToken++;
      setState(() => _candidates = const []);
    } else {
      _scheduleRecognition();
    }
  }

  void _clear() {
    _debounce?.cancel();
    _recognitionToken++;
    setState(() {
      _strokes.clear();
      _current = null;
      _candidates = const [];
    });
  }

  void _selectCandidate(String text) {
    widget.onCharacterSelected(text);
    // Clear so the next character starts from a blank canvas, matching how
    // Shirabe Jisho lets you write a word one character at a time.
    _clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildCandidateStrip(theme),
          const Divider(height: 1),
          Expanded(child: _buildCanvas(theme)),
        ],
      ),
    );
  }

  Widget _buildCandidateStrip(ThemeData theme) {
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          Expanded(child: _buildCandidateContent(theme)),
          IconButton(
            onPressed: _strokes.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo),
            tooltip: 'Undo stroke',
          ),
          IconButton(
            onPressed: _strokes.isEmpty ? null : _clear,
            icon: const Icon(Icons.clear),
            tooltip: 'Clear',
          ),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.keyboard_hide),
            tooltip: 'Close draw pad',
          ),
        ],
      ),
    );
  }

  Widget _buildCandidateContent(ThemeData theme) {
    return ValueListenableBuilder<InkModelStatus>(
      valueListenable: _handwriting.status,
      builder: (context, status, _) {
        if (status == InkModelStatus.downloading ||
            status == InkModelStatus.unknown) {
          return _statusMessage(
            theme,
            'Downloading handwriting model…',
            showSpinner: true,
          );
        }
        if (status == InkModelStatus.failed) {
          return _statusMessage(
            theme,
            'Handwriting model unavailable — check your connection.',
          );
        }
        if (_candidates.isEmpty) {
          return _statusMessage(theme, 'Draw a character below');
        }

        return ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          itemCount: _candidates.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            final candidate = _candidates[index];
            return InkWell(
              onTap: () => _selectCandidate(candidate),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                constraints: const BoxConstraints(minWidth: 48),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  // The top guess gets a highlighted border, so the most
                  // likely match is obvious without reading left-to-right.
                  border: Border.all(
                    color: index == 0
                        ? theme.colorScheme.primary
                        : theme.dividerColor,
                    width: index == 0 ? 2 : 1,
                  ),
                ),
                child: Text(
                  candidate,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _statusMessage(
    ThemeData theme,
    String message, {
    bool showSpinner = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (showSpinner) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
          ],
          Flexible(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // Recorded for the recognition call — ML Kit uses the writing area to
        // judge character scale. Assigned during layout rather than in
        // setState because it changes only on rotation/resize.
        _canvasSize = size;

        return GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            size: size,
            painter: _StrokePainter(
              strokes: _strokes,
              current: _current,
              inkColor: theme.colorScheme.onSurface,
              guideColor: theme.dividerColor,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter({
    required this.strokes,
    required this.current,
    required this.inkColor,
    required this.guideColor,
  });

  final List<List<InkPoint>> strokes;
  final List<InkPoint>? current;
  final Color inkColor;
  final Color guideColor;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGuides(canvas, size);

    final paint = Paint()
      ..color = inkColor
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      _paintStroke(canvas, stroke, paint);
    }
    final active = current;
    if (active != null) _paintStroke(canvas, active, paint);
  }

  /// Dashed centre cross, the standard visual cue for "write the character
  /// centred and filling the box" that IME handwriting pads use.
  void _paintGuides(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = guideColor
      ..strokeWidth = 1;

    const dash = 8.0;
    const gap = 6.0;

    for (double x = 0; x < size.width; x += dash + gap) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset((x + dash).clamp(0, size.width), size.height / 2),
        paint,
      );
    }
    for (double y = 0; y < size.height; y += dash + gap) {
      canvas.drawLine(
        Offset(size.width / 2, y),
        Offset(size.width / 2, (y + dash).clamp(0, size.height)),
        paint,
      );
    }
  }

  void _paintStroke(Canvas canvas, List<InkPoint> stroke, Paint paint) {
    if (stroke.isEmpty) return;
    if (stroke.length == 1) {
      // A tap with no drag still needs to leave a mark — a dot is a valid
      // stroke in several kana.
      canvas.drawCircle(
        Offset(stroke.first.x, stroke.first.y),
        paint.strokeWidth / 2,
        Paint()..color = paint.color,
      );
      return;
    }

    final path = Path()..moveTo(stroke.first.x, stroke.first.y);
    for (final point in stroke.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}

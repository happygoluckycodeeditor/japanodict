import 'package:flutter/material.dart';
import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
import '../utils/svg_path.dart';

/// Stroke order for a character by literal, falling back to the plain glyph.
///
/// Owns the lookup so callers don't have to: KanjiVG covers ~6,700 of
/// KANJIDIC2's ~10,400 characters, so "no diagram" is a normal outcome and
/// every caller would otherwise repeat the same null handling.
///
/// The future is created once in [initState] rather than inline in a
/// `FutureBuilder`. The entry sheet is a [DraggableScrollableSheet], whose
/// builder re-runs on every drag frame — an inline future would re-query the
/// database each time the user nudged the sheet.
class KanjiStrokeView extends StatefulWidget {
  const KanjiStrokeView({super.key, required this.literal, this.size = 88});

  final String literal;
  final double size;

  @override
  State<KanjiStrokeView> createState() => _KanjiStrokeViewState();
}

class _KanjiStrokeViewState extends State<KanjiStrokeView> {
  late Future<KanjiStrokes?> _strokes;

  @override
  void initState() {
    super.initState();
    _strokes = DatabaseService().getStrokesFor(widget.literal);
  }

  @override
  void didUpdateWidget(KanjiStrokeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.literal != widget.literal) {
      _strokes = DatabaseService().getStrokesFor(widget.literal);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<KanjiStrokes?>(
      future: _strokes,
      builder: (context, snapshot) {
        final strokes = snapshot.data;
        if (strokes == null || strokes.outlines.isEmpty) {
          return SizedBox(
            width: widget.size,
            height: widget.size,
            child: Center(
              child: Text(
                widget.literal,
                style: TextStyle(fontSize: widget.size * 0.62),
              ),
            ),
          );
        }
        return StrokeOrderDiagram(strokes: strokes, size: widget.size);
      },
    );
  }
}

/// Animated stroke-order diagram for a single character.
///
/// Strokes are drawn one at a time in writing order, each tracing from its
/// start point, with already-drawn strokes left in place. Tapping replays it.
/// Static-but-numbered diagrams are the other common presentation, but
/// numbers get illegible at the size this sits at inside a kanji card, and
/// the direction of each stroke — the thing that's actually hard to infer —
/// only really comes across in motion.
class StrokeOrderDiagram extends StatefulWidget {
  const StrokeOrderDiagram({
    super.key,
    required this.strokes,
    this.size = 88,
  });

  final KanjiStrokes strokes;
  final double size;

  @override
  State<StrokeOrderDiagram> createState() => _StrokeOrderDiagramState();
}

class _StrokeOrderDiagramState extends State<StrokeOrderDiagram>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late List<Path> _paths;

  /// Roughly how long one stroke takes; the total scales with stroke count so
  /// a 20-stroke kanji doesn't crawl and a 2-stroke one doesn't flash past.
  static const _perStroke = Duration(milliseconds: 420);

  @override
  void initState() {
    super.initState();
    _paths = _parse(widget.strokes);
    _controller = AnimationController(
      vsync: this,
      duration: _perStroke * _paths.length,
    )..forward();
  }

  @override
  void didUpdateWidget(StrokeOrderDiagram oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.strokes.literal != widget.strokes.literal) {
      _paths = _parse(widget.strokes);
      _controller
        ..duration = _perStroke * _paths.length
        ..forward(from: 0);
    }
  }

  static List<Path> _parse(KanjiStrokes strokes) =>
      strokes.outlines.map(parseKanjiVgPath).toList();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _replay() => _controller.forward(from: 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'Stroke order for ${widget.strokes.literal}, '
          '${_paths.length} strokes. Tap to replay.',
      button: true,
      child: GestureDetector(
        onTap: _replay,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: theme.dividerColor),
          ),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return CustomPaint(
                painter: _StrokePainter(
                  paths: _paths,
                  progress: _controller.value,
                  strokeColor: theme.colorScheme.onSurface,
                  guideColor: theme.dividerColor,
                ),
                size: Size.square(widget.size),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter({
    required this.paths,
    required this.progress,
    required this.strokeColor,
    required this.guideColor,
  });

  final List<Path> paths;
  final double progress;
  final Color strokeColor;
  final Color guideColor;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGuides(canvas, size);
    if (paths.isEmpty) return;

    // KanjiVG uses a fixed square viewBox, so scale by ratio rather than
    // fitting to measured bounds — otherwise 一 would be blown up to fill
    // the cell and lose its relationship to the character's real proportions.
    final scale = size.width / KanjiStrokes.viewBox;
    canvas.save();
    canvas.scale(scale);

    final paint = Paint()
      ..color = strokeColor
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // Which stroke is mid-draw, and how far through it we are.
    final exact = progress * paths.length;
    final currentIndex = exact.floor();
    final currentFraction = exact - currentIndex;

    for (var i = 0; i < paths.length; i++) {
      if (i < currentIndex) {
        canvas.drawPath(paths[i], paint);
      } else if (i == currentIndex) {
        canvas.drawPath(_partial(paths[i], currentFraction), paint);
      }
    }

    canvas.restore();
  }

  /// The first [fraction] of a path, by arc length — this is what makes the
  /// stroke appear to be written in its true direction.
  Path _partial(Path path, double fraction) {
    if (fraction >= 1.0) return path;
    final result = Path();
    for (final metric in path.computeMetrics()) {
      if (metric.length == 0) continue;
      result.addPath(
        metric.extractPath(0, metric.length * fraction.clamp(0.0, 1.0)),
        Offset.zero,
      );
    }
    return result;
  }

  void _paintGuides(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = guideColor
      ..strokeWidth = 1;
    const dash = 5.0;
    const gap = 4.0;
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

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.paths != paths ||
      oldDelegate.strokeColor != strokeColor;
}

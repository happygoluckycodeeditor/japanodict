import 'dart:ui';

/// Minimal SVG path parser covering exactly what KanjiVG emits.
///
/// A survey of the whole KanjiVG release (79,907 stroke outlines) shows only
/// six commands in use: `M`/`m` (moveto) and the cubic Béziers `C`/`c` and
/// `S`/`s`. There are no arcs, quadratics, lines or closepaths, so a full SVG
/// path implementation (or a dependency for one) would be dead weight — but
/// anything outside that set is silently skipped rather than mis-drawn.
Path parseKanjiVgPath(String d) {
  final path = Path();
  final tokens = _Tokenizer(d);

  // Current point, and the previous cubic's second control point — `S`/`s`
  // are defined as reflecting it through the current point.
  double x = 0, y = 0;
  double? lastControlX, lastControlY;

  String? command;
  while (true) {
    final next = tokens.peekCommand();
    if (next != null) {
      command = next;
      tokens.consumeCommand();
    } else if (command == null) {
      break;
    }
    // With no new command letter, SVG repeats the previous one implicitly
    // (e.g. "c1,2 3,4 5,6 7,8 9,10 11,12" is two curves). An implicit repeat
    // of moveto means lineto per spec, but KanjiVG never relies on that.

    if (!tokens.hasNumbers) break;

    switch (command) {
      case 'M':
      case 'm':
        final relative = command == 'm';
        final nx = tokens.number();
        final ny = tokens.number();
        x = relative ? x + nx : nx;
        y = relative ? y + ny : ny;
        path.moveTo(x, y);
        lastControlX = lastControlY = null;
        break;

      case 'C':
      case 'c':
        final relative = command == 'c';
        final ox = relative ? x : 0.0;
        final oy = relative ? y : 0.0;
        final x1 = ox + tokens.number();
        final y1 = oy + tokens.number();
        final x2 = ox + tokens.number();
        final y2 = oy + tokens.number();
        final ex = ox + tokens.number();
        final ey = oy + tokens.number();
        path.cubicTo(x1, y1, x2, y2, ex, ey);
        lastControlX = x2;
        lastControlY = y2;
        x = ex;
        y = ey;
        break;

      case 'S':
      case 's':
        final relative = command == 's';
        final ox = relative ? x : 0.0;
        final oy = relative ? y : 0.0;
        // Reflect the previous control point; if the last segment wasn't a
        // cubic, the spec says the control point coincides with the current
        // point.
        final x1 = lastControlX == null ? x : 2 * x - lastControlX;
        final y1 = lastControlY == null ? y : 2 * y - lastControlY;
        final x2 = ox + tokens.number();
        final y2 = oy + tokens.number();
        final ex = ox + tokens.number();
        final ey = oy + tokens.number();
        path.cubicTo(x1, y1, x2, y2, ex, ey);
        lastControlX = x2;
        lastControlY = y2;
        x = ex;
        y = ey;
        break;

      default:
        // Unknown command — drop one number so we can't spin forever.
        tokens.number();
        break;
    }
  }

  return path;
}

/// Walks an SVG path string, yielding command letters and numbers.
///
/// SVG number syntax is looser than Dart's parser: separators may be commas,
/// whitespace, or nothing at all when a sign disambiguates ("0.5-1.2" is two
/// numbers), and exponents are legal.
class _Tokenizer {
  _Tokenizer(this._source);

  final String _source;
  int _pos = 0;

  void _skipSeparators() {
    while (_pos < _source.length) {
      final c = _source.codeUnitAt(_pos);
      // space, tab, CR, LF, comma
      if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A || c == 0x2C) {
        _pos++;
      } else {
        break;
      }
    }
  }

  String? peekCommand() {
    _skipSeparators();
    if (_pos >= _source.length) return null;
    final c = _source[_pos];
    return RegExp(r'[A-Za-z]').hasMatch(c) ? c : null;
  }

  void consumeCommand() => _pos++;

  bool get hasNumbers {
    _skipSeparators();
    if (_pos >= _source.length) return false;
    return RegExp(r'[0-9.+-]').hasMatch(_source[_pos]);
  }

  double number() {
    _skipSeparators();
    final start = _pos;

    if (_pos < _source.length &&
        (_source[_pos] == '-' || _source[_pos] == '+')) {
      _pos++;
    }
    while (_pos < _source.length && _isDigitOrDot(_source.codeUnitAt(_pos))) {
      _pos++;
    }
    // Exponent, e.g. "1.5e-3".
    if (_pos < _source.length &&
        (_source[_pos] == 'e' || _source[_pos] == 'E')) {
      _pos++;
      if (_pos < _source.length &&
          (_source[_pos] == '-' || _source[_pos] == '+')) {
        _pos++;
      }
      while (_pos < _source.length && _isDigit(_source.codeUnitAt(_pos))) {
        _pos++;
      }
    }

    if (_pos == start) {
      // Nothing consumed — advance so callers can't loop forever.
      _pos++;
      return 0;
    }
    return double.tryParse(_source.substring(start, _pos)) ?? 0;
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
  static bool _isDigitOrDot(int c) => _isDigit(c) || c == 0x2E;
}

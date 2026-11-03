import 'diagnostics.dart';

enum TokKind { ident, number, string, char, punct }

class Token {
  Token(this.kind, this.text, this.loc, {this.doc});

  /// A `///<` comment after this token on its line (enumerators use it).
  String? trailingDoc;

  final TokKind kind;
  final String text;
  final SourceLoc loc;

  /// Doc comment (`///` or `/** */`) directly before this token, if any.
  final String? doc;

  bool isPunct(String p) => kind == TokKind.punct && text == p;
  bool isIdent([String? name]) => kind == TokKind.ident && (name == null || text == name);

  @override
  String toString() => text;
}

/// A `#include "..."` or `#include <...>` directive.
class Include {
  Include(this.path, this.loc, {this.angled = false});

  /// `<...>`: searched in the -I directories only, not next to the file.
  final bool angled;

  final String path;
  final SourceLoc loc;
}

/// Splits C++ source into tokens. Comments are dropped (doc comments are
/// attached to the next token) and preprocessor directives are skipped
/// (includes are recorded).
class Lexer {
  Lexer(this.source, this.path);

  final String source;
  final String path;
  final tokens = <Token>[];
  final includes = <Include>[];

  int _pos = 0;
  int _line = 1;
  int _lineStart = 0;
  bool _atLineStart = true;
  final _doc = <String>[];

  static const _punct3 = ['...', '->*', '<=>'];
  static const _punct2 = ['::', '->', '&&', '||', '==', '!=', '++', '--', '+=', '-=', '*=', '/=', '%=', '|=', '&=', '^=', '.*'];

  List<Token> run() {
    while (_pos < source.length) {
      final c = source[_pos];
      if (c == '\n') {
        _newline();
        _pos++;
        continue;
      }
      if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v') {
        _pos++;
        continue;
      }
      if (c == '#' && _atLineStart) {
        _directive();
        continue;
      }
      _atLineStart = false;
      if (_startsWith('//')) {
        _lineComment();
        continue;
      }
      if (_startsWith('/*')) {
        _blockComment();
        continue;
      }
      final loc = _loc();
      if (_isIdentStart(c)) {
        final start = _pos;
        while (_pos < source.length && _isIdentPart(source[_pos])) {
          _pos++;
        }
        final word = source.substring(start, _pos);
        if (_pos < source.length && source[_pos] == '"' && const {'R', 'u8R', 'uR', 'UR', 'LR'}.contains(word)) {
          _rawString(start, loc);
        } else if (_pos < source.length && source[_pos] == '"' && const {'u8', 'u', 'U', 'L'}.contains(word)) {
          _quoted('"', start, loc, TokKind.string);
        } else if (_pos < source.length && source[_pos] == "'" && const {'u8', 'u', 'U', 'L'}.contains(word)) {
          _quoted("'", start, loc, TokKind.char);
        } else {
          _emit(TokKind.ident, word, loc);
        }
        continue;
      }
      if (_isDigit(c) || (c == '.' && _pos + 1 < source.length && _isDigit(source[_pos + 1]))) {
        _number(loc);
        continue;
      }
      if (c == '"') {
        _quoted('"', _pos, loc, TokKind.string);
        continue;
      }
      if (c == "'") {
        _quoted("'", _pos, loc, TokKind.char);
        continue;
      }
      final p = _punct3.firstWhere(_startsWith, orElse: () => _punct2.firstWhere(_startsWith, orElse: () => c));
      _pos += p.length;
      _emit(TokKind.punct, p, loc);
    }
    return tokens;
  }

  SourceLoc _loc() => SourceLoc(path, _line, _pos - _lineStart + 1);

  void _newline() {
    _line++;
    _lineStart = _pos + 1;
    _atLineStart = true;
  }

  bool _startsWith(String s) => source.startsWith(s, _pos);

  void _emit(TokKind kind, String text, SourceLoc loc) {
    tokens.add(Token(kind, text, loc, doc: _doc.isEmpty ? null : _doc.join('\n')));
    _doc.clear();
  }

  void _lineComment() {
    final isDoc = (_startsWith('///') && !_startsWith('////')) || _startsWith('//!');
    final end = source.indexOf('\n', _pos);
    final stop = end < 0 ? source.length : end;
    if (isDoc) {
      var text = source.substring(_pos + 3, stop);
      if (text.startsWith('<')) {
        // trailing doc (`///<`): belongs to what precedes it on the line, e.g.
        // `Run, ///< @label Running` documents the enumerator, not the comma.
        var k = tokens.length - 1;
        while (k >= 0 && tokens[k].kind == TokKind.punct && (tokens[k].text == ',' || tokens[k].text == ';')) {
          k--;
        }
        if (k >= 0) {
          var t = text.substring(1);
          if (t.startsWith(' ')) t = t.substring(1);
          final prev = tokens[k].trailingDoc;
          tokens[k].trailingDoc = prev == null ? t.trimRight() : '$prev\n${t.trimRight()}';
        }
      } else {
        if (text.startsWith(' ')) text = text.substring(1);
        _doc.add(text.trimRight());
      }
    }
    _pos = stop;
  }

  void _blockComment() {
    final isDoc = _startsWith('/**') && !_startsWith('/**/');
    final end = source.indexOf('*/', _pos + 2);
    if (end < 0) throw GeneratorException(_loc(), 'unterminated comment');
    final body = source.substring(_pos + (isDoc ? 3 : 2), end);
    for (var k = _pos; k < end; k++) {
      if (source[k] == '\n') {
        _line++;
        _lineStart = k + 1;
      }
    }
    _pos = end + 2;
    if (isDoc) {
      for (var line in body.split('\n')) {
        line = line.trim();
        if (line.startsWith('*')) line = line.substring(1);
        if (line.startsWith(' ')) line = line.substring(1);
        _doc.add(line.trimRight());
      }
      while (_doc.isNotEmpty && _doc.first.isEmpty) {
        _doc.removeAt(0);
      }
      while (_doc.isNotEmpty && _doc.last.isEmpty) {
        _doc.removeLast();
      }
    }
  }

  void _directive() {
    final loc = _loc();
    final buf = StringBuffer();
    while (_pos < source.length) {
      final c = source[_pos];
      if (c == '\\' && _pos + 1 < source.length && source[_pos + 1] == '\n') {
        _pos += 2;
        _line++;
        _lineStart = _pos;
        continue;
      }
      if (c == '\n') break;
      if (_startsWith('//')) {
        final end = source.indexOf('\n', _pos);
        _pos = end < 0 ? source.length : end;
        break;
      }
      buf.write(c);
      _pos++;
    }
    _doc.clear();
    final m = RegExp(r'^#\s*include\s*(?:"([^"]+)"|<([^>]+)>)').firstMatch(buf.toString());
    if (m != null) includes.add(Include(m.group(1) ?? m.group(2)!, loc, angled: m.group(1) == null));
  }

  void _number(SourceLoc loc) {
    final start = _pos;
    final hex = source.startsWith(RegExp('0[xX]'), _pos);
    while (_pos < source.length) {
      final c = source[_pos];
      final prev = source[_pos - 1 < start ? start : _pos - 1];
      if (_isIdentPart(c) || c == '.') {
        _pos++;
      } else if (c == "'" && _pos + 1 < source.length && _isIdentPart(source[_pos + 1])) {
        _pos++; // digit separator
      } else if ((c == '+' || c == '-') && _pos > start && (hex ? (prev == 'p' || prev == 'P') : (prev == 'e' || prev == 'E'))) {
        _pos++; // exponent sign
      } else {
        break;
      }
    }
    _emit(TokKind.number, source.substring(start, _pos), loc);
  }

  void _quoted(String quote, int start, SourceLoc loc, TokKind kind) {
    _pos++; // opening quote
    while (_pos < source.length && source[_pos] != quote) {
      if (source[_pos] == '\\') _pos++;
      if (_pos < source.length && source[_pos] == '\n') {
        throw GeneratorException(loc, 'unterminated literal');
      }
      _pos++;
    }
    if (_pos >= source.length) throw GeneratorException(loc, 'unterminated literal');
    _pos++;
    _emit(kind, source.substring(start, _pos), loc);
  }

  void _rawString(int start, SourceLoc loc) {
    // R"delim( ... )delim"
    final open = source.indexOf('(', _pos);
    if (open < 0) throw GeneratorException(loc, 'malformed raw string');
    final delim = source.substring(_pos + 1, open);
    final close = source.indexOf(')$delim"', open);
    if (close < 0) throw GeneratorException(loc, 'unterminated raw string');
    for (var k = _pos; k < close; k++) {
      if (source[k] == '\n') {
        _line++;
        _lineStart = k + 1;
      }
    }
    _pos = close + delim.length + 2;
    _emit(TokKind.string, source.substring(start, _pos), loc);
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  static bool _isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u >= 128;
  }

  static bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);
}

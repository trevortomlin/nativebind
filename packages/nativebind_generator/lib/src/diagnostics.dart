/// A position in a source file (1-based line and column).
class SourceLoc {
  const SourceLoc(this.path, this.line, this.column);

  final String path;
  final int line;
  final int column;

  @override
  String toString() => '$path:$line:$column';
}

/// An error in a module file, reported like a compiler diagnostic:
///
///     player.cpp:12:5: error: unknown type `Mode` for property `mode`
///       hint: define the enum in this file or in an included header
class GeneratorException implements Exception {
  GeneratorException(this.loc, this.message, {this.hint});

  final SourceLoc? loc;
  final String message;
  final String? hint;

  @override
  String toString() {
    final where = loc == null ? '' : '$loc: ';
    final h = hint == null ? '' : '\n  hint: $hint';
    return '${where}error: $message$h';
  }
}

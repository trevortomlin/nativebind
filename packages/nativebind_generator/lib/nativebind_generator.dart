/// Generator for nativebind: reads C++ module files and writes the FFI glue
/// (`*.nb.cpp`) and typed Dart view models (`*.nb.dart`).
library;

export 'src/analysis.dart' show Analyzer, RModule, schemaOf;
export 'src/diagnostics.dart';
export 'src/generator.dart';
export 'src/lexer.dart' show Lexer, Token, TokKind;
export 'src/model.dart';
export 'src/parser.dart' show Parser;

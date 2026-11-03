import 'package:nativebind_generator/nativebind_generator.dart';
import 'package:test/test.dart';

List<String> lex(String src) => Lexer(src, 't.cpp').run().map((t) => t.text).toList();

void main() {
  test('splits identifiers, numbers and punctuation', () {
    expect(lex('std::vector<std::vector<int>> v{1, 2};'),
        ['std', '::', 'vector', '<', 'std', '::', 'vector', '<', 'int', '>', '>', 'v', '{', '1', ',', '2', '}', ';']);
  });

  test('numbers with separators, suffixes and exponents', () {
    expect(lex("1'000'000 0x1F 0b1010u 1.5e-3f .5 5. 0x1p+3"), ["1'000'000", '0x1F', '0b1010u', '1.5e-3f', '.5', '5.', '0x1p+3']);
    expect(lex('0xE-1'), ['0xE', '-', '1']); // hex digit E is not an exponent
  });

  test('strings, chars and raw strings', () {
    final toks = Lexer(r'''a = "x\"y"; b = 'c'; r = R"d(a ) " ( b)d"; u = u8"z";''', 't.cpp').run();
    final strings = toks.where((t) => t.kind == TokKind.string).map((t) => t.text).toList();
    expect(strings, [r'"x\"y"', 'R"d(a ) " ( b)d"', 'u8"z"']);
    expect(toks.where((t) => t.kind == TokKind.char).single.text, "'c'");
  });

  test('comments are dropped; doc comments attach to the next token', () {
    final toks = Lexer('''
// plain
/// Doc line one
/// line two
int a; /* block */ int b;
/** Block doc
 * continues
 */
int c;
''', 't.cpp').run();
    expect(toks.map((t) => t.text).toList(), ['int', 'a', ';', 'int', 'b', ';', 'int', 'c', ';']);
    expect(toks[0].doc, 'Doc line one\nline two');
    expect(toks[3].doc, isNull);
    expect(toks[6].doc, 'Block doc\ncontinues');
  });

  test('preprocessor lines are skipped and includes recorded', () {
    final lexer = Lexer('''
#include <vector>
#include "types.hpp"
  #  include "other.h" // comment
#define X(a) \\
    a + 1
int x;
''', 't.cpp');
    expect(lexer.run().map((t) => t.text).toList(), ['int', 'x', ';']);
    expect(lexer.includes.map((i) => i.path).toList(), ['vector', 'types.hpp', 'other.h']);
    expect(lexer.includes.map((i) => i.angled).toList(), [true, false, false]);
  });

  test('tracks lines and columns', () {
    final toks = Lexer('a\n  bb\n/* x\ny */ c', 't.cpp').run();
    expect([for (final t in toks) '${t.loc.line}:${t.loc.column}'], ['1:1', '2:3', '4:6']);
  });

  test('reports unterminated literals', () {
    expect(() => Lexer('"abc', 't.cpp').run(), throwsA(isA<GeneratorException>()));
    expect(() => Lexer('/* abc', 't.cpp').run(), throwsA(isA<GeneratorException>()));
  });
}

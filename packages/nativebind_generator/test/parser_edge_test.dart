// Parser edge cases: macro names in comments and strings, preprocessor
// lines, nested templates, defaults with braces, out-of-line definitions.
import 'package:test/test.dart';

import 'support.dart';

String dartOf(String members, {String prelude = ''}) => generate({'m.cpp': module(members, prelude: prelude)})['m.nb.dart']!;

void main() {
  test('macros inside comments and string literals are ignored', () {
    final d = dartOf(r'''
    // NATIVEBIND_PROP(int, commented, 0)
    /* NATIVEBIND_READ(int, blocked, 0) */
    NATIVEBIND_PROP(std::string, text, "NATIVEBIND_PROP(int, fake, 0)")
    NATIVEBIND_READ(std::string, raw, R"x(NATIVEBIND_LIST(int, nope) )" )x")
''', prelude: '#include <string>');
    expect(d, contains('text'));
    expect(d, contains('raw'));
    for (final n in ['commented', 'blocked', 'fake', 'nope']) {
      expect(d, isNot(contains(n)));
    }
  });

  test('nested templates close with >>', () {
    final d = dartOf('    NATIVEBIND_READ(std::vector<std::vector<int>>, grid, {})\n', prelude: '#include <vector>');
    expect(d, contains('List<List<int>>'));
  });

  test('defaults containing commas, braces and parentheses', () {
    final d = dartOf('''
    NATIVEBIND_READ(std::vector<int>, xs, std::vector<int>{1, 2, 3})
    NATIVEBIND_PROP(double, y, std::max(1.0, 2.0), .min = 0, .max = 10)
''', prelude: '#include <vector>\n#include <algorithm>');
    expect(d, contains('xs'));
    expect(d, contains('y'));
  });

  test('preprocessor lines and line continuations do not confuse the parser', () {
    final d = dartOf(r'''
#define HELPER(x) \
    ((x) + 1)
#if 0
#endif
    NATIVEBIND_READ(int, after, HELPER(1))
''');
    expect(d, contains('after'));
  });

  test('out-of-line invoke definitions and default arguments', () {
    final files = generate({
      'm.cpp': '''
${module('    NATIVEBIND_INVOKE int twice(int v, int times = 2) const;\n')}
int M::twice(int v, int times) const { return v * times; }
'''
    });
    expect(files['m.nb.dart'], contains('twice'));
    // C++ default expressions are not translated: Dart callers pass every argument.
    expect(files['m.nb.dart'], contains('twice(int v, int times)'));
  });

  test('doc comments become Dart doc comments', () {
    final d = dartOf('''
    /// Supply air temperature.
    /// Second line.
    NATIVEBIND_READ(double, supply, 0)
''');
    expect(d, contains('/// Supply air temperature.'));
    expect(d, contains('/// Second line.'));
  });

  test('CRLF line endings', () {
    final d = generate({'m.cpp': module('    NATIVEBIND_READ(int, a, 0)\n    NATIVEBIND_PROP(int, b, 1)\n').replaceAll('\n', '\r\n')})['m.nb.dart']!;
    expect(d, contains(' a'));
    expect(d, contains(' b'));
  });
}

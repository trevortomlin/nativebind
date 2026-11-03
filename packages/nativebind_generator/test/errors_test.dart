import 'package:test/test.dart';

import 'support.dart';

/// Every error must name the file and line, and say what to do.
void main() {
  void expectError(String source, String message, {int? line, String? hint, Map<String, String> extra = const {}}) {
    final e = generateError(source, extra: extra);
    expect(e.message, contains(message));
    if (line != null) expect(e.loc?.line, line, reason: e.toString());
    if (hint != null) expect(e.hint, contains(hint));
    expect(e.loc?.path, endsWith('m.cpp'));
    expect(e.toString(), contains('m.cpp:${e.loc?.line}:'));
  }

  test('unknown type', () {
    expectError(module('    NATIVEBIND_PROP(Mode, mode, Mode::A)'), 'unknown type `Mode` for property `mode`',
        line: 6, hint: '#include');
  });

  test('pointers and references', () {
    expectError(module('    NATIVEBIND_PROP(int*, p, nullptr)'), 'pointer type `int*`');
    expectError(module('    NATIVEBIND_READ(int&, r, x)'), 'reference type');
  });

  test('unsupported containers', () {
    expectError(module('    NATIVEBIND_READ(std::map<int, int>, m, {})'), 'contains a comma', hint: 'alias');
    expectError(module('    NATIVEBIND_READ(IntMap, m, {})', prelude: '#include <map>\nusing IntMap = std::map<int, int>;'),
        'cannot cross the binding');
    expectError(module('    NATIVEBIND_READ(std::set<int>, s, {})'), 'cannot cross the binding', hint: 'std::vector');
    expectError(module('    NATIVEBIND_READ(std::optional<std::optional<int>>, o, {})'), 'nested std::optional');
    expectError(module('    NATIVEBIND_READ(std::string_view, v, "")'), 'string_view cannot be stored', hint: 'std::string');
    expectError(module('    NATIVEBIND_READ(std::chrono::steady_clock::time_point, t, {})'), 'unknown type');
  });

  test('macros outside a module or in the wrong place', () {
    expectError('#include <nativebind/nativebind.hpp>\nstruct S { NATIVEBIND_PROP(int, x, 0) };', 'before NATIVEBIND_MODULE');
    expectError('NATIVEBIND_PROP(int, x, 0)', 'must be inside a class');
    expectError('''
class M : public nativebind::Module {
    NATIVEBIND_MODULE(Other)
};''', 'NATIVEBIND_MODULE(Other) is inside class M', hint: 'NATIVEBIND_MODULE(M)');
    expectError('''
class M {
    NATIVEBIND_MODULE(M)
};''', 'must derive from nativebind::Module');
    expectError(module('', options: ', .singleton = true'), 'unknown module option', hint: '.instanced');
    expectError(module('    NATIVEBIND_PROP(int, x)'), 'expected NATIVEBIND_PROP(Type, name, initial');
  });

  test('methods', () {
    expectError(module('    NATIVEBIND_INVOKE static void f();'), 'must not be static');
    expectError(module('    NATIVEBIND_INVOKE void f(int);\n    NATIVEBIND_INVOKE void f(double);'), 'declared twice',
        hint: 'overloaded');
    expectError(module('    NATIVEBIND_INVOKE_AS() void f();'), 'needs one permission');
    expectError(module('    NATIVEBIND_INVOKE_AS(Nope::X) void f();'), 'cannot resolve the permission');
    expectError(module('    NATIVEBIND_INVOKE void f(int* p);'), 'pointer type');
    expectError(module('    NATIVEBIND_INVOKE void* f();'), 'pointer type');
  });

  test('structs that cannot cross the binding', () {
    expectError(module('    NATIVEBIND_READ(S, s, {})', prelude: 'struct Base {}; struct S : Base { int x; };'), 'has a base class');
    expectError(module('    NATIVEBIND_READ(S, s, {})', prelude: 'class S { int x; };'), 'field `x` of S is not public');
    expectError(module('    NATIVEBIND_READ(S, s, {})', prelude: 'struct S { int a, b; };'), 'one field per statement');
    expectError(module('    NATIVEBIND_READ(S, s, {})', prelude: 'struct S { int a[3]; };'), 'C arrays');
    expectError(module('    NATIVEBIND_READ(S, s, {})', prelude: 'struct S { void f(); };'), 'has no fields');
    expectError(module('    NATIVEBIND_READ(S, s, {})', prelude: 'struct S { int* p; };'), 'pointer type');
  });

  test('enum values nativebind cannot evaluate', () {
    expectError(module('    NATIVEBIND_READ(E, e, E::A)', prelude: 'enum class E { A = sizeof(int) };'),
        'is not a constant nativebind can read');
  });

  test('Dart name clashes', () {
    expectError(module('    NATIVEBIND_PROP(int, instance, 0)'), 'clashes with the generated M.instance');
    expectError(module('    NATIVEBIND_PROP(int, a_b, 0)\n    NATIVEBIND_PROP(int, aB, 0)'), 'are both `aB` in Dart');
    expectError(module('    NATIVEBIND_READ(int, key, 0)', options: ', .instanced = true'), 'clashes');
  });

  test('two modules with the same name', () {
    final e = (() {
      try {
        generate({'m.cpp': module(''), 'n.cpp': module('')});
      } on Exception catch (e) {
        return e;
      }
      return null;
    })();
    expect(e.toString(), contains('two modules are named M'));
  });
}

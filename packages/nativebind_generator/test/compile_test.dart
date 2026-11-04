// Compiles generated glue with the host C++ compiler, so the C++ output is
// checked by a real compiler (including the generator's static_asserts).

import 'dart:io';

import 'package:nativebind_generator/nativebind_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

String? findCompiler() {
  for (final c in [Platform.environment['CXX'], 'g++', 'clang++']) {
    if (c == null) continue;
    try {
      if (Process.runSync(c, ['--version']).exitCode == 0) return c;
    } on ProcessException {
      continue;
    }
  }
  return null;
}

void main() {
  final cxx = findCompiler();

  void compiles(List<String> inputs, {List<String> includeDirs = const [], String? provides}) {
    final dir = Directory.systemTemp.createTempSync('nativebind_cc_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Generator(GeneratorOptions(inputs: inputs, cppOut: dir.path, includeDirs: includeDirs, provides: provides)).run();
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.nb.cpp')).toList();
    expect(files, isNotEmpty);
    for (final f in files) {
      final r = Process.runSync(cxx!, [
        '-std=c++20', '-fsyntax-only', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
        '-I', '$nativeRoot/include', for (final d in includeDirs) ...['-I', d], f.path,
      ]);
      expect(r.exitCode, 0, reason: '${f.path}\n${r.stderr}');
    }
  }

  test('hvac fixture glue compiles', () => compiles(['$fixtures/hvac']), skip: cxx == null ? 'no C++ compiler' : null);
  test('names fixture glue compiles', () => compiles(['$fixtures/names']), skip: cxx == null ? 'no C++ compiler' : null);

  test('a struct field the generator missed fails to compile', () {
    // Simulate a parser miss: hide one field behind a macro the generator
    // cannot see through.
    final dir = Directory.systemTemp.createTempSync('nativebind_miss_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/m.cpp').writeAsStringSync('''
#include <nativebind/nativebind.hpp>
#define HIDDEN_FIELD int hidden = 0;
struct S { int x = 0; HIDDEN_FIELD };
class M : public nativebind::Module {
    NATIVEBIND_MODULE(M)
public:
    NATIVEBIND_READ(S, s, {})
};
''');
    Generator(GeneratorOptions(inputs: ['${dir.path}/m.cpp'], cppOut: dir.path)).run();
    final r = Process.runSync(cxx!, ['-std=c++20', '-fsyntax-only', '-I', '$nativeRoot/include', '${dir.path}/m.nb.cpp']);
    expect(r.exitCode, isNot(0));
    // GCC: "only 1 name provided for structured binding"; Clang: "binds to 2
    // elements, but only 1 name was provided".
    expect(r.stderr, matches(RegExp(r'structured binding|binds to \d+ elements')));
  }, skip: cxx == null ? 'no C++ compiler' : null);

  test('a type the generator misread fails to compile, wherever it is used', () {
    // Simulate a misread: the generator sees both branches and keeps the
    // last alias (double); the compiler takes the first (std::string). Only
    // the nested types differ for the struct field.
    final dir = Directory.systemTemp.createTempSync('nativebind_misread_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/m.cpp').writeAsStringSync('''
#include <nativebind/nativebind.hpp>
#include <string>
#include <vector>
#if 1
using Num = std::string;
#else
using Num = double;
#endif
struct S { std::vector<Num> xs; };
class M : public nativebind::Module {
    NATIVEBIND_MODULE(M)
public:
    NATIVEBIND_READ(S, s, {})
    NATIVEBIND_READ(std::optional<Num>, maybe, {})
    NATIVEBIND_SIGNAL(changed, Num)
    NATIVEBIND_INVOKE Num twice(Num v) { return v; }
};
''');
    Generator(GeneratorOptions(inputs: ['${dir.path}/m.cpp'], cppOut: dir.path)).run();
    final r = Process.runSync(cxx!, ['-std=c++20', '-fsyntax-only', '-I', '$nativeRoot/include', '${dir.path}/m.nb.cpp']);
    expect(r.exitCode, isNot(0));
    final err = r.stderr as String;
    expect(err, contains('read ::S::xs as list<double>'));
    expect(err, contains('read M::maybe as optional<double>'));
    expect(err, contains('read the arguments of M::changed as (double)'));
    expect(err, contains('read M::twice as double(double)'));
  }, skip: cxx == null ? 'no C++ compiler' : null);

  test('equivalent spellings of a type compile', () {
    final dir = Directory.systemTemp.createTempSync('nativebind_spellings_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/m.cpp').writeAsStringSync('''
#include <nativebind/nativebind.hpp>
#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>
enum class Mode : uint8_t { A, B };
struct P { std::optional<std::vector<int16_t>> v; std::chrono::milliseconds d{}; Mode mode = Mode::A; };
using Ps = std::vector<P>;
class M : public nativebind::Module {
    NATIVEBIND_MODULE(M)
public:
    NATIVEBIND_PROP(uint64_t, count, 0)
    NATIVEBIND_READ(std::chrono::system_clock::time_point, at, {})
    NATIVEBIND_LIST(P, ps)
    NATIVEBIND_SIGNAL(done)
    NATIVEBIND_SIGNAL(moved, std::string, int)
    NATIVEBIND_INVOKE void take(std::string_view s, const Ps& ps, std::optional<Mode> m) const noexcept { (void)s; (void)ps; (void)m; }
    NATIVEBIND_INVOKE Ps all() { return {}; }
};
''');
    compiles(['${dir.path}/m.cpp']);
  }, skip: cxx == null ? 'no C++ compiler' : null);
}

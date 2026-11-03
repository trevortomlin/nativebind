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
    expect(r.stderr, contains('structured binding'));
  }, skip: cxx == null ? 'no C++ compiler' : null);
}

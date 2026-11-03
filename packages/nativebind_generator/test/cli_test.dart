// The command line, run as a subprocess: exit codes, --check, --depfile.
import 'dart:io';

import 'package:test/test.dart';

import 'support.dart';

final _bin = '$generatorRoot/bin/nativebind_generator.dart';

ProcessResult gen(List<String> args, {String? cwd}) =>
    Process.runSync(Platform.resolvedExecutable, [_bin, ...args], workingDirectory: cwd);

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nativebind_cli_');
    File('${dir.path}/native/heat.cpp')
      ..createSync(recursive: true)
      ..writeAsStringSync(module('    NATIVEBIND_PROP(double, setpoint, 21.0)\n', name: 'Heat'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('--help exits 0 and prints usage', () {
    final r = gen(['--help']);
    expect(r.exitCode, 0);
    expect(r.stdout, contains('Usage:'));
  });

  test('bad options exit 2 with usage', () {
    for (final args in [
      ['--bogus'],
      ['--dart-out'],
      ['--no-dart'],
    ]) {
      final r = gen(args, cwd: dir.path);
      expect(r.exitCode, 2, reason: '$args');
      expect(r.stderr, contains('error:'));
      expect(r.stderr, contains('Usage:'));
    }
  });

  test('default run scans ./native and writes lib/nativebind', () {
    final r = gen([], cwd: dir.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(File('${dir.path}/lib/nativebind/heat.nb.dart').existsSync(), isTrue);
    expect(File('${dir.path}/lib/nativebind/nativebind_modules.dart').existsSync(), isTrue);
    expect(r.stdout, contains('1 module (Heat)'));
  });

  test('a second run writes nothing; -q prints nothing', () {
    gen([], cwd: dir.path);
    final r = gen([], cwd: dir.path);
    expect(r.stdout, contains('0 files written'));
    expect(gen(['-q'], cwd: dir.path).stdout, isEmpty);
  });

  test('--check: 0 when fresh, 3 when stale or missing, and writes nothing', () {
    expect(gen(['--check'], cwd: dir.path).exitCode, 3, reason: 'nothing generated yet');
    expect(File('${dir.path}/lib/nativebind/heat.nb.dart').existsSync(), isFalse);
    gen([], cwd: dir.path);
    expect(gen(['--check'], cwd: dir.path).exitCode, 0);
    File('${dir.path}/native/heat.cpp')
        .writeAsStringSync(module('    NATIVEBIND_PROP(double, setpoint, 22.0)\n    NATIVEBIND_READ(int, x, 0)\n', name: 'Heat'));
    final r = gen(['--check'], cwd: dir.path);
    expect(r.exitCode, 3);
    expect(r.stderr, contains('heat.nb.dart'));
  });

  test('source errors exit 1 with file:line', () {
    File('${dir.path}/native/heat.cpp').writeAsStringSync(module('    NATIVEBIND_PROP(Unknown, x, {})\n', name: 'Heat'));
    final r = gen([], cwd: dir.path);
    expect(r.exitCode, 1);
    expect(r.stderr, contains('heat.cpp:'));
  });

  test('missing input exits 1', () {
    final r = gen(['nope.cpp'], cwd: dir.path);
    expect(r.exitCode, 1);
  });

  test('--cpp-out with --depfile lists the module and its local headers', () {
    File('${dir.path}/native/types.hpp').writeAsStringSync('#pragma once\nenum class Mode { Off, On };\n');
    File('${dir.path}/native/heat.cpp').writeAsStringSync(
        module('    NATIVEBIND_PROP(Mode, mode, Mode::Off)\n', name: 'Heat', prelude: '#include "types.hpp"'));
    final r = gen(['--no-dart', '--cpp-out', 'out', '--depfile', 'out/heat.d', 'native/heat.cpp'], cwd: dir.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(File('${dir.path}/out/heat.nb.cpp').existsSync(), isTrue);
    final dep = File('${dir.path}/out/heat.d').readAsStringSync();
    expect(dep, contains('heat.nb.cpp:'));
    expect(dep, contains('heat.cpp'));
    expect(dep, contains('types.hpp'));
  });
}

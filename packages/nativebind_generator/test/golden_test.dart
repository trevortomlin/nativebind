// Checked-in generated files must match what the generator produces now.
// Regenerate with:  NATIVEBIND_UPDATE_GOLDENS=1 dart test test/golden_test.dart

import 'dart:io';

import 'package:nativebind_generator/nativebind_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

final update = Platform.environment['NATIVEBIND_UPDATE_GOLDENS'] == '1';

void expectFresh(GeneratorOptions options) {
  final r = Generator(GeneratorOptions(
    inputs: options.inputs,
    dartOut: options.dartOut,
    cppOut: options.cppOut,
    barrel: options.barrel,
    includeDirs: options.includeDirs,
    provides: options.provides,
    check: !update,
  )).run();
  expect(r.stale, isEmpty, reason: 'out of date; rerun with NATIVEBIND_UPDATE_GOLDENS=1');
}

void main() {
  test('runtime test modules (glue)', () {
    expectFresh(GeneratorOptions(inputs: ['$nativeRoot/tests/modules/thermo.cpp'], cppOut: '$nativeRoot/tests/modules'));
  });

  test('thermo Dart', () {
    expectFresh(GeneratorOptions(inputs: ['$nativeRoot/tests/modules/thermo.cpp'], dartOut: '$generatorRoot/../nativebind/test/generated/thermo'));
  });

  test('device module Dart', () {
    expectFresh(GeneratorOptions(inputs: ['$nativeRoot/tests/modules/device.cpp'], dartOut: '$generatorRoot/../nativebind/test/generated/device'));
  });

  test('device module glue', () {
    expectFresh(GeneratorOptions(inputs: ['$nativeRoot/tests/modules/device.cpp'], cppOut: '$nativeRoot/tests/modules'));
  });

  test('hvac fixture Dart', () {
    expectFresh(GeneratorOptions(inputs: ['$fixtures/hvac'], dartOut: '$generatorRoot/../nativebind/test/generated/hvac'));
  });

  test('names fixture Dart', () {
    expectFresh(GeneratorOptions(inputs: ['$fixtures/names'], dartOut: '$generatorRoot/../nativebind/test/generated/names'));
  });

  test('showcase example Dart', () {
    final app = '$generatorRoot/../../examples/showcase';
    expectFresh(GeneratorOptions(inputs: ['$app/native'], dartOut: '$app/lib/nativebind'));
  });

  test('check mode reports stale output without writing', () {
    final dir = Directory.systemTemp.createTempSync('nativebind_check_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final r = Generator(GeneratorOptions(inputs: ['$fixtures/hvac'], dartOut: dir.path, check: true)).run();
    expect(r.stale, hasLength(4));
    expect(dir.listSync(), isEmpty);
  });

  test('unchanged output is not rewritten', () {
    final dir = Directory.systemTemp.createTempSync('nativebind_write_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final opts = GeneratorOptions(inputs: ['$fixtures/hvac'], dartOut: dir.path, cppOut: dir.path);
    expect(Generator(opts).run().written, hasLength(8)); // + the two .nb.hpp
    final again = Generator(opts).run();
    expect(again.written, isEmpty);
    expect(again.unchanged, hasLength(8));
  });
}

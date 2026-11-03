// Mutated and truncated module sources must either generate or fail with a
// GeneratorException (a located diagnostic), never crash with anything else.
import 'dart:io';
import 'dart:math';

import 'package:nativebind_generator/nativebind_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

final _pieces = [
  '{', '}', '(', ')', '<', '>', ',', ';', '::', '"', "'", '/*', '*/', '//', '#', '\n', 'NATIVEBIND_PROP(', 'NATIVEBIND_LIST(',
  'NATIVEBIND_INVOKE ', 'NATIVEBIND_MODULE(', 'class ', 'struct ', 'enum class ', 'template <typename T>', 'std::vector<',
  'R"(', ')"', '= 0', '.min = ', '\\', '#define X', 'namespace {', 'using T = int;', '[[nodiscard]]', '...',
];

String mutate(String src, Random rng) {
  final b = StringBuffer();
  var at = 0;
  final n = 1 + rng.nextInt(4);
  final cuts = List.generate(n, (_) => rng.nextInt(src.length))..sort();
  for (final c in cuts) {
    if (c < at) continue;
    b.write(src.substring(at, c));
    switch (rng.nextInt(3)) {
      case 0: // delete a span
        at = min(src.length, c + rng.nextInt(20));
      case 1: // insert a piece
        b.write(_pieces[rng.nextInt(_pieces.length)]);
        at = c;
      default: // duplicate a span
        final end = min(src.length, c + rng.nextInt(30));
        b.write(src.substring(c, end));
        at = c;
    }
  }
  b.write(src.substring(at));
  return b.toString();
}

/// Generates; returns null on success or a GeneratorException, rethrows the rest.
Object? attempt(Map<String, String> files) {
  try {
    generate(files);
    return null;
  } on GeneratorException catch (e) {
    expect(e.message, isNotEmpty);
    return e;
  }
}

void main() {
  final fixture = File('$fixtures/hvac/air_handler.cpp').readAsStringSync();
  final header = File('$fixtures/hvac/hvac_types.hpp').readAsStringSync();
  final thermo = File('$nativeRoot/tests/modules/thermo.cpp').readAsStringSync();

  test('every truncation of a module', () {
    var failures = 0;
    for (var n = 0; n < thermo.length; n += 37) {
      if (attempt({'thermo.cpp': thermo.substring(0, n)}) != null) failures++;
    }
    expect(failures, greaterThan(0));
  });

  test('random mutations of a real module', () {
    final rng = Random(11);
    var ok = 0, rejected = 0;
    for (var i = 0; i < 300; i++) {
      final src = mutate(fixture, rng);
      try {
        attempt({'air_handler.cpp': src, 'hvac_types.hpp': header}) == null ? ok++ : rejected++;
      } catch (e, st) {
        fail('mutation $i crashed with ${e.runtimeType}: $e\n$st\n---\n$src');
      }
    }
    expect(rejected, greaterThan(0));
    printOnFailure('ok=$ok rejected=$rejected');
  });

  test('random token soup inside a module body', () {
    final rng = Random(12);
    for (var i = 0; i < 300; i++) {
      final body = List.generate(1 + rng.nextInt(12), (_) => _pieces[rng.nextInt(_pieces.length)]).join(' ');
      try {
        attempt({'m.cpp': module(body)});
      } catch (e, st) {
        fail('soup $i crashed with ${e.runtimeType}: $e\n$st\n---\n$body');
      }
    }
  });

  test('random bytes', () {
    final rng = Random(13);
    for (var i = 0; i < 200; i++) {
      final src = String.fromCharCodes(List.generate(rng.nextInt(200), (_) => 1 + rng.nextInt(126)));
      try {
        attempt({'m.cpp': 'NATIVEBIND_MODULE $src'});
      } catch (e, st) {
        fail('bytes $i crashed with ${e.runtimeType}: $e\n$st');
      }
    }
  });
}

// Generator throughput. Budgets are ~10x a desktop measurement.
// Run with: dart test --tags perf
@Tags(['perf'])
library;

import 'dart:io';

import 'package:nativebind_generator/nativebind_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

String synthetic(int k) => module('''
    enum class Mode$k { Off, Heat, Cool, Auto };
    struct Point$k { double x = 0; double y = 0; std::string label; };
    NATIVEBIND_PROP(double, setpoint, 21.0, .min = 5, .max = 35, .step = 0.5, .attrs = {{"unit", "celsius"}})
    NATIVEBIND_PROP(Mode$k, mode, Mode$k::Off)
    NATIVEBIND_READ(int, stage, 0)
    NATIVEBIND_READ(std::vector<std::string>, notes, {})
    NATIVEBIND_LIST(Point$k, points)
    NATIVEBIND_SIGNAL(tripped, std::string, int)
    NATIVEBIND_INVOKE double scale(double a, int b) { return a * b; }
    NATIVEBIND_INVOKE void reset() {}
private:
    void helper() { if (stage > 0) { for (int i = 0; i < 3; ++i) {} } }
''', name: 'Mod$k', prelude: '#include <string>\n#include <vector>');

void main() {
  test('300 modules generate within budget', () {
    final files = {for (var k = 0; k < 300; k++) 'mod_$k.cpp': synthetic(k)};
    final sw = Stopwatch()..start();
    final out = generate(files);
    sw.stop();
    expect(out.keys.where((k) => k.endsWith('.nb.dart')), hasLength(300));
    expect(out.keys.where((k) => k.endsWith('.nb.cpp')), hasLength(300));
    stdout.writeln('  perf: 300 modules                          ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(20000));
  });

  test('lexer throughput', () {
    final src = List.generate(200, synthetic).join('\n');
    final sw = Stopwatch()..start();
    var tokens = 0;
    for (var rep = 0; rep < 5; rep++) {
      tokens = Lexer(src, 'x.cpp').run().length;
    }
    sw.stop();
    final perSec = tokens * 5 / (sw.elapsedMicroseconds / 1e6);
    stdout.writeln('  perf: lexer                                ${(perSec / 1e6).toStringAsFixed(2)} M tokens/s');
    expect(perSec, greaterThan(200000));
  });
}

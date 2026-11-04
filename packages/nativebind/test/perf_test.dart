// Throughput and latency budgets. Budgets are generous (about 10x what a
// desktop measures) so they catch regressions in complexity, not noise.
// Run with: flutter test --tags perf
@Tags(['perf'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/generated.dart';
import 'package:nativebind/testing.dart';

import 'generated/thermo/nativebind_modules.dart';

import 'support/native_library.dart';

const thermo = 1;

void Function(WireWriter) reading(String sensor, double value) => (w) {
      w.beginStruct(3);
      w.stringValue(sensor);
      w.doubleValue(value);
      w.beginList(0);
    };

Future<FakeNative> boot() async {
  final f = FakeNative(nativebindModules);
  f.feed
    ..resync()
    ..added(thermo, f.idOf('Thermo'))
    ..meta(thermo, 0, min: 15, max: 30, step: 0.5)
    ..prop(thermo, 0, d(21.5))
    ..meta(thermo, 4, writable: false)
    ..prop(thermo, 4, d(20))
    ..listReset(thermo, 0, 1, []);
  f.publish();
  await NativeBind.start(native: f, modules: nativebindModules);
  return f;
}

double median(List<int> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2].toDouble();
}

double p95(List<int> xs) {
  final s = [...xs]..sort();
  return s[(s.length * 0.95).floor().clamp(0, s.length - 1)].toDouble();
}

void report(String name, String value) => stdout.writeln('  perf: ${name.padRight(44)} $value');

void main() {
  tearDown(NativeBind.stop);

  test('wire: decode 100k scalar values', () {
    final w = WireWriter();
    for (var k = 0; k < 100000; k++) {
      w.doubleValue(k * 0.5);
    }
    final bytes = Uint8List.fromList(w.bytes);
    final sw = Stopwatch()..start();
    final r = WireReader(bytes);
    var n = 0;
    while (!r.atEnd) {
      r.value();
      n++;
    }
    sw.stop();
    expect(n, 100000);
    report('decode 100k doubles', '${sw.elapsedMicroseconds} µs');
    expect(sw.elapsedMilliseconds, lessThan(200));
  });

  test('runtime: apply 10k property changes in one drain', () async {
    final f = await boot();
    final room = Thermo.instance.roomTemp;
    var notified = 0;
    room.addListener(() => notified++);
    final times = <int>[];
    for (var rep = 0; rep < 10; rep++) {
      for (var k = 0; k < 10000; k++) {
        f.feed.prop(thermo, 4, d(k + rep * 0.1));
      }
      f.publish();
      final sw = Stopwatch()..start();
      NativeBind.instance.drainNow();
      times.add(sw.elapsedMicroseconds);
    }
    report('drain 10k prop records (median)', '${median(times)} µs');
    expect(notified, lessThanOrEqualTo(10), reason: 'one notification per drain, not per record');
    expect(median(times), lessThan(100000));
  });

  test('runtime: 2000 list inserts then 2000 updates', () async {
    final f = await boot();
    final list = Thermo.instance.readings;
    var v = 1;
    for (var k = 0; k < 2000; k++) {
      f.feed.listInsert(thermo, 0, ++v, k, reading('s$k', 0));
    }
    f.publish();
    var sw = Stopwatch()..start();
    NativeBind.instance.drainNow();
    final insertUs = sw.elapsedMicroseconds;
    expect(list, hasLength(2000));
    for (var k = 0; k < 2000; k++) {
      f.feed.listUpdate(thermo, 0, ++v, k, reading('s$k', 1));
    }
    f.publish();
    sw = Stopwatch()..start();
    NativeBind.instance.drainNow();
    final updateUs = sw.elapsedMicroseconds;
    report('2000 list inserts', '$insertUs µs');
    report('2000 list updates', '$updateUs µs');
    expect(insertUs, lessThan(200000));
    expect(updateUs, lessThan(200000));
  });

  test('runtime: a list reset of 5000 structs (median)', () async {
    final f = await boot();
    final list = Thermo.instance.readings;
    void Function(WireWriter) withHistory(int k) => (w) {
          w.beginStruct(3);
          w.stringValue('sensor $k');
          w.doubleValue(k * 0.5);
          w.beginList(8);
          for (var h = 0; h < 8; h++) {
            w.intValue(h);
          }
        };
    final items = [for (var k = 0; k < 5000; k++) withHistory(k)];
    final times = <int>[];
    for (var rep = 0; rep < 9; rep++) {
      f.feed.listReset(thermo, 0, 2 + rep, items);
      f.publish();
      final sw = Stopwatch()..start();
      NativeBind.instance.drainNow();
      times.add(sw.elapsedMicroseconds);
    }
    expect(list, hasLength(5000));
    report('list reset of 5000 structs (median)', '${median(times)} µs');
    expect(median(times), lessThan(100000));
  });

  test('runtime: 5000 optimistic writes', () async {
    final f = await boot();
    final sp = Thermo.instance.setpoint;
    final sw = Stopwatch()..start();
    for (var k = 0; k < 5000; k++) {
      sp.value = 15 + (k % 30) * 0.5;
    }
    sw.stop();
    expect(f.writes, hasLength(5000));
    report('5000 optimistic writes', '${sw.elapsedMicroseconds} µs');
    expect(sw.elapsedMilliseconds, lessThan(500));
  });

  group('real library', () {
    late String library;
    setUpAll(() => library = requireNativeTestLibrary());

    test('write → acknowledged echo latency', () async {
      await NativeBind.start(library: library, modules: nativebindModules);
      final sp = Thermo.instance.setpoint;
      final times = <int>[];
      for (var k = 0; k < 200; k++) {
        final sw = Stopwatch()..start();
        await sp.write(k.isEven ? 20 : 21);
        times.add(sw.elapsedMicroseconds);
      }
      report('write → ack median / p95', '${median(times)} / ${p95(times)} µs');
      expect(median(times), lessThan(20000));
      expect(p95(times), lessThan(100000));
    });

    test('invoke → result latency', () async {
      await NativeBind.start(library: library, modules: nativebindModules);
      final times = <int>[];
      for (var k = 0; k < 200; k++) {
        final sw = Stopwatch()..start();
        await Thermo.instance.add(k.toDouble(), 1);
        times.add(sw.elapsedMicroseconds);
      }
      report('invoke → result median / p95', '${median(times)} / ${p95(times)} µs');
      expect(median(times), lessThan(20000));
      expect(p95(times), lessThan(100000));
    });

    test('1000 concurrent invokes complete', () async {
      await NativeBind.start(library: library, modules: nativebindModules);
      final sw = Stopwatch()..start();
      final r = await Future.wait([for (var k = 0; k < 1000; k++) Thermo.instance.add(k.toDouble(), 0)]);
      sw.stop();
      expect(r.last, 999);
      report('1000 concurrent invokes', '${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(5000));
    });
  });
}

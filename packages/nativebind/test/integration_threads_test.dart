// Integration with C++ worker threads: batches seen atomically from Dart,
// UI writes forwarded to an I/O thread, rapid writes, instance churn and
// restart cycles, against the real native library.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/nativebind.dart';

import 'generated/device/nativebind_modules.dart' as dev;
import 'generated/thermo/nativebind_modules.dart' as th;

import 'support/native_library.dart';

/// Waits (real time) until [cond] holds, draining the feed meanwhile.
Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    NativeBind.instance.drainNow();
  }
}

void main() {
  final library = requireNativeTestLibrary();
  final modules = [...th.nativebindModules, ...dev.nativebindModules];

  Future<void> start() => NativeBind.start(library: library, modules: modules);
  tearDown(NativeBind.stop);

  test('a polling worker\'s batches are never seen half-applied in Dart', () async {
    await start();
    final d = dev.Device.instance;
    var checks = 0;
    void check() {
      checks++;
      expect(d.a.value + d.b.value, 100, reason: 'a=${d.a.value} b=${d.b.value}');
    }

    d.a.addListener(check);
    d.b.addListener(check);
    await d.startPolling();
    await until(() => d.polls.value > 400);
    await d.stopPolling();
    expect(checks, greaterThan(20));
  });

  test('UI writes reach the device on its I/O thread', () async {
    await start();
    final d = dev.Device.instance;
    final kept = await d.setpoint.write(42);
    expect(kept, 42);
    await until(() => d.written.value == 42);
  });

  test('a burst of writes ends at the last value, acknowledged', () async {
    await start();
    final sp = th.Thermo.instance.setpoint;
    for (var k = 0; k < 300; k++) {
      sp.value = 15 + (k % 30) * 0.5;
    }
    final last = sp.value;
    await until(() => !sp.isPending);
    expect(sp.value, last);
    expect(sp.remoteValue, last);
  });

  test('a drag (edit session) sends few writes and lands on the final value', () async {
    await start();
    final sp = th.Thermo.instance.setpoint;
    final edit = sp.beginEdit(interval: const Duration(milliseconds: 50));
    for (var k = 0; k < 100; k++) {
      edit.update(16 + k * 0.1);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    edit.commit(25);
    await until(() => !sp.isPending);
    expect(sp.value, 25);
  });

  test('spawning and destroying many instances keeps Dart in step', () async {
    await start();
    final t = th.Thermo.instance;
    for (var k = 1; k <= 40; k++) {
      await t.spawnZone(k, 'zone $k');
    }
    await until(() => th.Zone.instances.length == 40);
    expect(th.Zone.instances.map((z) => z.key).toList(), [for (var k = 1; k <= 40; k++) k]);
    for (var k = 1; k <= 40; k += 2) {
      await t.destroyZone(k);
    }
    await until(() => th.Zone.instances.length == 20);
    expect(th.Zone.instances.every((z) => z.key.isEven), isTrue);
    expect(th.Zone.byKey(2)!.label.value, 'zone 2');
  });

  test('restart cycles with running workers', () async {
    for (var k = 0; k < 5; k++) {
      await start();
      final d = dev.Device.instance;
      await d.startPolling();
      await until(() => d.polls.value > 20);
      await NativeBind.stop();
      expect(d.isAlive, isFalse);
    }
  });

  test('a hot restart while a worker is polling reattaches cleanly', () async {
    await start();
    await dev.Device.instance.startPolling();
    await until(() => dev.Device.instance.polls.value > 20);
    await NativeBind.stop(stopNative: false); // what a hot restart does
    await start();
    final before = dev.Device.instance.polls.value;
    await until(() => dev.Device.instance.polls.value > before + 20);
    await dev.Device.instance.stopPolling();
  });

  test('calls made while C++ is busy all complete', () async {
    await start();
    await dev.Device.instance.startPolling();
    final results = await Future.wait([for (var k = 0; k < 200; k++) th.Thermo.instance.add(k.toDouble(), 1)]);
    expect(results, [for (var k = 0; k < 200; k++) k + 1.0]);
    await dev.Device.instance.stopPolling();
  });
}

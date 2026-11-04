// End to end: generated Dart code + the real C++ runtime and test modules
// (native/tests/modules/thermo.cpp), built with CMake on first run.


import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/nativebind.dart';

import 'generated/thermo/nativebind_modules.dart';

import 'support/native_library.dart';

void main() {
  final library = buildNativeTestLibrary();
  final skip = library == null ? 'cmake not available' : null;

  Future<Thermo> start() async {
    await NativeBind.start(library: library, modules: nativebindModules);
    return Thermo.instance;
  }

  Future<void> settle() => NativeBind.instance.settle();

  tearDown(() => NativeBind.stop());

  test('initial state and metadata come from C++', () async {
    final t = await start();
    expect(t.setpoint.value, 21.5);
    expect(t.setpoint.meta.min, 15);
    expect(t.setpoint.meta.max, 30);
    expect(t.setpoint.meta.attrs, {'unit': 'celsius'});
    expect(t.roomTemp.meta.attrs, {'unit': 'celsius', 'decimals': 1, 'trend': true, 'scale': 0.5});
    expect(t.name.value, 'Living room');
    expect(t.name.meta.label, 'Room name');
    expect(t.roomTemp.meta.writable, isFalse);
    expect(t.fanSpeed.meta.attr<int>('level'), 2);
  }, skip: skip);

  test('writes are validated by C++', () async {
    final t = await start();
    t.setpoint.value = 23;
    await settle();
    expect(t.setpoint.value, 23);
    expect(t.setpoint.isPending, isFalse);

    expect(await t.setpoint.write(29), 23, reason: 'the C++ validator rejects 29');
    expect(t.setpoint.value, 23);

    t.setpoint.value = 99;
    await settle();
    expect(t.setpoint.value, 30);

    expect(await t.name.write('A very long room name indeed'), 'A very long room', reason: 'C++ truncates');
  }, skip: skip);

  test('metadata changes made in C++', () async {
    final t = await start();
    await t.limitSetpoint(25);
    await t.setRoomTemp(19.5);
    await settle();
    expect(t.setpoint.meta.max, 25);
    expect(t.roomTemp.value, 19.5);
    t.setpoint.value = 28;
    expect(t.setpoint.value, 25, reason: 'clamped locally to the new range');
  }, skip: skip);

  test('calls: results, structs, exceptions', () async {
    final t = await start();
    expect(await t.add(1.5, 2.25), 3.75);
    final r = await t.makeReading('floor');
    expect(r.sensor, 'floor');
    expect(r.value, 1.5);
    expect(r.history, [1, 2]);
    await expectLater(t.fail(), throwsA(isA<BindInvokeException>().having((e) => e.message, 'message', 'boom')));
  }, skip: skip);

  test('the C++ guard decides writes and permissions', () async {
    final t = await start();
    await expectLater(t.calibrate(0.5), throwsA(isA<BindAccessDenied>()), reason: 'no guard: INVOKE_AS is refused');

    await t.installGuard(1);
    await expectLater(t.calibrate(0.5), throwsA(isA<BindAccessDenied>().having((e) => e.message, 'm', contains('level 2'))));
    expect(t.fanSpeed.canWrite, isTrue, reason: 'no Dart write guard installed');
    expect(() => t.fanSpeed.value = 2, throwsA(isA<BindAccessDenied>()), reason: 'refused by C++ at once');
    expect(t.fanSpeed.value, 1);

    await t.installGuard(2);
    await t.calibrate(0.5);
    t.fanSpeed.value = 2;
    await settle();
    expect(t.fanSpeed.value, 2);
  }, skip: skip);

  test('lists and signals', () async {
    final t = await start();
    final temps = <double>[];
    final sub = t.overTemp.listen(temps.add);
    await t.addReading(const Reading(sensor: 'a', value: 1, history: [3]));
    await t.addReading(const Reading(sensor: 'b', value: 2));
    await t.emitOverTemp(36.5);
    await settle();
    expect(t.readings.map((r) => r.sensor).toList(), ['a', 'b']);
    expect(t.readings.first.history, [3]);
    expect(temps, [36.5]);
    await sub.cancel();
  }, skip: skip);

  test('instances spawned and destroyed in C++', () async {
    final t = await start();
    await t.spawnZone(3, 'Lab');
    await t.spawnZone(1, 'Office');
    await settle();
    expect(Zone.instances.map((z) => '${z.key}:${z.label.value}').toList(), ['1:Office', '3:Lab']);
    final lab = Zone.byKey(3)!;
    await lab.bump();
    await settle();
    expect(lab.temp.value, 21);
    await t.destroyZone(3);
    await settle();
    expect(Zone.byKey(3), isNull);
    expect(lab.isAlive, isFalse);
  }, skip: skip);

  test('a hot restart reattaches to the running native state', () async {
    final t = await start();
    t.setpoint.value = 24;
    await settle();
    await NativeBind.stop(stopNative: false); // what a Flutter hot restart amounts to
    final again = await start();
    expect(identical(again, t), isFalse);
    expect(again.setpoint.value, 24);
  }, skip: skip);
}

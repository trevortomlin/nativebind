// Runtime behavior against a scripted native side: initial state, batching,
// optimistic writes and their acknowledgment, edits, lists, signals, calls,
// instances and resyncs.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/generated.dart';

import 'generated/thermo/nativebind_modules.dart';
import 'package:nativebind/testing.dart';

// Thermo: props setpoint(0) enabled(1) name(2) fanSpeed(3) roomTemp(4) stage(5);
// list readings(0); signals overTemp(0) note(1); methods boost(0) add(1) ...
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
    ..meta(thermo, 0, min: 15, max: 30, step: 0.5, attrs: {'unit': 'celsius'})
    ..prop(thermo, 0, d(21.5))
    ..meta(thermo, 1)
    ..prop(thermo, 1, b(true))
    ..meta(thermo, 2, label: 'Room name')
    ..prop(thermo, 2, s('Living room'))
    ..meta(thermo, 3, min: 0, max: 3, attrs: {'level': 2})
    ..prop(thermo, 3, i(1))
    ..meta(thermo, 4, writable: false, attrs: {'unit': 'celsius', 'decimals': 1, 'trend': true, 'scale': 0.5})
    ..prop(thermo, 4, d(20))
    ..meta(thermo, 5, writable: false)
    ..prop(thermo, 5, e(0))
    ..listReset(thermo, 0, 1, []);
  f.publish();
  await NativeBind.start(native: f, modules: nativebindModules);
  return f;
}

void push(FakeNative f, void Function(Feed feed) build) {
  build(f.feed);
  f.publish();
  NativeBind.instance.drainNow();
}

void main() {
  reflectionTests();

  tearDown(NativeBind.stop);

  group('startup', () {
    test('loads the complete state before returning', () async {
      await boot();
      final t = Thermo.instance;
      expect(t.setpoint.value, 21.5);
      expect(t.setpoint.meta.min, 15);
      expect(t.setpoint.meta.step, 0.5);
      expect(t.setpoint.meta.attrs, {'unit': 'celsius'});
      expect(t.roomTemp.meta.attr<int>('decimals'), 1);
      expect(t.roomTemp.meta.attr<bool>('trend'), isTrue);
      expect(t.roomTemp.meta.attr<double>('scale'), 0.5);
      expect(t.roomTemp.meta.attr<String>('decimals'), isNull, reason: 'wrong type');
      expect(t.roomTemp.meta.attr<int>('missing'), isNull);
      expect(t.name.value, 'Living room');
      expect(t.name.meta.label, 'Room name');
      expect(t.stage.value, Stage.off);
      expect(t.roomTemp.meta.writable, isFalse);
      expect(t.readings, isEmpty);
    });

    test('a module missing from the native library is reported', () async {
      final f = FakeNative(nativebindModules)..schemas.remove('Zone');
      await expectLater(NativeBind.start(native: f, modules: nativebindModules),
          throwsA(isA<BindNotStarted>().having((e) => e.message, 'message', contains('nativebind_add_modules'))));
    });

    test('a stale schema is reported with a diff', () async {
      final f = FakeNative(nativebindModules);
      f.schemas['Thermo'] = f.schemas['Thermo']!.replaceFirst('prop setpoint double rw', 'prop setpoint int rw');
      await expectLater(
          NativeBind.start(native: f, modules: nativebindModules),
          throwsA(isA<BindSchemaMismatch>().having((e) => e.message, 'message',
              allOf(contains('native: prop setpoint int rw'), contains('dart:   prop setpoint double rw')))));
    });

    test('Thermo.instance before start explains what to do', () {
      expect(() => Thermo.instance, throwsA(isA<BindNotStarted>()));
    });
  });

  group('values', () {
    test('listeners run once per batch', () async {
      final f = await boot();
      final t = Thermo.instance;
      var calls = 0;
      t.roomTemp.addListener(() => calls++);
      push(f, (feed) {
        feed
          ..prop(thermo, 4, d(21))
          ..prop(thermo, 4, d(22))
          ..prop(thermo, 4, d(23));
      });
      expect(calls, 1);
      expect(t.roomTemp.value, 23);
    });

    test('listeners see the whole batch applied', () async {
      final f = await boot();
      final t = Thermo.instance;
      final seen = <String>[];
      t.roomTemp.addListener(() => seen.add('${t.roomTemp.value}/${t.stage.value.name}'));
      push(f, (feed) {
        feed
          ..prop(thermo, 4, d(25))
          ..prop(thermo, 5, e(2));
      });
      expect(seen, ['25.0/high']);
    });

    test('meta changes notify', () async {
      final f = await boot();
      final t = Thermo.instance;
      var calls = 0;
      t.setpoint.addListener(() => calls++);
      push(f, (feed) => feed.meta(thermo, 0, min: 16, max: 26, step: 0.5, enabled: false));
      expect(calls, 1);
      expect(t.setpoint.meta.max, 26);
      expect(t.setpoint.canWrite, isFalse);
    });
  });

  group('writes', () {
    test('are optimistic and reconcile with the acknowledgment', () async {
      final f = await boot();
      final sp = Thermo.instance.setpoint;
      sp.value = 23;
      expect(sp.value, 23);
      expect(sp.isPending, isTrue);
      expect(f.writes.single.index, 0);
      expect(f.valueOf(f.writes.single), 23.0);
      final seq = f.writes.single.id;

      // An unrelated update (older ack) must not move the optimistic value.
      push(f, (feed) => feed.prop(thermo, 0, d(21.5), ack: seq - 1));
      expect(sp.value, 23);
      expect(sp.remoteValue, 21.5);

      // C++ processed the write and corrected it.
      push(f, (feed) => feed.prop(thermo, 0, d(22.5), ack: seq));
      expect(sp.value, 22.5);
      expect(sp.isPending, isFalse);
    });

    test('a rejected write reverts', () async {
      final f = await boot();
      final sp = Thermo.instance.setpoint;
      final kept = sp.write(29);
      expect(sp.value, 29);
      push(f, (feed) => feed.prop(thermo, 0, d(21.5), ack: f.writes.last.id));
      expect(await kept, 21.5);
      expect(sp.value, 21.5);
    });

    test('numbers are clamped to the range before sending', () async {
      final f = await boot();
      final t = Thermo.instance;
      t.setpoint.value = 99;
      expect(t.setpoint.value, 30);
      expect(f.valueOf(f.writes.last), 30.0);
      t.setpoint.setNumber(10);
      expect(f.valueOf(f.writes.last), 15.0);
    });

    test('refused at once when read-only, disabled or denied by the write guard', () async {
      final f = await boot();
      final t = Thermo.instance;
      var level = 0;
      NativeBind.writeGuard = (p) {
        final need = p.meta.attr<int>('level') ?? 0;
        return need > level ? BindAccessDenied('${p.name} needs level $need') : null;
      };
      addTearDown(() => NativeBind.writeGuard = null);
      expect(t.fanSpeed.canWrite, isFalse);
      expect(() => t.fanSpeed.value = 2, throwsA(isA<BindAccessDenied>().having((e) => e.message, 'm', 'fanSpeed needs level 2')));
      expect(t.setpoint.canWrite, isTrue);
      level = 2;
      t.fanSpeed.value = 2;
      expect(f.writes, hasLength(1));

      push(f, (feed) => feed.meta(thermo, 1, enabled: false));
      expect(() => t.enabled.value = false, throwsA(isA<BindWriteRejected>()));
      expect(t.enabled.whyNotWritable?.message, contains('disabled'));
    });

    test('a native refusal throws and keeps the old value', () async {
      final f = await boot();
      f.writeStatus = BindStatus.access;
      final sp = Thermo.instance.setpoint;
      expect(() => sp.value = 25, throwsA(isA<BindAccessDenied>()));
      expect(sp.value, 21.5);
      expect(sp.isPending, isFalse);
    });

    test('edit throttling follows elapsed time, not the wall clock', () async {
      final f = await boot();
      final sp = Thermo.instance.setpoint;
      // Fake time moves only the timers, as a wall-clock jump (an NTP step at
      // boot) would move only DateTime.now().
      fakeAsync((time) {
        final edit = sp.beginEdit(interval: const Duration(milliseconds: 40));
        edit.update(20);
        expect(f.writes, hasLength(1));
        time.elapse(const Duration(milliseconds: 100));
        edit.update(21);
        expect(f.writes, hasLength(2)); // the interval is over: sent at once
        edit.update(22);
        expect(f.writes, hasLength(2)); // within the next interval: held back
        time.elapse(const Duration(milliseconds: 40));
        expect(f.writes, hasLength(3)); // trailing edge
        expect(f.valueOf(f.writes.last), 22.0);
        edit.cancel();
      });
    });

    test('edits throttle writes and ignore incoming values until commit', () async {
      final f = await boot();
      final sp = Thermo.instance.setpoint;
      final edit = sp.beginEdit(interval: const Duration(milliseconds: 40));
      for (var k = 0; k < 10; k++) {
        edit.update(20.0 + k * 0.5);
      }
      expect(sp.value, 24.5);
      expect(f.writes, hasLength(1)); // leading edge only so far

      // C++ echoes the first write; the finger still wins.
      push(f, (feed) => feed.prop(thermo, 0, d(20), ack: f.writes.first.id));
      expect(sp.value, 24.5);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(f.writes, hasLength(2)); // trailing edge sent the latest value
      expect(f.valueOf(f.writes.last), 24.5);

      edit.commit(25);
      expect(f.valueOf(f.writes.last), 25.0);
      expect(sp.isEditing, isFalse);
      push(f, (feed) => feed.prop(thermo, 0, d(25), ack: f.writes.last.id));
      expect(sp.value, 25);
      expect(sp.isPending, isFalse);
    });

    test('cancelled edits show the C++ value again', () async {
      await boot();
      final sp = Thermo.instance.setpoint;
      final edit = sp.beginEdit();
      edit.update(28);
      edit.cancel();
      // the first update was sent and is still pending
      expect(sp.isPending, isTrue);
      expect(sp.value, 28);
    });
  });

  group('lists', () {
    test('apply operations and report changes', () async {
      final f = await boot();
      final l = Thermo.instance.readings;
      final changes = <ListChange<Reading>>[];
      final sub = l.changes.listen(changes.add);
      var notified = 0;
      l.addListener(() => notified++);
      push(f, (feed) {
        feed
          ..listInsert(thermo, 0, 2, 0, reading('a', 1))
          ..listInsert(thermo, 0, 3, 1, reading('b', 2))
          ..listInsert(thermo, 0, 4, 0, reading('c', 3))
          ..listUpdate(thermo, 0, 5, 1, reading('a', 10))
          ..listMove(thermo, 0, 6, 0, 2)
          ..listRemove(thermo, 0, 7, 0, 1);
      });
      await Future<void>.delayed(Duration.zero);
      expect(l.map((r) => '${r.sensor}${r.value.toInt()}').toList(), ['b2', 'c3']);
      expect(notified, 1);
      expect(changes.map((c) => c.runtimeType.toString()).toList(), [
        'ListInserted<Reading>',
        'ListInserted<Reading>',
        'ListInserted<Reading>',
        'ListUpdated<Reading>',
        'ListMoved<Reading>',
        'ListRemoved<Reading>'
      ]);
      expect((changes.last as ListRemoved<Reading>).items.single.sensor, 'a');
      await sub.cancel();
    });

    test('old operations are ignored and gaps request a resync', () async {
      final f = await boot();
      final l = Thermo.instance.readings;
      push(f, (feed) => feed.listReset(thermo, 0, 10, [reading('x', 1)]));
      push(f, (feed) => feed.listInsert(thermo, 0, 9, 0, reading('old', 0))); // already in the reset
      expect(l.length, 1);
      push(f, (feed) => feed.listInsert(thermo, 0, 12, 0, reading('gap', 0))); // 11 is missing
      expect(l.length, 1);
      expect(f.resyncRequests, 1);
    });

    test('are read-only in Dart', () async {
      await boot();
      expect(() => Thermo.instance.readings.add(const Reading()), throwsUnsupportedError);
    });
  });

  test('signals arrive after the batch, decoded', () async {
    final f = await boot();
    final t = Thermo.instance;
    final temps = <double>[];
    final notes = <(String, int)>[];
    t.overTemp.listen(temps.add);
    t.note.listen(notes.add);
    push(f, (feed) {
      feed
        ..signal(thermo, 0, [d(35.5)])
        ..signal(thermo, 1, [s('filter'), i(3)]);
    });
    await Future<void>.delayed(Duration.zero);
    expect(temps, [35.5]);
    expect(notes, [('filter', 3)]);
  });

  group('calls', () {
    test('complete with the decoded result', () async {
      final f = await boot();
      final future = Thermo.instance.add(1.5, 2.25);
      final call = f.invokes.single;
      expect(call.index, 1);
      final args = WireReader(call.bytes);
      expect([args.value(), args.value()], [1.5, 2.25]);
      push(f, (feed) => feed.result(call.id, value: d(3.75)));
      expect(await future, 3.75);
    });

    test('struct results', () async {
      final f = await boot();
      final future = Thermo.instance.makeReading('floor');
      push(f, (feed) => feed.result(f.invokes.single.id, value: reading('floor', 1.5)));
      expect(await future, const Reading(sensor: 'floor', value: 1.5));
    });

    test('C++ exceptions become BindInvokeException', () async {
      final f = await boot();
      final future = Thermo.instance.fail();
      push(f, (feed) => feed.result(f.invokes.single.id, status: BindStatus.exception, error: 'boom'));
      await expectLater(future, throwsA(isA<BindInvokeException>().having((e) => e.message, 'message', 'boom')));
    });

    test('a permission refused by the C++ guard arrives as BindAccessDenied', () async {
      final f = await boot();
      final call = Thermo.instance.calibrate(0.5);
      expect(f.invokes, hasLength(1), reason: 'C++ decides; Dart does not pre-check permissions');
      push(f, (feed) => feed.result(f.invokes.single.id, status: BindStatus.access, error: 'needs level 2'));
      await expectLater(call, throwsA(isA<BindAccessDenied>()));
    });

    test('pending calls fail when nativebind stops', () async {
      await boot();
      final failed = expectLater(Thermo.instance.boost(10), throwsA(isA<BindNotStarted>()));
      await NativeBind.stop();
      await failed;
    });
  });

  group('instances', () {
    test('are added in key order, found by key and removed', () async {
      final f = await boot();
      final zoneType = f.idOf('Zone');
      var changes = 0;
      Zone.instances.addListener(() => changes++);
      push(f, (feed) {
        feed
          ..added(20, zoneType, key: 7)
          ..meta(20, 0)
          ..prop(20, 0, s('Lab'))
          ..added(21, zoneType, key: 3)
          ..meta(21, 0)
          ..prop(21, 0, s('Office'));
      });
      expect(changes, 1);
      expect(Zone.instances.map((z) => z.key).toList(), [3, 7]);
      final lab = Zone.byKey(7)!;
      expect(lab.label.value, 'Lab');

      final pending = lab.label.write('Lab 2');
      push(f, (feed) => feed.removed(20));
      expect(Zone.instances.map((z) => z.key).toList(), [3]);
      expect(lab.isAlive, isFalse);
      expect(lab.label.canWrite, isFalse);
      await expectLater(pending, throwsA(isA<BindInstanceGone>()));
      await expectLater(lab.bump(), throwsA(isA<BindInstanceGone>()));
    });

    test('a resync drops instances that no longer exist', () async {
      final f = await boot();
      push(f, (feed) => feed.added(30, f.idOf('Zone'), key: 1));
      expect(Zone.instances, hasLength(1));
      push(f, (feed) {
        feed
          ..resync()
          ..added(thermo, f.idOf('Thermo'));
      });
      expect(Zone.instances, isEmpty);
      expect(Thermo.instance.setpoint.value, 21.5); // kept, same handle
    });
  });

  test('malformed data is reported and triggers a resync', () async {
    final f = await boot();
    final errors = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = old);
    push(f, (feed) => feed.prop(thermo, 0, (w) => w.tag(99)));
    expect(errors.single.library, 'nativebind');
    expect(f.resyncRequests, 1);
  });
}

// Additions for generic UIs: $values, choices, doc, labels.
void reflectionTests() {
  group('reflection', () {
    tearDown(NativeBind.stop);

    test(r'$values lists every property in declaration order', () async {
      await boot();
      final t = Thermo.instance;
      expect(t.$values.map((v) => v.name), ['setpoint', 'enabled', 'name', 'fanSpeed', 'roomTemp', 'stage']);
      expect(t.$values.first, same(t.setpoint));
    });

    test('choices: enum values, false/true for bools, null otherwise', () async {
      await boot();
      final t = Thermo.instance;
      expect(t.stage.choices, Stage.values);
      expect(t.enabled.choices, [false, true]);
      expect(t.setpoint.choices, isNull);
    });

    test('doc comes from the C++ doc comment', () async {
      await boot();
      expect(Thermo.instance.setpoint.doc, 'Target room temperature.');
      expect(Thermo.instance.enabled.doc, isNull);
    });

    test('enum labels', () {
      expect(Stage.high.label, 'High');
      expect(bindLabel(Stage.low), 'Low');
      expect(bindLabel(true), 'On');
      expect(bindLabel(false, off: 'Closed'), 'Closed');
      expect(bindLabel(null), '--');
    });
  });
}

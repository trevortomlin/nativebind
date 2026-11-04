// More runtime behavior against the scripted native side.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/generated.dart';
import 'package:nativebind/testing.dart';

import 'generated/thermo/nativebind_modules.dart';

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
    ..meta(thermo, 3, min: 0, max: 3)
    ..prop(thermo, 3, i(1))
    ..meta(thermo, 4, writable: false)
    ..prop(thermo, 4, d(20))
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
  tearDown(NativeBind.stop);

  test('sequence numbers compare across the 2^32 wrap', () {
    expect(BoundProperty.seqReached(5, 5), isTrue);
    expect(BoundProperty.seqReached(6, 5), isTrue);
    expect(BoundProperty.seqReached(4, 5), isFalse);
    expect(BoundProperty.seqReached(2, 0xfffffffe), isTrue); // wrapped past
    expect(BoundProperty.seqReached(0xfffffffe, 2), isFalse);
    expect(BoundProperty.seqReached(0x7fffffff, 0), isTrue);
  });

  test('several writes in flight: only the newest ack ends the optimistic value', () async {
    final f = await boot();
    final sp = Thermo.instance.setpoint;
    final results = <double>[];
    for (final v in [22.0, 23.0, 24.0]) {
      unawaited(sp.write(v).then(results.add));
    }
    final seqs = [for (final w in f.writes) w.id];
    push(f, (feed) => feed.prop(thermo, 0, d(22), ack: seqs[0]));
    expect(sp.value, 24, reason: 'still waiting for the last write');
    expect(sp.isPending, isTrue);
    push(f, (feed) => feed.prop(thermo, 0, d(24), ack: seqs[2]));
    expect(sp.isPending, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(results, [22.0, 24.0, 24.0]);
  });

  test('edits of int properties round numbers', () async {
    final f = await boot();
    final edit = Thermo.instance.fanSpeed.beginEdit(interval: Duration.zero);
    edit.updateNumber(1.6);
    edit.commitNumber(2.4);
    expect(f.writes.map(f.valueOf).toList(), [2, 2]);
  });

  test('random list operations mirror a model', () async {
    final f = await boot();
    final list = Thermo.instance.readings;
    final rng = Random(5);
    final model = <String>[];
    var version = 1;
    var key = 0;
    for (var step = 0; step < 600; step++) {
      push(f, (feed) {
        for (var k = 0; k < 1 + rng.nextInt(4); k++) {
          version++;
          final n = model.length;
          final op = rng.nextInt(5);
          if (op <= 1 || n == 0) {
            final at = rng.nextInt(n + 1);
            final name = 'k${key++}';
            model.insert(at, name);
            feed.listInsert(thermo, 0, version, at, reading(name, 0));
          } else if (op == 2) {
            final at = rng.nextInt(n);
            model.removeAt(at);
            feed.listRemove(thermo, 0, version, at, 1);
          } else if (op == 3) {
            final at = rng.nextInt(n);
            feed.listUpdate(thermo, 0, version, at, reading(model[at], step.toDouble()));
          } else {
            final from = rng.nextInt(n), to = rng.nextInt(n);
            model.insert(to, model.removeAt(from));
            feed.listMove(thermo, 0, version, from, to);
          }
        }
      });
      expect(list.map((r) => r.sensor).toList(), model, reason: 'step $step');
    }
    expect(f.resyncRequests, 0);
  });

  test('an instance re-added with a new handle gets a fresh proxy', () async {
    final f = await boot();
    push(f, (feed) => feed..added(10, f.idOf('Zone'), key: 4));
    final old = Zone.byKey(4)!;
    push(f, (feed) {
      feed
        ..removed(10)
        ..added(11, f.idOf('Zone'), key: 4)
        ..meta(11, 0)
        ..prop(11, 0, s('again'));
    });
    final fresh = Zone.byKey(4)!;
    expect(identical(old, fresh), isFalse);
    expect(old.isAlive, isFalse);
    expect(fresh.label.value, 'again');
  });

  test('every native status maps to its exception type', () {
    expect(BindException.fromStatus(BindStatus.access, ''), isA<BindAccessDenied>());
    expect(BindException.fromStatus(BindStatus.exception, ''), isA<BindInvokeException>());
    expect(BindException.fromStatus(BindStatus.noInstance, ''), isA<BindInstanceGone>());
    expect(BindException.fromStatus(BindStatus.notStarted, ''), isA<BindNotStarted>());
    expect(BindException.fromStatus(BindStatus.readOnly, ''), isA<BindWriteRejected>());
    expect(BindException.fromStatus(BindStatus.disabled, ''), isA<BindWriteRejected>());
    for (final s in [BindStatus.type, BindStatus.noMember, BindStatus.internal, -99]) {
      final e = BindException.fromStatus(s, 'm');
      expect(e.status, s);
      expect(e.toString(), contains('m'));
    }
  });

  test('call failures surface with their message', () async {
    final f = await boot();
    for (final (status, type) in [
      (BindStatus.type, isA<BindException>()),
      (BindStatus.access, isA<BindAccessDenied>()),
      (BindStatus.noInstance, isA<BindInstanceGone>()),
    ]) {
      final call = Thermo.instance.add(1, 2);
      push(f, (feed) => feed.result(f.invokes.last.id, status: status, error: 'why $status'));
      await expectLater(call, throwsA(type.having((e) => e.message, 'message', 'why $status')));
    }
    f.invokeStatus = BindStatus.noMember;
    await expectLater(Thermo.instance.add(1, 2), throwsA(isA<BindException>()));
  });

  test('unknown record kinds are skipped (forward compatible)', () async {
    final f = await boot();
    final unknown = WireWriter()
      ..u8(99) // a record kind from a newer runtime
      ..u32(3)
      ..u8(1)
      ..u8(2)
      ..u8(3);
    f.feed.prop(thermo, 4, d(31));
    f.publishRaw(Uint8List.fromList([...unknown.bytes, ...f.feed.take()]));
    NativeBind.instance.drainNow();
    expect(Thermo.instance.roomTemp.value, 31);
  });

  test('listeners see values before signals, and signals before call results', () async {
    final f = await boot();
    final t = Thermo.instance;
    final order = <String>[];
    t.roomTemp.addListener(() => order.add('value ${t.roomTemp.value}'));
    t.overTemp.listen((v) => order.add('signal $v (value ${t.roomTemp.value})'));
    final call = t.add(1, 2).then((v) => order.add('result $v'));
    push(f, (feed) {
      feed
        ..result(f.invokes.last.id, value: d(3))
        ..signal(thermo, 0, [d(40)])
        ..prop(thermo, 4, d(40));
    });
    await call;
    await Future<void>.delayed(Duration.zero);
    expect(order, ['value 40.0', 'signal 40.0 (value 40.0)', 'result 3.0']);
  });

  test('a state that cannot be applied does not resync forever', () async {
    final f = await boot();
    final errors = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = old);
    for (var k = 0; k < 6; k++) {
      push(f, (feed) => feed.prop(thermo, 0, (w) => w.tag(77)));
    }
    expect(errors, hasLength(6));
    expect(f.resyncRequests, 3);
    push(f, (feed) => feed.prop(thermo, 4, d(25))); // a good batch resets the counter
    push(f, (feed) => feed.prop(thermo, 0, (w) => w.tag(77)));
    expect(f.resyncRequests, 4);
  });

  test('values of a destroyed instance stop notifying and refuse writes', () async {
    final f = await boot();
    push(
        f,
        (feed) => feed
          ..added(12, f.idOf('Zone'), key: 9)
          ..meta(12, 0)
          ..prop(12, 0, s('x')));
    final z = Zone.byKey(9)!;
    var n = 0;
    z.label.addListener(() => n++);
    push(f, (feed) => feed.removed(12));
    final afterRemove = n;
    push(f, (feed) => feed.prop(12, 0, s('ignored')));
    expect(n, afterRemove);
    expect(() => z.label.value = 'y', throwsA(isA<BindInstanceGone>()));
    expect(() => z.label.beginEdit(), throwsA(isA<BindInstanceGone>()));
  });

  group('one bad record does not poison its batch', () {
    late List<FlutterErrorDetails> errors;
    setUp(() {
      errors = [];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);
    });

    test('later records and call results in the batch still apply', () async {
      final f = await boot();
      final t = Thermo.instance;
      final stage = t.stage; // bound, so its Enum codec decodes incoming values
      final sum = t.add(1, 2);
      final call = f.invokes.single.id;
      push(
          f,
          (feed) => feed
            ..prop(thermo, 5, e(42)) // no Stage has the value 42 (e.g. a C++ bit flag)
            ..prop(thermo, 4, d(25))
            ..result(call, value: d(3)));
      expect(await sum.timeout(const Duration(seconds: 1)), 3.0);
      expect(t.roomTemp.value, 25.0);
      expect(stage.hasValue, isFalse); // the bad record was skipped as a whole
      expect(errors, hasLength(1));
      expect(errors.single.exception, isA<BindProtocolException>());

      push(f, (feed) => feed.prop(thermo, 5, e(1)));
      expect(stage.value, Stage.low);
      push(f, (feed) => feed.prop(thermo, 5, e(42)));
      expect(stage.value, Stage.low); // keeps the last good value
    });

    test('a result whose value cannot be decoded fails just that call', () async {
      final f = await boot();
      final bad = Thermo.instance.add(1, 2);
      final good = Thermo.instance.add(2, 2);
      final [badCall, goodCall] = [for (final c in f.invokes) c.id];
      push(
          f,
          (feed) => feed
            ..result(badCall, value: (w) => w.tag(77))
            ..result(goodCall, value: d(4)));
      await expectLater(bad.timeout(const Duration(seconds: 1)), throwsA(isA<BindProtocolException>()));
      expect(await good.timeout(const Duration(seconds: 1)), 4.0);
    });

    test('a list operation that cannot be decoded leaves the list as it was', () async {
      final f = await boot();
      final readings = Thermo.instance.readings;
      // A struct with the wrong field count, at version 2.
      push(f, (feed) => feed.listInsert(thermo, 0, 2, 0, (w) => w..beginStruct(1)..stringValue('bad')));
      expect(readings, isEmpty);
      expect(errors, hasLength(1));
      // Version 2 was not consumed, so the real operation 2 still applies.
      push(f, (feed) => feed.listInsert(thermo, 0, 2, 0, reading('a', 1)));
      expect(readings.map((r) => r.sensor), ['a']);
    });

    test('gap resyncs stop when the full state itself cannot be applied', () async {
      final f = await boot();
      Thermo.instance.readings; // bound
      void badFullState(Feed feed) => feed
        ..resync()
        ..added(thermo, f.idOf('Thermo'))
        ..listReset(thermo, 0, 5, [(w) => w..beginStruct(1)..stringValue('bad')]);
      // Every full state fails to apply, and every later list operation then
      // sees a version gap: without a cap this resyncs on every change.
      var afterFive = 0;
      for (var k = 1; k <= 10; k++) {
        push(f, badFullState);
        push(f, (feed) => feed.listInsert(thermo, 0, 6 + k, 0, reading('x', 0)));
        if (k == 5) afterFive = f.resyncRequests;
      }
      expect(f.resyncRequests, afterFive, reason: 'resync requests must stop growing');
      expect(f.resyncRequests, lessThanOrEqualTo(6));

      // Once a full state applies again, gaps resync as usual.
      push(
          f,
          (feed) => feed
            ..resync()
            ..added(thermo, f.idOf('Thermo'))
            ..listReset(thermo, 0, 20, []));
      final before = f.resyncRequests;
      push(f, (feed) => feed.listInsert(thermo, 0, 30, 0, reading('y', 0)));
      expect(f.resyncRequests, before + 1);
    });
  });
}

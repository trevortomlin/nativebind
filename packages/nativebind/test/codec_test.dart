import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/generated.dart';

import 'generated/hvac/nativebind_modules.dart';

T roundTrip<T>(Codec<T> codec, T value) {
  final w = WireWriter(4); // tiny initial capacity exercises growth
  codec.encode(w, value);
  final r = WireReader(w.bytes);
  final out = codec.decode(r.value());
  expect(r.atEnd, isTrue);
  return out;
}

void main() {
  test('primitives', () {
    expect(roundTrip(boolCodec, true), true);
    expect(roundTrip(intCodec, -1 << 40), -1 << 40);
    expect(roundTrip(doubleCodec, 21.5), 21.5);
    expect(roundTrip(stringCodec, 'Zone 1 — 21 °C ✓'), 'Zone 1 — 21 °C ✓');
    expect(roundTrip(stringCodec, ''), '');
    expect(roundTrip(durationCodec, const Duration(minutes: 90)), const Duration(minutes: 90));
    final t = DateTime.fromMicrosecondsSinceEpoch(1793500000123456);
    expect(roundTrip(timeCodec, t), t);
  });

  test('ints decode as doubles where a double is expected', () {
    final w = WireWriter()..intValue(22);
    expect(doubleCodec.decode(WireReader(w.bytes).value()), 22.0);
  });

  test('containers', () {
    const lc = ListCodec<int>(intCodec);
    expect(roundTrip(lc, [1, 2, 3]), [1, 2, 3]);
    expect(() => roundTrip(lc, [1]).add(2), throwsUnsupportedError); // unmodifiable
    const oc = OptionalCodec<double>(doubleCodec);
    expect(roundTrip(oc, null), isNull);
    expect(roundTrip(oc, 4.5), 4.5);
  });

  test('generated enums and structs', () {
    expect(roundTrip(Mode.$codec, Mode.fanOnly), Mode.fanOnly);
    expect(Mode.fanOnly.wire, 32);
    const entry = ScheduleEntry(day: 2, label: 'Away', humidity: 40, mode: Mode.cool);
    expect(roundTrip(ScheduleEntry.$codec, entry), entry);
    expect(entry.start, const Duration(minutes: 390)); // default from the C++ initializer
    expect(entry.copyWith(day: 3).day, 3);
    expect(entry.copyWith(day: 3), isNot(entry));
    expect(entry.hashCode, const ScheduleEntry(day: 2, label: 'Away', humidity: 40, mode: Mode.cool).hashCode);
  });

  test('type mismatches and unknown enum values are protocol errors', () {
    final w = WireWriter()..stringValue('x');
    expect(() => doubleCodec.decode(WireReader(w.bytes).value()), throwsA(isA<BindProtocolException>()));
    final e = WireWriter()..enumValue(99);
    expect(() => Mode.$codec.decode(WireReader(e.bytes).value()), throwsA(isA<BindProtocolException>()));
    expect(() => WireReader(WireWriter().bytes).value(), throwsA(isA<BindProtocolException>()));
  });

  test('deep equality', () {
    expect(
        deepEquals([
          1,
          [2, 3]
        ], [
          1,
          [2, 3]
        ]),
        isTrue);
    expect(
        deepEquals([
          1,
          [2, 3]
        ], [
          1,
          [2, 4]
        ]),
        isFalse);
    expect(
        deepHash([
          1,
          [2]
        ]),
        deepHash([
          1,
          [2]
        ]));
  });
}

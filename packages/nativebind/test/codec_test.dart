import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/generated.dart';

import 'generated/hvac/nativebind_modules.dart';

/// Encodes [value], then decodes it both ways: through [WireReader.value]
/// and [Codec.decode], and straight from the bytes with [Codec.read].
T roundTrip<T>(Codec<T> codec, T value) {
  final w = WireWriter(4); // tiny initial capacity exercises growth
  codec.encode(w, value);
  final r = WireReader(w.bytes);
  final out = codec.decode(r.value());
  expect(r.atEnd, isTrue);
  final direct = WireReader(w.bytes);
  expect(codec.read(direct), out);
  expect(direct.atEnd, isTrue);
  return out;
}

/// The error [read] and [decode] give for the same bytes.
(String, String) errorsOf<T>(Codec<T> codec, void Function(WireWriter w) write) {
  final w = WireWriter();
  write(w);
  String fail(void Function() f) {
    try {
      f();
    } on BindProtocolException catch (e) {
      return e.message;
    }
    return 'no error';
  }

  return (fail(() => codec.read(WireReader(w.bytes))), fail(() => codec.decode(WireReader(w.bytes).value())));
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

  test('reading straight from the bytes fails like decoding', () {
    for (final (read, decode) in [
      errorsOf(doubleCodec, (w) => w.stringValue('x')),
      errorsOf(const ListCodec<int>(intCodec), (w) => w.intValue(1)),
      errorsOf(const ListCodec<int>(intCodec), (w) => w..beginList(1)..stringValue('x')),
      errorsOf(Mode.$codec, (w) => w.enumValue(99)),
      errorsOf(Mode.$codec, (w) => w.intValue(1)),
      errorsOf(ScheduleEntry.$codec, (w) => w.beginStruct(0)),
      errorsOf(ScheduleEntry.$codec, (w) => w.intValue(1)),
    ]) {
      expect(read, isNot('no error'));
      expect(read, decode);
    }
    final w = WireWriter()..intValue(22);
    expect(doubleCodec.read(WireReader(w.bytes)), 22.0); // an int where a double is expected
    final big = WireWriter()..beginList(1 << 30); // a count the message cannot hold
    expect(() => const ListCodec<int>(intCodec).read(WireReader(big.bytes)), throwsA(isA<BindProtocolException>()));
  });

  test('a struct codec generated without a reader still reads', () {
    // Code generated before StructCodec.read existed passes only decode.
    final legacy = StructCodec<(int, String)>(
      name: 'Pair',
      fieldCount: 2,
      decode: (f) => (intCodec.decode(f[0]), stringCodec.decode(f[1])),
      encode: (w, v) {
        intCodec.encode(w, v.$1);
        stringCodec.encode(w, v.$2);
      },
    );
    expect(roundTrip(legacy, (7, 'seven')), (7, 'seven'));
    expect(roundTrip(ListCodec(legacy), [(1, 'a'), (2, 'b')]), [(1, 'a'), (2, 'b')]);
  });
}

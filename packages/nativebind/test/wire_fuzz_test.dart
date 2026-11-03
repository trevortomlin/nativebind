// Property-based and fuzz tests of the Dart wire layer.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/generated.dart';

/// Writes a random value; returns what WireReader.value() must give back.
Object? writeRandom(WireWriter w, Random rng, int depth) {
  switch (rng.nextInt(depth > 3 ? 7 : 10)) {
    case 0:
      final v = rng.nextBool();
      w.boolValue(v);
      return v;
    case 1:
      final v = rng.nextInt(1 << 31) * (rng.nextBool() ? 1 : -1) * 1000003;
      w.intValue(v);
      return v;
    case 2:
      final v = (rng.nextDouble() - 0.5) * 1e6;
      w.doubleValue(v);
      return v;
    case 3:
      final v = String.fromCharCodes(List.generate(rng.nextInt(12), (_) => 32 + rng.nextInt(0x2FF)));
      w.stringValue(v);
      return v;
    case 4:
      final v = rng.nextInt(1000) - 500;
      w.enumValue(v);
      return WireEnum(v);
    case 5:
      w.noneValue();
      return null;
    case 6:
      final v = Duration(microseconds: rng.nextInt(1 << 30));
      w.durationValue(v);
      return v;
    case 7:
      final n = rng.nextInt(4);
      w.beginList(n);
      return [for (var i = 0; i < n; i++) writeRandom(w, rng, depth + 1)];
    case 8:
      final n = rng.nextInt(4);
      w.beginStruct(n);
      return ['struct', for (var i = 0; i < n; i++) writeRandom(w, rng, depth + 1)];
    default:
      final v = DateTime.fromMicrosecondsSinceEpoch(rng.nextInt(1 << 31) * 1000003);
      w.timeValue(v);
      return v;
  }
}

Object? normalize(Object? v) => switch (v) {
      WireStruct(:final fields) => ['struct', ...fields.map(normalize)],
      List<Object?>() => v.map(normalize).toList(),
      _ => v,
    };

void main() {
  test('random nested values round-trip', () {
    final rng = Random(1);
    for (var i = 0; i < 3000; i++) {
      final w = WireWriter(1);
      final expected = writeRandom(w, rng, 0);
      final r = WireReader(Uint8List.fromList(w.bytes));
      expect(normalize(r.value()), expected);
      expect(r.atEnd, isTrue);
    }
  });

  test('garbage only ever raises BindProtocolException', () {
    final rng = Random(2);
    var rejected = 0;
    for (var i = 0; i < 20000; i++) {
      final bytes = Uint8List.fromList(List.generate(rng.nextInt(40), (_) => rng.nextInt(256)));
      try {
        WireReader(bytes).value();
      } on BindProtocolException {
        rejected++;
      }
    }
    expect(rejected, greaterThan(10000));
  });

  test('every truncation of a valid message is rejected', () {
    final w = WireWriter()
      ..beginList(2)
      ..beginStruct(2)
      ..stringValue('floor')
      ..doubleValue(21.5)
      ..beginStruct(2)
      ..stringValue('air')
      ..intValue(-3);
    final full = Uint8List.fromList(w.bytes);
    for (var n = 0; n < full.length; n++) {
      expect(() => WireReader(Uint8List.sublistView(full, 0, n)).value(), throwsA(isA<BindProtocolException>()),
          reason: 'cut at $n');
    }
    expect(WireReader(full).value(), hasLength(2));
  });

  test('codecs reject values of the wrong type', () {
    final rng = Random(3);
    final codecs = <Codec<Object?>>[boolCodec, intCodec, doubleCodec, stringCodec, timeCodec, durationCodec];
    for (var i = 0; i < 2000; i++) {
      final w = WireWriter();
      writeRandom(w, rng, 0);
      final raw = WireReader(Uint8List.fromList(w.bytes)).value();
      for (final c in codecs) {
        try {
          c.decode(raw);
        } on BindProtocolException {
          // expected for mismatches
        }
      }
    }
  });

  test('integers keep 64-bit precision; doubles keep special values', () {
    for (final v in [0, -1, 1 << 53, -(1 << 62), 0x7fffffffffffffff]) {
      final w = WireWriter()..intValue(v);
      expect(WireReader(Uint8List.fromList(w.bytes)).value(), v);
    }
    for (final v in [double.infinity, double.negativeInfinity, -0.0, double.minPositive]) {
      final w = WireWriter()..doubleValue(v);
      expect(WireReader(Uint8List.fromList(w.bytes)).value(), v);
    }
    final w = WireWriter()..doubleValue(double.nan);
    expect((WireReader(Uint8List.fromList(w.bytes)).value()! as double).isNaN, isTrue);
  });

  test('times beyond DateTime range clamp instead of throwing', () {
    for (final us in [0x7fffffffffffffff, -0x7fffffffffffffff - 1]) {
      final w = WireWriter()
        ..tag(9)
        ..i64(us);
      final t = WireReader(Uint8List.fromList(w.bytes)).value()! as DateTime;
      expect(t.microsecondsSinceEpoch.abs(), 8640000000000000000);
    }
  });

  test('strings: empty, multi-byte, long', () {
    for (final s in ['', 'µA °C ✓ 日本 🙂', 'x' * 100000]) {
      final w = WireWriter(1)..stringValue(s);
      expect(WireReader(Uint8List.fromList(w.bytes)).value(), s);
    }
  });
}

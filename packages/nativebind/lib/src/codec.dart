// Typed conversion between decoded wire values and Dart types. Generated code
// composes these; applications never need them directly.

import 'errors.dart';
import 'wire.dart';

/// Converts between a Dart type and its wire encoding.
abstract class Codec<T> {
  const Codec();

  /// Converts a value decoded by [WireReader.value].
  T decode(Object? raw);

  /// Reads one tagged value straight from [r]. Codecs of containers, enums
  /// and structs override it so no intermediate [WireReader.value] tree is
  /// built; every other value goes through [decode].
  T read(WireReader r) => decode(r.value());

  /// Appends the tagged encoding of [value].
  void encode(WireWriter w, T value);
}

Never _mismatch(String want, Object? raw) =>
    throw BindProtocolException('expected $want, got ${raw.runtimeType} ($raw)');

final class _BoolCodec extends Codec<bool> {
  const _BoolCodec();
  @override
  bool decode(Object? raw) => raw is bool ? raw : _mismatch('bool', raw);
  @override
  void encode(WireWriter w, bool value) => w.boolValue(value);
}

final class _IntCodec extends Codec<int> {
  const _IntCodec();
  @override
  int decode(Object? raw) => raw is int ? raw : _mismatch('int', raw);
  @override
  void encode(WireWriter w, int value) => w.intValue(value);
}

final class _DoubleCodec extends Codec<double> {
  const _DoubleCodec();
  @override
  double decode(Object? raw) => raw is num ? raw.toDouble() : _mismatch('double', raw);
  @override
  void encode(WireWriter w, double value) => w.doubleValue(value);
}

final class _StringCodec extends Codec<String> {
  const _StringCodec();
  @override
  String decode(Object? raw) => raw is String ? raw : _mismatch('String', raw);
  @override
  void encode(WireWriter w, String value) => w.stringValue(value);
}

final class _TimeCodec extends Codec<DateTime> {
  const _TimeCodec();
  @override
  DateTime decode(Object? raw) => raw is DateTime ? raw : _mismatch('DateTime', raw);
  @override
  void encode(WireWriter w, DateTime value) => w.timeValue(value);
}

final class _DurationCodec extends Codec<Duration> {
  const _DurationCodec();
  @override
  Duration decode(Object? raw) => raw is Duration ? raw : _mismatch('Duration', raw);
  @override
  void encode(WireWriter w, Duration value) => w.durationValue(value);
}

final class _VoidCodec extends Codec<void> {
  const _VoidCodec();
  @override
  void decode(Object? raw) {}
  @override
  void encode(WireWriter w, void value) => w.tag(WireTag.voidT);
}

const Codec<bool> boolCodec = _BoolCodec();
const Codec<int> intCodec = _IntCodec();
const Codec<double> doubleCodec = _DoubleCodec();
const Codec<String> stringCodec = _StringCodec();
const Codec<DateTime> timeCodec = _TimeCodec();
const Codec<Duration> durationCodec = _DurationCodec();
const Codec<void> voidCodec = _VoidCodec();

/// `std::vector<T>` as an unmodifiable `List<T>`.
final class ListCodec<T> extends Codec<List<T>> {
  const ListCodec(this.item);
  final Codec<T> item;

  @override
  List<T> decode(Object? raw) => raw is List ? List<T>.unmodifiable(raw.map(item.decode)) : _mismatch('List', raw);

  @override
  List<T> read(WireReader r) {
    if (r.peek() != WireTag.listT) return decode(r.value());
    r.u8();
    final n = r.u32();
    if (n > r.remaining) throw const BindProtocolException('list length exceeds message');
    return List<T>.unmodifiable(List<T>.generate(n, (_) => item.read(r), growable: false));
  }

  @override
  void encode(WireWriter w, List<T> value) {
    w.beginList(value.length);
    for (final v in value) {
      item.encode(w, v);
    }
  }
}

/// `std::optional<T>` as `T?`.
final class OptionalCodec<T extends Object> extends Codec<T?> {
  const OptionalCodec(this.inner);
  final Codec<T> inner;

  @override
  T? decode(Object? raw) => raw == null ? null : inner.decode(raw);

  @override
  T? read(WireReader r) {
    final t = r.peek();
    if (t == WireTag.none || t == WireTag.voidT) {
      r.u8();
      return null;
    }
    return inner.read(r);
  }

  @override
  void encode(WireWriter w, T? value) => value == null ? w.noneValue() : inner.encode(w, value);
}

/// A C++ enum as a Dart enum carrying the enumerator value.
/// Implemented by every generated enum: its C++ value and a display label
/// (`///< @label Text` on the enumerator, or the name in words).
abstract interface class BindEnum implements Enum {
  int get wire;
  String get label;
}

/// The display label of [value]: a [BindEnum]'s label, On/Off for bools,
/// otherwise `toString()`.
String bindLabel(Object? value, {String on = 'On', String off = 'Off'}) => switch (value) {
      final BindEnum e => e.label,
      final bool b => b ? on : off,
      final Enum e => e.name,
      null => '--',
      _ => '$value',
    };

final class EnumCodec<E extends Enum> extends Codec<E> {
  EnumCodec(List<E> values, this._wire)
      : values = List.unmodifiable(values),
        _byWire = {for (final v in values) _wire(v): v};

  /// Every value, in declaration order.
  final List<E> values;

  final int Function(E) _wire;
  final Map<int, E> _byWire;

  @override
  E decode(Object? raw) {
    if (raw is! WireEnum) _mismatch('enum', raw);
    return _byWire[raw.value] ?? (throw BindProtocolException('unknown value ${raw.value} for enum ${E.toString()}'));
  }

  @override
  E read(WireReader r) {
    if (r.peek() != WireTag.enumT) return decode(r.value());
    r.u8();
    final v = r.i32();
    return _byWire[v] ?? (throw BindProtocolException('unknown value $v for enum ${E.toString()}'));
  }

  @override
  void encode(WireWriter w, E value) => w.enumValue(_wire(value));
}

/// A C++ struct as a generated Dart class.
final class StructCodec<T> extends Codec<T> {
  StructCodec({
    required this.name,
    required this.fieldCount,
    required T Function(List<Object?> fields) decode,
    required void Function(WireWriter w, T value) encode,
    T Function(WireReader r)? read,
  })  : _decode = decode,
        _encode = encode,
        _read = read;

  final String name;
  final int fieldCount;
  final T Function(List<Object?>) _decode;
  final void Function(WireWriter, T) _encode;

  /// Reads the fields in order (generated); null in code generated before
  /// it existed, which reads them through [decode].
  final T Function(WireReader)? _read;

  @override
  T decode(Object? raw) {
    if (raw is! WireStruct) _mismatch('struct $name', raw);
    if (raw.fields.length != fieldCount) {
      throw BindProtocolException('struct $name has ${raw.fields.length} fields, expected $fieldCount');
    }
    return _decode(raw.fields);
  }

  @override
  T read(WireReader r) {
    final fields = _read;
    if (fields == null || r.peek() != WireTag.structT) return decode(r.value());
    r.u8();
    final n = r.u16();
    if (n != fieldCount) throw BindProtocolException('struct $name has $n fields, expected $fieldCount');
    return fields(r);
  }

  @override
  void encode(WireWriter w, T value) {
    w.beginStruct(fieldCount);
    _encode(w, value);
  }
}

/// Deep equality for generated data classes (lists compare element-wise).
bool deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int deepHash(Object? v) => v is List ? Object.hashAll(v.map(deepHash)) : v.hashCode;

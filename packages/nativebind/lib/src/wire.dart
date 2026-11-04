// Binary encoding shared with the native runtime (native/doc/wire-format.md).

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// Value tags (nativebind::Tag).
abstract final class WireTag {
  static const voidT = 0;
  static const boolT = 1;
  static const intT = 2;
  static const doubleT = 3;
  static const stringT = 4;
  static const enumT = 5;
  static const structT = 6;
  static const listT = 7;
  static const none = 8;
  static const time = 9;
  static const duration = 10;
}

/// A decoded enum value (kept distinct from ints until a codec maps it).
final class WireEnum {
  const WireEnum(this.value);
  final int value;

  @override
  bool operator ==(Object other) => other is WireEnum && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => 'enum($value)';
}

/// A decoded struct: its fields in declaration order.
final class WireStruct {
  const WireStruct(this.fields);
  final List<Object?> fields;
  @override
  String toString() => 'struct$fields';
}

/// Appends encoded values to a growable buffer.
final class WireWriter {
  WireWriter([int capacity = 256]) : _bytes = Uint8List(capacity) {
    _data = ByteData.sublistView(_bytes);
  }

  Uint8List _bytes;
  late ByteData _data;
  int _length = 0;

  int get length => _length;

  /// The encoded bytes (a view; valid until the next write).
  Uint8List get bytes => Uint8List.sublistView(_bytes, 0, _length);

  void clear() => _length = 0;

  void _reserve(int n) {
    if (_length + n <= _bytes.length) return;
    var cap = _bytes.length * 2;
    while (cap < _length + n) {
      cap *= 2;
    }
    final next = Uint8List(cap)..setRange(0, _length, _bytes);
    _bytes = next;
    _data = ByteData.sublistView(_bytes);
  }

  void u8(int v) {
    _reserve(1);
    _bytes[_length++] = v;
  }

  void u16(int v) {
    _reserve(2);
    _data.setUint16(_length, v, Endian.little);
    _length += 2;
  }

  void u32(int v) {
    _reserve(4);
    _data.setUint32(_length, v, Endian.little);
    _length += 4;
  }

  void i32(int v) {
    _reserve(4);
    _data.setInt32(_length, v, Endian.little);
    _length += 4;
  }

  void i64(int v) {
    _reserve(8);
    _data.setInt64(_length, v, Endian.little);
    _length += 8;
  }

  void f64(double v) {
    _reserve(8);
    _data.setFloat64(_length, v, Endian.little);
    _length += 8;
  }

  void rawBytes(List<int> b) {
    _reserve(b.length);
    _bytes.setRange(_length, _length + b.length, b);
    _length += b.length;
  }

  void tag(int t) => u8(t);

  void boolValue(bool v) {
    tag(WireTag.boolT);
    u8(v ? 1 : 0);
  }

  void intValue(int v) {
    tag(WireTag.intT);
    i64(v);
  }

  void doubleValue(double v) {
    tag(WireTag.doubleT);
    f64(v);
  }

  void stringValue(String v) {
    final b = utf8.encode(v);
    tag(WireTag.stringT);
    u32(b.length);
    rawBytes(b);
  }

  void enumValue(int v) {
    tag(WireTag.enumT);
    i32(v);
  }

  void beginStruct(int fieldCount) {
    tag(WireTag.structT);
    u16(fieldCount);
  }

  void beginList(int count) {
    tag(WireTag.listT);
    u32(count);
  }

  void noneValue() => tag(WireTag.none);

  void timeValue(DateTime t) {
    tag(WireTag.time);
    i64(t.microsecondsSinceEpoch);
  }

  void durationValue(Duration d) {
    tag(WireTag.duration);
    i64(d.inMicroseconds);
  }
}

/// Largest |microseconds since epoch| a DateTime can hold.
const _maxDateTimeUs = 8640000000000000000;

/// Reads encoded data; every read is bounds-checked.
final class WireReader {
  WireReader(Uint8List bytes)
      : _bytes = bytes,
        _data = ByteData.sublistView(bytes),
        _end = bytes.length;

  WireReader._sub(this._bytes, this._data, this._pos, this._end);

  final Uint8List _bytes;
  final ByteData _data;
  int _pos = 0;
  final int _end;

  bool get atEnd => _pos >= _end;
  int get remaining => _end - _pos;

  void _need(int n) {
    if (_end - _pos < n) throw const BindProtocolException('message truncated');
  }

  int u8() {
    _need(1);
    return _bytes[_pos++];
  }

  /// The next byte (a value's tag), without consuming it.
  int peek() {
    _need(1);
    return _bytes[_pos];
  }

  int i8() {
    _need(1);
    return _data.getInt8(_pos++);
  }

  int u16() {
    _need(2);
    final v = _data.getUint16(_pos, Endian.little);
    _pos += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = _data.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int i32() {
    _need(4);
    final v = _data.getInt32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  /// The 64 bits of a uint64 as a Dart int: values at or above 2^63 are
  /// negative (instance keys keep their bits; ordering compares them unsigned).
  int u64() => i64();

  int i64() {
    _need(8);
    final v = _data.getInt64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  double f64() {
    _need(8);
    final v = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  String str() {
    final n = u32();
    _need(n);
    final s = utf8.decode(Uint8List.sublistView(_bytes, _pos, _pos + n), allowMalformed: true);
    _pos += n;
    return s;
  }

  /// A reader over the next [n] bytes; this reader skips past them.
  WireReader sub(int n) {
    _need(n);
    final r = WireReader._sub(_bytes, _data, _pos, _pos + n);
    _pos += n;
    return r;
  }

  /// Decodes one tagged value into Dart objects: bool, int, double, String,
  /// [WireEnum], [WireStruct], List, null (void/none), DateTime, Duration.
  Object? value() {
    final t = u8();
    switch (t) {
      case WireTag.voidT || WireTag.none:
        return null;
      case WireTag.boolT:
        return u8() != 0;
      case WireTag.intT:
        return i64();
      case WireTag.doubleT:
        return f64();
      case WireTag.stringT:
        return str();
      case WireTag.enumT:
        return WireEnum(i32());
      case WireTag.structT:
        final n = u16();
        return WireStruct(List<Object?>.generate(n, (_) => value(), growable: false));
      case WireTag.listT:
        final n = u32();
        if (n > remaining) throw const BindProtocolException('list length exceeds message');
        return List<Object?>.generate(n, (_) => value(), growable: false);
      case WireTag.time:
        // C++ "never" sentinels (time_point::max/min) exceed DateTime's range: clamp.
        return DateTime.fromMicrosecondsSinceEpoch(i64().clamp(-_maxDateTimeUs, _maxDateTimeUs));
      case WireTag.duration:
        return Duration(microseconds: i64());
      default:
        throw BindProtocolException('unknown value tag $t');
    }
  }
}

import 'dart:typed_data';

import '../../generated.dart';
import '../native.dart' as native_abi show abiVersion;

/// Builds change-feed records exactly as the native runtime encodes them.
class Feed {
  final _w = WireWriter();

  Uint8List take() {
    final out = Uint8List.fromList(_w.bytes);
    _w.clear();
    return out;
  }

  void _rec(int kind, void Function(WireWriter w) body) {
    final b = WireWriter();
    body(b);
    _w.u8(kind);
    _w.u32(b.length);
    _w.rawBytes(b.bytes);
  }

  void resync() => _rec(1, (_) {});
  void added(int handle, int type, {int key = 0}) => _rec(2, (w) {
        w.u32(handle);
        w.u16(type);
        w.i64(key);
      });
  void removed(int handle) => _rec(3, (w) => w.u32(handle));

  void prop(int handle, int index, void Function(WireWriter w) value, {int ack = 0}) => _rec(4, (w) {
        w.u32(handle);
        w.u16(index);
        w.u32(ack);
        value(w);
      });

  void meta(int handle, int index,
          {double min = double.negativeInfinity,
          double max = double.infinity,
          double step = 0,
          bool writable = true,
          bool enabled = true,
          String label = '',
          Map<String, Object> attrs = const {}}) =>
      _rec(5, (w) {
        w.u32(handle);
        w.u16(index);
        w.f64(min);
        w.f64(max);
        w.f64(step);
        w.u8((writable ? 1 : 0) | (enabled ? 2 : 0));
        _untaggedString(w, label);
        w.u16(attrs.length);
        for (final MapEntry(:key, :value) in attrs.entries) {
          _untaggedString(w, key);
          switch (value) {
            case bool():
              w.boolValue(value);
            case int():
              w.intValue(value);
            case double():
              w.doubleValue(value);
            default:
              w.stringValue('$value');
          }
        }
      });

  void listReset(int handle, int index, int version, List<void Function(WireWriter w)> items) => _rec(6, (w) {
        w.u32(handle);
        w.u16(index);
        w.u32(version);
        w.u32(items.length);
        for (final i in items) {
          i(w);
        }
      });

  void listInsert(int handle, int index, int version, int at, void Function(WireWriter w) item) => _rec(7, (w) {
        w.u32(handle);
        w.u16(index);
        w.u32(version);
        w.u32(at);
        item(w);
      });

  void listRemove(int handle, int index, int version, int at, int count) => _rec(8, (w) {
        w.u32(handle);
        w.u16(index);
        w.u32(version);
        w.u32(at);
        w.u32(count);
      });

  void listUpdate(int handle, int index, int version, int at, void Function(WireWriter w) item) => _rec(9, (w) {
        w.u32(handle);
        w.u16(index);
        w.u32(version);
        w.u32(at);
        item(w);
      });

  void listMove(int handle, int index, int version, int from, int to) => _rec(10, (w) {
        w.u32(handle);
        w.u16(index);
        w.u32(version);
        w.u32(from);
        w.u32(to);
      });

  void signal(int handle, int index, List<void Function(WireWriter w)> args) => _rec(11, (w) {
        w.u32(handle);
        w.u16(index);
        w.u8(args.length);
        for (final a in args) {
          a(w);
        }
      });

  void result(int callId, {void Function(WireWriter w)? value, int status = 0, String error = ''}) => _rec(12, (w) {
        w.u32(callId);
        w.i32(status);
        if (status == 0) {
          (value ?? (w) => w.tag(0))(w);
        } else {
          _untaggedString(w, error);
        }
      });
}

void _untaggedString(WireWriter w, String s) {
  final b = WireWriter()..stringValue(s);
  w.rawBytes(b.bytes.sublist(1)); // drop the tag
}

/// Value encoders for records: `feed.prop(h, 0, d(21.5))`.
void Function(WireWriter) d(double v) => (w) => w.doubleValue(v);
void Function(WireWriter) i(int v) => (w) => w.intValue(v);
void Function(WireWriter) b(bool v) => (w) => w.boolValue(v);
void Function(WireWriter) s(String v) => (w) => w.stringValue(v);
void Function(WireWriter) e(int v) => (w) => w.enumValue(v);

/// A write or invoke the runtime sent to the native side.
class Call {
  Call(this.instance, this.index, this.bytes, this.id);
  final int instance;
  final int index;
  final Uint8List bytes;
  final int id;
}

/// A native side scripted by the test.
class FakeNative implements BindNative {
  FakeNative(List<ModuleType<ModuleProxy>> types) {
    for (final t in types) {
      schemas[t.name] = t.schema;
    }
  }

  final schemas = <String, String>{};
  late final List<String> _ids = schemas.keys.toList();
  final feed = Feed();
  final writes = <Call>[];
  final invokes = <Call>[];
  int resyncRequests = 0;
  int writeStatus = 0;
  int invokeStatus = 0;
  bool started = false;
  Uint8List _pending = Uint8List(0);

  int idOf(String name) => _ids.indexOf(name);

  /// Queues raw feed bytes (e.g. malformed or future record kinds).
  void publishRaw(Uint8List bytes) => _pending = Uint8List.fromList([..._pending, ...bytes]);

  /// Queues the records built so far for the next drain.
  void publish() {
    final more = feed.take();
    _pending = Uint8List.fromList([..._pending, ...more]);
  }

  /// Decodes the single value of a recorded write.
  Object? valueOf(Call c) => WireReader(c.bytes).value();

  @override
  int abiVersion() => native_abi.abiVersion;
  @override
  void initDartApi() {}
  @override
  void attachPort(int port) {}
  @override
  int start() {
    started = true;
    return 0;
  }

  @override
  void stop() => started = false;

  @override
  Uint8List drain() {
    final out = _pending;
    _pending = Uint8List(0);
    return out;
  }

  @override
  void requestResync() => resyncRequests++;
  @override
  int typeId(String name) => _ids.contains(name) ? _ids.indexOf(name) : -9;
  @override
  String? typeSchema(int id) => schemas[_ids[id]];

  @override
  int write(int instance, int prop, Uint8List value, int seq) {
    if (writeStatus != 0) return writeStatus;
    writes.add(Call(instance, prop, Uint8List.fromList(value), seq));
    return 0;
  }

  @override
  int invoke(int instance, int method, Uint8List args, int callId) {
    if (invokeStatus != 0) return invokeStatus;
    invokes.add(Call(instance, method, Uint8List.fromList(args), callId));
    return 0;
  }

  @override
  int flush(int timeoutMs) => 0;
  @override
  String lastError() => 'fake error';
}

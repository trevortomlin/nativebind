import 'dart:async';
import 'dart:ffi' show NativePort;
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'codec.dart';
import 'collections.dart';
import 'errors.dart';
import 'instance.dart';
import 'meta.dart';
import 'module.dart';
import 'native.dart';
import 'values.dart';
import 'wire.dart';

/// Record kinds of the change feed (nativebind::detail::Rec).
abstract final class _Rec {
  static const resync = 1;
  static const instanceAdded = 2;
  static const instanceRemoved = 3;
  static const prop = 4;
  static const meta = 5;
  static const listReset = 6;
  static const listInsert = 7;
  static const listRemove = 8;
  static const listUpdate = 9;
  static const listMove = 10;
  static const signal = 11;
  static const result = 12;
}

typedef _CallDone = void Function(int status, Object? value, String? error);

/// Result status for a Result record whose value could not be decoded.
const _malformedResult = -1000;

/// How applying one drained batch went.
typedef _Applied = ({int failures, bool gap, bool resync, Object? error, StackTrace? stack});

/// The nativebind runtime: connects the generated Dart modules to the native
/// library and keeps them in sync.
///
///     await NativeBind.start(library: 'libmy_backend.so', modules: nativebindModules);
///     runApp(const App());
final class NativeBind {
  NativeBind._(this.native);

  static NativeBind? _current;

  /// The running instance. Throws [BindNotStarted] before [start].
  static NativeBind get instance => _current ?? (throw const BindNotStarted('call NativeBind.start first'));
  static bool get isStarted => _current != null;

  /// Decides whether the UI may write a property right now: returns the
  /// reason it may not, or null. Libraries built on nativebind install it
  /// (e.g. one that checks the signed-in user's role) so the UI can show a
  /// lock and ask for a login before writing. It mirrors the C++
  /// `nativebind::setGuard` policy, which always has the final word.
  static BindException? Function(BoundProperty<Object?> property)? writeGuard;

  /// Loads the native [library] (or uses [native]), checks every module's
  /// schema, starts the C++ runtime and loads the complete state, so the
  /// first frame already shows real values.
  ///
  /// Calling it again (e.g. after a hot restart) reattaches to the running
  /// native runtime.
  static Future<NativeBind> start({
    String? library,
    BindNative? native,
    required List<ModuleType<ModuleProxy>> modules,
    bool checkSchemas = true,
  }) async {
    final existing = _current;
    if (existing != null) return existing;
    if (native == null && library == null) {
      throw ArgumentError('NativeBind.start needs the native library name (library: "libbackend.so")');
    }
    final p = NativeBind._(native ?? FfiNative.open(library!));
    p._init(modules, checkSchemas: checkSchemas);
    _current = p;
    return p;
  }

  /// Detaches from the native library; with [stopNative] also stops the C++
  /// runtime (every module's onStop runs).
  static Future<void> stop({bool stopNative = true}) async {
    final p = _current;
    if (p == null) return;
    _current = null;
    p._shutdown(stopNative: stopNative);
  }

  final BindNative native;
  final _types = <int, ModuleType<ModuleProxy>>{};
  final _instances = <int, Instance>{};
  final _calls = <int, _CallDone>{};
  ReceivePort? _port;

  /// Shared encode buffer (the runtime is single-threaded).
  final WireWriter scratchWriter = WireWriter();
  int _seq = 0;
  int _callId = 0;
  bool _draining = false;

  /// Instances listed by the full state being applied (null outside a resync).
  Set<int>? _seen;

  /// Consecutive batches with records that could not be applied.
  int _failedBatches = 0;

  /// Consecutive full states (resyncs) with records that could not be
  /// applied. Another resync would only fail again, so after a few no more
  /// are requested, not even for list version gaps, until one applies.
  int _failedResyncs = 0;

  final _dirty = <Object>{};
  final _signals = <(SignalSlot, List<Object?>)>[];
  final _results = <(int, int, Object?, String?)>[];


  /// Module type names known to the Dart side.
  Iterable<String> get moduleNames => _types.values.map((t) => t.name);

  /// Keeps [nextSeq] past every acknowledgment C++ reports. After a hot
  /// restart C++ still holds the acks of the previous isolate's writes; new
  /// writes numbered from 1 would count as already acknowledged.
  void observeAck(int ack) {
    if (((_seq - ack) & 0xffffffff) >= 0x80000000) _seq = ack; // ack is ahead of _seq
  }

  int nextSeq() {
    _seq = (_seq + 1) & 0xffffffff;
    if (_seq == 0) _seq = 1;
    return _seq;
  }

  // ------------------------------------------------------------ lifecycle

  void _init(List<ModuleType<ModuleProxy>> modules, {required bool checkSchemas}) {
    final v = native.abiVersion();
    if (v != abiVersion) {
      throw BindNotStarted('native library ABI version $v, but this nativebind package expects $abiVersion');
    }
    native.initDartApi();

    final all = <String, ModuleType<ModuleProxy>>{};
    for (final t in modules) {
      final other = all[t.name];
      if (other != null && !identical(other, t)) {
        throw ArgumentError('two module types are named ${t.name}');
      }
      all[t.name] = t;
    }
    for (final t in all.values) {
      final id = native.typeId(t.name);
      if (id < 0) {
        throw BindNotStarted('module ${t.name} is not in the native library. '
            'Is its .cpp listed in nativebind_add_modules, and is the library rebuilt?');
      }
      final schema = native.typeSchema(id) ?? '';
      if (checkSchemas && schema != t.schema) throw BindSchemaMismatch(t.name, t.schema, schema);
      _types[id] = t;
      t.$reset();
      t.$runtime = this;
    }

    final port = _port = ReceivePort('nativebind');
    port.listen((_) => drainNow());
    native.attachPort(port.sendPort.nativePort);
    final status = native.start();
    if (status != BindStatus.ok) {
      port.close();
      throw BindException.fromStatus(status, 'nativebind_start failed: ${native.lastError()}');
    }
    drainNow();
  }

  void _shutdown({required bool stopNative}) {
    _port?.close();
    _port = null;
    if (stopNative) native.stop();
    for (final inst in _instances.values) {
      inst.markGone();
    }
    _instances.clear();
    for (final t in _types.values) {
      _dirty.add(t.instances);
      t.$reset();
    }
    final calls = Map.of(_calls);
    _calls.clear();
    for (final done in calls.values) {
      done(BindStatus.notStarted, null, 'nativebind stopped');
    }
    _notify();
  }

  /// Waits until the native side has processed everything sent so far and
  /// applies the resulting changes. Mostly for tests.
  Future<void> settle({Duration timeout = const Duration(seconds: 5)}) async {
    if (native.flush(timeout.inMilliseconds) != BindStatus.ok) {
      throw TimeoutException('nativebind: native side did not settle', timeout);
    }
    drainNow();
    await Future<void>.delayed(Duration.zero); // let signal listeners run
  }

  // ------------------------------------------------------------ change feed

  /// Applies pending changes now (called on every wake-up from C++).
  void drainNow() {
    if (_draining) return;
    _draining = true;
    try {
      final bytes = native.drain();
      if (bytes.isNotEmpty) _settle(_apply(bytes));
    } catch (e, st) {
      // The framing itself is broken: the rest of the batch is lost.
      _settle((failures: 1, gap: false, resync: false, error: e, stack: st));
    } finally {
      _draining = false;
    }
    _notify();
  }

  /// Reports what could not be applied and decides whether to resync.
  void _settle(_Applied a) {
    if (a.failures > 0) {
      FlutterError.reportError(FlutterErrorDetails(
          exception: a.error!,
          stack: a.stack,
          library: 'nativebind',
          context: ErrorDescription(a.failures == 1
              ? 'while applying native changes (the record was skipped)'
              : 'while applying native changes (${a.failures} records were skipped)')));
    }
    if (a.resync) _failedResyncs = a.failures > 0 ? _failedResyncs + 1 : 0;
    _failedBatches = a.failures > 0 ? _failedBatches + 1 : 0;
    // A resync usually recovers; if the full state itself cannot be applied,
    // retrying would spin forever, so give up after a few attempts.
    final retry = a.gap || (a.failures > 0 && _failedBatches <= 3);
    if (retry && _failedResyncs < 3) native.requestResync();
  }

  /// Applies a batch record by record: records are length-framed, so one
  /// that cannot be applied is skipped and the rest still apply (call
  /// results in particular, which would otherwise never complete).
  _Applied _apply(Uint8List bytes) {
    final top = WireReader(bytes);
    _seen = null;
    var gap = false;
    var failures = 0;
    Object? error;
    StackTrace? stack;
    while (!top.atEnd) {
      final kind = top.u8();
      final r = top.sub(top.u32());
      try {
        gap = _record(kind, r) || gap;
      } catch (e, st) {
        failures++;
        error ??= e;
        stack ??= st;
      }
    }
    final alive = _seen;
    _seen = null;
    if (alive != null) {
      for (final h in _instances.keys.where((h) => !alive.contains(h)).toList()) {
        _remove(h);
      }
    }
    return (failures: failures, gap: gap, resync: alive != null, error: error, stack: stack);
  }

  /// Applies one record. Typed values are decoded before any state changes,
  /// so a record that throws leaves everything as it was. Returns true on a
  /// list version gap.
  bool _record(int kind, WireReader r) {
    switch (kind) {
      case _Rec.resync:
        _seen = <int>{};
      case _Rec.instanceAdded:
        final h = r.u32(), typeId = r.u16(), key = r.u64();
        _seen?.add(h);
        if (_instances.containsKey(h)) break;
        final type = _types[typeId];
        final inst = _instances[h] = Instance(this, h, typeId, key, type);
        if (type != null) {
          type.$adopt(inst);
          _dirty.add(type.instances);
        }
      case _Rec.instanceRemoved:
        _remove(r.u32());
      case _Rec.prop:
        final inst = _instances[r.u32()];
        final index = r.u16(), ack = r.u32();
        inst?.prop(index).applyValue(r, ack);
      case _Rec.meta:
        final inst = _instances[r.u32()];
        final index = r.u16();
        final min = r.f64(), max = r.f64(), step = r.f64(), flags = r.u8();
        final label = r.str();
        final attrs = <String, Object?>{};
        for (var n = r.u16(); n > 0; n--) {
          final key = r.str();
          final v = r.value();
          attrs[key] = v is WireEnum ? v.value : v;
        }
        inst?.prop(index).applyMeta(PropertyMeta(
              min: min,
              max: max,
              step: step,
              writable: flags & 1 != 0,
              enabled: flags & 2 != 0,
              label: label.isEmpty ? null : label,
              attrs: Map.unmodifiable(attrs),
            ));
      case _Rec.listReset:
        final inst = _instances[r.u32()];
        final index = r.u16(), version = r.u32(), count = r.u32();
        if (count > r.remaining) throw const BindProtocolException('list length exceeds record');
        inst?.list(index).reset(version, r, count);
      // List operations decode the item and check the index before changing
      // anything (see ListSlot).
      case _Rec.listInsert:
        final inst = _instances[r.u32()];
        final index = r.u16(), version = r.u32(), at = r.u32();
        return inst != null && !inst.list(index).insert(version, at, r);
      case _Rec.listRemove:
        final inst = _instances[r.u32()];
        final index = r.u16(), version = r.u32(), at = r.u32(), count = r.u32();
        return inst != null && !inst.list(index).remove(version, at, count);
      case _Rec.listUpdate:
        final inst = _instances[r.u32()];
        final index = r.u16(), version = r.u32(), at = r.u32();
        return inst != null && !inst.list(index).update(version, at, r);
      case _Rec.listMove:
        final inst = _instances[r.u32()];
        final index = r.u16(), version = r.u32(), from = r.u32(), to = r.u32();
        return inst != null && !inst.list(index).move(version, from, to);
      case _Rec.signal:
        final inst = _instances[r.u32()];
        final index = r.u16(), argc = r.u8();
        final args = List<Object?>.generate(argc, (_) => r.value(), growable: false);
        if (inst != null) _signals.add((inst.signal(index), args));
      case _Rec.result:
        final id = r.u32(), status = r.i32();
        try {
          _results.add(status == BindStatus.ok ? (id, status, r.value(), null) : (id, status, null, r.str()));
        } catch (e) {
          // Still complete the call, so its Future does not hang.
          _results.add((id, _malformedResult, null, 'malformed result: $e'));
          rethrow;
        }
      default:
        break; // unknown record kinds are skipped (forward compatible)
    }
    return false;
  }

  void _remove(int handle) {
    final inst = _instances.remove(handle);
    if (inst == null) return;
    inst.markGone();
    final type = inst.type;
    if (type != null) {
      type.$drop(inst);
      _dirty.add(type.instances);
    }
  }

  void markDirty(Object o) => _dirty.add(o);

  /// Listeners run after a whole batch is applied, so they never see a
  /// half-updated state; then signals, then call results.
  void _notify() {
    while (_dirty.isNotEmpty) {
      final batch = _dirty.toList();
      _dirty.clear();
      for (final o in batch) {
        switch (o) {
          case BoundValue<Object?>():
            o.$notify();
          case BoundList<Object?>():
            o.$notify();
          case BoundInstances<ModuleProxy>():
            o.$notify();
        }
      }
    }
    final signals = List.of(_signals);
    _signals.clear();
    for (final (slot, args) in signals) {
      slot.bound?.$emit(args);
    }
    final results = List.of(_results);
    _results.clear();
    for (final (id, status, value, error) in results) {
      _calls.remove(id)?.call(status, value, error);
    }
  }

  // ------------------------------------------------------------ calls

  Future<R> invoke<R>(Instance inst, int method, void Function(WireWriter w)? args, Codec<R> codec) {
    if (!inst.alive) return Future.error(BindInstanceGone('${inst.typeName}: the instance was destroyed'));
    final w = scratchWriter..clear();
    try {
      args?.call(w);
    } catch (e, st) {
      return Future.error(e, st); // like every other failure of a call
    }
    _callId = (_callId + 1) & 0xffffffff;
    final id = _callId;
    final status = native.invoke(inst.handle, method, w.bytes, id);
    if (status != BindStatus.ok) return Future.error(BindException.fromStatus(status, native.lastError()));
    final c = Completer<R>();
    _calls[id] = (status, value, error) {
      if (status == _malformedResult) {
        c.completeError(BindProtocolException(error ?? 'malformed result'));
        return;
      }
      if (status != BindStatus.ok) {
        c.completeError(BindException.fromStatus(status, error ?? 'call failed'));
        return;
      }
      try {
        c.complete(codec.decode(value));
      } catch (e, st) {
        c.completeError(e, st);
      }
    };
    return c.future;
  }
}

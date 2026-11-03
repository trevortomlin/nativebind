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
  int _failedDrains = 0;

  final _dirty = <Object>{};
  final _signals = <(SignalSlot, List<Object?>)>[];
  final _results = <(int, int, Object?, String?)>[];


  /// Module type names known to the Dart side.
  Iterable<String> get moduleNames => _types.values.map((t) => t.name);

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
      if (bytes.isNotEmpty) _apply(bytes);
      _failedDrains = 0;
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(
          exception: e, stack: st, library: 'nativebind', context: ErrorDescription('while applying native changes')));
      // A resync usually recovers; if the full state itself cannot be applied,
      // retrying would spin forever, so give up after a few attempts.
      if (++_failedDrains <= 3) native.requestResync();
    } finally {
      _draining = false;
    }
    _notify();
  }

  void _apply(Uint8List bytes) {
    final top = WireReader(bytes);
    Set<int>? seen;
    var gap = false;
    while (!top.atEnd) {
      final kind = top.u8();
      final r = top.sub(top.u32());
      switch (kind) {
        case _Rec.resync:
          seen = <int>{};
        case _Rec.instanceAdded:
          final h = r.u32(), typeId = r.u16(), key = r.u64();
          seen?.add(h);
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
          final value = r.value();
          inst?.prop(index).applyValue(value, ack);
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
          final items = List<Object?>.generate(count, (_) => r.value());
          inst?.list(index).reset(version, items);
        case _Rec.listInsert:
          final inst = _instances[r.u32()];
          final index = r.u16(), version = r.u32(), at = r.u32();
          final item = r.value();
          if (inst != null &&
              !inst.list(index).apply(version, (items, typed) {
                items.insert(at, item);
                typed?.$insert(at, item);
              })) {
            gap = true;
          }
        case _Rec.listRemove:
          final inst = _instances[r.u32()];
          final index = r.u16(), version = r.u32(), at = r.u32(), count = r.u32();
          if (inst != null &&
              !inst.list(index).apply(version, (items, typed) {
                items.removeRange(at, at + count);
                typed?.$remove(at, count);
              })) {
            gap = true;
          }
        case _Rec.listUpdate:
          final inst = _instances[r.u32()];
          final index = r.u16(), version = r.u32(), at = r.u32();
          final item = r.value();
          if (inst != null &&
              !inst.list(index).apply(version, (items, typed) {
                items[at] = item;
                typed?.$update(at, item);
              })) {
            gap = true;
          }
        case _Rec.listMove:
          final inst = _instances[r.u32()];
          final index = r.u16(), version = r.u32(), from = r.u32(), to = r.u32();
          if (inst != null &&
              !inst.list(index).apply(version, (items, typed) {
                items.insert(to, items.removeAt(from));
                typed?.$move(from, to);
              })) {
            gap = true;
          }
        case _Rec.signal:
          final inst = _instances[r.u32()];
          final index = r.u16(), argc = r.u8();
          final args = List<Object?>.generate(argc, (_) => r.value(), growable: false);
          if (inst != null) _signals.add((inst.signal(index), args));
        case _Rec.result:
          final id = r.u32(), status = r.i32();
          if (status == BindStatus.ok) {
            _results.add((id, status, r.value(), null));
          } else {
            _results.add((id, status, null, r.str()));
          }
        default:
          break; // unknown record kinds are skipped (forward compatible)
      }
    }
    if (seen != null) {
      for (final h in _instances.keys.where((h) => !seen!.contains(h)).toList()) {
        _remove(h);
      }
    }
    if (gap) native.requestResync();
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
    args?.call(w);
    _callId = (_callId + 1) & 0xffffffff;
    final id = _callId;
    final status = native.invoke(inst.handle, method, w.bytes, id);
    if (status != BindStatus.ok) return Future.error(BindException.fromStatus(status, native.lastError()));
    final c = Completer<R>();
    _calls[id] = (status, value, error) {
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

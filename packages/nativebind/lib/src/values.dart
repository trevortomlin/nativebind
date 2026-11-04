import 'dart:async';

import 'package:flutter/foundation.dart';

import 'codec.dart';
import 'errors.dart';
import 'instance.dart';
import 'meta.dart';
import 'runtime.dart';
import 'wire.dart';

Type _typeOf<X>() => X;

/// A value bound to a C++ property. Listen to it like any
/// [ValueListenable]; it notifies when the value or its [meta] change.
///
///     ValueListenableBuilder(valueListenable: Player.instance.position, builder: ...)
class BoundValue<T> extends ChangeNotifier implements ValueListenable<T> {
  BoundValue.$(this.$slot, this.$codec) {
    if ($slot.hasValue) _remote = $codec.decode($slot.raw); // before binding: a failure can be retried
    $slot.bind(this);
  }

  final PropSlot $slot;
  final Codec<T> $codec;

  T? _remote;

  /// Member name in C++.
  String get name => $slot.name;

  /// False until C++ sent the first value (normally only during startup).
  bool get hasValue => $slot.hasValue;

  /// The value C++ holds (for a [BoundProperty], after pending writes are
  /// acknowledged).
  T get remoteValue {
    if (!$slot.hasValue) throw BindException('$name has no value yet');
    return _remote as T;
  }

  @override
  T get value => remoteValue;

  PropertyMeta get meta => $slot.meta;

  /// The C++ doc comment of the property (`/// ...` above it), or null.
  /// Handy as help text.
  String? get doc => $slot.instance.type?.docs[name];

  /// The values an enum or bool property can take (declaration order;
  /// `[false, true]` for bools), or null for other types. Use it to build
  /// choice lists without naming the enum.
  List<T>? get choices {
    final Object c = $codec;
    if (c is EnumCodec) return List<T>.unmodifiable(c.values);
    if (identical(c, boolCodec)) return List<T>.unmodifiable(<Object>[false, true]);
    return null;
  }

  /// False once the module instance was destroyed in C++.
  bool get isAlive => $slot.instance.alive;

  /// Reads a value C++ sent. Called by the runtime before it updates the
  /// slot; throws without changing anything if the value cannot be decoded.
  void $readRemote(WireReader r) => _remote = $codec.read(r);

  /// Called by the runtime when a Prop or Meta record was applied.
  void $onRemote({required bool valueChanged}) {}

  void $notify() => notifyListeners();

  @override
  String toString() => '${$slot.instance.typeName}.$name = ${$slot.hasValue ? value : '<none>'}';
}

/// A property the UI may write. Writes are optimistic: [value] changes at
/// once, and C++ confirms or corrects it (its validator may clamp or reject).
///
///     player.volume.value = 0.8;                 // fire and forget
///     final kept = await player.volume.write(2);   // what C++ accepted (clamped to 1.0)
class BoundProperty<T> extends BoundValue<T> {
  BoundProperty.$(super.slot, super.codec) : super.$();

  T? _optimistic;
  bool _hasOptimistic = false;
  int _pendingSeq = 0;
  PropertyEdit<T>? _edit;
  final _waiters = <(int, Completer<T>)>[];

  @override
  T get value => _hasOptimistic ? _optimistic as T : remoteValue;

  set value(T v) => set(v);

  /// A write is in flight (C++ has not acknowledged it yet).
  bool get isPending => _pendingSeq != 0;

  /// A [PropertyEdit] is active (e.g. a finger is on the slider).
  bool get isEditing => _edit != null;

  /// Whether a write would currently be accepted (writable, enabled, alive,
  /// and allowed by [NativeBind.writeGuard]).
  bool get canWrite => whyNotWritable == null;

  /// The reason a write would be refused, or null.
  BindException? get whyNotWritable {
    final m = meta;
    if (!isAlive) return BindInstanceGone('$name: the module instance was destroyed');
    if (!m.writable) return BindWriteRejected('$name is read-only');
    if (!m.enabled) return BindWriteRejected('$name is disabled', status: BindStatus.disabled);
    return NativeBind.writeGuard?.call(this);
  }

  /// Writes [v] (optimistically). Numbers are clamped to the property's
  /// range first. Throws a [BindException] if the write is refused at once
  /// (read-only, disabled, denied by [NativeBind.writeGuard]).
  void set(T v) {
    final why = whyNotWritable;
    if (why != null) throw why;
    final clamped = _clamp(v);
    _send(clamped);
    _showLocal(clamped);
  }

  /// Writes [v] and completes with the value C++ kept once it processed the
  /// write: [v], a corrected value, or the old value if it was rejected.
  Future<T> write(T v) {
    set(v);
    final c = Completer<T>();
    _waiters.add((_pendingSeq, c));
    return c.future;
  }

  /// Writes a number given in any numeric type (rounded for int properties).
  void setNumber(num v) => set(_fromNum(v));

  /// Starts an interactive edit: [PropertyEdit.update] shows values at once
  /// and sends them at most once per [interval]; incoming values do not move
  /// the control until [PropertyEdit.commit] or [PropertyEdit.cancel].
  PropertyEdit<T> beginEdit({Duration interval = const Duration(milliseconds: 100)}) {
    _edit?.cancel();
    final why = whyNotWritable;
    if (why != null) throw why;
    return _edit = PropertyEdit<T>._(this, interval);
  }

  T _fromNum(num v) {
    final isInt = T == int || T == _typeOf<int?>();
    return (isInt ? v.round() : v.toDouble()) as T;
  }

  T _clamp(T v) {
    if (v is! num) return v;
    final m = meta;
    final num n = v;
    if (n.isNaN) return v;
    if (n < m.min) return _fromNum(n is int ? m.min.ceil() : m.min);
    if (n > m.max) return _fromNum(n is int ? m.max.floor() : m.max);
    return v;
  }

  void _send(T v) {
    final runtime = $slot.instance.runtime;
    final w = runtime.scratchWriter..clear();
    $codec.encode(w, v);
    final seq = runtime.nextSeq();
    final status = runtime.native.write($slot.instance.handle, $slot.index, w.bytes, seq);
    if (status != BindStatus.ok) {
      throw BindException.fromStatus(status, runtime.native.lastError());
    }
    _pendingSeq = seq;
  }

  void _showLocal(T v) {
    _optimistic = v;
    _hasOptimistic = true;
    notifyListeners();
  }

  @override
  void $onRemote({required bool valueChanged}) {
    super.$onRemote(valueChanged: valueChanged);
    final ack = $slot.ackSeq;
    if (_pendingSeq != 0 && _seqReached(ack, _pendingSeq)) {
      _pendingSeq = 0;
      if (_edit == null) {
        _hasOptimistic = false;
        _optimistic = null;
      }
    }
    if (_waiters.isNotEmpty && $slot.hasValue) {
      final done = _waiters.where((w) => _seqReached(ack, w.$1)).toList();
      _waiters.removeWhere(done.contains);
      for (final w in done) {
        w.$2.complete(remoteValue);
      }
    }
  }

  /// Sequence numbers wrap at 2^32.
  static bool _seqReached(int ack, int seq) => seqReached(ack, seq);

  /// Whether acknowledgment [ack] covers write [seq] (serial-number arithmetic, RFC 1982).
  @visibleForTesting
  static bool seqReached(int ack, int seq) => ((ack - seq) & 0xffffffff) < 0x80000000;

  void _endEdit() {
    _edit = null;
    if (_pendingSeq == 0 && _hasOptimistic) {
      _hasOptimistic = false;
      _optimistic = null;
      notifyListeners();
    }
  }

  void $instanceGone() {
    for (final w in _waiters) {
      w.$2.completeError(BindInstanceGone('$name: the module instance was destroyed'));
    }
    _waiters.clear();
    _edit?._timer?.cancel();
    _edit = null;
  }
}

/// An interactive edit of a [BoundProperty] (a drag on a slider or dial).
final class PropertyEdit<T> {
  PropertyEdit._(this._property, this._interval);

  final BoundProperty<T> _property;
  final Duration _interval;
  Timer? _timer;
  T? _latest;
  bool _hasLatest = false;
  bool _unsent = false;
  bool _active = true;

  bool get isActive => _active;

  /// Shows [v] at once and sends it (throttled).
  void update(T v) {
    if (!_active) return;
    final clamped = _property._clamp(v);
    _latest = clamped;
    _hasLatest = true;
    _property._showLocal(clamped);
    if (_timer == null) {
      _send();
    } else {
      _unsent = true; // sent when the interval since the last send is over
    }
  }

  // Sends now and holds later updates back for [_interval]. A Timer measures
  // the interval: it runs on a monotonic clock, so a wall-clock step (an NTP
  // correction at boot) neither stalls a drag nor lets it burst.
  void _send() {
    _flush();
    _timer = Timer(_interval, () {
      _timer = null;
      if (_unsent && _active) _send();
    });
  }

  /// Sends the final value (if not sent yet) and ends the edit; the control
  /// then follows C++ again once the write is acknowledged.
  void commit([T? v]) {
    if (!_active) return;
    if (v != null) {
      _latest = _property._clamp(v);
      _hasLatest = true;
      _unsent = true;
    }
    _timer?.cancel();
    _timer = null;
    if (_unsent && _hasLatest) _flush();
    _active = false;
    _property._endEdit();
  }

  /// [update] with a number of any numeric type (rounded for int properties).
  void updateNumber(num v) => update(_property._fromNum(v));

  /// [commit] with a number of any numeric type.
  void commitNumber([num? v]) => commit(v == null ? null : _property._fromNum(v));

  /// Ends the edit without sending more; the control shows C++'s value.
  void cancel() {
    if (!_active) return;
    _timer?.cancel();
    _timer = null;
    _active = false;
    _property._endEdit();
  }

  void _flush() {
    _unsent = false;
    try {
      _property._send(_latest as T);
    } on BindException {
      cancel();
      rethrow;
    }
  }
}

/// Encodes values with a reusable buffer (internal helper type alias).
typedef ArgsWriter = void Function(WireWriter w);

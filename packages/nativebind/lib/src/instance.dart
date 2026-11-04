// Mirror of one C++ module instance. The runtime applies change records to
// its slots; typed objects (BoundValue, BoundList, BoundSignal) bind to
// the slots when the generated proxy first touches them.

import 'collections.dart';
import 'meta.dart';
import 'module.dart';
import 'runtime.dart';
import 'values.dart';

final class Instance {
  Instance(this.runtime, this.handle, this.typeId, this.key, this.type);

  final NativeBind runtime;
  final int handle;
  final int typeId;
  final int key;

  /// Null for native module types the app did not generate Dart code for.
  final ModuleType<ModuleProxy>? type;

  bool alive = true;
  ModuleProxy? proxy;

  final _props = <int, PropSlot>{};
  final _lists = <int, ListSlot>{};
  final _signals = <int, SignalSlot>{};

  String get typeName => type?.name ?? 'type#$typeId';

  PropSlot prop(int index) => _props.putIfAbsent(index, () => PropSlot(this, index));
  ListSlot list(int index) => _lists.putIfAbsent(index, () => ListSlot(this, index));
  SignalSlot signal(int index) => _signals.putIfAbsent(index, () => SignalSlot(this, index));

  void markGone() {
    alive = false;
    for (final p in _props.values) {
      final b = p.bound;
      if (b is BoundProperty) b.$instanceGone();
      if (b != null) runtime.markDirty(b);
    }
    for (final l in _lists.values) {
      final b = l.bound;
      if (b != null) runtime.markDirty(b);
    }
    for (final s in _signals.values) {
      s.bound?.$close();
    }
  }
}

final class PropSlot {
  PropSlot(this.instance, this.index);

  final Instance instance;
  final int index;
  Object? raw;
  bool hasValue = false;
  int ackSeq = 0;
  PropertyMeta meta = PropertyMeta.unknown;
  BoundValue<Object?>? bound;
  String? _name;

  String get name => _name ??= instance.type?.propName(index) ?? 'prop#$index';

  void bind(BoundValue<Object?> v) {
    if (bound != null) throw StateError('${instance.typeName}.$name is bound twice');
    bound = v;
  }

  void applyValue(Object? value, int ack) {
    instance.runtime.observeAck(ack);
    final b = bound;
    b?.$takeRemote(value); // decodes first: throws (e.g. an unknown enum value) before anything changes
    raw = value;
    hasValue = true;
    ackSeq = ack;
    if (b != null) {
      b.$onRemote(valueChanged: true);
      instance.runtime.markDirty(b);
    }
  }

  void applyMeta(PropertyMeta m) {
    if (m == meta) return;
    meta = m;
    final b = bound;
    if (b != null) {
      b.$onRemote(valueChanged: false);
      instance.runtime.markDirty(b);
    }
  }
}

/// Raw list state plus version, mirrored from C++.
final class ListSlot {
  ListSlot(this.instance, this.index);

  final Instance instance;
  final int index;
  int version = 0;
  List<Object?> items = [];
  BoundList<Object?>? bound;

  void bind(BoundList<Object?> l) {
    if (bound != null) throw StateError('${instance.typeName} list #$index is bound twice');
    bound = l;
  }

  void reset(int v, List<Object?> next) {
    bound?.$reset(next); // decodes every item first: throws before anything changes
    version = v;
    items = List<Object?>.of(next);
    _dirty();
  }

  /// Applies an operation. Returns false on a version gap (resync needed).
  /// [op] must throw before changing anything; the version only advances
  /// once it succeeded, so a failed operation shows up as a gap later.
  bool apply(int v, void Function(List<Object?> items, BoundList<Object?>? typed) op) {
    if (v <= version) return true; // already contained in a reset
    if (v != version + 1) return false;
    op(items, bound);
    version = v;
    _dirty();
    return true;
  }

  void _dirty() {
    final b = bound;
    if (b != null) instance.runtime.markDirty(b);
  }
}

final class SignalSlot {
  SignalSlot(this.instance, this.index);

  final Instance instance;
  final int index;
  BoundSignal<Object?>? bound;

  void bind(BoundSignal<Object?> s) {
    if (bound != null) throw StateError('${instance.typeName} signal #$index is bound twice');
    bound = s;
  }
}

// Mirror of one C++ module instance. The runtime applies change records to
// its slots; typed objects (BoundValue, BoundList, BoundSignal) bind to
// the slots when the generated proxy first touches them.

import 'collections.dart';
import 'meta.dart';
import 'module.dart';
import 'runtime.dart';
import 'values.dart';
import 'wire.dart';

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
      if (b is BoundList) b.$close();
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

  /// The value as [WireReader.value] decodes it, kept only until a
  /// [BoundValue] binds: from then on the typed value is the only copy.
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
    raw = null;
  }

  /// Applies a Prop record whose value [r] is positioned at.
  void applyValue(WireReader r, int ack) {
    instance.runtime.observeAck(ack);
    final b = bound;
    if (b != null) {
      b.$readRemote(r); // decodes first: throws (e.g. an unknown enum value) before anything changes
    } else {
      raw = r.value();
    }
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

/// A list's version, mirrored from C++, and its items until a [BoundList]
/// binds (from then on the typed list is the only copy).
final class ListSlot {
  ListSlot(this.instance, this.index);

  final Instance instance;
  final int index;
  int version = 0;
  List<Object?> _items = [];
  BoundList<Object?>? bound;

  /// The items as [WireReader.value] decodes them; empty once bound.
  List<Object?> get items => _items;

  int get length => bound?.length ?? _items.length;

  void bind(BoundList<Object?> l) {
    if (bound != null) throw StateError('${instance.typeName} list #$index is bound twice');
    bound = l;
    _items = const [];
  }

  /// Applies a ListReset record: [count] items follow in [r].
  void reset(int v, WireReader r, int count) {
    final b = bound;
    if (b != null) {
      b.$resetFrom(r, count); // decodes every item first: throws before anything changes
    } else {
      _items = List<Object?>.generate(count, (_) => r.value());
    }
    version = v;
    _dirty();
  }

  bool insert(int v, int at, WireReader r) => _apply(v, () {
        RangeError.checkValueInInterval(at, 0, length, 'index');
        final b = bound;
        b != null ? b.$insertFrom(at, r) : _items.insert(at, r.value());
      });

  bool remove(int v, int at, int count) => _apply(v, () {
        RangeError.checkValidRange(at, at + count, length);
        final b = bound;
        b != null ? b.$remove(at, count) : _items.removeRange(at, at + count);
      });

  bool update(int v, int at, WireReader r) => _apply(v, () {
        RangeError.checkValidIndex(at, null, 'index', length);
        final b = bound;
        b != null ? b.$updateFrom(at, r) : _items[at] = r.value();
      });

  bool move(int v, int from, int to) => _apply(v, () {
        RangeError.checkValidIndex(from, null, 'from', length);
        RangeError.checkValidIndex(to, null, 'to', length);
        final b = bound;
        b != null ? b.$move(from, to) : _items.insert(to, _items.removeAt(from));
      });

  /// Applies an operation. Returns false on a version gap (resync needed).
  /// [op] must throw before changing anything; the version only advances
  /// once it succeeded, so a failed operation shows up as a gap later.
  bool _apply(int v, void Function() op) {
    if (v <= version) return true; // already contained in a reset
    if (v != version + 1) return false;
    op();
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

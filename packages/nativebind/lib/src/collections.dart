import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'codec.dart';
import 'instance.dart';
import 'wire.dart';

/// One change of a [BoundList], for driving an `AnimatedList`.
sealed class ListChange<T> {
  const ListChange();
}

final class ListInserted<T> extends ListChange<T> {
  const ListInserted(this.index, this.item);
  final int index;
  final T item;
}

final class ListRemoved<T> extends ListChange<T> {
  const ListRemoved(this.index, this.items);
  final int index;

  /// The removed items (for the removal animation).
  final List<T> items;
}

final class ListUpdated<T> extends ListChange<T> {
  const ListUpdated(this.index, this.previous, this.item);
  final int index;
  final T previous;
  final T item;
}

final class ListMoved<T> extends ListChange<T> {
  const ListMoved(this.from, this.to);
  final int from;
  final int to;
}

/// The whole list was replaced.
final class ListReset<T> extends ListChange<T> {
  const ListReset(this.items);
  final List<T> items;
}

/// A list bound to a C++ `NATIVEBIND_LIST`, updated incrementally. It is a
/// read-only [List] and a [ValueListenable]; [changes] reports each
/// operation for animated lists.
class BoundList<T> extends ChangeNotifier with ListBase<T> implements ValueListenable<List<T>> {
  BoundList.$(this.$slot, this.$codec) {
    _items = $slot.items.map($codec.decode).toList(); // before binding: a failure can be retried
    $slot.bind(this);
  }

  final ListSlot $slot;
  final Codec<T> $codec;
  List<T> _items = [];
  final _changes = StreamController<ListChange<T>>.broadcast();

  /// Insert/remove/update/move/reset operations as they arrive. Ends when the
  /// module instance is destroyed (or nativebind stops).
  Stream<ListChange<T>> get changes => _changes.stream;

  /// False once the module instance was destroyed in C++.
  bool get isAlive => $slot.instance.alive;

  List<T>? _snapshot;

  /// The items as they are now, unmodifiable. Later changes do not show in a
  /// value already read, so it can be kept and compared.
  @override
  List<T> get value => _snapshot ??= List<T>.unmodifiable(_items);

  @override
  int get length => _items.length;

  @override
  set length(int _) => _readOnly();

  @override
  T operator [](int index) => _items[index];

  @override
  void operator []=(int index, T value) => _readOnly();

  Never _readOnly() =>
      throw UnsupportedError('BoundList is read-only in Dart; change it in C++ (e.g. through a NATIVEBIND_INVOKE method)');

  // ---- called by the runtime; items are read straight from the record

  void $resetFrom(WireReader r, int count) {
    _items = List<T>.generate(count, (_) => $codec.read(r)); // all decoded before anything changes
    _emit(ListReset<T>(List<T>.unmodifiable(_items)));
  }

  void $insertFrom(int index, WireReader r) {
    final item = $codec.read(r);
    _items.insert(index, item);
    _emit(ListInserted<T>(index, item));
  }

  void $remove(int index, int count) {
    final removed = _items.sublist(index, index + count);
    _items.removeRange(index, index + count);
    _emit(ListRemoved<T>(index, List<T>.unmodifiable(removed)));
  }

  void $updateFrom(int index, WireReader r) {
    final item = $codec.read(r);
    final previous = _items[index];
    _items[index] = item;
    _emit(ListUpdated<T>(index, previous, item));
  }

  void $move(int from, int to) {
    final item = _items.removeAt(from);
    _items.insert(to, item);
    _emit(ListMoved<T>(from, to));
  }

  void _emit(ListChange<T> c) {
    _snapshot = null; // every change goes through here
    if (_changes.hasListener) _changes.add(c);
  }

  void $notify() => notifyListeners();
  void $close() => _changes.close();

  @override
  void dispose() {
    _changes.close();
    super.dispose();
  }
}

/// A C++ `NATIVEBIND_SIGNAL` as a broadcast stream.
///
///     player.trackChanged.listen((title) => showToast('Now playing $title'));
class BoundSignal<T> extends Stream<T> {
  BoundSignal.$(this.$slot, this._decode) {
    $slot.bind(this);
  }

  final SignalSlot $slot;
  final T Function(List<Object?> args) _decode;
  final _controller = StreamController<T>.broadcast();

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<T> listen(void Function(T event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  void $emit(List<Object?> args) {
    if (!_controller.hasListener) return;
    try {
      _controller.add(_decode(args));
    } catch (e, st) {
      _controller.addError(e, st);
    }
  }

  void $close() => _controller.close();
}

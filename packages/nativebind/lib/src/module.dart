import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'codec.dart';
import 'collections.dart';
import 'errors.dart';
import 'instance.dart';
import 'runtime.dart';
import 'values.dart';
import 'wire.dart';

/// Base class of every generated module proxy (`Player`, `Download`, ...).
abstract class ModuleProxy {
  ModuleProxy(this.$instance);

  final Instance $instance;

  /// Key given to `nativebind::spawn` (0 for singletons).
  int get $key => $instance.key;

  /// Native instance handle (unique for the process lifetime).
  int get $handle => $instance.handle;

  /// False once the instance was destroyed in C++.
  bool get isAlive => $instance.alive;

  /// Every property of the module, in C++ declaration order (overridden by
  /// generated proxies). Generic screens (an "all parameters" list, a
  /// settings export) iterate it instead of naming each property.
  List<BoundValue<Object?>> get $values => const [];

  BoundProperty<T> $property<T>(int index, Codec<T> codec) => BoundProperty<T>.$($instance.prop(index), codec);

  BoundValue<T> $value<T>(int index, Codec<T> codec) => BoundValue<T>.$($instance.prop(index), codec);

  BoundList<T> $list<T>(int index, Codec<T> codec) => BoundList<T>.$($instance.list(index), codec);

  BoundSignal<T> $signal<T>(int index, T Function(List<Object?> args) decode) =>
      BoundSignal<T>.$($instance.signal(index), decode);

  /// Calls NATIVEBIND_INVOKE method [method]; [args] encodes the arguments.
  Future<R> $invoke<R>(int method, void Function(WireWriter w)? args, Codec<R> result) =>
      $instance.runtime.invoke($instance, method, args, result);

  @override
  String toString() => '${$instance.typeName}${$instance.type?.instanced == true ? '#${$instance.key}' : ''}';
}

/// Live instances of an instanced module, ordered by key.
class BoundInstances<T extends ModuleProxy> extends ChangeNotifier
    with ListBase<T>
    implements ValueListenable<List<T>> {
  final _items = <T>[];

  @override
  List<T> get value => UnmodifiableListView(_items);
  @override
  int get length => _items.length;
  @override
  set length(int _) => throw UnsupportedError('read-only');
  @override
  T operator [](int index) => _items[index];
  @override
  void operator []=(int index, T value) => throw UnsupportedError('read-only');

  T? byKey(int key) {
    for (final m in _items) {
      if (m.$key == key) return m;
    }
    return null;
  }

  void $add(T proxy) {
    var i = 0;
    while (i < _items.length && _items[i].$key <= proxy.$key) {
      i++;
    }
    _items.insert(i, proxy);
  }

  void $remove(ModuleProxy proxy) => _items.remove(proxy);
  void $clear() => _items.clear();
  void $notify() => notifyListeners();
}

/// Description of a generated module class; one static instance per class
/// (`Player.$type`). Pass all of them to `NativeBind.start`.
class ModuleType<T extends ModuleProxy> {
  ModuleType(
      {required this.name, required this.instanced, required this.schema, required this.create, this.docs = const {}});

  final String name;
  final bool instanced;

  /// C++ doc comments of the members, by member name (see [BoundValue.doc]).
  final Map<String, String> docs;

  /// Canonical schema text; compared with the native library at startup.
  final String schema;
  final T Function(Instance instance) create;

  final BoundInstances<T> instances = BoundInstances<T>();
  NativeBind? $runtime;
  T? _single;

  /// The singleton (singleton modules only).
  T get single {
    if (instanced) throw StateError('$name is instanced; use $name.instances or $name.byKey');
    final runtime = $runtime;
    if (runtime == null) {
      throw BindNotStarted('$name: nativebind is not started (call NativeBind.start with $name.\$type in modules)');
    }
    final s = _single;
    if (s == null) throw BindNotStarted('$name: the native library has no $name instance');
    return s;
  }

  T? byKey(int key) => instances.byKey(key);

  T $adopt(Instance instance) {
    final proxy = create(instance);
    instance.proxy = proxy;
    if (instanced) {
      instances.$add(proxy);
    } else {
      _single = proxy;
    }
    return proxy;
  }

  void $drop(Instance instance) {
    final proxy = instance.proxy;
    if (proxy == null) return;
    if (instanced) {
      instances.$remove(proxy);
    } else if (identical(_single, proxy)) {
      _single = null;
    }
  }

  void $reset() {
    _single = null;
    instances.$clear();
    $runtime = null;
  }

  late final List<String> _propNames = _names('prop');
  String propName(int index) => index < _propNames.length ? _propNames[index] : 'prop#$index';

  List<String> _names(String kind) => [
        for (final line in schema.split('\n'))
          if (line.startsWith('$kind ')) line.substring(kind.length + 1).split(RegExp(r'[ (]')).first,
      ];

  @override
  String toString() => 'ModuleType($name)';
}

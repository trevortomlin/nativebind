import 'package:flutter/foundation.dart';

/// Metadata of a property, sent by C++ (`NATIVEBIND_PROP(..., .min = 15, ...)`)
/// and updated live (e.g. `volume.setRange(...)`, `setEnabled(false)`).
@immutable
final class PropertyMeta {
  const PropertyMeta({
    this.min = double.negativeInfinity,
    this.max = double.infinity,
    this.step = 0,
    this.writable = false,
    this.enabled = true,
    this.label,
    this.attrs = const {},
  });

  static const unknown = PropertyMeta();

  final double min;
  final double max;

  /// UI increment; 0 = continuous.
  final double step;
  final bool writable;
  final bool enabled;
  final String? label;

  /// `Meta::attrs` from C++: values are bool, int (enums as their value),
  /// double or String. nativebind does not interpret them; libraries built
  /// on it read them through extension getters (e.g. a `meta.unit` getter for display units).
  final Map<String, Object?> attrs;

  bool get hasRange => min.isFinite && max.isFinite;

  /// The attribute [key] if it has type [V], else null.
  V? attr<V>(String key) {
    final v = attrs[key];
    return v is V ? v : null;
  }

  @override
  bool operator ==(Object other) =>
      other is PropertyMeta &&
      other.min == min &&
      other.max == max &&
      other.step == step &&
      other.writable == writable &&
      other.enabled == enabled &&
      other.label == label &&
      mapEquals(other.attrs, attrs);

  @override
  int get hashCode =>
      Object.hash(min, max, step, writable, enabled, label, Object.hashAllUnordered(attrs.entries.map((e) => (e.key, e.value))));

  @override
  String toString() => 'PropertyMeta(${[
        if (hasRange) '[$min, $max]',
        if (step > 0) 'step $step',
        if (writable) 'writable' else 'read-only',
        if (!enabled) 'disabled',
        if (label != null) '"$label"',
        for (final MapEntry(:key, :value) in attrs.entries) '$key: $value',
      ].join(', ')})';
}

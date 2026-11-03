/// Status codes of the C ABI (nativebind.h).
abstract final class BindStatus {
  static const ok = 0;
  static const notStarted = -1;
  static const noInstance = -2;
  static const noMember = -3;
  static const type = -4;
  static const readOnly = -5;
  static const disabled = -6;
  static const access = -7;
  static const exception = -8;
  static const unknownType = -9;
  static const timeout = -10;
  static const internal = -11;
}

/// Base class of every error nativebind reports.
class BindException implements Exception {
  const BindException(this.message, {this.status = BindStatus.internal});

  /// Creates the most specific exception for a native status code.
  factory BindException.fromStatus(int status, String message) => switch (status) {
        BindStatus.access => BindAccessDenied(message),
        BindStatus.exception => BindInvokeException(message),
        BindStatus.noInstance => BindInstanceGone(message),
        BindStatus.notStarted => BindNotStarted(message),
        BindStatus.readOnly || BindStatus.disabled => BindWriteRejected(message, status: status),
        _ => BindException(message, status: status),
      };

  final String message;
  final int status;

  @override
  String toString() => '$runtimeType: $message';
}

/// The write guard refused a write or call (`nativebind::setGuard` in C++,
/// or [NativeBind.writeGuard] in Dart).
class BindAccessDenied extends BindException {
  const BindAccessDenied(super.message) : super(status: BindStatus.access);
}

/// A NATIVEBIND_INVOKE method threw a C++ exception.
class BindInvokeException extends BindException {
  const BindInvokeException(super.message) : super(status: BindStatus.exception);
}

/// The module instance was destroyed in C++.
class BindInstanceGone extends BindException {
  const BindInstanceGone(super.message) : super(status: BindStatus.noInstance);
}

/// A write was refused immediately (read-only or disabled property).
class BindWriteRejected extends BindException {
  const BindWriteRejected(super.message, {super.status = BindStatus.readOnly});
}

/// The runtime is not started, or the module is not in the native library.
class BindNotStarted extends BindException {
  const BindNotStarted(super.message) : super(status: BindStatus.notStarted);
}

/// Malformed data from the native side (indicates a version mismatch or bug).
class BindProtocolException extends BindException {
  const BindProtocolException(super.message);
}

/// The generated Dart code and the native library disagree about a module.
class BindSchemaMismatch extends BindException {
  BindSchemaMismatch(this.module, this.dartSchema, this.nativeSchema)
      : super(_describe(module, dartSchema, nativeSchema));

  final String module;
  final String dartSchema;
  final String nativeSchema;

  static String _describe(String module, String dart, String native) {
    final d = dart.trimRight().split('\n');
    final n = native.trimRight().split('\n');
    final b = StringBuffer('module $module: the generated Dart code does not match the native library.\n'
        'Re-run `dart run nativebind_generator` and rebuild the native library.\n');
    for (var i = 0; i < d.length || i < n.length; i++) {
      final dl = i < d.length ? d[i] : null;
      final nl = i < n.length ? n[i] : null;
      if (dl == nl) continue;
      if (nl != null) b.writeln('  native: $nl');
      if (dl != null) b.writeln('  dart:   $dl');
    }
    return b.toString().trimRight();
  }
}

// The native boundary: the fixed C ABI of nativebind.h. Every application uses
// these same functions; modules are addressed by type, handle and index.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'errors.dart';

const abiVersion = 2;

/// What the runtime needs from the native side. Implemented over FFI by
/// [FfiNative]; tests may substitute a fake.
abstract interface class BindNative {
  int abiVersion();
  void initDartApi();
  void attachPort(int port);
  int start();
  void stop();

  /// Pending change records (valid until the next call).
  Uint8List drain();
  void requestResync();
  int typeId(String name);
  String? typeSchema(int id);
  int write(int instance, int prop, Uint8List value, int seq);
  int invoke(int instance, int method, Uint8List args, int callId);
  int flush(int timeoutMs);
  String lastError();
}

final class FfiNative implements BindNative {
  FfiNative(DynamicLibrary lib)
      : _abiVersion = lib.lookupFunction<Int32 Function(), int Function()>('nativebind_abi_version'),
        _initDartApi =
            lib.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('nativebind_init_dart_api'),
        _start = lib.lookupFunction<Int32 Function(), int Function()>('nativebind_start'),
        _stop = lib.lookupFunction<Void Function(), void Function()>('nativebind_stop'),
        _attachPort = lib.lookupFunction<Void Function(Int64), void Function(int)>('nativebind_attach_port'),
        // Not a leaf call: encoding a full state (a resync) can take a while.
        _drain = lib.lookupFunction<Pointer<Uint8> Function(Pointer<Uint32>), Pointer<Uint8> Function(Pointer<Uint32>)>(
            'nativebind_drain'),
        _requestResync = lib.lookupFunction<Void Function(), void Function()>('nativebind_request_resync'),
        _typeId = lib.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('nativebind_type_id'),
        _typeSchema =
            lib.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('nativebind_type_schema'),
        _write = lib.lookupFunction<Int32 Function(Uint32, Uint16, Pointer<Uint8>, Uint32, Uint32),
            int Function(int, int, Pointer<Uint8>, int, int)>('nativebind_write', isLeaf: true),
        _invoke = lib.lookupFunction<Int32 Function(Uint32, Uint16, Pointer<Uint8>, Uint32, Uint32),
            int Function(int, int, Pointer<Uint8>, int, int)>('nativebind_invoke', isLeaf: true),
        _flush = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('nativebind_flush'),
        _lastError = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('nativebind_last_error');

  /// Opens [name] (e.g. `libmy_backend.so`). A bare name is searched in
  /// the directories of the `NATIVEBIND_LIBRARY_PATH` environment variable
  /// (colon-separated), then by the system loader (`LD_LIBRARY_PATH`,
  /// /usr/lib, ...), then next to the executable and in its `lib/` directory
  /// (desktop bundles). Under flutter-pi the executable is flutter-pi itself,
  /// so install the library system-wide or set `NATIVEBIND_LIBRARY_PATH`.
  factory FfiNative.open(String name) {
    final tried = <String>[];
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final searchPath = Platform.environment['NATIVEBIND_LIBRARY_PATH'] ?? '';
    final candidates = [
      if (!name.contains('/'))
        for (final dir in searchPath.split(':').where((d) => d.isNotEmpty)) '$dir/$name',
      name,
      if (!name.contains('/')) ...['$exeDir/lib/$name', '$exeDir/$name'],
    ];
    for (final c in candidates) {
      final DynamicLibrary lib;
      try {
        lib = DynamicLibrary.open(c);
      } on ArgumentError catch (e) {
        tried.add('$c: ${_loaderReason(c, e)}');
        continue;
      }
      if (!lib.providesSymbol('nativebind_abi_version')) {
        throw BindNotStarted('"$c" was loaded but does not export nativebind_abi_version, so it is not a '
            'nativebind library: build it with nativebind_add_modules, and if you hide symbols, keep the '
            'nativebind_* functions exported');
      }
      return FfiNative(lib);
    }
    throw BindNotStarted('cannot load the native library "$name". Tried:\n  ${tried.join('\n  ')}');
  }

  /// The system loader's message without the parts that repeat the path.
  static String _loaderReason(String path, ArgumentError e) {
    var m = '${e.message}';
    final prefix = "Failed to load dynamic library '$path': ";
    if (m.startsWith(prefix)) m = m.substring(prefix.length);
    if (m.startsWith('$path: ')) m = m.substring(path.length + 2);
    return m.trim();
  }

  final int Function() _abiVersion;
  final int Function(Pointer<Void>) _initDartApi;
  final int Function() _start;
  final void Function() _stop;
  final void Function(int) _attachPort;
  final Pointer<Uint8> Function(Pointer<Uint32>) _drain;
  final void Function() _requestResync;
  final int Function(Pointer<Utf8>) _typeId;
  final Pointer<Utf8> Function(int) _typeSchema;
  final int Function(int, int, Pointer<Uint8>, int, int) _write;
  final int Function(int, int, Pointer<Uint8>, int, int) _invoke;
  final int Function(int) _flush;
  final Pointer<Utf8> Function() _lastError;

  final Pointer<Uint32> _len = calloc<Uint32>();
  Pointer<Uint8> _scratch = calloc<Uint8>(1024);
  int _scratchSize = 1024;

  Pointer<Uint8> _copy(Uint8List bytes) {
    if (bytes.length > _scratchSize) {
      calloc.free(_scratch);
      _scratchSize = bytes.length * 2;
      _scratch = calloc<Uint8>(_scratchSize);
    }
    _scratch.asTypedList(bytes.length).setAll(0, bytes);
    return _scratch;
  }

  @override
  int abiVersion() => _abiVersion();

  @override
  void initDartApi() {
    final r = _initDartApi(NativeApi.initializeApiDLData);
    if (r != 0) throw BindNotStarted('nativebind_init_dart_api failed ($r): ${lastError()}');
  }

  @override
  void attachPort(int port) => _attachPort(port);

  @override
  int start() => _start();

  @override
  void stop() => _stop();

  @override
  Uint8List drain() {
    final p = _drain(_len);
    final n = _len.value;
    if (n == 0 || p == nullptr) return Uint8List(0);
    return p.asTypedList(n);
  }

  @override
  void requestResync() => _requestResync();

  @override
  int typeId(String name) {
    final s = name.toNativeUtf8();
    try {
      return _typeId(s);
    } finally {
      calloc.free(s);
    }
  }

  @override
  String? typeSchema(int id) {
    final p = _typeSchema(id);
    return p == nullptr ? null : p.toDartString();
  }

  @override
  int write(int instance, int prop, Uint8List value, int seq) =>
      _write(instance, prop, _copy(value), value.length, seq);

  @override
  int invoke(int instance, int method, Uint8List args, int callId) =>
      _invoke(instance, method, args.isEmpty ? nullptr : _copy(args), args.length, callId);

  @override
  int flush(int timeoutMs) => _flush(timeoutMs);

  @override
  String lastError() => _lastError().toDartString();
}

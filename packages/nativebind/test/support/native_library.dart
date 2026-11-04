// Builds the C++ test modules library (native/tests) with CMake, shared by
// every test file that loads the real native runtime.
//
// `flutter test` runs test files concurrently in separate processes, so the
// configure + build is serialized with an exclusive file lock: concurrent
// CMake runs in the same build directory clobber each other's files.

import 'dart:io';

final String nativeTestBuildDir = '${Directory.current.path}/build/native_test';

/// Returns the path of the built library, or null when cmake is not installed.
/// Throws [StateError] if configuring or building fails.
String? buildNativeTestLibrary() {
  if (Process.runSync('which', ['cmake']).exitCode != 0) return null;
  final ninja = Process.runSync('which', ['ninja']).exitCode == 0;

  Directory(nativeTestBuildDir).createSync(recursive: true);
  final lock = File('$nativeTestBuildDir.lock').openSync(mode: FileMode.write);
  lock.lockSync(FileLock.blockingExclusive);
  try {
    for (final args in [
      [
        '-S',
        'native',
        '-B',
        nativeTestBuildDir,
        if (ninja) ...['-G', 'Ninja'],
        '-DCMAKE_BUILD_TYPE=Debug',
        '-DNATIVEBIND_WERROR=OFF',
      ],
      ['--build', nativeTestBuildDir, '--target', 'nativebind_test_modules'],
    ]) {
      final r = Process.runSync('cmake', args);
      if (r.exitCode != 0) throw StateError('cmake ${args.first} failed:\n${r.stdout}\n${r.stderr}');
    }
  } finally {
    lock.closeSync(); // releases the lock
  }

  final lib = File('$nativeTestBuildDir/tests/libnativebind_test_modules.so');
  if (!lib.existsSync()) throw StateError('native build produced no library at ${lib.path}');
  return lib.path;
}

/// Like [buildNativeTestLibrary], but cmake is required.
String requireNativeTestLibrary() =>
    buildNativeTestLibrary() ?? (throw StateError('cmake is required to build the native test library'));

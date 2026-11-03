import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Relative import: CMake runs this file with plain `dart`, without `pub get`.
// ignore: avoid_relative_lib_imports
import '../lib/nativebind_generator.dart';

const _usage = '''
Generates FFI glue and Dart view models for nativebind modules.

Usage: dart run nativebind_generator [options] [module files or directories]

With no paths, scans ./native for files containing NATIVEBIND_MODULE.

Options:
  --dart-out <dir>      Dart output directory (default: lib/nativebind)
  --no-dart             Do not write Dart code
  --cpp-out <dir>       Write <module>.nb.cpp glue to <dir> (CMake does this)
  -I <dir>              Additional directory for #include lookups
  --provides <uri>      Generate the types of headers that declare
                        NATIVEBIND_DART_LIBRARY(<uri>) instead of importing them
                        (for packages that provide a Dart library)
  --depfile <file>      Write a Makefile-style dependency file (one input, --cpp-out)
  --no-barrel           Do not write nativebind_modules.dart
  --check               Write nothing; exit 3 if any output is out of date (CI)
  --watch               Regenerate whenever a module file changes
  -q, --quiet           Only print errors
  -h, --help            Show this help
''';

Future<void> main(List<String> argv) async {
  final inputs = <String>[];
  final includes = <String>[];
  String? dartOut = 'lib/nativebind';
  String? cppOut;
  String? depfile;
  String? provides;
  var barrel = true, check = false, watch = false, quiet = false;

  String value(int i, String flag) {
    if (i + 1 >= argv.length) _fail('$flag needs a value');
    return argv[i + 1];
  }

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    switch (a) {
      case '-h' || '--help':
        stdout.write(_usage);
        return;
      case '--dart-out':
        dartOut = value(i++, a);
      case '--no-dart':
        dartOut = null;
      case '--cpp-out':
        cppOut = value(i++, a);
      case '-I' || '--include':
        includes.add(value(i++, a));
      case '--depfile':
        depfile = value(i++, a);
      case '--provides':
        provides = value(i++, a);
      case '--no-barrel':
        barrel = false;
      case '--check':
        check = true;
      case '--watch':
        watch = true;
      case '-q' || '--quiet':
        quiet = true;
      default:
        if (a.startsWith('-I') && a.length > 2) {
          includes.add(a.substring(2));
        } else if (a.startsWith('-')) {
          _fail('unknown option $a');
        } else {
          inputs.add(a);
        }
    }
  }
  if (inputs.isEmpty) inputs.add('native');
  includes.addAll(_packageHeaderDirs());
  if (dartOut == null && cppOut == null) _fail('nothing to do: --no-dart without --cpp-out');

  GeneratorOptions options() => GeneratorOptions(
        inputs: inputs,
        dartOut: dartOut,
        cppOut: cppOut,
        includeDirs: includes,
        depfile: depfile,
        provides: provides,
        barrel: barrel,
        check: check,
      );

  final code = _runOnce(options(), quiet: quiet);
  if (!watch) exit(code);

  stdout.writeln('nativebind: watching ${inputs.join(', ')} (Ctrl+C to stop)');
  Timer? pending;
  final dirs = {
    for (final i in inputs)
      FileSystemEntity.isDirectorySync(i) ? Directory(i).absolute.path : File(i).absolute.parent.path,
  };
  for (final d in dirs) {
    Directory(d).watch(recursive: true).listen((event) {
      if (event.path.contains('.nb.')) return;
      pending?.cancel();
      pending = Timer(const Duration(milliseconds: 150), () => _runOnce(options(), quiet: quiet));
    });
  }
  await Completer<void>().future;
}

int _runOnce(GeneratorOptions options, {required bool quiet}) {
  try {
    final r = Generator(options).run();
    if (options.check) {
      if (r.stale.isEmpty) {
        if (!quiet) stdout.writeln('nativebind: ${_count(r.modules.length, 'module')}, generated code is up to date');
        return 0;
      }
      stderr.writeln('nativebind: generated code is out of date:');
      for (final s in r.stale) {
        stderr.writeln('  $s');
      }
      stderr.writeln('run `dart run nativebind_generator` and commit the result');
      return 3;
    }
    if (!quiet) {
      for (final w in r.written) {
        stdout.writeln('nativebind: wrote $w');
      }
      stdout.writeln('nativebind: ${_count(r.modules.length, 'module')} (${r.modules.join(', ')}), '
          '${_count(r.written.length, 'file')} written, ${r.unchanged.length} unchanged');
    }
    return 0;
  } on GeneratorException catch (e) {
    stderr.writeln(e);
    return 1;
  } on FileSystemException catch (e) {
    stderr.writeln('error: ${e.message}: ${e.path}');
    return 1;
  }
}

/// `<package>/native/include` of every package in ./.dart_tool/package_config.json
/// (e.g. a shared library of types), so module files can `#include <my_lib/types.hpp>`
/// without -I. CMake builds get the same through nativebind_add_header_dirs.
List<String> _packageHeaderDirs() {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return const [];
  try {
    final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    final out = <String>[];
    for (final pkg in (json['packages'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>()) {
      final uri = pkg['rootUri'];
      if (uri is! String) continue;
      final root = uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : '${config.parent.path}/$uri';
      final dir = Directory('$root/native/include');
      if (dir.existsSync()) out.add(dir.path);
    }
    return out;
  } on FormatException {
    return const [];
  }
}

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

Never _fail(String message) {
  stderr.writeln('error: $message\n');
  stderr.write(_usage);
  exit(2);
}

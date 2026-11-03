import 'dart:io';

import 'package:nativebind_generator/nativebind_generator.dart';

/// Repository paths used by the tests.
final generatorRoot = Directory.current.path;
final nativeRoot = '$generatorRoot/../nativebind/native';
final fixtures = '$generatorRoot/test/fixtures';

/// Writes [files] to a temporary directory and runs the generator on them.
/// Returns the generated files by name.
Map<String, String> generate(Map<String, String> files, {bool dart = true, bool cpp = true, String? provides}) {
  final dir = Directory.systemTemp.createTempSync('nativebind_gen_');
  try {
    for (final MapEntry(:key, :value) in files.entries) {
      File('${dir.path}/src/$key')
        ..createSync(recursive: true)
        ..writeAsStringSync(value);
    }
    final sources = files.keys.where((k) => k.endsWith('.cpp')).map((k) => '${dir.path}/src/$k').toList();
    Generator(GeneratorOptions(
      inputs: sources,
      dartOut: dart ? '${dir.path}/dart' : null,
      cppOut: cpp ? '${dir.path}/cpp' : null,
      provides: provides,
    )).run();
    final out = <String, String>{};
    for (final sub in ['dart', 'cpp']) {
      final d = Directory('${dir.path}/$sub');
      if (!d.existsSync()) continue;
      for (final f in d.listSync().whereType<File>()) {
        out[f.uri.pathSegments.last] = f.readAsStringSync();
      }
    }
    return out;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Runs the generator on one module source and returns the exception.
GeneratorException generateError(String source, {Map<String, String> extra = const {}}) {
  try {
    generate({'m.cpp': source, ...extra});
  } on GeneratorException catch (e) {
    return e;
  }
  throw StateError('expected a GeneratorException');
}

/// Wraps member declarations in a module class.
String module(String members, {String prelude = '', String name = 'M', String options = ''}) => '''
#include <nativebind/nativebind.hpp>
$prelude
class $name : public nativebind::Module {
    NATIVEBIND_MODULE($name$options)
public:
$members
};
''';

import 'dart:io';

import 'analysis.dart';
import 'cpp_emitter.dart';
import 'dart_emitter.dart';
import 'diagnostics.dart';
import 'lexer.dart';
import 'model.dart';
import 'naming.dart' show cppString;
import 'parser.dart';
import 'paths.dart' as p;

const sourceExtensions = {'cpp', 'cc', 'cxx', 'c++'};
const headerExtensions = {'hpp', 'hh', 'hxx', 'h', 'h++'};

class GeneratorOptions {
  GeneratorOptions({
    required this.inputs,
    this.dartOut,
    this.cppOut,
    this.includeDirs = const [],
    this.provides,
    this.depfile,
    this.barrel = true,
    this.check = false,
  });

  /// Module files or directories to scan.
  final List<String> inputs;
  final String? dartOut;
  final String? cppOut;
  final List<String> includeDirs;

  /// The Dart library being generated (e.g. `package:my_lib/my_lib.dart`):
  /// headers that name it in NATIVEBIND_DART_LIBRARY are generated here
  /// instead of imported.
  final String? provides;
  final String? depfile;
  final bool barrel;

  /// Do not write; report outputs that differ.
  final bool check;
}

class GeneratorResult {
  final written = <String>[];
  final unchanged = <String>[];
  final stale = <String>[]; // check mode
  final modules = <String>[];
  final parsedFiles = <String>[];
}

/// One run of the generator over a set of module files.
class Generator {
  Generator(this.options);

  final GeneratorOptions options;
  final _root = Scope.root();
  final _parsed = <String, ParsedFile>{};

  GeneratorResult run() {
    final result = GeneratorResult();
    final inputs = _collectInputs();
    if (inputs.isEmpty) {
      throw GeneratorException(null, 'no module files found in ${options.inputs.join(', ')}',
          hint: 'pass .cpp files or directories containing NATIVEBIND_MODULE classes');
    }
    for (final f in inputs) {
      _parse(f);
    }
    result.parsedFiles.addAll(_parsed.keys);

    final analyzer = Analyzer(_root);
    final moduleFiles = inputs.where((f) => _parsed[f]!.modules.isNotEmpty).toList();
    final resolved = <String, List<RModule>>{
      for (final f in moduleFiles) f: [for (final m in _parsed[f]!.modules) analyzer.module(m)],
    };
    for (final ms in resolved.values) {
      result.modules.addAll(ms.map((m) => m.decl.name));
    }
    final dartNames = <String>{};
    for (final ms in resolved.values) {
      for (final m in ms) {
        if (!dartNames.add(m.decl.name)) {
          throw GeneratorException(m.decl.loc, 'two modules are named ${m.decl.name}', hint: 'module names must be unique');
        }
      }
    }

    if (options.cppOut != null) {
      for (final f in moduleFiles) {
        final stem = p.withoutExtension(p.basename(f));
        final out = p.join(options.cppOut!, '$stem.nb.cpp');
        final header = '$stem.nb.hpp';
        final refs = CppRefEmitter(analyzer, resolved[f]!,
            sourceFile: f,
            sourceLabel: p.basename(f),
            includes: [
              for (final (path, angled, res) in _parsed[f]!.rawIncludes)
                if (angled)
                  '<$path>'
                else if (res != null)
                  cppString(p.relative(res, from: p.dirname(out))),
            ]);
        _write(p.join(options.cppOut!, header), refs.emitHeader(), result);
        final code = CppEmitter(analyzer, resolved[f]!,
                includePath: p.relative(f, from: p.dirname(out)),
                sourceLabel: p.basename(f),
                isExternal: (cpp) => _externalLibraryOf(cpp) != null,
                refs: refs,
                refHeader: header)
            .emit();
        _write(out, code, result);
      }
      final dep = options.depfile;
      if (dep != null && moduleFiles.length == 1) {
        final out = p.join(options.cppOut!, '${p.withoutExtension(p.basename(moduleFiles.first))}.nb.cpp');
        String esc(String s) => s.replaceAll(' ', r'\ ');
        final deps = _dependencies(moduleFiles.first).map(esc).join(' \\\n  ');
        _write(dep, '${esc(p.absolute(out))}: \\\n  $deps\n', result, quiet: true);
      }
    }

    if (options.dartOut != null) _emitDart(analyzer, resolved, result);
    return result;
  }

  // ------------------------------------------------------------ inputs

  List<String> _collectInputs() {
    final out = <String>[];
    void add(String path) {
      final abs = p.absolute(path);
      if (!out.contains(abs)) out.add(abs);
    }

    for (final input in options.inputs) {
      final type = FileSystemEntity.typeSync(input);
      if (type == FileSystemEntityType.directory) {
        final files = Directory(input)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((f) {
              final ext = p.extension(f.path).toLowerCase();
              return sourceExtensions.contains(ext) || headerExtensions.contains(ext);
            })
            .where((f) => !p.basename(f.path).contains('.nb.'))
            .map((f) => f.path)
            .toList()
          ..sort();
        for (final f in files) {
          if (File(f).readAsStringSync().contains('NATIVEBIND_MODULE')) add(f);
        }
      } else if (type == FileSystemEntityType.file) {
        add(input);
      } else {
        throw GeneratorException(null, 'no such file or directory: $input');
      }
    }
    return out;
  }

  ParsedFile _parse(String path) {
    final existing = _parsed[path];
    if (existing != null) return existing;
    final file = ParsedFile(path);
    _parsed[path] = file; // before recursing: include cycles
    final lexer = Lexer(File(path).readAsStringSync(), _display(path));
    final tokens = lexer.run();
    for (final inc in lexer.includes) {
      if (inc.path.startsWith('nativebind/')) continue; // nativebind's own headers are known
      if (p.basename(inc.path).contains('.nb.')) continue; // generated (e.g. another module's .nb.hpp)
      final resolved = _resolveInclude(inc.path, inc.angled ? null : p.dirname(path));
      file.rawIncludes.add((inc.path, inc.angled, resolved));
      if (resolved == null) continue; // system or generated header: not ours to read
      file.includes.add(resolved);
      _parse(resolved);
    }
    Parser(tokens, file, _root).parse();
    return file;
  }

  String? _resolveInclude(String include, String? fromDir) {
    for (final dir in [if (fromDir != null) fromDir, ...options.includeDirs]) {
      final candidate = p.join(p.absolute(dir), include);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  String? _externalLibraryOf(String cppFile) {
    final lib = _parsed[cppFile]?.dartLibrary;
    return lib != null && lib != options.provides ? lib : null;
  }

  Set<String> _dependencies(String file) {
    final out = <String>{};
    void visit(String f) {
      if (!out.add(f)) return;
      for (final i in _parsed[f]!.includes) {
        visit(i);
      }
    }

    visit(file);
    return out;
  }

  String _display(String path) {
    final rel = p.relative(path, from: Directory.current.path);
    return rel.startsWith('../../..') ? path : rel;
  }

  // ------------------------------------------------------------ Dart

  void _emitDart(Analyzer analyzer, Map<String, List<RModule>> resolved, GeneratorResult result) {
    // Types used by any module, grouped by the file that declares them.
    final enumsByFile = <String, List<EnumDecl>>{};
    final structsByFile = <String, List<StructDecl>>{};
    for (final ms in resolved.values) {
      for (final m in ms) {
        for (final e in m.enums) {
          final d = e.decl;
          if (d != null && _externalLibraryOf(d.file) == null && !(enumsByFile[d.file] ??= []).contains(d)) {
            enumsByFile[d.file]!.add(d);
          }
        }
        for (final s in m.structs) {
          final d = s.decl;
          if (d != null && _externalLibraryOf(d.file) == null && !(structsByFile[d.file] ??= []).contains(d)) {
            structsByFile[d.file]!.add(d);
          }
        }
      }
    }
    // Keep declaration order within each file.
    for (final list in enumsByFile.values) {
      list.sort((a, b) => a.loc.line.compareTo(b.loc.line));
    }
    for (final list in structsByFile.values) {
      list.sort((a, b) => a.loc.line.compareTo(b.loc.line));
    }

    final files = <String>{...resolved.keys, ...enumsByFile.keys, ...structsByFile.keys}.toList();
    final dartFile = _dartFileNames(files);
    final names = DartNames();
    final emitted = <String>[];
    for (final f in files) {
      final name = dartFile[f]!;
      final emitter = DartEmitter(analyzer, names,
          sourceLabel: p.basename(f),
          dartFileOf: (cpp) => dartFile[cpp]!,
          ownFile: name,
          externalLibraryOf: _externalLibraryOf);
      final code = emitter.emit(
        enums: enumsByFile[f] ?? const [],
        structs: structsByFile[f] ?? const [],
        modules: resolved[f] ?? const [],
      );
      _write(p.join(options.dartOut!, name), code, result);
      emitted.add(name);
    }

    if (options.barrel) {
      final b = StringBuffer()
        ..writeln('// Generated by nativebind_generator. DO NOT EDIT.')
        ..writeln('//')
        ..writeln('// ignore_for_file: type=lint')
        ..writeln()
        ..writeln("import 'package:nativebind/generated.dart' as \$p;")
        ..writeln();
      final sorted = [...emitted]..sort();
      final withModules = {for (final f in resolved.keys) dartFile[f]!};
      for (final e in sorted.where(withModules.contains)) {
        b.writeln("import '$e';");
      }
      b.writeln();
      for (final e in sorted) {
        b.writeln("export '$e';");
      }
      b
        ..writeln()
        ..writeln('/// Every generated module type. Pass it to `NativeBind.start`:')
        ..writeln('///')
        ..writeln("///     await NativeBind.start(library: 'libbackend.so', modules: nativebindModules);")
        ..writeln('final List<\$p.ModuleType> nativebindModules = [');
      for (final f in files) {
        for (final m in resolved[f] ?? const <RModule>[]) {
          b.writeln('  ${m.decl.name}.\$type,');
        }
      }
      b.writeln('];');
      _write(p.join(options.dartOut!, 'nativebind_modules.dart'), b.toString(), result);
    }
  }

  /// `player.cpp` -> `player.nb.dart`; clashing names get the extension.
  Map<String, String> _dartFileNames(List<String> files) {
    final byBase = <String, List<String>>{};
    for (final f in files) {
      (byBase[p.withoutExtension(p.basename(f))] ??= []).add(f);
    }
    final out = <String, String>{};
    for (final MapEntry(key: base, value: group) in byBase.entries) {
      if (group.length == 1) {
        out[group.first] = '$base.nb.dart';
        continue;
      }
      final seen = <String>{};
      for (final f in group) {
        final name = '${base}_${p.extension(f)}.nb.dart';
        if (!seen.add(name)) {
          throw GeneratorException(SourceLoc(f, 1, 1), 'two module files are named ${p.basename(f)}',
              hint: 'Dart output is flat; rename one of them');
        }
        out[f] = name;
      }
    }
    return out;
  }

  // ------------------------------------------------------------ output

  void _write(String path, String content, GeneratorResult result, {bool quiet = false}) {
    final file = File(path);
    final same = file.existsSync() && file.readAsStringSync() == content;
    if (same) {
      if (!quiet) result.unchanged.add(path);
      return;
    }
    if (options.check) {
      result.stale.add(path);
      return;
    }
    file.parent.createSync(recursive: true);
    // Write-then-rename so a concurrent build never sees a partial file.
    final tmp = File('$path.tmp$pid');
    tmp.writeAsStringSync(content);
    tmp.renameSync(path);
    if (!quiet) result.written.add(path);
  }
}

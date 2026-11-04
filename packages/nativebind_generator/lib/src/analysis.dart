import 'diagnostics.dart';
import 'lexer.dart';
import 'model.dart';


// ---------------------------------------------------------------- resolved model

sealed class RMember {
  RMember(this.member);
  final Member member;
  String get name => member.name;
}

class RProp extends RMember {
  RProp(PropMember super.member, this.type);
  final TypeRef type;
  PropMember get decl => member as PropMember;
}

class RList extends RMember {
  RList(ListMember super.member, this.item);
  final TypeRef item;
}

class RSignal extends RMember {
  RSignal(SignalMember super.member, this.args);
  final List<TypeRef> args;
}

class RParam {
  RParam(this.name, this.type);
  final String? name;
  final TypeRef type;
}

class RMethod extends RMember {
  RMethod(MethodMember super.member, this.returns, this.params, {this.permission});
  final TypeRef returns;
  final List<RParam> params;

  /// NATIVEBIND_INVOKE_AS argument as a C++ expression valid anywhere
  /// (an integer, or a fully qualified enumerator), or null.
  final String? permission;
  MethodMember get decl => member as MethodMember;
}

class RField {
  RField(this.decl, this.type);
  final FieldDecl decl;
  final TypeRef type;
}

class RStruct {
  RStruct(this.decl, this.fields);
  final StructDecl decl;
  final List<RField> fields;
}

class RModule {
  RModule(this.decl, this.members, this.structs, this.enums);
  final ModuleDecl decl;
  final List<RMember> members;

  /// Structs and enums the module uses (transitively), in first-use order.
  /// Includes nativebind's builtin types.
  final List<StructType> structs;
  final List<EnumType> enums;

  Iterable<RProp> get props => members.whereType<RProp>();
  Iterable<RList> get lists => members.whereType<RList>();
  Iterable<RSignal> get signals => members.whereType<RSignal>();
  Iterable<RMethod> get methods => members.whereType<RMethod>();
}

// ---------------------------------------------------------------- resolver

/// Where a type appears (references and string_view are allowed for parameters).
enum TypeUse { value, param, result }

class Analyzer {
  Analyzer(this.root);

  final Scope root;
  final _structCache = <StructDecl, RStruct>{};

  RStruct structOf(StructDecl d) {
    final cached = _structCache[d];
    if (cached != null) return cached;
    if (d.problems.isNotEmpty) throw d.problems.first;
    final scope = d.scope.classes[d.name] ?? d.scope;
    final r = RStruct(d, []);
    _structCache[d] = r; // before fields: allows recursive types
    for (final f in d.fields) {
      r.fields.add(RField(f, resolve(f.type, scope, 'field `${f.name}` of ${d.name}')));
    }
    if (r.fields.isEmpty) {
      throw GeneratorException(d.loc, 'struct ${d.name} has no fields that can cross the binding');
    }
    return r;
  }

  RModule module(ModuleDecl m) {
    final members = <RMember>[];
    final seen = <String>{};
    for (final mem in m.members) {
      if (!seen.add(mem.name)) {
        throw GeneratorException(mem.loc, '`${mem.name}` is declared twice in ${m.name}',
            hint: 'NATIVEBIND_INVOKE methods cannot be overloaded');
      }
      final ctx = m.classScope;
      members.add(switch (mem) {
        PropMember() => RProp(mem, resolve(mem.type, ctx, 'property `${mem.name}`')),
        ListMember() => RList(mem, resolve(mem.itemType, ctx, 'list `${mem.name}`')),
        SignalMember() => RSignal(mem, [
            for (final (k, a) in mem.args.indexed) resolve(a, ctx, 'argument ${k + 1} of signal `${mem.name}`'),
          ]),
        MethodMember() => RMethod(
            mem,
            resolve(mem.returnType, ctx, 'the result of `${mem.name}`', use: TypeUse.result),
            [
              for (final (k, p) in mem.params.indexed)
                RParam(p.name, resolve(p.type, ctx, 'parameter ${p.name ?? '${k + 1}'} of `${mem.name}`', use: TypeUse.param)),
            ],
            permission: _permission(mem, ctx),
          ),
      });
    }

    final structs = <StructType>[];
    final enums = <EnumType>[];
    void visit(TypeRef t) {
      switch (t) {
        case ListType(:final item):
          visit(item);
        case OptionalType(:final inner):
          visit(inner);
        case EnumType():
          if (!enums.any((e) => e.name == t.name)) enums.add(t);
        case StructType():
          if (structs.any((s) => s.name == t.name)) return;
          structs.add(t);
          if (t.decl != null) {
            for (final f in structOf(t.decl!).fields) {
              visit(f.type);
            }
          }
        case PrimType():
          break;
      }
    }

    for (final mem in members) {
      switch (mem) {
        case RProp(:final type):
          visit(type);
        case RList(:final item):
          visit(item);
        case RSignal(:final args):
          args.forEach(visit);
        case RMethod(:final returns, :final params):
          for (final p in params) {
            visit(p.type);
          }
          visit(returns);
      }
    }
    return RModule(m, members, structs, enums);
  }

  /// Resolves a C++ type written in [ctx] to a wire type.
  TypeRef resolve(TypeExpr e, Scope ctx, String what, {TypeUse use = TypeUse.value, int depth = 0}) {
    if (depth > 32) throw GeneratorException(e.loc, 'type alias cycle in $what');
    final toks = e.tokens.where((t) => !t.isIdent('const') && !t.isIdent('volatile') && !t.isIdent('typename')).toList();
    while (toks.isNotEmpty && (toks.last.isPunct('&') || toks.last.isPunct('&&'))) {
      if (use == TypeUse.value) throw GeneratorException(e.loc, 'reference type `${e.text}` for $what');
      toks.removeLast();
    }
    if (toks.any((t) => t.isPunct('*'))) {
      throw GeneratorException(e.loc, 'pointer type `${e.text}` for $what cannot cross the binding',
          hint: 'use a value type, std::optional or std::vector');
    }
    if (toks.isNotEmpty && const {'struct', 'class', 'enum'}.contains(toks.first.text)) toks.removeAt(0);
    if (toks.isEmpty) throw GeneratorException(e.loc, 'missing type for $what');

    // builtin arithmetic spellings
    if (toks.every((t) => t.kind == TokKind.ident)) {
      final words = toks.map((t) => t.text).toList();
      final set = words.toSet();
      if (words.length == 1 && words.first == 'void') {
        if (use != TypeUse.result) throw GeneratorException(e.loc, '`void` is not a valid type for $what');
        return const PrimType(Prim.voidT);
      }
      if (words.length == 1 && words.first == 'bool') return const PrimType(Prim.boolT);
      if ((set.difference({'long', 'double'}).isEmpty && set.contains('double')) || (words.length == 1 && words.first == 'float')) {
        return const PrimType(Prim.doubleT);
      }
      if (set.difference(const {'unsigned', 'signed', 'short', 'long', 'int', 'char'}).isEmpty) {
        return const PrimType(Prim.intT);
      }
      if (words.length == 1 && words.first == 'auto') {
        throw GeneratorException(e.loc, '`auto` is not allowed for $what', hint: 'write the type explicitly');
      }
    }

    final name = _QualifiedName.parse(toks, e);
    final path = name.path;
    final plain = path.first == 'std' ? path.sublist(1) : path;
    final joined = plain.join('::');

    TypeRef arg(int k, String role) {
      if (name.args.length <= k) throw GeneratorException(e.loc, '`${e.text}` needs a template argument');
      return resolve(TypeExpr(name.args[k], e.loc), ctx, '$role of $what', depth: depth + 1);
    }

    const ints = {
      'int8_t', 'int16_t', 'int32_t', 'int64_t', 'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t', 'size_t',
      'ptrdiff_t', 'intptr_t', 'uintptr_t', 'int_least32_t', 'int_fast32_t', 'ssize_t', 'intmax_t', 'uintmax_t',
    };
    const durations = {
      'nanoseconds', 'microseconds', 'milliseconds', 'seconds', 'minutes', 'hours', 'days', 'weeks', 'months', 'years',
    };
    if (plain.length == 1 && ints.contains(joined)) return const PrimType(Prim.intT);
    switch (joined) {
      case 'string':
        return const PrimType(Prim.stringT);
      case 'string_view':
        if (use == TypeUse.param) return const PrimType(Prim.stringT);
        throw GeneratorException(e.loc, 'std::string_view cannot be stored or returned ($what)', hint: 'use std::string');
      case 'vector':
        final item = arg(0, 'the item type');
        return ListType(item);
      case 'optional':
        final inner = arg(0, 'the value type');
        if (inner is OptionalType) throw GeneratorException(e.loc, 'nested std::optional for $what');
        return OptionalType(inner);
      case 'chrono::system_clock::time_point':
        return const PrimType(Prim.timeT);
      case 'chrono::time_point':
        final clock = name.args.isEmpty ? '' : name.args.first.map((t) => t.text).join();
        if (clock.endsWith('system_clock')) return const PrimType(Prim.timeT);
        throw GeneratorException(e.loc, 'only std::chrono::system_clock time points can cross the binding ($what)');
      case 'chrono::duration':
        return const PrimType(Prim.durationT);
    }
    if (plain.length == 2 && plain.first == 'chrono' && durations.contains(plain.last)) {
      return const PrimType(Prim.durationT);
    }
    if (const {'vector', 'optional', 'map', 'unordered_map', 'set', 'array', 'pair', 'tuple', 'variant', 'shared_ptr', 'unique_ptr'}
            .contains(joined) ||
        name.args.isNotEmpty) {
      throw GeneratorException(e.loc, '`${e.text}` cannot cross the binding ($what)',
          hint: 'supported: bool, integers, double, std::string, enums, structs, std::vector, std::optional, '
              'std::chrono durations and system_clock time points');
    }

    // user types
    final found = _lookup(path, ctx, absolute: name.absolute);
    switch (found) {
      case EnumDecl():
        _checkEnumRange(found);
        return EnumType(found.name, decl: found);
      case StructDecl():
        structOf(found); // validates the fields now, with a precise location
        return StructType(found.name, decl: found);
      case Alias():
        return resolve(found.target, found.scope, what, use: use, depth: depth + 1);
    }

    throw GeneratorException(e.loc, 'unknown type `${e.text}` for $what',
        hint: 'define the enum or struct in this file or in a header it #includes; headers outside the file\'s '
            'directory need -I <dir> (CMake: nativebind_add_header_dirs)');
  }

  final _rangeChecked = <EnumDecl>{};

  /// Enums cross the wire as i32: a value outside that range would arrive
  /// truncated (0xFFFFFFFF as -1) and match no Dart enum value. Only enums
  /// that actually cross the binding are checked.
  void _checkEnumRange(EnumDecl d) {
    if (!_rangeChecked.add(d)) return;
    for (final v in d.values) {
      if (v.value < -0x80000000 || v.value > 0x7fffffff) {
        throw GeneratorException(d.loc, 'enumerator ${d.name}::${v.name} = ${v.value} does not fit the binding',
            hint: 'enums cross the binding as int32 values (-2147483648 to 2147483647); '
                'use smaller values, or send the value as an integer property instead');
      }
    }
  }

  /// Qualifies a NATIVEBIND_INVOKE_AS argument so the generated glue (in
  /// namespace nativebind::glue) can use it.
  String? _permission(MethodMember mem, Scope ctx) {
    final p = mem.permission;
    if (p == null) return null;
    if (RegExp(r'^-?(0x[0-9a-fA-F]+|\d+)$').hasMatch(p)) return p;
    final absolute = p.startsWith('::');
    final parts = (absolute ? p.substring(2) : p).split('::');
    if (parts.length >= 2 && parts.every((x) => RegExp(r'^[A-Za-z_]\w*$').hasMatch(x))) {
      final found = _lookup(parts.sublist(0, parts.length - 1), ctx, absolute: absolute);
      if (found is EnumDecl && found.values.any((v) => v.name == parts.last)) return '${found.qualified}::${parts.last}';
    }
    throw GeneratorException(mem.loc, 'NATIVEBIND_INVOKE_AS(`$p`): cannot resolve the permission',
        hint: 'use an integer or an enumerator of a scoped enum, e.g. NATIVEBIND_INVOKE_AS(Role::Admin)');
  }

  /// Finds a type by (possibly qualified) name, searching outwards from ctx.
  Object? _lookup(List<String> path, Scope ctx, {required bool absolute}) {
    if (absolute) return _lookupIn(root, path);
    for (Scope? s = ctx; s != null; s = s.parent) {
      final r = _lookupIn(s, path);
      if (r != null) return r;
      for (final u in s.usingNamespaces) {
        var ns = _scopeAt(root, u) ?? _scopeAt(s, u);
        if (ns == null) continue;
        final r2 = _lookupIn(ns, path);
        if (r2 != null) return r2;
      }
    }
    return null;
  }

  Scope? _scopeAt(Scope from, List<String> path) {
    Scope? s = from;
    for (final p in path) {
      s = s?.namespaces[p] ?? s?.classes[p];
      if (s == null) return null;
    }
    return s;
  }

  Object? _lookupIn(Scope s, List<String> path) {
    if (path.length == 1) {
      final n = path.first;
      final hit = s.aliases[n] ?? s.enums[n] ?? s.structs[n];
      if (hit != null) return hit;
      final anon = s.namespaces[''];
      if (anon != null) return _lookupIn(anon, path);
      return null;
    }
    final child = s.namespaces[path.first] ?? s.classes[path.first];
    if (child != null) {
      final r = _lookupIn(child, path.sublist(1));
      if (r != null) return r;
    }
    final anon = s.namespaces[''];
    return anon == null ? null : _lookupIn(anon, path);
  }
}

class _QualifiedName {
  _QualifiedName(this.path, this.args, this.absolute);

  final List<String> path;
  final List<List<Token>> args;
  final bool absolute;

  static _QualifiedName parse(List<Token> toks, TypeExpr e) {
    var k = 0;
    var absolute = false;
    if (toks[k].isPunct('::')) {
      absolute = true;
      k++;
    }
    final path = <String>[];
    final args = <List<Token>>[];
    while (k < toks.length) {
      final t = toks[k];
      if (t.kind != TokKind.ident) throw GeneratorException(e.loc, 'cannot read type `${e.text}`');
      path.add(t.text);
      k++;
      if (k < toks.length && toks[k].isPunct('<')) {
        // template arguments up to the matching '>'
        var depth = 0;
        final start = k + 1;
        var end = -1;
        for (var j = k; j < toks.length; j++) {
          if (toks[j].isPunct('<')) depth++;
          if (toks[j].isPunct('>') && --depth == 0) {
            end = j;
            break;
          }
        }
        if (end < 0) throw GeneratorException(e.loc, 'unbalanced `<` in `${e.text}`');
        var current = <Token>[];
        var d = 0;
        for (final x in toks.sublist(start, end)) {
          if (x.isPunct('<') || x.isPunct('(')) d++;
          if (x.isPunct('>') || x.isPunct(')')) d--;
          if (x.isPunct(',') && d == 0) {
            args.add(current);
            current = [];
            continue;
          }
          current.add(x);
        }
        if (current.isNotEmpty) args.add(current);
        k = end + 1;
      }
      if (k < toks.length && toks[k].isPunct('::')) {
        k++;
        continue;
      }
      break;
    }
    if (k != toks.length || path.isEmpty) throw GeneratorException(e.loc, 'cannot read type `${e.text}`');
    return _QualifiedName(path, args, absolute);
  }
}

// ---------------------------------------------------------------- schema

/// Canonical description of a module. The C++ glue and the Dart code both
/// embed it; the Dart runtime compares them at startup to detect stale code.
String schemaOf(RModule m, Analyzer a) {
  final b = StringBuffer('module ${m.decl.name} ${m.decl.instanced ? 'instanced' : 'singleton'}\n');
  for (final mem in m.members) {
    switch (mem) {
      case RProp(:final type):
        b.writeln('prop ${mem.name} ${type.schema} ${mem.decl.writable ? 'rw' : 'ro'}');
      case RList(:final item):
        b.writeln('list ${mem.name} ${item.schema}');
      case RSignal(:final args):
        b.writeln('signal ${mem.name}(${args.map((t) => t.schema).join(', ')})');
      case RMethod(:final params, :final returns):
        final permission = mem.decl.permission == null ? '' : ' permission=${mem.decl.permission}';
        b.writeln('method ${mem.name}(${params.map((p) => p.type.schema).join(', ')}) -> ${returns.schema}$permission');
    }
  }
  for (final s in m.structs) {
    if (s.decl == null) continue;
    final fields = a.structOf(s.decl!).fields.map((f) => '${f.type.schema} ${f.decl.name}; ').join();
    b.writeln('struct ${s.name} { $fields}');
  }
  for (final e in m.enums) {
    if (e.decl == null) continue;
    final values = e.decl!.values.map((v) => '${v.name}=${v.value}');
    b.writeln('enum ${e.name} { ${values.join(', ')} }');
  }
  return b.toString();
}

import 'diagnostics.dart';
import 'lexer.dart';

// ---------------------------------------------------------------- scopes

enum ScopeKind { root, namespace, klass }

/// A namespace or class. Namespaces are merged across files and reopenings,
/// so lookup sees everything parsed in one run.
class Scope {
  Scope.root()
      : kind = ScopeKind.root,
        name = '',
        parent = null;
  Scope(this.kind, this.name, Scope this.parent);

  final ScopeKind kind;
  final String name;
  final Scope? parent;

  final namespaces = <String, Scope>{};
  final classes = <String, Scope>{};
  final enums = <String, EnumDecl>{};
  final structs = <String, StructDecl>{};
  final aliases = <String, Alias>{};
  final usingNamespaces = <List<String>>[];

  /// `::a::b::C`, or `` for the root.
  String get qualified {
    if (parent == null) return '';
    if (name.isEmpty) return parent!.qualified; // anonymous namespace
    return '${parent!.qualified}::$name';
  }

  /// Namespace path from the root (`['nativebind']`).
  List<String> get path {
    final out = <String>[];
    for (Scope? s = this; s != null && s.parent != null; s = s.parent) {
      if (s.name.isNotEmpty) out.insert(0, s.name);
    }
    return out;
  }

  Scope namespace(String n) => namespaces.putIfAbsent(n, () => Scope(ScopeKind.namespace, n, this));
}

class Alias {
  Alias(this.name, this.target, this.scope);

  final String name;
  final TypeExpr target;
  final Scope scope;
}

/// Unresolved C++ type as written, plus where it was written.
class TypeExpr {
  TypeExpr(this.tokens, this.loc);

  final List<Token> tokens;
  final SourceLoc loc;

  String get text {
    final b = StringBuffer();
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (i > 0 && t.kind == TokKind.ident && tokens[i - 1].kind == TokKind.ident) b.write(' ');
      b.write(t.text);
    }
    return b.toString();
  }

  @override
  String toString() => text;
}

// ---------------------------------------------------------------- declarations

class EnumValue {
  EnumValue(this.name, this.value, this.doc);

  final String name;
  final int value;
  final String? doc;
}

class EnumDecl {
  EnumDecl(this.name, this.scope, this.values, this.loc, this.doc, this.file);

  final String name;
  final Scope scope;
  final List<EnumValue> values;
  final SourceLoc loc;
  final String? doc;
  final String file;

  String get qualified => '${scope.qualified}::$name';
}

class FieldDecl {
  FieldDecl(this.name, this.type, this.init, this.loc, this.doc);

  final String name;
  final TypeExpr type;

  /// Initializer tokens (`= x` or `{x}`), or null.
  final List<Token>? init;
  final SourceLoc loc;
  final String? doc;
}

class StructDecl {
  StructDecl(this.name, this.scope, this.loc, this.doc, this.file);

  final String name;
  final Scope scope;
  final SourceLoc loc;
  final String? doc;
  final String file;
  final fields = <FieldDecl>[];

  /// Why this struct cannot cross the binding (bases, private fields, ...).
  final problems = <GeneratorException>[];

  String get qualified => '${scope.qualified}::$name';
}

sealed class Member {
  Member(this.name, this.loc, this.doc);

  final String name;
  final SourceLoc loc;
  final String? doc;
}

class PropMember extends Member {
  PropMember(super.name, super.loc, super.doc, this.type, {required this.writable});

  final TypeExpr type;
  final bool writable;
}

class ListMember extends Member {
  ListMember(super.name, super.loc, super.doc, this.itemType);

  final TypeExpr itemType;
}

class SignalMember extends Member {
  SignalMember(super.name, super.loc, super.doc, this.args);

  final List<TypeExpr> args;
}

class Param {
  Param(this.name, this.type);

  final String? name;
  final TypeExpr type;
}

class MethodMember extends Member {
  MethodMember(super.name, super.loc, super.doc, this.returnType, this.params, this.permission);

  final TypeExpr returnType;
  final List<Param> params;

  /// NATIVEBIND_INVOKE_AS argument as written (e.g. `Role::Admin`), or null.
  final String? permission;
}

class ModuleDecl {
  ModuleDecl(this.name, this.scope, this.classScope, this.loc, this.doc, this.file, {required this.instanced});

  final String name;

  /// Enclosing scope of the class.
  final Scope scope;

  /// The class body (for resolving nested types).
  final Scope classScope;
  final SourceLoc loc;
  final String? doc;
  final String file;
  final bool instanced;
  final members = <Member>[];

  String get qualified => '${scope.qualified}::$name';
  Iterable<PropMember> get props => members.whereType<PropMember>();
  Iterable<ListMember> get lists => members.whereType<ListMember>();
  Iterable<SignalMember> get signals => members.whereType<SignalMember>();
  Iterable<MethodMember> get methods => members.whereType<MethodMember>();
}

/// Everything parsed from one file.
class ParsedFile {
  ParsedFile(this.path);

  final String path;
  final includes = <String>[]; // resolved paths of parsed local includes

  /// Every #include as written: (path, angled, resolved path or null).
  final rawIncludes = <(String, bool, String?)>[];
  final modules = <ModuleDecl>[];
  final enums = <EnumDecl>[];
  final structs = <StructDecl>[];

  /// NATIVEBIND_DART_LIBRARY: the Dart library that already defines this
  /// file's enums and structs, or null.
  String? dartLibrary;
}

// ---------------------------------------------------------------- resolved types

sealed class TypeRef {
  const TypeRef();

  /// Spelling in the schema text.
  String get schema;
}

enum Prim { voidT, boolT, intT, doubleT, stringT, timeT, durationT }

class PrimType extends TypeRef {
  const PrimType(this.prim);

  final Prim prim;

  @override
  String get schema => switch (prim) {
        Prim.voidT => 'void',
        Prim.boolT => 'bool',
        Prim.intT => 'int',
        Prim.doubleT => 'double',
        Prim.stringT => 'string',
        Prim.timeT => 'time',
        Prim.durationT => 'duration',
      };
}

class ListType extends TypeRef {
  const ListType(this.item);

  final TypeRef item;

  @override
  String get schema => 'list<${item.schema}>';
}

class OptionalType extends TypeRef {
  const OptionalType(this.inner);

  final TypeRef inner;

  @override
  String get schema => 'optional<${inner.schema}>';
}

/// An enum parsed from source.
class EnumType extends TypeRef {
  const EnumType(this.name, {this.decl});

  final String name;
  final EnumDecl? decl;

  @override
  String get schema => name;
}

class StructType extends TypeRef {
  const StructType(this.name, {this.decl});

  final String name;
  final StructDecl? decl;

  bool get isBuiltin => decl == null;

  @override
  String get schema => name;
}

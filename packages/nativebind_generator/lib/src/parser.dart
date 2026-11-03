import 'diagnostics.dart';
import 'lexer.dart';
import 'model.dart';

/// State of the class body being parsed.
class _ClassCtx {
  _ClassCtx(this.name, this.scope, {required this.isStruct, required this.isTemplate, required this.bases})
      : access = isStruct ? 'public' : 'private';

  final String? name;
  final Scope scope;
  final bool isStruct;
  final bool isTemplate;
  final List<Token> bases;
  String access;
  ModuleDecl? module;
  final fields = <FieldDecl>[];
  final problems = <GeneratorException>[];
}

const _nbMacros = {
  'NATIVEBIND_MODULE',
  'NATIVEBIND_PROP',
  'NATIVEBIND_READ',
  'NATIVEBIND_LIST',
  'NATIVEBIND_SIGNAL',
  'NATIVEBIND_INVOKE',
  'NATIVEBIND_INVOKE_AS',
};

/// Finds namespaces, enums, structs, aliases and nativebind modules in one file.
/// It is not a full C++ parser: it recognizes declarations at namespace and
/// class scope and skips everything else (function bodies, initializers).
class Parser {
  Parser(this._t, this.file, this.root);

  final List<Token> _t;
  final ParsedFile file;
  final Scope root;
  int _i = 0;
  bool _templatePending = false;

  void parse() {
    _body(root, null);
    if (_i < _t.length) throw GeneratorException(_t[_i].loc, 'unbalanced `}`');
  }

  // ------------------------------------------------------------ helpers

  bool get _done => _i >= _t.length;
  Token get _cur => _t[_i];
  Token? _at(int k) => k < _t.length ? _t[k] : null;

  SourceLoc get _eofLoc => _t.isEmpty ? SourceLoc(file.path, 1, 1) : _t.last.loc;

  GeneratorException _err(Token? at, String message, {String? hint}) =>
      GeneratorException(at?.loc ?? _eofLoc, message, hint: hint);

  /// Index just past the bracket matching the one at [open].
  int _matching(int open) {
    final o = _t[open].text;
    final c = switch (o) { '(' => ')', '{' => '}', '[' => ']', _ => throw StateError(o) };
    var depth = 0;
    for (var k = open; k < _t.length; k++) {
      final x = _t[k];
      if (x.kind != TokKind.punct) continue;
      if (x.text == o) depth++;
      if (x.text == c && --depth == 0) return k + 1;
    }
    throw _err(_t[open], 'unbalanced `$o`');
  }

  /// Index just past the `>` matching the `<` at [open] (parens nest inside).
  int _matchingAngle(int open) {
    var depth = 0;
    for (var k = open; k < _t.length; k++) {
      final x = _t[k];
      if (x.isPunct('(') || x.isPunct('[') || x.isPunct('{')) {
        k = _matching(k) - 1;
        continue;
      }
      if (x.isPunct('<')) depth++;
      if (x.isPunct('>') && --depth == 0) return k + 1;
      if (x.isPunct(';')) break;
    }
    throw _err(_t[open], 'unbalanced `<`');
  }

  void _skipToSemicolon() {
    while (!_done && !_cur.isPunct(';')) {
      if (_cur.isPunct('{') || _cur.isPunct('(') || _cur.isPunct('[')) {
        _i = _matching(_i);
      } else if (_cur.isPunct('}')) {
        return;
      } else {
        _i++;
      }
    }
    if (!_done) _i++;
  }

  int _skipAttributes(int k) {
    while (true) {
      final x = _at(k);
      if (x == null) return k;
      if (x.isPunct('[') && (_at(k + 1)?.isPunct('[') ?? false)) {
        k = _matching(k);
      } else if (x.isIdent('alignas') && (_at(k + 1)?.isPunct('(') ?? false)) {
        k = _matching(k + 1);
      } else {
        return k;
      }
    }
  }

  /// Splits tokens at top-level commas. Parentheses, brackets and braces
  /// always nest; angle brackets only when [angles] (C++ declarations, not
  /// macro arguments, which split like the preprocessor does).
  List<List<Token>> _splitCommas(List<Token> toks, {required bool angles}) {
    final out = <List<Token>>[[]];
    var depth = 0, angle = 0;
    for (final x in toks) {
      if (x.kind == TokKind.punct) {
        switch (x.text) {
          case '(' || '[' || '{':
            depth++;
          case ')' || ']' || '}':
            depth--;
          case '<' when angles && depth == 0:
            angle++;
          case '>' when angles && depth == 0 && angle > 0:
            angle--;
          case ',' when depth == 0 && angle == 0:
            out.add([]);
            continue;
        }
      }
      out.last.add(x);
    }
    return out;
  }

  /// If [start, end) looks like a function declaration (`R name(...)`),
  /// returns the index of its parameter `(`; otherwise -1.
  int _functionParen(int start, int end) {
    var angle = 0;
    for (var k = start; k < end; k++) {
      final x = _t[k];
      if (x.isPunct('=') || x.isPunct('{')) return -1; // initializer
      if (x.isPunct('<') && k > start && (_t[k - 1].kind == TokKind.ident || _t[k - 1].isPunct('>'))) {
        angle++;
      } else if (x.isPunct('>') && angle > 0) {
        angle--;
      } else if (x.isPunct('(') && angle == 0) {
        final prev = k > start ? _t[k - 1] : null;
        if (prev == null) return -1;
        if (prev.kind == TokKind.ident &&
            !const {'decltype', 'alignas', 'sizeof', 'noexcept', 'alignof', 'static_assert', 'requires'}.contains(prev.text)) {
          return k;
        }
        if (prev.kind == TokKind.punct && k - 2 >= start && _t[k - 2].isIdent('operator')) return k;
        return -1;
      } else if (x.isPunct('[') && (_at(k + 1)?.isPunct('[') ?? false)) {
        k = _matching(k) - 1;
      }
    }
    return -1;
  }

  // ------------------------------------------------------------ bodies

  /// Parses declarations until `}` (not consumed) or the end of the file.
  void _body(Scope scope, _ClassCtx? cls) {
    var stmt = _i;
    while (!_done) {
      final tok = _cur;
      if (tok.isPunct('}')) return;

      if (tok.isPunct(';')) {
        if (cls != null) _field(cls, stmt, _i);
        _i++;
        stmt = _i;
        continue;
      }

      if (tok.isPunct('{')) {
        final paren = _functionParen(stmt, _i);
        if (paren < 0) {
          _i = _matching(_i); // brace initializer; the statement goes on
          continue;
        }
        final close = _matching(paren);
        final hasInitList = _t.sublist(close, _i).any((x) => x.isPunct(':'));
        final prev = _t[_i - 1];
        if (hasInitList && (prev.kind == TokKind.ident || prev.isPunct('>'))) {
          _i = _matching(_i); // member initializer `x{...}` in a constructor init list
          continue;
        }
        _i = _matching(_i); // function body
        stmt = _i;
        continue;
      }

      if (tok.isPunct('(') || (tok.isPunct('[') && (_at(_i + 1)?.isPunct('[') ?? false))) {
        _i = _matching(_i);
        continue;
      }

      if (tok.kind == TokKind.ident) {
        final atStart = _i == stmt;
        switch (tok.text) {
          case 'namespace' when atStart:
            _namespace(scope);
            stmt = _i;
            continue;
          case 'inline' when atStart && (_at(_i + 1)?.isIdent('namespace') ?? false):
            _i++;
            stmt = _i;
            continue;
          case 'extern' when atStart && _at(_i + 1)?.kind == TokKind.string && (_at(_i + 2)?.isPunct('{') ?? false):
            _i += 3;
            _body(scope, cls);
            if (!_done) _i++;
            stmt = _i;
            continue;
          case 'template' when atStart:
            _i++;
            if (!_done && _cur.isPunct('<')) _i = _matchingAngle(_i);
            _templatePending = true;
            stmt = _i;
            continue;
          case 'enum' when atStart:
            if (_enum(scope)) {
              _skipToSemicolon();
              stmt = _i;
              continue;
            }
          case 'struct' || 'class' || 'union' when atStart:
            if (_class(scope, tok.text)) {
              _skipToSemicolon();
              stmt = _i;
              continue;
            }
          case 'using' when atStart:
            _using(scope);
            stmt = _i;
            continue;
          case 'typedef' when atStart:
            _typedef(scope);
            stmt = _i;
            continue;
          case 'public' || 'private' || 'protected' when atStart && (_at(_i + 1)?.isPunct(':') ?? false):
            if (cls != null) cls.access = tok.text;
            _i += 2;
            stmt = _i;
            continue;
          default:
            if (tok.text == 'NATIVEBIND_DART_LIBRARY') {
              _i++;
              final args = _macroArgs(tok);
              if (args.length != 1 || args.first.length != 1 || args.first.first.kind != TokKind.string) {
                throw _err(tok, 'NATIVEBIND_DART_LIBRARY needs one string literal',
                    hint: 'NATIVEBIND_DART_LIBRARY("package:my_package/my_package.dart")');
              }
              final lit = args.first.first.text;
              file.dartLibrary = lit.length >= 2 && lit.startsWith('"') && lit.endsWith('"') ? lit.substring(1, lit.length - 1) : lit;
              _optionalSemicolon();
              stmt = _i;
              continue;
            }
            if (_nbMacros.contains(tok.text)) {
              if (!atStart) throw _err(tok, '${tok.text} must start a declaration');
              _macro(tok, cls);
              stmt = _i;
              continue;
            }
        }
      }
      _templatePending = false;
      _i++;
    }
  }

  void _namespace(Scope scope) {
    final kw = _cur;
    _i++;
    final names = <String>[];
    while (!_done && _cur.kind == TokKind.ident) {
      if (_cur.text != 'inline') names.add(_cur.text);
      _i++;
      if (!_done && _cur.isPunct('::')) _i++;
    }
    _i = _skipAttributes(_i);
    if (_done) throw _err(kw, 'expected namespace body');
    if (_cur.isPunct('=')) {
      _skipToSemicolon(); // namespace alias
      return;
    }
    if (!_cur.isPunct('{')) throw _err(_cur, 'expected `{` after namespace');
    _i++;
    var target = scope;
    if (names.isEmpty) {
      target = scope.namespace(''); // anonymous: contributes no qualification
    } else {
      for (final n in names) {
        target = target.namespace(n);
      }
    }
    _body(target, null);
    if (_done) throw _err(kw, 'unterminated namespace');
    _i++;
  }

  void _using(Scope scope) {
    final start = _i;
    _i++;
    if (!_done && _cur.isIdent('namespace')) {
      _i++;
      final path = <String>[];
      while (!_done && !_cur.isPunct(';')) {
        if (_cur.kind == TokKind.ident) path.add(_cur.text);
        _i++;
      }
      _i++;
      scope.usingNamespaces.add(path);
      return;
    }
    if (_at(_i)?.kind == TokKind.ident && (_at(_i + 1)?.isPunct('=') ?? false)) {
      final name = _cur.text;
      _i += 2;
      final typeStart = _i;
      _skipToSemicolon();
      final toks = _t.sublist(typeStart, _i - 1);
      if (toks.isNotEmpty) scope.aliases[name] = Alias(name, TypeExpr(toks, _t[start].loc), scope);
      return;
    }
    _skipToSemicolon();
  }

  void _typedef(Scope scope) {
    final start = _i;
    _skipToSemicolon();
    final toks = _t.sublist(start + 1, _i - 1);
    if (toks.length < 2 || toks.any((x) => x.isPunct('(') || x.isPunct('{')) || toks.last.kind != TokKind.ident) return;
    final name = toks.last.text;
    scope.aliases[name] = Alias(name, TypeExpr(toks.sublist(0, toks.length - 1), _t[start].loc), scope);
  }

  // ------------------------------------------------------------ enums

  bool _enum(Scope scope) {
    final kw = _cur;
    var k = _i + 1;
    if (_at(k)?.isIdent('class') ?? false) k++;
    if (_at(k)?.isIdent('struct') ?? false) k++;
    k = _skipAttributes(k);
    String? name;
    if (_at(k)?.kind == TokKind.ident) name = _t[k++].text;
    if (_at(k)?.isPunct(':') ?? false) {
      while (k < _t.length && !_t[k].isPunct('{') && !_t[k].isPunct(';')) {
        k++;
      }
    }
    if (!(_at(k)?.isPunct('{') ?? false)) return false;
    final close = _matching(k);
    final body = _t.sublist(k + 1, close - 1);
    final values = <EnumValue>[];
    final known = <String, int>{};
    var next = 0;
    for (final part in _splitCommas(body, angles: false)) {
      if (part.isEmpty) continue; // trailing comma
      final nameTok = part.first;
      if (nameTok.kind != TokKind.ident) throw _err(nameTok, 'expected an enumerator name');
      var value = next;
      var rest = part.sublist(1);
      rest = rest.sublist(_skipAttributesIn(rest));
      if (rest.isNotEmpty) {
        if (!rest.first.isPunct('=')) throw _err(rest.first, 'unexpected `${rest.first}` in enum ${name ?? ''}');
        value = _ConstExpr(rest.sublist(1), known).evaluate();
      }
      known[nameTok.text] = value;
      final docs = [nameTok.doc, nameTok.trailingDoc].whereType<String>().toList();
      values.add(EnumValue(nameTok.text, value, docs.isEmpty ? null : docs.join('\n')));
      next = value + 1;
    }
    _i = close;
    _templatePending = false;
    if (name != null) {
      final decl = EnumDecl(name, scope, values, kw.loc, kw.doc, file.path);
      scope.enums[name] = decl;
      file.enums.add(decl);
    }
    return true;
  }

  int _skipAttributesIn(List<Token> toks) {
    var k = 0;
    while (k + 1 < toks.length && toks[k].isPunct('[') && toks[k + 1].isPunct('[')) {
      var depth = 0;
      for (; k < toks.length; k++) {
        if (toks[k].isPunct('[')) depth++;
        if (toks[k].isPunct(']') && --depth == 0) {
          k++;
          break;
        }
      }
    }
    return k;
  }

  // ------------------------------------------------------------ classes

  bool _class(Scope scope, String keyword) {
    final kw = _cur;
    var k = _skipAttributes(_i + 1);
    String? name;
    if (_at(k)?.kind == TokKind.ident && !(_at(k)?.isIdent('final') ?? false)) {
      name = _t[k++].text;
      while ((_at(k)?.isPunct('::') ?? false) && _at(k + 1)?.kind == TokKind.ident) {
        name = _t[k + 1].text; // out-of-line nested definition: keep the last name
        k += 2;
      }
    }
    if (_at(k)?.isIdent('final') ?? false) k++;
    final bases = <Token>[];
    if (_at(k)?.isPunct(':') ?? false) {
      k++;
      while (k < _t.length && !_t[k].isPunct('{') && !_t[k].isPunct(';')) {
        if (_t[k].isPunct('<')) {
          final end = _matchingAngle(k);
          bases.addAll(_t.sublist(k, end));
          k = end;
          continue;
        }
        bases.add(_t[k++]);
      }
    }
    if (!(_at(k)?.isPunct('{') ?? false)) return false;

    final isTemplate = _templatePending;
    _templatePending = false;
    final classScope = Scope(ScopeKind.klass, name ?? '', scope);
    if (name != null) scope.classes[name] = classScope;
    final ctx = _ClassCtx(name, classScope, isStruct: keyword != 'class', isTemplate: isTemplate, bases: bases);
    _i = k + 1;
    _body(classScope, ctx);
    if (_done) throw _err(kw, 'unterminated $keyword ${name ?? ''}');
    _i++; // '}'

    if (name == null) return true;
    final module = ctx.module;
    if (module != null) {
      if (!bases.any((b) => b.isIdent('Module'))) {
        throw _err(kw, 'module $name must derive from nativebind::Module', hint: 'class $name : public nativebind::Module { ... }');
      }
      file.modules.add(module);
      return true;
    }
    final decl = StructDecl(name, scope, kw.loc, kw.doc, file.path);
    decl.fields.addAll(ctx.fields);
    decl.problems.addAll(ctx.problems);
    if (bases.isNotEmpty) {
      decl.problems.add(_err(kw, 'struct $name has a base class', hint: 'structs that cross the binding must be plain aggregates'));
    }
    if (isTemplate) decl.problems.add(_err(kw, '$name is a template'));
    scope.structs[name] = decl;
    file.structs.add(decl);
    return true;
  }

  /// Records a data member of a struct from the statement [start, end).
  void _field(_ClassCtx cls, int start, int end) {
    if (cls.module != null || start >= end) return;
    var toks = _t.sublist(start, end);
    toks = toks.sublist(_skipAttributesIn(toks));
    if (toks.isEmpty) return;
    const skip = {
      'using', 'typedef', 'friend', 'static_assert', 'template', 'static', 'enum', 'struct', 'class', 'union',
      'operator', 'virtual', 'explicit', 'inline', 'constexpr', 'consteval', 'requires',
    };
    if (skip.contains(toks.first.text) || toks.any((x) => x.isIdent('operator'))) return;
    if (_functionParen(start, end) >= 0) return;
    toks = toks.where((x) => !x.isIdent('mutable')).toList();

    var split = toks.length;
    var depth = 0, angle = 0;
    for (var k = 0; k < toks.length; k++) {
      final x = toks[k];
      if (x.isPunct('(') || x.isPunct('[')) depth++;
      if (x.isPunct(')') || x.isPunct(']')) depth--;
      if (x.isPunct('<') && depth == 0) angle++;
      if (x.isPunct('>') && depth == 0 && angle > 0) angle--;
      if (depth == 0 && angle == 0 && (x.isPunct('=') || x.isPunct('{'))) {
        split = k;
        break;
      }
    }
    final decl = toks.sublist(0, split);
    List<Token>? init;
    if (split < toks.length) {
      init = toks[split].isPunct('{') ? toks.sublist(split + 1, toks.length - 1) : toks.sublist(split + 1);
    }
    if (decl.any((x) => x.isPunct(':') || x.isPunct('['))) {
      final at = decl.lastWhere((x) => x.kind == TokKind.ident, orElse: () => decl.first);
      cls.problems.add(_err(at, 'field `${at.text}` of ${cls.name}: bit-fields and C arrays are not supported',
          hint: 'use std::vector'));
      return;
    }
    if (decl.length < 2 || decl.last.kind != TokKind.ident) return;
    final name = decl.last;
    if (_splitCommas(decl, angles: true).length > 1) {
      cls.problems.add(_err(name, 'declare one field per statement in struct ${cls.name}'));
      return;
    }
    if (cls.access != 'public') {
      cls.problems.add(_err(name, 'field `${name.text}` of ${cls.name} is not public'));
    }
    cls.fields.add(FieldDecl(name.text, TypeExpr(decl.sublist(0, decl.length - 1), toks.first.loc), init, name.loc,
        toks.first.doc ?? name.doc));
  }

  // ------------------------------------------------------------ macros

  /// Macro arguments split like the preprocessor (commas inside parens only).
  List<List<Token>> _macroArgs(Token macro) {
    if (_done || !_cur.isPunct('(')) throw _err(macro, 'expected `(` after ${macro.text}');
    final end = _matching(_i);
    final args = _splitCommas(_t.sublist(_i + 1, end - 1), angles: false);
    _i = end;
    return args;
  }

  void _macro(Token macro, _ClassCtx? cls) {
    _i++;
    if (cls == null) throw _err(macro, '${macro.text} must be inside a class');
    final name = macro.text;

    if (name == 'NATIVEBIND_MODULE') {
      final args = _macroArgs(macro);
      if (args.first.length != 1 || args.first.first.kind != TokKind.ident) {
        throw _err(macro, 'NATIVEBIND_MODULE needs the class name: NATIVEBIND_MODULE(${cls.name ?? 'Name'})');
      }
      if (args.first.first.text != cls.name) {
        throw _err(args.first.first, 'NATIVEBIND_MODULE(${args.first.first.text}) is inside class ${cls.name}',
            hint: 'write NATIVEBIND_MODULE(${cls.name})');
      }
      if (cls.module != null) throw _err(macro, 'NATIVEBIND_MODULE appears twice in ${cls.name}');
      var instanced = false;
      for (final opt in args.skip(1)) {
        final text = opt.map((x) => x.text).join(' ');
        // .order only matters at runtime (creation order); the compiler checks it.
        if (RegExp(r'^\. order = ').hasMatch(text)) continue;
        final m = RegExp(r'^\. instanced = (true|false)$').firstMatch(text);
        if (m == null) {
          throw _err(opt.isEmpty ? macro : opt.first, 'unknown module option `$text`',
              hint: 'supported: .instanced = true, .order = <int>');
        }
        instanced = m.group(1) == 'true';
      }
      cls.module = ModuleDecl(cls.name!, cls.scope.parent!, cls.scope, macro.loc, macro.doc, file.path, instanced: instanced);
      _optionalSemicolon();
      return;
    }

    final module = cls.module;
    if (module == null) {
      throw _err(macro, '$name in ${cls.name} before NATIVEBIND_MODULE', hint: 'put NATIVEBIND_MODULE(${cls.name}) first in the class');
    }

    if (name == 'NATIVEBIND_INVOKE' || name == 'NATIVEBIND_INVOKE_AS') {
      String? permission;
      if (name == 'NATIVEBIND_INVOKE_AS') {
        final args = _macroArgs(macro);
        permission = args.expand((a) => a).map((x) => x.text).join();
        if (args.length != 1 || permission.isEmpty) {
          throw _err(macro, 'NATIVEBIND_INVOKE_AS needs one permission: an integer or enum value for the guard',
              hint: 'NATIVEBIND_INVOKE_AS(Role::Admin)');
        }
      }
      module.members.add(_method(macro, permission));
      return;
    }

    final args = _macroArgs(macro);
    // The preprocessor splits arguments at every comma outside parentheses,
    // so `std::map<K, V>` arrives in pieces.
    final typeArgs = name == 'NATIVEBIND_SIGNAL' ? args.skip(1) : args.take(1);
    for (final a in typeArgs) {
      final open = a.where((x) => x.isPunct('<')).length;
      final close = a.where((x) => x.isPunct('>')).length;
      if (open > close) {
        throw _err(a.first, 'a type in $name contains a comma, which splits macro arguments',
            hint: 'name it with an alias first, e.g. `using Pair = std::pair<int, int>;`');
      }
    }
    Token nameOf(List<Token> a, String usage) {
      if (a.length != 1 || a.first.kind != TokKind.ident) throw _err(a.isEmpty ? macro : a.first, 'expected a member name: $usage');
      return a.first;
    }

    switch (name) {
      case 'NATIVEBIND_PROP' || 'NATIVEBIND_READ':
        final usage = '$name(Type, name, initial[, .min = ...])';
        if (args.length < 3 || args[0].isEmpty || args[2].isEmpty) throw _err(macro, 'expected $usage');
        final n = nameOf(args[1], usage);
        module.members.add(PropMember(n.text, n.loc, macro.doc, TypeExpr(args[0], args[0].first.loc), writable: name == 'NATIVEBIND_PROP'));
      case 'NATIVEBIND_LIST':
        const usage = 'NATIVEBIND_LIST(Type, name)';
        if (args.length != 2 || args[0].isEmpty) throw _err(macro, 'expected $usage');
        final n = nameOf(args[1], usage);
        module.members.add(ListMember(n.text, n.loc, macro.doc, TypeExpr(args[0], args[0].first.loc)));
      case 'NATIVEBIND_SIGNAL':
        const usage = 'NATIVEBIND_SIGNAL(name, ArgTypes...)';
        final n = nameOf(args[0], usage);
        final types = <TypeExpr>[];
        for (final a in args.skip(1)) {
          if (a.isEmpty) {
            if (args.length == 2) break; // NATIVEBIND_SIGNAL(name, ) is fine
            throw _err(n, 'empty argument type in NATIVEBIND_SIGNAL($n)');
          }
          types.add(TypeExpr(a, a.first.loc));
        }
        module.members.add(SignalMember(n.text, n.loc, macro.doc, types));
    }
    _optionalSemicolon();
  }

  void _optionalSemicolon() {
    if (!_done && _cur.isPunct(';')) _i++;
  }

  MethodMember _method(Token macro, String? permission) {
    final start = _i;
    var paren = -1;
    var angle = 0;
    for (var k = start; k < _t.length; k++) {
      final x = _t[k];
      if (x.isPunct(';') || x.isPunct('{')) break;
      if (x.isPunct('[') && (_at(k + 1)?.isPunct('[') ?? false)) {
        k = _matching(k) - 1;
        continue;
      }
      if (x.isPunct('<')) angle++;
      if (x.isPunct('>') && angle > 0) angle--;
      if (x.isPunct('(') && angle == 0) {
        paren = k;
        break;
      }
    }
    if (paren <= start) throw _err(macro, 'expected a method declaration after ${macro.text}');
    final nameTok = _t[paren - 1];
    if (nameTok.kind != TokKind.ident) throw _err(nameTok, '${macro.text} must be followed by a named method');
    if (paren - 2 >= start && (_t[paren - 2].isIdent('operator') || _t[paren - 2].isPunct('~'))) {
      throw _err(nameTok, '${macro.text} cannot mark an operator or destructor');
    }
    var ret = _t.sublist(start, paren - 1);
    ret = ret.sublist(_skipAttributesIn(ret));
    if (ret.any((x) => x.isIdent('static'))) {
      throw _err(nameTok, 'NATIVEBIND_INVOKE method `${nameTok.text}` must not be static');
    }
    ret = ret.where((x) => !const {'virtual', 'inline', 'constexpr', 'consteval', 'explicit'}.contains(x.text)).toList();

    final close = _matching(paren);
    final params = <Param>[];
    final inner = _t.sublist(paren + 1, close - 1);
    if (!(inner.length == 1 && inner.first.isIdent('void'))) {
      for (var p in _splitCommas(inner, angles: true)) {
        if (p.isEmpty) continue;
        final eq = p.indexWhere((x) => x.isPunct('='));
        if (eq >= 0) p = p.sublist(0, eq);
        p = p.sublist(_skipAttributesIn(p));
        String? pname;
        var ptype = p;
        if (p.length >= 2 && p.last.kind == TokKind.ident && !p[p.length - 2].isPunct('::') &&
            !const {'int', 'long', 'short', 'unsigned', 'signed', 'char', 'double', 'float', 'bool'}.contains(p.last.text)) {
          pname = p.last.text;
          ptype = p.sublist(0, p.length - 1);
        }
        if (ptype.isEmpty) throw _err(nameTok, 'cannot read a parameter of `${nameTok.text}`');
        params.add(Param(pname, TypeExpr(ptype, ptype.first.loc)));
      }
    }

    // qualifiers, trailing return type, body
    _i = close;
    List<Token>? trailing;
    while (!_done && !_cur.isPunct('{') && !_cur.isPunct(';') && !_cur.isPunct('=')) {
      if (_cur.isPunct('->')) {
        _i++;
        final ts = _i;
        while (!_done && !_cur.isPunct('{') && !_cur.isPunct(';') && !_cur.isPunct('=') &&
            !_cur.isIdent('override') && !_cur.isIdent('final')) {
          _i++;
        }
        trailing = _t.sublist(ts, _i);
        continue;
      }
      if (_cur.isPunct('(')) {
        _i = _matching(_i); // noexcept(...)
        continue;
      }
      _i++;
    }
    if (_done) throw _err(nameTok, 'unterminated declaration of `${nameTok.text}`');
    if (_cur.isPunct('{')) {
      _i = _matching(_i);
    } else {
      _skipToSemicolon();
    }
    if (trailing != null && ret.length == 1 && ret.first.isIdent('auto')) ret = trailing;
    if (ret.isEmpty) throw _err(nameTok, 'method `${nameTok.text}` has no return type');
    return MethodMember(nameTok.text, nameTok.loc, macro.doc, TypeExpr(ret, ret.first.loc), params, permission);
  }
}

/// Integer constant expressions in enumerator initializers: literals, earlier
/// enumerators, parentheses, unary - ~ +, binary * / % + - << >> & ^ |.
class _ConstExpr {
  _ConstExpr(this._t, this._known);

  final List<Token> _t;
  final Map<String, int> _known;
  int _i = 0;

  int evaluate() {
    if (_t.isEmpty) throw GeneratorException(null, 'missing enumerator value');
    final v = _binary(0);
    if (_i != _t.length) throw _fail();
    return v;
  }

  GeneratorException _fail() => GeneratorException(
        _t.isEmpty ? null : _t[_i < _t.length ? _i : _t.length - 1].loc,
        'enumerator value `${_t.map((x) => x.text).join(' ')}` is not a constant nativebind can read',
        hint: 'use integer literals, earlier enumerators and + - * << | &',
      );

  static const _prec = {'|': 1, '^': 2, '&': 3, '<<': 4, '>>': 4, '+': 5, '-': 5, '*': 6, '/': 6, '%': 6};

  String? _op() {
    if (_i >= _t.length || _t[_i].kind != TokKind.punct) return null;
    final x = _t[_i].text;
    if ((x == '<' || x == '>') && _i + 1 < _t.length && _t[_i + 1].text == x) return '$x$x';
    return _prec.containsKey(x) ? x : null;
  }

  int _binary(int minPrec) {
    var left = _unary();
    while (true) {
      final op = _op();
      if (op == null || _prec[op]! <= minPrec) return left;
      _i += op.length == 2 && (op == '<<' || op == '>>') ? 2 : 1;
      final right = _binary(_prec[op]!);
      left = switch (op) {
        '|' => left | right,
        '^' => left ^ right,
        '&' => left & right,
        '<<' => left << right,
        '>>' => left >> right,
        '+' => left + right,
        '-' => left - right,
        '*' => left * right,
        '/' => right == 0 ? throw _fail() : left ~/ right,
        _ => right == 0 ? throw _fail() : left % right,
      };
    }
  }

  int _unary() {
    if (_i >= _t.length) throw _fail();
    final x = _t[_i];
    if (x.isPunct('-')) {
      _i++;
      return -_unary();
    }
    if (x.isPunct('+')) {
      _i++;
      return _unary();
    }
    if (x.isPunct('~')) {
      _i++;
      return ~_unary();
    }
    if (x.isPunct('(')) {
      _i++;
      final v = _binary(0);
      if (_i >= _t.length || !_t[_i].isPunct(')')) throw _fail();
      _i++;
      return v;
    }
    if (x.kind == TokKind.number) {
      _i++;
      return parseCppInt(x.text) ?? (throw _fail());
    }
    if (x.kind == TokKind.char) {
      _i++;
      final body = x.text.substring(x.text.indexOf("'") + 1, x.text.length - 1);
      if (body.length == 1) return body.codeUnitAt(0);
      throw _fail();
    }
    if (x.kind == TokKind.ident) {
      // Name, or Enum::Name / ::ns::Enum::Name: use the last component.
      var k = _i;
      var last = x.text;
      while (k + 2 < _t.length && _t[k + 1].isPunct('::') && _t[k + 2].kind == TokKind.ident) {
        last = _t[k + 2].text;
        k += 2;
      }
      _i = k + 1;
      final v = _known[last];
      if (v == null) throw _fail();
      return v;
    }
    throw _fail();
  }
}

/// Parses a C++ integer literal (with separators and suffixes), or null.
int? parseCppInt(String text) {
  var s = text.replaceAll("'", '');
  s = s.replaceFirst(RegExp(r'[uUlLzZ]+$'), '');
  if (s.startsWith('0x') || s.startsWith('0X')) return int.tryParse(s.substring(2), radix: 16);
  if (s.startsWith('0b') || s.startsWith('0B')) return int.tryParse(s.substring(2), radix: 2);
  if (s.length > 1 && s.startsWith('0')) return int.tryParse(s.substring(1), radix: 8);
  return int.tryParse(s);
}

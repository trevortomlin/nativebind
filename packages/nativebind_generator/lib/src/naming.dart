/// C++ to Dart identifier conventions.
library;

/// Reserved words: never valid as identifiers.
const dartReserved = {
  'assert', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum',
  'extends', 'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with', 'yield',
};

/// Built-in identifiers: valid member names, but not type names.
const dartBuiltIn = {
  'abstract', 'as', 'covariant', 'deferred', 'dynamic', 'export', 'extension', 'external', 'factory', 'Function',
  'get', 'implements', 'import', 'interface', 'late', 'library', 'mixin', 'operator', 'part', 'required', 'set',
  'static', 'typedef',
};

/// Members every Dart object has.
const objectMembers = {'hashCode', 'runtimeType', 'toString', 'noSuchMethod'};

List<String> _words(String s) {
  s = s.replaceAll(RegExp(r'^_+|_+$'), '');
  final out = <String>[];
  for (final part in s.split(RegExp('_+'))) {
    if (part.isEmpty) continue;
    if (part == part.toUpperCase()) {
      out.add(part.toLowerCase()); // FAST_FORWARD, USB
      continue;
    }
    // split camel case, keeping acronyms together: HTTPServer -> HTTP, Server
    final m = RegExp(r'[A-Z]+(?![a-z])|[A-Z]?[a-z0-9]+|[0-9]+').allMatches(part);
    out.addAll(m.map((x) => x.group(0)!.toLowerCase()));
  }
  return out;
}

String _cap(String w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1);

String _safe(String id) => dartReserved.contains(id) || objectMembers.contains(id) ? '${id}_' : id;

/// play_count, playCount, PlayCount -> playCount
String dartMember(String cpp) {
  final w = _words(cpp);
  if (w.isEmpty) return _safe(cpp);
  return _safe(w.first + w.skip(1).map(_cap).join());
}

/// media_player, MediaPlayer -> MediaPlayer
String dartType(String cpp) {
  final t = RegExp(r'^[A-Z][A-Za-z0-9]*$').hasMatch(cpp) ? cpp : _words(cpp).map(_cap).join();
  return dartReserved.contains(t) || dartBuiltIn.contains(t) ? '${t}_' : t;
}

/// Off -> off, FAST_FORWARD -> fastForward, kFastForward -> fastForward
String dartEnumValue(String cpp) {
  final stripped = RegExp(r'^k[A-Z]').hasMatch(cpp) ? cpp.substring(1) : cpp;
  final v = dartMember(stripped);
  return const {'values', 'index', 'name', 'wire', 'codec', 'label'}.contains(v) ? '${v}_' : v;
}

/// Escapes a string for a single-quoted Dart literal.
String dartString(String s) {
  final b = StringBuffer("'");
  for (final r in s.runes) {
    switch (r) {
      case 0x5C:
        b.write(r'\\');
      case 0x27:
        b.write(r"\'");
      case 0x24:
        b.write(r'\$');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        if (r < 0x20) {
          b.write('\\u{${r.toRadixString(16)}}');
        } else {
          b.writeCharCode(r);
        }
    }
  }
  b.write("'");
  return b.toString();
}

/// Escapes a string for a C++ string literal.
String cppString(String s) {
  final b = StringBuffer('"');
  for (final c in s.split('')) {
    switch (c) {
      case '\\':
        b.write(r'\\');
      case '"':
        b.write(r'\"');
      case '\n':
        b.write(r'\n');
      case '\t':
        b.write(r'\t');
      default:
        b.write(c);
    }
  }
  b.write('"');
  return b.toString();
}

/// A C identifier made from a qualified C++ name: ::media::Track -> media_Track
String cIdent(String qualified) => qualified.replaceFirst(RegExp('^::'), '').replaceAll('::', '_');

/// Display label derived from a C++ enumerator or member name, in sentence
/// case, keeping acronyms: FastForward -> Fast forward, UsbDrive -> Usb drive,
/// HTTPServer -> HTTP server, FAST_FORWARD -> Fast forward, kOff -> Off.
String humanLabel(String cpp) {
  var s = RegExp(r'^k[A-Z]').hasMatch(cpp) ? cpp.substring(1) : cpp;
  s = s.replaceAll(RegExp(r'^_+|_+$'), '');
  final allCaps = s == s.toUpperCase();
  final words = <String>[];
  for (final part in s.split(RegExp('_+'))) {
    if (part.isEmpty) continue;
    if (allCaps) {
      words.add(part.toLowerCase());
      continue;
    }
    for (final m in RegExp(r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+').allMatches(part)) {
      final w = m.group(0)!;
      words.add(w.length > 1 && w == w.toUpperCase() && RegExp('[A-Z]').hasMatch(w) ? w : w.toLowerCase());
    }
  }
  if (words.isEmpty) return cpp;
  final first = words.first;
  return [first[0].toUpperCase() + first.substring(1), ...words.skip(1)].join(' ');
}

/// Splits `@label Text` out of a doc comment: (label or null, remaining doc).
(String?, String?) labelFromDoc(String? doc) {
  if (doc == null) return (null, null);
  String? label;
  final rest = <String>[];
  for (final line in doc.split('\n')) {
    final m = RegExp(r'^\s*@label\s+(.+?)\s*$').firstMatch(line);
    if (m != null && label == null) {
      label = m.group(1);
    } else {
      rest.add(line);
    }
  }
  final text = rest.join('\n').trim();
  return (label, text.isEmpty ? null : text);
}

/// Doc comment text as runtime help: single line breaks become spaces,
/// blank lines stay paragraph breaks.
String docText(String doc) => doc
    .trim()
    .split(RegExp(r'\n\s*\n'))
    .map((p) => p.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join(' '))
    .join('\n\n');

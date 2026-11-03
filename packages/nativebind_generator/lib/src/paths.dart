import 'dart:io';

/// Minimal path helpers (the generator has no package dependencies).
String normalize(String path) {
  final p = path.replaceAll('\\', '/');
  final absolute = p.startsWith('/');
  final drive = RegExp(r'^[A-Za-z]:/').hasMatch(p) ? p.substring(0, 2) : null;
  final parts = <String>[];
  for (final seg in (drive != null ? p.substring(2) : p).split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..' && parts.isNotEmpty && parts.last != '..') {
      parts.removeLast();
    } else if (seg == '..' && (absolute || drive != null)) {
      continue; // nothing above the root
    } else {
      parts.add(seg);
    }
  }
  final joined = parts.join('/');
  if (drive != null) return '$drive/$joined';
  return absolute ? '/$joined' : (joined.isEmpty ? '.' : joined);
}

String absolute(String path) => normalize(File(path).absolute.path);

String join(String a, String b) => normalize('$a/$b');

String dirname(String path) {
  final p = normalize(path);
  final k = p.lastIndexOf('/');
  if (k < 0) return '.';
  if (k == 0) return '/';
  return p.substring(0, k);
}

String basename(String path) {
  final p = normalize(path);
  return p.substring(p.lastIndexOf('/') + 1);
}

String withoutExtension(String name) {
  final k = name.lastIndexOf('.');
  return k <= 0 ? name : name.substring(0, k);
}

String extension(String name) {
  final k = name.lastIndexOf('.');
  return k <= 0 ? '' : name.substring(k + 1);
}

/// Path of [target] relative to directory [from] (both made absolute).
String relative(String target, {required String from}) {
  final t = absolute(target).split('/');
  final f = absolute(from).split('/');
  var k = 0;
  while (k < t.length && k < f.length && t[k] == f[k]) {
    k++;
  }
  if (k <= 1) return absolute(target); // nothing but the root in common
  final up = List.filled(f.length - k, '..');
  return [...up, ...t.sublist(k)].join('/');
}

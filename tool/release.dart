// Release helper. Both packages share one version, recorded in several files;
// this keeps them in step. Run from anywhere with `dart tool/release.dart`.
//
//   prepare <version>            set every version, date the changelog section
//   check [<version>]            versions agree (and equal <version>, with a
//                                changelog section for it); exit 1 if not
//   notes <version>              print that version's changelog section
//   published <package> <version>  print true if pub.dev has it
//
// See RELEASING.md.

import 'dart:convert';
import 'dart:io';

final root = File.fromUri(Platform.script).parent.parent.path;

String read(String path) => File('$root/$path').readAsStringSync();
void write(String path, String text) => File('$root/$path').writeAsStringSync(text);

const pubspecs = ['packages/nativebind/pubspec.yaml', 'packages/nativebind_generator/pubspec.yaml'];
const packageChangelogs = ['packages/nativebind/CHANGELOG.md', 'packages/nativebind_generator/CHANGELOG.md'];
const cmake = 'packages/nativebind/native/CMakeLists.txt';
const showcase = 'examples/showcase/pubspec.yaml';
const changelog = 'CHANGELOG.md';

final _semver = RegExp(r'^\d+\.\d+\.\d+$');

/// Every place a version is recorded: (description, version found or null).
List<(String, String?)> recordedVersions() => [
  for (final p in pubspecs) (p, RegExp(r'^version: (\S+)$', multiLine: true).firstMatch(read(p))?.group(1)),
  (cmake, RegExp(r'project\(nativebind VERSION (\S+)').firstMatch(read(cmake))?.group(1)),
  for (final dep in ['nativebind', 'nativebind_generator'])
    ('$showcase ($dep)', RegExp('^  $dep: \\^(\\S+)\$', multiLine: true).firstMatch(read(showcase))?.group(1)),
];

/// The body of `## <version>` in the root changelog, or null.
String? section(String version) {
  final text = read(changelog);
  final start = RegExp('^## ${RegExp.escape(version)}( |\$)', multiLine: true).firstMatch(text);
  if (start == null) return null;
  final bodyStart = text.indexOf('\n', start.start) + 1;
  final next = RegExp(r'^## ', multiLine: true).firstMatch(text.substring(bodyStart));
  return text.substring(bodyStart, next == null ? text.length : bodyStart + next.start).trim();
}

int check(String? version) {
  final problems = <String>[];
  final found = recordedVersions();
  final want = version ?? found.first.$2;
  for (final (where, v) in found) {
    if (v == null) {
      problems.add('$where: no version found');
    } else if (v != want) {
      problems.add('$where: $v, expected $want');
    }
  }
  if (version != null) {
    final body = section(version);
    if (body == null || body.isEmpty) problems.add('$changelog: no "## $version" section');
    if (RegExp(r'^## Unreleased', multiLine: true).hasMatch(read(changelog))) {
      problems.add('$changelog: still has an "## Unreleased" section; run prepare');
    }
    for (final p in packageChangelogs) {
      if (!RegExp('^## ${RegExp.escape(version)}\$', multiLine: true).hasMatch(read(p))) {
        problems.add('$p: no "## $version" entry');
      }
    }
  }
  if (problems.isEmpty) {
    stdout.writeln('versions agree: $want');
    return 0;
  }
  stderr.writeln(problems.map((p) => 'error: $p').join('\n'));
  return 1;
}

int prepare(String version) {
  if (!_semver.hasMatch(version)) {
    stderr.writeln('error: "$version" is not MAJOR.MINOR.PATCH');
    return 64;
  }
  var log = read(changelog);
  if (!RegExp(r'^## Unreleased$', multiLine: true).hasMatch(log)) {
    stderr.writeln('error: $changelog has no "## Unreleased" section to release');
    return 1;
  }
  final now = DateTime.now();
  final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  log = log.replaceFirst(RegExp(r'^## Unreleased$', multiLine: true), '## $version - $date');
  write(changelog, log);
  for (final p in pubspecs) {
    write(p, read(p).replaceFirst(RegExp(r'^version: \S+$', multiLine: true), 'version: $version'));
  }
  write(
    cmake,
    read(cmake).replaceFirst(RegExp(r'project\(nativebind VERSION \S+'), 'project(nativebind VERSION $version'),
  );
  var app = read(showcase);
  for (final dep in ['nativebind', 'nativebind_generator']) {
    app = app.replaceFirst(RegExp('^  $dep: \\^\\S+\$', multiLine: true), '  $dep: ^$version');
  }
  write(showcase, app);
  for (final p in packageChangelogs) {
    final text = read(p);
    if (text.contains('## $version\n')) continue;
    write(
      p,
      '## $version\n\n- See the\n'
      '  [repository changelog](https://github.com/trevortomlin/nativebind/blob/main/CHANGELOG.md)\n'
      '  for details.\n\n$text',
    );
  }
  stdout.writeln('prepared $version ($date); review the diff, then open a PR');
  return check(version);
}

Future<int> published(String package, String version) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('https://pub.dev/api/packages/$package'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) {
      stdout.writeln('false');
      return 0;
    }
    if (res.statusCode != 200) {
      stderr.writeln('error: pub.dev answered ${res.statusCode}');
      return 1;
    }
    final versions = ((jsonDecode(body) as Map<String, Object?>)['versions'] as List<Object?>).map(
      (v) => (v as Map<String, Object?>)['version'],
    );
    stdout.writeln(versions.contains(version));
    return 0;
  } finally {
    client.close();
  }
}

Future<void> main(List<String> args) async {
  final code = switch (args) {
    ['prepare', final v] => prepare(v),
    ['check'] => check(null),
    ['check', final v] => check(v),
    ['notes', final v] => () {
      final body = section(v);
      if (body == null) {
        stderr.writeln('error: no "## $v" section in $changelog');
        return 1;
      }
      stdout.writeln(body);
      return 0;
    }(),
    ['published', final p, final v] => await published(p, v),
    _ => () {
      stderr.writeln(
        'usage: dart tool/release.dart prepare <version> | check [<version>] | notes <version> | '
        'published <package> <version>',
      );
      return 64;
    }(),
  };
  exit(code);
}

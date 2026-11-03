// The whole app against the real C++ backend, which this test builds with
// CMake into build/native.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/nativebind.dart';
import 'package:nativebind_showcase/app.dart';
import 'package:nativebind_showcase/nativebind/nativebind_modules.dart';

String _buildBackend() {
  const dir = 'build/native';
  for (final args in [
    ['-S', 'native', '-B', dir, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Debug'],
    ['--build', dir],
  ]) {
    final r = Process.runSync('cmake', args);
    if (r.exitCode != 0) throw StateError('cmake ${args.join(' ')} failed:\n${r.stdout}\n${r.stderr}');
  }
  return File('$dir/libshowcase_backend.so').absolute.path;
}

void main() {
  late String library;

  setUpAll(() => library = _buildBackend());
  tearDown(NativeBind.stop);

  /// Lets C++ run for [ms] of real time, then applies its changes.
  Future<void> run(WidgetTester tester, [int ms = 50]) async {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    NativeBind.instance.drainNow();
    await tester.pump();
  }

  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() => NativeBind.start(library: library, modules: nativebindModules));
    await tester.pumpWidget(const ShowcaseApp());
  }

  testWidgets('counter: calls, read-only values, writes and signals', (tester) async {
    await boot(tester);
    final counter = Counter.instance;
    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await run(tester);
    expect(find.text('1'), findsOneWidget);

    counter.step.value = 9; // optimistic: shows at once, C++ acknowledges it
    await tester.pump();
    expect(find.text('Step: 9'), findsOneWidget);
    await run(tester);
    expect(counter.step.isPending, isFalse);

    final kept = await tester.runAsync(() => counter.step.write(50));
    expect(kept, 10, reason: 'C++ clamps to .max');

    final milestones = <int>[];
    final sub = counter.milestone.listen(milestones.add);
    await tester.tap(find.text('Add'));
    await run(tester);
    expect(find.text('11'), findsOneWidget);
    expect(milestones, [10]);
    expect(find.text('Reached 10!'), findsOneWidget);
    sub.cancel(); // not awaited: it completes outside the test's fake time

    await tester.tap(find.text('Reset'));
    await run(tester);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('player: enum state, timer, validation and list edits', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Player'));
    await tester.pump();
    final player = Player.instance;

    expect(player.queue.map((t) => t.title), ['Morning Light', 'Binding Agent', 'Zero Copy']);
    expect(player.queue.first.length, const Duration(minutes: 3, seconds: 4));
    expect(player.state.value, PlayState.stopped);

    await tester.tap(find.byTooltip('Play'));
    await run(tester, 400);
    expect(player.state.value, PlayState.playing);
    expect(player.position.value, greaterThan(0));

    final volume = await tester.runAsync(() => player.volume.write(0.33));
    expect(volume, 0.35, reason: 'validate() snaps to 5 % steps');

    final titles = <String>[];
    final sub = player.trackChanged.listen(titles.add);
    await tester.tap(find.byTooltip('Next'));
    await run(tester);
    expect(player.title.value, 'Binding Agent');
    expect(titles, ['Binding Agent']);
    sub.cancel(); // not awaited: it completes outside the test's fake time

    await tester.tap(find.byTooltip('Like').first);
    await run(tester);
    expect(player.queue.first.liked, isTrue);

    final id = await tester.runAsync(() => player.add('Extra', 'Test', 30));
    await run(tester);
    expect(player.queue.last.id, id);
    await tester.runAsync(() => player.remove(id!));
    await run(tester);
    expect(player.queue, hasLength(3));
  });

  testWidgets('downloads: instances created by C++ and updated by worker threads', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Downloads'));
    await tester.pump();
    expect(find.text('No downloads. Tap + to start one.'), findsOneWidget);

    final key = await tester.runAsync(() => Downloads.instance.start('small.bin', 64 * 1024));
    await run(tester);
    final d = Download.byKey(key!)!;
    expect(find.text('small.bin'), findsOneWidget);

    for (var i = 0; i < 40 && d.state.value != DownloadState.done; i++) {
      await run(tester);
    }
    expect(d.state.value, DownloadState.done);
    expect(d.progress.value, 1.0);
    expect(d.received.value, d.total.value);
    await run(tester);
    expect(Downloads.instance.active.value, 0);

    await tester.runAsync(Downloads.instance.clearFinished);
    await run(tester);
    expect(d.isAlive, isFalse);
    expect(Download.instances.value, isEmpty);
    expect(find.text('No downloads. Tap + to start one.'), findsOneWidget);
  });
}

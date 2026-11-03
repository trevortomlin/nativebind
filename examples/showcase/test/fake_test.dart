// The counter page against a scripted native side (no C++ library needed).
// FakeNative replays change-feed records exactly as the C++ runtime sends them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/nativebind.dart';
import 'package:nativebind/testing.dart';
import 'package:nativebind_showcase/nativebind/nativebind_modules.dart';
import 'package:nativebind_showcase/pages/counter_page.dart';

// Counter's members by declaration order: props step(0), count(1);
// signal milestone(0); methods increment(0), reset(1).
const counter = 1; // instance handle

void main() {
  tearDown(NativeBind.stop);

  testWidgets('shows the native state and sends calls', (tester) async {
    final native = FakeNative(nativebindModules);
    native.feed
      ..resync()
      ..added(counter, native.idOf('Counter'))
      ..meta(counter, 0, min: 1, max: 10)
      ..prop(counter, 0, i(2))
      ..meta(counter, 1, writable: false)
      ..prop(counter, 1, i(41));
    native.publish();
    await NativeBind.start(native: native, modules: nativebindModules);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CounterPage())));
    expect(find.text('41'), findsOneWidget);
    expect(find.text('Step: 2'), findsOneWidget);

    await tester.tap(find.text('Add'));
    expect(native.invokes.single.index, 0, reason: 'increment()');

    // Play the C++ side: the count changes and a milestone signal arrives.
    native.feed
      ..prop(counter, 1, i(43))
      ..signal(counter, 0, [i(40)]);
    native.publish();
    NativeBind.instance.drainNow();
    await tester.pump();
    expect(find.text('43'), findsOneWidget);
    expect(find.text('Reached 40!'), findsOneWidget);
  });
}

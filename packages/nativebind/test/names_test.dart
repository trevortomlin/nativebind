// Generated code for C++ names that collide with Dart (test/fixtures/names in
// the generator): it must compile and bind to the right members.

import 'package:flutter_test/flutter_test.dart';
import 'package:nativebind/generated.dart';
import 'package:nativebind/testing.dart';

import 'generated/names/nativebind_modules.dart';

const names = 1;

void main() {
  tearDown(NativeBind.stop);

  test('colliding names bind under their Dart spellings', () async {
    final f = FakeNative(nativebindModules);
    f.feed
      ..resync()
      ..added(names, f.idOf('Names'))
      ..prop(names, 0, i(7))
      ..prop(names, 1, i(3))
      ..prop(names, 2, e(0))
      ..prop(names, 4, (w) {
        w.beginStruct(1);
        w.intValue(40);
      })
      ..prop(names, 5, (w) => w.durationValue(const Duration(milliseconds: 250)));
    f.publish();
    await NativeBind.start(native: f, modules: nativebindModules);

    final n = Names.instance;
    expect(n.isAlive, isTrue); // ModuleProxy.isAlive, still a bool
    expect(n.isAlive_.value, 7); // the C++ property named isAlive
    expect(n.hashCode_.value, 3);
    expect(n.runtimeType_.value, Mode.values_);
    final DeviceDuration span = n.span.value; // renamed with @dart
    expect(span.ticks, 40);
    final Duration timeout = n.timeout.value; // still dart:core's Duration
    expect(timeout, const Duration(milliseconds: 250));
  });
}

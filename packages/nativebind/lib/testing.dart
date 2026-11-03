/// Test support: a scripted native side for testing views and widgets
/// without the C++ library.
///
/// ```dart
/// final native = FakeNative(nativebindModules);
/// native.feed..resync()..added(1, native.idOf('Player'))..prop(1, 0, d(0.5));
/// native.publish();
/// await NativeBind.start(native: native, modules: nativebindModules);
/// ```
library;

export 'src/testing/fake_native.dart';

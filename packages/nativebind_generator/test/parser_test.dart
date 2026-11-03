import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('reads members in declaration order with Dart names', () {
    final out = generate({
      'm.cpp': module('''
    NATIVEBIND_PROP(double, floor_temp, 1.0)
    NATIVEBIND_READ(int, count, 0);
    NATIVEBIND_LIST(std::string, names)
    NATIVEBIND_SIGNAL(beep)
    NATIVEBIND_INVOKE void go();
'''),
    });
    final dart = out['m.nb.dart']!;
    expect(dart, contains(r'late final $p.BoundProperty<double> floorTemp = $property(0, $p.doubleCodec);'));
    expect(dart, contains(r'late final $p.BoundValue<int> count = $value(1, $p.intCodec);'));
    expect(dart, contains(r'late final $p.BoundList<String> names = $list(0, $p.stringCodec);'));
    expect(dart, contains(r'late final $p.BoundSignal<void> beep = $signal(0, (_) {});'));
    expect(dart, contains(r'Future<void> go() => $invoke(0, null, $p.voidCodec);'));
    expect(out['m.nb.cpp'], contains('"prop floor_temp double rw\\n"'));
  });

  test('skips function bodies, initializers and constructor init lists', () {
    final out = generate({
      'm.cpp': module('''
    M() : a_(1), b_{2}, c_{[] { return 3; }()} {
        NATIVEBIND_FAKE(x);
        struct Inner { int z; };
    }
    void helper() { if (true) { int q = 1; (void)q; } }
    std::function<void()> fn = [] { };
    int arr{3};
    NATIVEBIND_PROP(int, after, 0)
private:
    int a_, b_, c_;
'''),
    });
    expect(out['m.nb.dart'], contains(r'BoundProperty<int> after = $property(0'));
    expect(out['m.nb.cpp'], isNot(contains('Inner')));
  });

  test('method qualifiers, attributes, defaults and trailing returns', () {
    final out = generate({
      'm.cpp': module('''
    NATIVEBIND_INVOKE [[nodiscard]] virtual std::string a(const std::string& s, int n = 3) const noexcept;
    NATIVEBIND_INVOKE auto b(std::string_view v) -> std::vector<int>;
    NATIVEBIND_INVOKE int c(int, double) override { return 1; }
    NATIVEBIND_INVOKE void d(void);
'''),
    });
    final dart = out['m.nb.dart']!;
    expect(dart, contains('Future<String> a(String s, int n)'));
    expect(dart, contains('Future<List<int>> b(String v)'));
    expect(dart, contains('Future<int> c(int arg0, double arg1)'));
    expect(dart, contains(r'Future<void> d() => $invoke(3, null'));
  });

  test('enums: explicit values, expressions, Dart value names', () {
    final out = generate({
      'm.cpp': module('NATIVEBIND_PROP(Flags, f, Flags::kRead)', prelude: '''
enum class Flags : unsigned { kRead = 1 << 0, kWrite = 1 << 1, kAll = kRead | kWrite, HEAT_COOL = 0x10, Neg = -2, Next };
'''),
    });
    final dart = out['m.nb.dart']!;
    expect(dart, contains("read(1, 'Read'),"));
    expect(dart, contains("write(2, 'Write'),"));
    expect(dart, contains("all(3, 'All'),"));
    expect(dart, contains("heatCool(16, 'Heat cool'),"));
    expect(dart, contains("neg(-2, 'Neg'),"));
    expect(dart, contains("next(-1, 'Next');"));
    expect(out['m.nb.cpp'], contains('static_cast<long long>(::Flags::kAll) == 3LL'));
  });

  test('struct defaults become Dart defaults; others are required', () {
    final out = generate({
      'm.cpp': module('NATIVEBIND_LIST(S, items)', prelude: '''
#include <chrono>
#include <optional>
enum class E { A, B };
struct Other { int x = 0; };
struct S {
    bool b = true;
    int i = -0x10;
    unsigned u{017};
    double d = 2;
    double e = 1.5e3f;
    std::string s = "a" "b\\n\$";
    E e1 = E::B;
    E e2;
    std::optional<int> o = std::nullopt;
    std::optional<int> o2 = 4;
    std::chrono::seconds t1 = std::chrono::seconds(30);
    std::chrono::milliseconds t2{250};
    std::chrono::system_clock::time_point at;
    Other other;
    int computed = 1 + 2;
    std::vector<int> v;
};
'''),
    });
    final dart = out['m.nb.dart']!;
    for (final expected in [
      'this.b = true,',
      'this.i = -16,',
      'this.u = 15,',
      'this.d = 2.0,',
      'this.e = 1500.0,',
      r"this.s = 'ab\n\$',",
      'this.e1 = E.b,',
      'this.e2 = E.a,',
      'this.o,',
      'this.o2 = 4,',
      'this.t1 = const Duration(seconds: 30),',
      'required this.at,',
      'required this.other,',
      'required this.computed,',
      'this.v = const [],',
    ]) {
      expect(dart, contains(expected));
    }
    // t2{250}: a bare number in braces has no unit in the source text
    expect(dart, contains('required this.t2,'));
  });

  test('aliases, nested types, namespaces and using-directives', () {
    final out = generate({
      'm.cpp': '''
#include <nativebind/nativebind.hpp>
namespace outer::inner {
using Temp = double;
typedef int Count;
class M : public nativebind::Module {
    NATIVEBIND_MODULE(M)
public:
    enum Nested { One = 1 };
    NATIVEBIND_PROP(Temp, t, 0)
    NATIVEBIND_PROP(Count, c, 0)
    NATIVEBIND_PROP(Nested, n, One)
};
}
''',
    });
    final cpp = out['m.nb.cpp']!;
    expect(cpp, contains('struct nativebind::glue::Invoker<::outer::inner::M>'));
    expect(cpp, contains('::outer::inner::M::Nested::One'));
    expect(cpp, contains('"prop t double rw\\n"'));
    expect(cpp, contains('"prop c int rw\\n"'));
  });

  group('NATIVEBIND_DART_LIBRARY headers', () {
    const lib = '''
#pragma once
#include <string>
NATIVEBIND_DART_LIBRARY("package:vendor/vendor.dart");
namespace vendor {
enum class Level { Low, High = 5 };
struct Fault { std::string id; Level level = Level::Low; bool operator==(const Fault&) const = default; };
}
''';
    String app() => '#include "vendor.hpp"\n${module('''
    NATIVEBIND_PROP(vendor::Level, level, vendor::Level::High)
    NATIVEBIND_LIST(vendor::Fault, faults)
    NATIVEBIND_INVOKE_AS(vendor::Level::High) void reset();
''', name: 'App')}';

    test('their types are imported from that library, not generated', () {
      final out = generate({'vendor.hpp': lib, 'app.cpp': app()});
      expect(out.keys, isNot(contains('vendor.nb.dart')));
      final dart = out['app.nb.dart']!;
      expect(dart, contains("import 'package:vendor/vendor.dart' as \$x0;"));
      expect(dart, contains(r'BoundProperty<$x0.Level> level'));
      expect(dart, contains(r'BoundList<$x0.Fault> faults'));
      expect(dart, contains(r'$x0.Fault.$codec'));
      expect(dart, isNot(contains('class Fault')));
      final cpp = out['app.nb.cpp']!;
      expect(cpp, isNot(contains('StructRegistrar<::vendor::Fault>')), reason: 'the library registers its codecs');
      expect(cpp, contains('static_cast<int64_t>(::vendor::Level::High)'));
      expect(cpp, contains('requirePermission("App", "reset"'));
    });

    test('--provides generates them (the library itself)', () {
      final out = generate({'vendor.hpp': lib, 'app.cpp': app()}, provides: 'package:vendor/vendor.dart');
      expect(out.keys, contains('vendor.nb.dart'));
      expect(out['vendor.nb.dart'], contains('class Fault'));
      expect(out['app.nb.dart'], isNot(contains('package:vendor')));
      expect(out['app.nb.cpp'], contains('StructRegistrar<::vendor::Fault>'));
    });

    test('the macro needs one string literal', () {
      expect(generateError('NATIVEBIND_DART_LIBRARY(vendor);\n${module('')}').message, contains('one string literal'));
    });
  });

  test('types from included headers go to their own Dart file', () {
    final out = generate({
      'types.hpp': 'namespace t { enum class Mode { A, B }; }',
      'a.cpp': '#include "types.hpp"\n${module('NATIVEBIND_PROP(t::Mode, mode, t::Mode::A)', name: 'A')}',
      'b.cpp': '#include "types.hpp"\n${module('NATIVEBIND_READ(t::Mode, mode, t::Mode::B)', name: 'B')}',
    });
    expect(out.keys, containsAll(['a.nb.dart', 'b.nb.dart', 'types.nb.dart', 'nativebind_modules.dart']));
    expect(out['types.nb.dart'], contains(r'enum Mode implements $p.BindEnum {'));
    expect(out['a.nb.dart'], contains("import 'types.nb.dart';"));
    expect(out['a.nb.dart'], isNot(contains('\nenum Mode ')));
    expect(out['nativebind_modules.dart'], contains(r'A.$type,'));
  });

  test('instanced modules get instances/byKey/key', () {
    final dart = generate({'m.cpp': module('NATIVEBIND_READ(int, x, 0)', options: ', .instanced = true')})['m.nb.dart']!;
    expect(dart, contains(r'static $p.BoundInstances<M> get instances'));
    expect(dart, contains('static M? byKey(int key)'));
    expect(dart, contains(r'int get key => $key;'));
    expect(dart, contains('instanced: true,'));
  });

  test('doc comments reach Dart', () {
    final dart = generate({
      'm.cpp': module('''
    /// Room temperature.
    ///
    /// Measured at the wall sensor.
    NATIVEBIND_READ(double, temp, 0)
''', prelude: '/// The module.'),
    })['m.nb.dart']!;
    expect(dart, contains('  /// Room temperature.\n  ///\n  /// Measured at the wall sensor.\n  late final'));
  });

  test('enum labels: @label in the enumerator doc, else the name in words', () {
    final dart = generate({
      'm.cpp': module('NATIVEBIND_PROP(State, s, State::PrePurge)', prelude: '''
enum class State {
    PrePurge,     ///< Purging before ignition.
    WaitingForAHU,
    /// @label Use BMS/Modbus
    /// A Modbus master sets the value.
    BmsModbus,
    Run,          ///< @label Running
    Lockout       ///< @label Locked out
};
'''),
    })['m.nb.dart']!;
    expect(dart, contains(r'enum State implements $p.BindEnum {'));
    expect(dart, contains("prePurge(0, 'Pre purge'),"));
    expect(dart, contains("waitingForAhu(1, 'Waiting for AHU'),"));
    expect(dart, contains("bmsModbus(2, 'Use BMS/Modbus'),"));
    expect(dart, contains("run(3, 'Running'),"), reason: 'trailing ///< after the comma');
    expect(dart, contains("lockout(4, 'Locked out');"), reason: 'trailing ///< without a comma');
    expect(dart, contains('  /// Purging before ignition.\n  prePurge'));
    expect(dart, contains('  /// A Modbus master sets the value.\n  bmsModbus'));
    expect(dart, isNot(contains('/// @label')));
  });

  test('member docs are kept for runtime help, and \$values lists every property', () {
    final dart = generate({
      'm.cpp': module('''
    /// Supply setpoint.
    /// Used when the reset curve is off.
    ///
    /// Second paragraph.
    NATIVEBIND_PROP(double, setpoint, 60)
    NATIVEBIND_READ(double, temp, 0)
    NATIVEBIND_LIST(int, items)
'''),
    })['m.nb.dart']!;
    expect(dart, contains("    docs: {\n      'setpoint': 'Supply setpoint. Used when the reset curve is off.\\n\\nSecond paragraph.',\n    },"));
    expect(dart, contains(r'late final List<$p.BoundValue<Object?>> $values = List.unmodifiable('));
    expect(dart, contains('    setpoint,\n    temp,\n  ]);'));
  });

  test('typed references: a header for other module files, get() in the glue', () {
    final out = generate({
      'types.hpp': '#pragma once\nenum class Shared { A, B };\n',
      'm.cpp': module('''
    NATIVEBIND_PROP(double, setpoint, 60)
    NATIVEBIND_READ(std::vector<std::string>, names, {})
    NATIVEBIND_PROP(Local, local, Local::X)
    NATIVEBIND_PROP(Shared, shared, Shared::A)
    NATIVEBIND_LIST(int32_t, items)
''', prelude: '#include "types.hpp"\n#include <vector>\nenum class Local { X };'),
      'z.cpp': module('NATIVEBIND_PROP(int, n, 0)', name: 'Z', options: ', .instanced = true'),
    }, dart: false);
    final h = out['m.nb.hpp']!;
    expect(h, contains('#include "../src/types.hpp"'));
    expect(h, contains('#include <vector>'));
    expect(h, contains('struct M {'));
    expect(h, contains('    ::nativebind::Prop<double>& setpoint;'));
    expect(h, contains('    ::nativebind::Prop<std::vector<std::string>>& names;'));
    expect(h, contains('    // local: not available here (`Local` is declared in m.cpp)'));
    expect(h, contains('    ::nativebind::Prop<::Shared>& shared;'));
    expect(h, contains('    ::nativebind::List<int32_t>& items;'));
    expect(h, contains('    static M get();'));
    expect(out['m.nb.cpp'], contains('#include "m.nb.hpp"'));
    expect(out['m.nb.cpp'], contains('    return {m.setpoint, m.names, m.shared, m.items};'));
    expect(out['z.nb.hpp'], contains('    static Z get(uint64_t key);'));
  });

  test('includes of generated headers are not parsed', () {
    final out = generate({
      'm.cpp': module('NATIVEBIND_PROP(double, x, 0)', prelude: '#include "other.nb.hpp"'),
      'other.nb.hpp': 'this is not C++ {{{',
    });
    expect(out['m.nb.dart'], contains('x ='));
  });

  test('reserved Dart words are escaped', () {
    final dart = generate({'m.cpp': module('NATIVEBIND_PROP(bool, default, false)\n    NATIVEBIND_INVOKE void in(int is);')})['m.nb.dart']!;
    expect(dart, contains('default_ ='));
    expect(dart, contains('Future<void> in_(int is_)'));
  });
}

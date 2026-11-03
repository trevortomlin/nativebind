import 'package:nativebind_generator/src/naming.dart';
import 'package:nativebind_generator/src/paths.dart' as p;
import 'package:test/test.dart';

void main() {
  group('naming', () {
    test('members', () {
      expect(dartMember('floor_temp'), 'floorTemp');
      expect(dartMember('floorTemp'), 'floorTemp');
      expect(dartMember('FloorTemp'), 'floorTemp');
      expect(dartMember('HVACMode'), 'hvacMode');
      expect(dartMember('_trailing_'), 'trailing');
      expect(dartMember('co2_ppm'), 'co2Ppm');
      expect(dartMember('stage2'), 'stage2');
      expect(dartMember('MAX_TEMP'), 'maxTemp');
    });

    test('reserved words and Object members get a suffix', () {
      for (final w in ['class', 'switch', 'default', 'new', 'is', 'in']) {
        expect(dartMember(w), '${w}_');
      }
      expect(dartMember('hash_code'), 'hashCode_');
      expect(dartMember('to_string'), 'toString_');
      expect(dartMember('get'), 'get', reason: 'built-ins are fine as members');
    });

    test('types', () {
      expect(dartType('ComfortHeat'), 'ComfortHeat');
      expect(dartType('comfort_heat'), 'ComfortHeat');
      expect(dartType('AHU'), 'AHU');
      expect(dartType('Function'), 'Function_');
      expect(dartType('dynamic'), 'Dynamic', reason: 'snake-case conversion capitalizes');
    });

    test('enum values', () {
      expect(dartEnumValue('Off'), 'off');
      expect(dartEnumValue('HEAT_COOL'), 'heatCool');
      expect(dartEnumValue('kHeatCool'), 'heatCool');
      expect(dartEnumValue('keep'), 'keep', reason: 'k + lowercase is not a prefix');
      for (final v in ['values', 'index', 'name', 'Wire', 'codec']) {
        expect(dartEnumValue(v), endsWith('_'));
      }
    });

    test('Dart string literals escape everything that matters', () {
      expect(dartString(r"it's $5 \ ok"), r"'it\'s \$5 \\ ok'");
      expect(dartString('a\nb\tc\r'), r"'a\nb\tc\r'");
      expect(dartString('\x01'), r"'\u{1}'");
      expect(dartString('°C µA 🙂'), "'°C µA 🙂'");
    });

    test('C++ string literals', () {
      expect(cppString('say "hi"\\\n\t'), r'"say \"hi\"\\\n\t"');
    });

    test('C identifiers from qualified names', () {
      expect(cIdent('::hvac::Reading'), 'hvac_Reading');
      expect(cIdent('Reading'), 'Reading');
      expect(cIdent('a::b::C'), 'a_b_C');
    });
  });

  group('paths', () {
    test('normalize', () {
      expect(p.normalize('a/./b//c/'), 'a/b/c');
      expect(p.normalize('a/b/../c'), 'a/c');
      expect(p.normalize('../a/../../b'), '../../b');
      expect(p.normalize('/x/../..'), '/');
      expect(p.normalize(''), '.');
      expect(p.normalize(r'C:\dev\src\..\lib'), 'C:/dev/lib');
    });

    test('dirname, basename, extensions', () {
      expect(p.dirname('/a/b/c.cpp'), '/a/b');
      expect(p.dirname('/c.cpp'), '/');
      expect(p.dirname('c.cpp'), '.');
      expect(p.basename('/a/b/c.nb.cpp'), 'c.nb.cpp');
      expect(p.withoutExtension('c.nb.cpp'), 'c.nb');
      expect(p.withoutExtension('.hidden'), '.hidden');
      expect(p.extension('x.cpp'), 'cpp');
      expect(p.extension('Makefile'), '');
    });

    test('relative', () {
      expect(p.relative('/a/b/c/d.dart', from: '/a/b'), 'c/d.dart');
      expect(p.relative('/a/x/y.dart', from: '/a/b/c'), '../../x/y.dart');
      expect(p.relative('/a/b', from: '/a/b'), '');
      expect(p.relative('/q/z', from: '/a/b'), '/q/z', reason: 'only the root in common');
      expect(p.join('/a/b', '../c'), '/a/c');
    });
  });
}

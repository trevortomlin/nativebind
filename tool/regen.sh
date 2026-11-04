#!/usr/bin/env bash
# Regenerates every checked-in generated file (*.nb.cpp, *.nb.hpp, *.nb.dart):
# the runtime's test modules, the generator fixtures and the showcase. The
# list lives in packages/nativebind_generator/test/golden_test.dart, which
# also fails CI when one of them is stale. Review the diff afterwards.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/packages/nativebind_generator"
dart pub get >/dev/null
NATIVEBIND_UPDATE_GOLDENS=1 dart test test/golden_test.dart
git -C "$root" status --short -- '*.nb.cpp' '*.nb.hpp' '*.nb.dart' '*nativebind_modules.dart'

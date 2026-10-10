#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ddc-tests
clang -fmodules -fmodules-cache-path="$PWD/.build/ddc-tests/modules" \
  -I Vendor/m1ddc/headers -framework Foundation -framework IOKit \
  -framework ApplicationServices -framework CoreDisplay \
  Tests/DDCRegressionTests/main.m -o .build/ddc-tests/regressions
.build/ddc-tests/regressions

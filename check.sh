#!/bin/bash
# Everything CI runs: unit tests, a universal release build and the localization check.
set -euo pipefail
cd "$(dirname "$0")"
swift test
./build.sh --compile-only

#!/usr/bin/env bash
# Run the application-hosted AppKit unit tests with scheme launch isolation.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/setup.sh
xcodegen generate
# "$@" so a caller can narrow the run: `scripts/test-app.sh -only-testing:agtermTests/FooTests`, or
# -skip-testing to leave one class out. Without it the flags are accepted by the shell and silently
# dropped, so a "targeted" run quietly executes the whole suite and reports on it as if narrowed.
xcodebuild test \
  -project agterm.xcodeproj \
  -scheme agtermTests \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  "$@"

#!/usr/bin/env bash
# Build a release app.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/setup.sh
xcodegen generate
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
# the commit's own date, not the build's: two builds of one commit are the same app, and this is
# what says which code the About panel's commit refers to.
GIT_COMMIT_DATE="$(git log -1 --format=%cd --date=short 2>/dev/null || echo "")"
# version = latest reachable v-tag (About panel / CFBundleShortVersionString);
# builds past the tag keep its version and the GitCommit parenthetical
# disambiguates. Falls back to 0.0.0 when no tag is reachable (shallow CI).
# `|| true` inside the substitution: `git describe` exits 128 with no tags, which
# under `set -e` would abort before the fallback below — swallow it so the empty
# result reaches the `-n` check.
VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
[ -n "$VERSION" ] || VERSION="0.0.0"
xcodebuild -project agterm.xcodeproj -scheme agterm -configuration Release \
  -derivedDataPath build/DerivedData \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" GIT_COMMIT="$GIT_COMMIT" \
  GIT_COMMIT_DATE="$GIT_COMMIT_DATE" build
echo "built: build/DerivedData/Build/Products/Release/agterm.app"

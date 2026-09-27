#!/usr/bin/env bash
# Re-sign a built app with the local self-signed identity, if one exists (fork-only, used by `make deploy`).
# Ad-hoc helpers get a per-build identifier (`agterm-session-host-<hash>`) and a cdhash designated
# requirement, so macOS treats every build as a new app and drops TCC grants such as Local Network;
# the background session host cannot show the prompt, so LAN access from shells silently fails.
# A certificate plus a fixed identifier makes the requirement `identifier X and certificate leaf = H"…"`,
# which survives rebuilds. Without the keychain the build stays ad-hoc.
# Setup: .claude/rules/release.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: sign-local.sh <agterm.app>}"
KEYCHAIN="${AGTERM_SIGN_KEYCHAIN:-$HOME/Library/Keychains/agterm-signing.keychain-db}"
IDENTITY="${AGTERM_SIGN_IDENTITY:-agterm Local Signing}"

if [ ! -f "$KEYCHAIN" ]; then
  echo "sign-local: no $KEYCHAIN, leaving $APP ad-hoc signed"
  exit 0
fi
# the keychain has an empty password so an unattended (ssh) build can unlock it
security unlock-keychain -p "" "$KEYCHAIN"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

# inside-out, helpers without entitlements and the app without --deep: see scripts/release.sh
for helper in agtermctl zmx agterm-session-host; do
  codesign --force --options runtime --keychain "$KEYCHAIN" --sign "$IDENTITY" \
    --identifier "$bundle_id.$helper" "$APP/Contents/MacOS/$helper"
done
codesign --force --options runtime --keychain "$KEYCHAIN" --sign "$IDENTITY" \
  --entitlements agterm/agterm.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "sign-local: signed $APP with \"$IDENTITY\""

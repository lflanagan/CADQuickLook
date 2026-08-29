#!/usr/bin/env bash
# Local alternative to .github/workflows/release.yml. Run AFTER
#   script/package_release.sh            (builds, signs, notarizes dist/*.zip)
#   gh release create vX.Y.Z dist/CADQuickLook-X.Y.Z-arm64.zip --title ... --notes ...
# It signs the archive with the Ed25519 key in your login Keychain (created by
# generate_keys), regenerates appcast.xml (merging the previous release's
# appcast so older items stay in the feed) and uploads it to the release.
#
# Usage: script/publish_appcast.sh [vX.Y.Z]      (defaults to v<CFBundleShortVersionString>)
set -euo pipefail

APP_NAME="CADQuickLook"
REPO="lflanagan/CADQuickLook"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/ReleaseDerivedData"
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
DIST_DIR="$ROOT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/CADQuickLook/Info.plist")"
TAG="${1:-v$VERSION}"
ARCHIVE="$DIST_DIR/$APP_NAME-$VERSION-arm64.zip"
WORK_DIR="$DIST_DIR/appcast"

for tool in generate_appcast generate_keys; do
  if [[ ! -x "$SPARKLE_BIN/$tool" ]]; then
    echo "Missing $SPARKLE_BIN/$tool. Build the Release configuration first (package_release.sh resolves the Sparkle package)." >&2
    exit 2
  fi
done
command -v gh >/dev/null || { echo "gh CLI is required." >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "Archive not found: $ARCHIVE (run script/package_release.sh)" >&2; exit 2; }

# Fail early if the key in the Keychain does not match the key baked into Info.plist.
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT_DIR/CADQuickLook/Info.plist")"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
if [[ "$PLIST_KEY" != "$KEYCHAIN_KEY" ]]; then
  echo "SUPublicEDKey in Info.plist ($PLIST_KEY) != Keychain public key ($KEYCHAIN_KEY)." >&2
  exit 2
fi

# The release must already exist and carry the archive we are about to describe.
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fxq "$(basename "$ARCHIVE")" \
  || { echo "Release $TAG does not contain $(basename "$ARCHIVE"). Create it first with gh release create." >&2; exit 2; }

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp "$ARCHIVE" "$WORK_DIR/"

# Seed with the previous release's appcast so older items are preserved.
PREVIOUS_TAG="$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --json tagName \
  --jq "[.[].tagName | select(. != \"$TAG\")] | .[0] // empty")"
if [[ -n "$PREVIOUS_TAG" ]]; then
  gh release download "$PREVIOUS_TAG" --repo "$REPO" --pattern appcast.xml --dir "$WORK_DIR" 2>/dev/null \
    || echo "No appcast.xml on $PREVIOUS_TAG; starting a fresh feed."
fi

# Release notes: GitHub release body (markdown) -> embedded <description>.
gh release view "$TAG" --repo "$REPO" --json body --jq .body > "$WORK_DIR/$APP_NAME-$VERSION-arm64.md"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  --full-release-notes-url "https://github.com/$REPO/releases" \
  --embed-release-notes \
  --maximum-versions 5 \
  "$WORK_DIR" 2>&1 | tee "$WORK_DIR/generate_appcast.log"

if grep -q "does not match" "$WORK_DIR/generate_appcast.log"; then
  echo "generate_appcast reported a key mismatch; not publishing." >&2
  exit 1
fi
[[ -s "$WORK_DIR/appcast.xml" ]] || { echo "appcast.xml was not generated." >&2; exit 1; }

gh release upload "$TAG" "$WORK_DIR/appcast.xml" --repo "$REPO" --clobber
echo "Published https://github.com/$REPO/releases/latest/download/appcast.xml"
echo "Smoke test: curl -fsSL https://github.com/$REPO/releases/latest/download/appcast.xml | head"

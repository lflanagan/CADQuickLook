#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CADQuickLook"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/CADQuickLook.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/ReleaseDerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$DIST_DIR/stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/CADQuickLook/Info.plist")"
ARCHIVE="$DIST_DIR/$APP_NAME-$VERSION-arm64.zip"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Set SIGNING_IDENTITY to a Developer ID Application certificate." >&2
  exit 2
fi

if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "GitHub release builds require a Developer ID Application certificate." >&2
  exit 2
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "Signing identity is not valid or its private key is unavailable: $SIGNING_IDENTITY" >&2
  exit 2
fi

# Sparkle orders updates by CFBundleVersion (sparkle:version), so it must move every release.
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/CADQuickLook/Info.plist")"
if [[ "$BUILD_VERSION" != "$VERSION" ]]; then
  echo "CFBundleVersion ($BUILD_VERSION) must equal CFBundleShortVersionString ($VERSION)." >&2
  exit 2
fi

PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT_DIR/CADQuickLook/Info.plist" 2>/dev/null || true)"
if [[ -z "$PUBLIC_ED_KEY" || "$PUBLIC_ED_KEY" == REPLACE_* ]]; then
  echo "SUPublicEDKey is not set in Info.plist. Run Sparkle's generate_keys and paste the public key." >&2
  exit 2
fi

EXPECTED_TEAM_ID="$(printf '%s\n' "$SIGNING_IDENTITY" | sed -E 's/^.*\(([A-Z0-9]{10})\)$/\1/')"
if [[ ! "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Signing identity must end with a 10-character Apple team ID." >&2
  exit 2
fi

if [[ ! -d "$PROJECT" ]]; then
  (cd "$ROOT_DIR" && xcodegen generate)
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
  build

rm -rf "$STAGE_DIR"
rm -f "$ARCHIVE"
mkdir -p "$STAGE_DIR" "$FRAMEWORKS_DIR"

# codesign does not expand $(...) build settings in entitlements files, so
# materialize the App Group identifier for this team.
APP_GROUP="$EXPECTED_TEAM_ID.com.liamflanagan.CADQuickLook"
sed "s/\$(CAD_APP_GROUP)/$APP_GROUP/g" "$ROOT_DIR/CADQuickLook/CADQuickLook.entitlements" > "$STAGE_DIR/app.entitlements"
sed "s/\$(CAD_APP_GROUP)/$APP_GROUP/g" "$ROOT_DIR/Extensions/Extension.entitlements" > "$STAGE_DIR/extension.entitlements"
# Development builds need library validation disabled to load Homebrew's
# ad-hoc-signed Open CASCADE dylibs. The release re-signs every dylib with the
# same Team ID, so keep the hardened runtime's library validation on.
for entitlements in "$STAGE_DIR/app.entitlements" "$STAGE_DIR/extension.entitlements"; do
  /usr/bin/plutil -remove 'com.apple.security.cs.disable-library-validation' "$entitlements"
done

/usr/bin/ditto "$BUILT_APP" "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/"

declare -a queue=()
declare -a source_names=()
declare -a source_paths=()

resolve_dependency() {
  local dependency="$1"
  local owner="$2"
  local name="${dependency##*/}"
  local candidate

  if [[ "$dependency" == /opt/homebrew/* && -f "$dependency" ]]; then
    printf '%s\n' "$dependency"
    return
  fi

  if [[ "$dependency" == @rpath/* && -f "$(dirname "$owner")/$name" ]]; then
    printf '%s\n' "$(dirname "$owner")/$name"
    return
  fi

  candidate="$(find -L /opt/homebrew/opt -path "*/lib/$name" -type f -print -quit 2>/dev/null || true)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
  return 0
}

enqueue_dependencies() {
  local owner="$1"
  local dependency source name

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /opt/homebrew/*|@rpath/*) ;;
      *) continue ;;
    esac
    source="$(resolve_dependency "$dependency" "$owner")"
    [[ -n "$source" ]] || continue
    name="${dependency##*/}"
    found=false
    for known_name in "${source_names[@]:-}"; do
      if [[ "$known_name" == "$name" ]]; then
        found=true
        break
      fi
    done
    if [[ "$found" == false ]]; then
      source_names+=("$name")
      source_paths+=("$source")
      queue+=("$name")
    fi
  done < <(otool -L "$owner" | tail -n +2 | awk '{print $1}')
}

while IFS= read -r -d '' binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    enqueue_dependencies "$binary"
  fi
done < <(find "$APP_BUNDLE" -type f -print0)

index=0
while (( index < ${#queue[@]} )); do
  name="${queue[$index]}"
  source=""
  for ((source_index = 0; source_index < ${#source_names[@]}; source_index += 1)); do
    if [[ "${source_names[$source_index]}" == "$name" ]]; then
      source="${source_paths[$source_index]}"
      break
    fi
  done
  [[ -n "$source" ]] || { echo "Unable to resolve $name" >&2; exit 1; }
  destination="$FRAMEWORKS_DIR/$name"
  cp -L "$source" "$destination"
  chmod u+w "$destination"
  install_name_tool -id "@rpath/$name" "$destination"
  enqueue_dependencies "$source"
  ((index += 1))
done

while IFS= read -r -d '' binary; do
  if ! file "$binary" | grep -q 'Mach-O'; then
    continue
  fi

  while IFS= read -r dependency; do
    name="${dependency##*/}"
    if [[ -f "$FRAMEWORKS_DIR/$name" && "$dependency" != "@rpath/$name" ]]; then
      install_name_tool -change "$dependency" "@rpath/$name" "$binary"
    fi
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')

  install_name_tool -delete_rpath /opt/homebrew/opt/opencascade/lib "$binary" 2>/dev/null || true
done < <(find "$APP_BUNDLE" -type f -print0)

while IFS= read -r -d '' library; do
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$library"
done < <(find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0)

# Sparkle.framework arrives ad-hoc signed from the SPM artifact (xcodebuild ran with
# CODE_SIGNING_ALLOWED=NO). Sign its nested code inside-out; never use --deep for signing.
SPARKLE_FRAMEWORK="$FRAMEWORKS_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  SPARKLE_VERSIONED="$SPARKLE_FRAMEWORK/Versions/B"
  for nested in \
    "$SPARKLE_VERSIONED/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSIONED/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSIONED/Autoupdate" \
    "$SPARKLE_VERSIONED/Updater.app"; do
    [[ -e "$nested" ]] || continue
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --preserve-metadata=entitlements \
      --sign "$SIGNING_IDENTITY" \
      "$nested"
  done
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE_FRAMEWORK"
fi

while IFS= read -r -d '' extension; do
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$STAGE_DIR/extension.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$extension"
done < <(find "$APP_BUNDLE/Contents/PlugIns" -type d -name '*.appex' -print0)

codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "$STAGE_DIR/app.entitlements" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

for signed_item in \
  "$APP_BUNDLE" \
  "$APP_BUNDLE"/Contents/PlugIns/*.appex \
  "$FRAMEWORKS_DIR"/Sparkle.framework \
  "$FRAMEWORKS_DIR"/Sparkle.framework/Versions/B/Autoupdate \
  "$FRAMEWORKS_DIR"/Sparkle.framework/Versions/B/Updater.app \
  "$FRAMEWORKS_DIR"/Sparkle.framework/Versions/B/XPCServices/*.xpc \
  "$FRAMEWORKS_DIR"/*.dylib; do
  [[ -e "$signed_item" ]] || continue
  actual_team="$(codesign -dvv "$signed_item" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
  if [[ "$actual_team" != "$EXPECTED_TEAM_ID" ]]; then
    echo "Unexpected signing team on $signed_item: $actual_team" >&2
    exit 1
  fi
done

/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP_BUNDLE" "$ARCHIVE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$ARCHIVE"
  /usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP_BUNDLE" "$ARCHIVE"
  spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
fi

echo "$ARCHIVE"
echo "Next: gh release create v$VERSION \"$ARCHIVE\" --title \"CADQuickLook $VERSION\" --notes-file <notes.md>" >&2
echo "      then .github/workflows/release.yml publishes appcast.xml (or run script/publish_appcast.sh v$VERSION)." >&2

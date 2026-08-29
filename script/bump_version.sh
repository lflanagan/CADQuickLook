#!/usr/bin/env bash
# Bumps the version in the app and both extension Info.plists, keeping
# CFBundleVersion equal to CFBundleShortVersionString. With no argument the
# patch component is incremented (dev builds); pass X.Y.Z to set it exactly
# (releases). Edits the version strings in place so comments and key order in
# the plists survive (PlistBuddy would rewrite the whole file).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLISTS=(
  "$ROOT_DIR/CADQuickLook/Info.plist"
  "$ROOT_DIR/Extensions/Preview/Info.plist"
  "$ROOT_DIR/Extensions/Thumbnail/Info.plist"
)

current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLISTS[0]}")"
if [[ $# -ge 1 ]]; then
  next="$1"
  [[ "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 [X.Y.Z]" >&2; exit 1; }
else
  IFS=. read -r major minor patch <<<"$current"
  next="$major.$minor.$((patch + 1))"
fi

for plist in "${PLISTS[@]}"; do
  perl -0pi -e "s|(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*|\${1}$next|; s|(<key>CFBundleVersion</key>\s*<string>)[^<]*|\${1}$next|" "$plist"
done
echo "$current -> $next"

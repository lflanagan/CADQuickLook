#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CADQuickLook"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT_APP="$ROOT_DIR/.build/DerivedData/Build/Products/Debug/$APP_NAME.app"
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$BUILT_APP" ]]; then
  "$ROOT_DIR/script/build_and_run.sh" --verify
fi

mkdir -p "$HOME/Applications"
pkill -x CADQuickLookPreview >/dev/null 2>&1 || true
pkill -x CADQuickLookThumbnail >/dev/null 2>&1 || true
/usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"
"$LSREGISTER" -f -R -trusted "$INSTALLED_APP"

pluginkit -a "$INSTALLED_APP/Contents/PlugIns/CADQuickLookPreview.appex"
pluginkit -a "$INSTALLED_APP/Contents/PlugIns/CADQuickLookThumbnail.appex"
pluginkit -e use -i com.liamflanagan.CADQuickLook.Preview
pluginkit -e use -i com.liamflanagan.CADQuickLook.Thumbnail

codesign --verify --deep --strict "$INSTALLED_APP"
echo "Installed $INSTALLED_APP"

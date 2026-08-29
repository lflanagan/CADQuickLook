#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CADQuickLook"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/CADQuickLook.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUNDLE_ID="com.liamflanagan.CADQuickLook"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ ! -d "$PROJECT" ]]; then
  (cd "$ROOT_DIR" && xcodegen generate)
fi

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$APP_NAME"
  -configuration Debug
  -derivedDataPath "$DERIVED_DATA"
  -allowProvisioningUpdates
)

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  # Sign with the team's Apple Development certificate (see project.yml).
  BUILD_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Apple Development")
fi

xcodebuild "${BUILD_ARGS[@]}" build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

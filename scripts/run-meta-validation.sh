#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT="SocialKitMetaValidation"
BUNDLE_ID="com.bravenewdesign.socialkit.metavalidation"
APP_BUNDLE="$ROOT/.build/MetaValidation.app"
BUILD_ONLY=0
ENTITLEMENTS="${ASSOCIATED_DOMAINS_ENTITLEMENTS:-}"
PROFILE="${DEVELOPMENT_PROVISIONING_PROFILE:-}"
NAMED_IDENTITY="${DEVELOPMENT_IDENTITY:-}"
if [[ "${1:-}" == "--build-only" ]]; then
    BUILD_ONLY=1
    shift
fi
if [[ "$#" -ne 0 ]]; then
    echo "Usage: $0 [--build-only]" >&2
    exit 2
fi
if [[ -n "$ENTITLEMENTS" || -n "$PROFILE" ]]; then
    if [[ -z "$ENTITLEMENTS" || -z "$PROFILE" || -z "$NAMED_IDENTITY" ]]; then
        echo "Associated-domain signing requires ASSOCIATED_DOMAINS_ENTITLEMENTS, DEVELOPMENT_PROVISIONING_PROFILE, and DEVELOPMENT_IDENTITY." >&2
        exit 2
    fi
    for path in "$ENTITLEMENTS" "$PROFILE"; do
        if [[ ! -f "$path" ]]; then
            echo "Signing input does not exist: $path" >&2
            exit 2
        fi
        case "$path" in
            "$ROOT"/*)
                echo "Signing inputs must be supplied from outside the repository: $path" >&2
                exit 2
                ;;
        esac
    done
fi

cd "$ROOT"
swift build --product "$PRODUCT"
BIN_PATH="$(swift build --show-bin-path)"
EXECUTABLE="$BIN_PATH/$PRODUCT"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Built executable not found: $EXECUTABLE" >&2
    exit 1
fi
if pgrep -x "$PRODUCT" >/dev/null 2>&1; then
    echo "The validation app is running. Quit it before rebuilding its bundle." >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$PRODUCT"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$PRODUCT</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>SocialKit Meta Validation</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

IDENTITY="$NAMED_IDENTITY"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE '/Apple Development:/s/^[[:space:]]*[0-9]+\) ([[:xdigit:]]+) .*/\1/p' \
        | head -n 1)"
fi
if [[ -n "$PROFILE" ]]; then
    cp "$PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi
if [[ -n "$IDENTITY" ]]; then
    CODESIGN_ARGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none)
    if [[ -n "$ENTITLEMENTS" ]]; then CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS"); fi
    codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE"
else
    # Ad hoc signing has no stable developer identity and may have limited Keychain ACL access.
    codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if [[ "$BUILD_ONLY" == "1" ]]; then
    echo "Built and signed $APP_BUNDLE"
    exit 0
fi
open -a "$APP_BUNDLE"
echo "Opened $APP_BUNDLE"

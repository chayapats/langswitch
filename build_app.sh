#!/bin/bash
set -euo pipefail
cd "$(/usr/bin/dirname "$0")"

APP_NAME="LangSwitch"
APP_DIR="$APP_NAME.app"
BUNDLE_ID="com.chayapats.langswitch"

echo "Building release..."
SWIFT_BUILD_ARGS=(-c release -Xswiftc -no-stdlib-rpath)
if [ "${SWIFTPM_DISABLE_SANDBOX:-0}" = "1" ]; then
  SWIFT_BUILD_ARGS=(--disable-sandbox "${SWIFT_BUILD_ARGS[@]}")
fi
/usr/bin/swift build "${SWIFT_BUILD_ARGS[@]}"

echo "Assembling $APP_DIR..."
/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
/bin/cp ".build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
/bin/cp "Info.plist" "$APP_DIR/Contents/Info.plist"
/bin/cp "assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/bin/cp "assets/logo.png" "$APP_DIR/Contents/Resources/logo.png"

# SwiftPM may add development-toolchain and @loader_path search paths even though every
# dependency in this executable has an absolute system path. Remove all unused RPATHs
# before signing so the loader has no alternate library search location.
while IFS= read -r rpath; do
  if [ -n "$rpath" ]; then
    /usr/bin/install_name_tool -delete_rpath "$rpath" "$APP_DIR/Contents/MacOS/$APP_NAME"
  fi
done < <(
  /usr/bin/otool -l "$APP_DIR/Contents/MacOS/$APP_NAME" |
    /usr/bin/awk '
      $1 == "cmd" && $2 == "LC_RPATH" {
        getline
        getline
        sub(/^[[:space:]]*path /, "")
        sub(/ \(offset.*$/, "")
        print
      }
    '
)

if /usr/bin/otool -l "$APP_DIR/Contents/MacOS/$APP_NAME" | /usr/bin/grep -q "LC_RPATH"; then
  echo "Refusing to sign: an unexpected runtime library search path remains" >&2
  exit 1
fi

DEFAULT_DEVELOPER_ID="Developer ID Application: Chayapat Sriwattanachote (SRAQ34JPLS)"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  if /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F -q "$DEFAULT_DEVELOPER_ID"; then
    SIGN_IDENTITY="$DEFAULT_DEVELOPER_ID"
  fi
fi

if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  echo "Signing with $SIGN_IDENTITY (hardened runtime, timestamped for notarization)"
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
else
  echo "Ad-hoc signing with Hardened Runtime (set SIGN_IDENTITY for a stable identity)"
  /usr/bin/codesign --force --options runtime --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

/usr/bin/codesign --verify --strict --verbose=2 "$APP_DIR"
echo "Built $APP_DIR"

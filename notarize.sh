#!/bin/bash
set -euo pipefail
cd "$(/usr/bin/dirname "$0")"

APP_DIR="LangSwitch.app"
ZIP="LangSwitch.app.zip"
PROFILE="${NOTARY_PROFILE:-oliv-notary}"

if [ ! -d "$APP_DIR" ]; then
  echo "Missing $APP_DIR — run ./build_app.sh first" >&2
  exit 1
fi

# `codesign -d` exits 1 even when it prints successfully.
codesign_info="$(/usr/bin/codesign -dvv "$APP_DIR" 2>&1 || true)"
if ! printf '%s\n' "$codesign_info" | /usr/bin/grep -q "Authority=Developer ID Application"; then
  echo "$APP_DIR is not signed with a Developer ID Application identity; cannot notarize" >&2
  exit 1
fi

/bin/rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

echo "Submitting for notarization (this can take a few minutes)..."
/usr/bin/xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling ticket to app..."
/usr/bin/xcrun stapler staple "$APP_DIR"
/usr/bin/xcrun stapler validate "$APP_DIR"

echo "Re-zipping stapled app..."
/bin/rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

echo "Verifying Gatekeeper acceptance..."
/usr/sbin/spctl -a -vvv -t install "$APP_DIR"

echo "Done: $APP_DIR is notarized and stapled."

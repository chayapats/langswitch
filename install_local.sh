#!/bin/bash
set -euo pipefail
cd "$(/usr/bin/dirname "$0")"

APP_NAME="LangSwitch"
INSTALL_ROOT="${HOME:?HOME is not set}/Applications"
TARGET="$INSTALL_ROOT/$APP_NAME.app"
STAGING="$INSTALL_ROOT/.$APP_NAME.installing.$$"
BACKUP="$INSTALL_ROOT/.$APP_NAME.previous.$$"

cleanup() {
  /bin/rm -rf "$STAGING"
  if [ -e "$BACKUP" ]; then
    if [ ! -e "$TARGET" ]; then
      /bin/mv "$BACKUP" "$TARGET"
    else
      /bin/rm -rf "$BACKUP"
    fi
  fi
}
trap cleanup EXIT

if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "LangSwitch is running. Quit it from the menu, then run this installer again." >&2
  exit 1
fi

"$PWD/build_app.sh"

# `codesign -d` exits 1 even when it prints successfully.
codesign_info="$(/usr/bin/codesign -dvv "$APP_NAME.app" 2>&1 || true)"
if printf '%s\n' "$codesign_info" | /usr/bin/grep -q "Authority=Developer ID Application"; then
  "$PWD/notarize.sh"
fi
/bin/mkdir -p "$INSTALL_ROOT"
/bin/rm -rf "$STAGING" "$BACKUP"
/usr/bin/ditto "$APP_NAME.app" "$STAGING"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING"

if [ -e "$TARGET" ]; then
  /bin/mv "$TARGET" "$BACKUP"
fi

if ! /bin/mv "$STAGING" "$TARGET"; then
  if [ -e "$BACKUP" ]; then
    /bin/mv "$BACKUP" "$TARGET"
  fi
  exit 1
fi

/bin/rm -rf "$BACKUP"
trap - EXIT

echo "Installed $TARGET"
if ! "$TARGET/Contents/MacOS/$APP_NAME" --register-login-item; then
  echo "Launch at Login could not be enabled automatically." >&2
  echo "Open the menu-bar app and use its Launch at Login item." >&2
fi

if [ "${LANGSWITCH_SKIP_OPEN:-0}" != "1" ]; then
  /usr/bin/open "$TARGET"
fi

# LangSwitch

Personal macOS menu-bar app. Tap Caps Lock to cycle the enabled keyboard input
sources without the normal Caps Lock activation delay.

## Language indicator

macOS's built-in near-cursor language indicator (`TSMLanguageIndicatorEnabled`) shows the
*previous* input source after a programmatic switch, so LangSwitch disables it on launch and
shows its own small indicator at the mouse cursor with the correct language on every switch.
Your original setting is restored when LangSwitch quits. Because macOS only reads this setting
at login, one logout or restart is needed for the native badge to fully disappear (and to
reappear after quitting); until then both indicators may briefly show.

## Security properties

- No third-party dependencies.
- No telemetry, sockets, HTTP requests, update feed, or automatic updater.
- No App Sandbox escape entitlement and no disabled Library Validation.
- No runtime library search paths; every linked library resolves to an Apple system path.
- The main app can launch at login through Apple's `SMAppService`; there is no bundled
  helper, LaunchAgent plist, daemon, privileged helper, or root operation.
- The only child commands are this same signed executable in watchdog mode and
  `/usr/bin/hidutil` with fixed argument structure; no shell is used.
- The global event tap forwards every key unchanged except F18. It never stores or logs
  keyboard events. A local health check restores the mapping if the event tap stops.
- Existing `UserKeyMapping` entries are snapshotted. Non-Caps-Lock mappings are preserved
  while the app runs, and the exact baseline is restored on quit.
- A separate restore watchdog restores the baseline if the GUI process crashes or is
  force-quit. Normal `SIGTERM`, `SIGINT`, `SIGHUP`, and `SIGQUIT` also use AppKit's clean
  shutdown path.
- A per-user process lock prevents two GUI instances from racing over the HID mapping.

Accessibility permission is still required. macOS requires it for the global event tap
that captures and swallows the remapped F18 key. LangSwitch does not request Full Disk
Access, Input Monitoring as a separate permission, Screen Recording, Automation, or
network access.

## One-command local install

```bash
cd /Users/chayapats/Projects/langswitch
./install_local.sh
```

This builds, verifies, and installs the app atomically at
`~/Applications/LangSwitch.app`, then opens it. On its first installed launch it asks
macOS to enable **Launch at Login**. The menu-bar menu shows the current state and lets
you disable it at any time. If macOS requires manual approval, the same menu item opens
the correct Login Items settings page.

The first menu row says **Status: Active — _input source_** when keyboard capture is
working. While permission is missing it says **Waiting for Accessibility** and the
menu-bar Caps Lock icon remains unfilled.

Move or install the app before granting Accessibility access so the permission is tied
to its stable daily-use path.

## Build only

Requires macOS 12 or later and Xcode Command Line Tools with Swift 5.9 or later.

```bash
cd /Users/chayapats/Projects/langswitch
./build_app.sh
open LangSwitch.app
```

The default build is ad-hoc signed with Hardened Runtime and no entitlements. Grant
Accessibility access to `LangSwitch.app` when macOS asks. Rebuilding an ad-hoc-signed app
may cause macOS to ask again.

If a stable Apple Development or other code-signing identity is available, select it
explicitly; the build script never searches the Keychain automatically:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build_app.sh
```

The build-only command leaves `LangSwitch.app` in the project directory and does not
install or launch it.

## Recovery

The app and watchdog normally restore the original mapping. If both processes are killed
simultaneously, logging out resets the session mapping. On a machine with no other custom
`hidutil` mappings, this command also clears it:

```bash
/usr/bin/hidutil property --set '{"UserKeyMapping":[]}'
```

Do not run that recovery command if you rely on other custom `hidutil` mappings; it clears
all of them.

## Limitations

- A kernel failure, power loss, or killing both the GUI and watchdog at the same time can
  prevent immediate restoration. macOS clears the mapping at logout.
- The personal build is not notarized for distribution. It is intended for this machine.
- There is deliberately no automatic update mechanism.

## License

MIT. See `LICENSE`.

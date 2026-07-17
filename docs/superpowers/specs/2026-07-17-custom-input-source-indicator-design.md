# Custom Input Source Indicator — Design

**Date:** 2026-07-17
**Status:** Approved (pending spec review)

## Problem

When the user switches keyboard input source via LangSwitch (Caps Lock → F18 →
`TISSelectInputSource`), macOS's native near-cursor language indicator (the blue
pill at the mouse cursor, controlled by `TSMLanguageIndicatorEnabled`) shows the
**previous** source instead of the newly-selected one:

- Switch to Thai → indicator shows `Aa` (should be `ก`)
- Switch to English → indicator shows `ก` (should be `Aa`)

### Root cause (confirmed during debugging)

- The **actual switch is always correct** — typing produces the intended
  language. Only the native indicator's display is wrong.
- The badge is a **native macOS feature**, not drawn by this app. The app only
  calls `TISSelectInputSource(next)` (`InputSourceSwitcher.swift:50`).
- The badge is **correct** when switching via the OS path (Ctrl+Space / Globe /
  menu), and **wrong** only when the app triggers the switch via
  `TISSelectInputSource`. This mechanism difference is macOS-internal and
  undocumented; it is *not* a timing/event-callback issue (deferring the switch
  out of the event-tap callback was tried and did **not** fix it).
- Conclusion: the app cannot make the native badge show the correct source.

## Goal

Show a **correct** input-source indicator at the mouse cursor on every switch,
and suppress the buggy native one. Constraints from the user: **lightweight, low
overhead, low maintenance, simple** — no over-engineering.

## Non-goals (YAGNI)

- Pixel-perfect reproduction of the native glyph rendering.
- Configurable appearance / position / duration (hardcode sensible defaults).
- Guaranteeing the caret position in every app. The caret is read via the
  Accessibility API, which some apps (terminals, certain Electron/web views) do
  not expose; those fall back to the mouse-cursor position. No per-app hacks.
- Supporting a large built-in language→glyph table (small map + fallback only).

## Design

### Components

**New file: `Sources/CapsLangSwitcher/LanguageIndicatorHUD.swift`**

A small class `LanguageIndicatorHUD` that owns a single, reused overlay window:

- A borderless `NSPanel`: `.nonactivatingPanel`, floating level
  (`.statusBar`), `ignoresMouseEvents = true`, `hidesOnDeactivate = false`,
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`,
  transparent background.
- Content: a rounded **blue** background view (solid `NSColor.systemBlue`,
  `cornerRadius` via a layer-backed view), containing a centered `NSTextField`
  with **white** text, styled like the native indicator (no blur material).
- Public API: `func show(for source: TISInputSource)`.
  1. Derive the glyph (see below).
  2. Position the panel just **below-left** of the **text caret** (see *Caret
     positioning*), clamped to the caret's screen. Fall back to below-left of the
     mouse-cursor position when the caret is unavailable.
  3. Set the glyph, order the panel front, reset a one-shot hide timer.
  4. On timer fire (~0.9s), fade out (~0.2s via `NSAnimationContext`) and order
     out.
- If a new switch happens while visible, reuse the same panel and restart the
  timer (natural debounce). No timers or work while idle → zero idle overhead.

### Caret positioning (Accessibility API)

Resolve the caret rect in screen coordinates, with a graceful fallback:

1. `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute` → the focused
   element.
2. `kAXSelectedTextRangeAttribute` (an `AXValue` of type `.cfRange`) →
   `kAXBoundsForRangeParameterizedAttribute` → an `AXValue` of type `.cgRect`
   giving the caret/selection bounds in **screen coordinates with a top-left
   origin** (Quartz), which must be flipped to AppKit's bottom-left origin using
   the caret screen's height.
3. Place the panel just **below-left** of that rect
   (`x = caret.minX − panelWidth`, `y = caret.minY − panelHeight − gap`), i.e. below
   the caret line and left of the caret column; clamp fully on-screen.
4. If any step fails (no focused element, attribute unsupported, zero rect), fall
   back to `NSEvent.mouseLocation`, offset to the left. This keeps behavior sane
   in apps that do not expose the caret via Accessibility.

The app already holds Accessibility permission (required for the event tap), so
no new prompt is introduced. All AX access is wrapped so failures never throw.

### Data flow

`AppDelegate` already observes `kTISNotifySelectedKeyboardInputSourceChanged`
(`main.swift:84`, currently routed to `updateStatusTitle`). Add the HUD to that
same path:

1. On the notification, read `TISCopyCurrentKeyboardInputSource()` — the source
   is already committed at this point, so it is always the correct new source.
2. Call `hud.show(for: currentSource)`.

Because it is driven by the input-source-change notification (not by our F18
handler), the HUD fires correctly for **all** switch paths — Caps Lock via this
app *and* Ctrl+Space / Globe / menu.

`AppDelegate` owns one `LanguageIndicatorHUD` instance.

### Glyph mapping

A pure function derives the display glyph. It lives in the **`LangSwitchCore`**
library target (new file `Sources/LangSwitchCore/InputSourceGlyph.swift`) — the
same testable library that already holds `HIDMappingManager` — so it can be
unit-tested without any UI or Carbon dependency:

```
public func indicatorGlyph(languageCode: String?, localizedName: String) -> String
```

- Caller (the HUD) reads `kTISPropertyInputSourceLanguages` → first element
  (`"th"`, `"en"`, …) and `kTISPropertyLocalizedName`, then calls this function.
- Small explicit map: `th → "ก"`, `en → "Aa"` (matches the native badge).
- Fallback: uppercased 2-letter language code (`"de"` → `"DE"`); if no language
  code, first character of `localizedName`.

This keeps the map tiny (only the user's two languages are special-cased) while
still producing a reasonable label for any other source without maintenance. The
function takes plain strings (no `TISInputSource`), keeping `LangSwitchCore` free
of the Carbon/AppKit dependency the HUD needs.

### Native indicator suppression (auto-managed by the app)

The app manages the global `TSMLanguageIndicatorEnabled` default
(`kCFPreferencesAnyApplication`) so the user does not have to run any command:

- **On launch:** read the current value. If not already `false`, save the prior
  value to `UserDefaults` (key `nativeIndicatorPriorValue`, storing
  present/absent + bool), then set the global default to `false` and synchronize.
- **On quit (`applicationWillTerminate`):** restore the saved prior value
  (remove our override if there was no prior value).
- **One-time notice:** the first time the app disables it, show a single
  informational alert (guarded by a `UserDefaults` flag) explaining that macOS's
  built-in indicator is replaced and that a **logout/restart is needed once** for
  the change to fully take effect. The app's own HUD works immediately regardless.
- All preference access is wrapped so a failure never blocks startup or the tap.

Known limitation (documented, accepted): the setting takes full effect only after
a logout/restart, so both indicators may appear until then. A hard kill (crash /
`kill -9`) skips the quit-time restore; the next launch re-applies `false`
idempotently, and the app is typically a login item so this self-heals.

### Cleanup of the failed fix

Revert the earlier experiment in `CapsLockTap.swift` that wrapped `onTap?()` in
`DispatchQueue.main.async`. It did not fix the bug and is unrelated to this
approach; reverting keeps the switch synchronous (zero-delay) and the diff focused.

## Appearance / behavior (hardcoded defaults)

- Position: just below-left of the text caret (fallback: below-left of the mouse
  cursor), clamped fully on-screen.
- Size: compact ~22×15pt rounded pill (11pt glyph), small like the native
  indicator so it does not cover the text being typed.
- Style: solid **blue** background (`NSColor.systemBlue`) with **white** text,
  resembling the native indicator; layer-backed rounded corners, no blur.
- Visible ~0.9s, then ~0.2s fade-out.

## Testing

- **Unit test** (`Tests/LangSwitchTests/InputSourceGlyphTests.swift`, using the
  existing `LangSwitchTests` target): the pure `indicatorGlyph(...)` mapping —
  `th → "ก"`, `en → "Aa"`, `de → "DE"`, empty/unknown → first letter of name.
- **Manual (by the user, on the real machine):** the HUD appearance/position, that
  it shows the correct language on Caps Lock and Ctrl+Space switches, and that the
  native badge is gone after one logout. (The native badge and overlay cannot be
  observed from a headless build.)

## Files changed

- **New:** `Sources/LangSwitchCore/InputSourceGlyph.swift` — pure
  `indicatorGlyph(languageCode:localizedName:)`.
- **New:** `Sources/CapsLangSwitcher/LanguageIndicatorHUD.swift` — the overlay
  panel; reads TIS properties, calls `indicatorGlyph`, positions/shows/hides.
- **Edit:** `Sources/CapsLangSwitcher/main.swift` — own the HUD, call it from the
  input-source-change observer, add native-indicator suppression lifecycle +
  one-time notice.
- **Edit:** `Sources/CapsLangSwitcher/CapsLockTap.swift` — revert the
  `DispatchQueue.main.async` experiment.
- **New:** `Tests/LangSwitchTests/InputSourceGlyphTests.swift` — tests for
  `indicatorGlyph`.
- **Edit:** `README.md` — note the replaced indicator and the logout-once caveat.

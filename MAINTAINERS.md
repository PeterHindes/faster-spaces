# Faster Spaces — Maintainer & Agent Handbook

Last updated: 2026-10-25 · App version: 1.0.3 · Verified on macOS 27.0.1 (26A434), Apple Silicon

This document is for anyone changing Faster Spaces or building a similar
Spaces/gesture utility. It describes the architecture, the private APIs we rely
on, the parts that are fragile, the bugs we already paid for, and the checks to
run before shipping.

Read the source comments first. They are intentionally dense around the
private event fields and the gesture state machine. This file is the map and
the warning label.

## Contents

0. [Read this first](#0-read-this-first)
1. [What the app is (and is not)](#1-what-the-app-is-and-is-not)
2. [High-level architecture](#2-high-level-architecture)
3. [File map](#3-file-map)
4. [Runtime flow](#4-runtime-flow)
5. [Private APIs and constants](#5-private-apis-and-constants)
6. [Finger-count policy](#6-finger-count-policy)
7. [Ctrl+arrow policy](#7-ctrlarrow-policy)
8. [Permissions, signing, and TCC](#8-permissions-signing-and-tcc)
9. [Build and release](#9-build-and-release)
10. [Testing](#10-testing)
11. [Lessons learned / failed approaches](#11-lessons-learned--failed-approaches)
12. [Known limitations and future work](#12-known-limitations-and-future-work)
13. [Change checklist for agents](#13-change-checklist-for-agents)
14. [Upstream work and licenses](#14-upstream-work-and-licenses)

---

## 0. Read this first

Faster Spaces is not a normal macOS app:

- It relies on **undocumented CGEvent fields**, the Dock's private
  `DockControl` event stream, and (on macOS 27+) a byte-exact serialized IOHID
  payload.
- It works by **suppressing the system gesture before the Dock sees it** and
  posting a synthetic complete gesture through the same pipeline.
- It needs **Accessibility**. It does **not** need Screen Recording anymore.
- The release is **self-signed, not notarized**, and the app bundle is
  **arm64 only**.
- Most failures are silent: a switch simply does nothing, or the wrong Space is
  targeted. Use the log and test with a real trackpad.

If you only remember one thing: **the private constants, sign conventions,
event tags, and OS-version gates are load-bearing. Do not “clean them up.”**

---

## 1. What the app is (and is not)

### It is

- A menu-bar accessory (`LSUIElement`) that switches macOS Spaces instantly.
- A replacement for the animated 3/4-finger Dock swipe and the animated
  Ctrl+←/→ shortcuts.
- A small visual direction HUD (two desktop tiles) that is independent of the
  switch.
- A multi-Space / bidirectional gesture mapper with a configurable distance.
- A local-only utility: no network code, no telemetry, no screenshots.

### It is not

- A window manager. It does not move or rearrange windows.
- A Mission Control replacement. Vertical gestures and Mission Control are
  untouchable.
- A SIP-disabling or code-injecting tool. It uses CGEvent taps/posts and a few
  private framework symbols.
- A notarized/Developer ID-signed product. The release is self-signed.

---

## 2. High-level architecture

```
                         ┌─────────────────────────────────────┐
 real trackpad ────────► │ CGEventTap (.cgSessionEventTap,      │
 real Ctrl+←/→ ────────► │ headInsert, .defaultTap)            │
                         │ SwipeInterceptor                    │
                         └───────────────┬─────────────────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              │                          │                          │
              ▼                          ▼                          ▼
   real DockControl 29/30       keyDown Ctrl+←/→           synthetic 29/30
   horizontal swipe             (guarded by CGS)            tagged "FSPS"
              │                          │                          │
              ▼                          ▼                          │
   finger-count filter           KeyboardSpaceShortcut            │
   MultitouchTracker             (no intercept if remapped)        │
              │                          │                          │
              └──────────────┬───────────┘                          │
                             ▼                                      │
                    SpaceSwitcher.switchBy                          │
                    - read CGS Spaces (SkyLight)                    │
                    - clamp / predict                               │
                    - post synthetic gesture ───────────────────────┘
                             │
                             ▼
                    Dock / WindowServer switches Space
                             │
                             ▼
                    SpaceHUDOverlay (independent visual cue)
```

Two input sources feed one switch core:

1. **Trackpad DockControl events** — intercepted, filtered, replaced.
2. **Ctrl+←/→ keyDown** — intercepted only while the macOS symbolic hotkey is
   still enabled and assigned to those keys.

Both call `SpaceSwitcher.switchBy(steps:direction:reason:)`. The HUD is shown
from that core and has no ability to affect the switch.

The app reads Spaces through private SkyLight (`SLS*`) functions, not through
Dock scripting or AppleScript.

---

## 3. File map

| Path | Responsibility |
|---|---|
| `Sources/FasterSpaces/FasterSpacesMain.swift` | Tiny `@main` entry point; sets accessory policy and runs the app. |
| `Sources/FasterSpaces/AppDelegate.swift` | Status item, menus, onboarding/settings/diagnostics windows, launch sequence, yank guard, URL commands, snapshot aid. |
| `Sources/FasterSpaces/SwipeInterceptor.swift` | Accessibility manager, event-tap lifecycle, gesture state machine, multi-Space math, finger-count filtering, Ctrl+arrow interception. |
| `Sources/FasterSpaces/SpaceSwitcher.swift` | CGS/SkyLight snapshot, display/cursor routing, edge clamping, prediction, synthetic macOS 26/27 gestures, IOHID payload. |
| `Sources/FasterSpaces/KeyboardSpaceShortcut.swift` | Reads live symbolic hotkeys 79/81; decides whether Ctrl+←/→ belongs to macOS. |
| `Sources/FasterSpaces/MultitouchTracker.swift` | Reads the macOS 3/4-finger setting; raw `MultitouchSupport` touch count. |
| `Sources/FasterSpaces/SpaceHUDOverlay.swift` | Borderless 0.25 s two-tile direction cue, repeated per Space, gesture-lifetime fade. |
| `Sources/FasterSpaces/SettingsStore.swift` | UserDefaults-backed settings and derived limits. |
| `Sources/FasterSpaces/LaunchAtLogin.swift` | Per-user LaunchAgent, path refresh, duplicate-safe enable/disable. |
| `Sources/FasterSpaces/Views.swift` | SwiftUI settings, onboarding, diagnostics. Avoids `@State` macros for restricted build environments. |
| `Sources/FasterSpaces/Log.swift` | Thread-safe in-memory + `~/Library/Logs/FasterSpaces.log` logger. |
| `scripts/build.sh` | Compiles, assembles the `.app`, signs, verifies. |
| `Resources/Info.plist` | Bundle identity, URL scheme, LSUIElement, minimum OS. |
| `docs/` | GitHub Pages promo site; `docs/settings.png` is generated by `fasterspaces://snapshot`. |

---

## 4. Runtime flow

### 4.1 Launch

1. `FasterSpacesMain` creates `AppDelegate` and runs `NSApplication`.
2. `AppDelegate.applicationDidFinishLaunching`:
   - refuses to start a second copy with the same bundle ID;
   - sets `.accessory`;
   - starts the status item and menu;
   - starts `MultitouchTracker`;
   - refreshes the launch-at-login agent path;
   - enables launch at login once after onboarding;
   - starts the Accessibility permission poll;
   - shows onboarding or settings if needed.
3. When trusted, `AccessibilityManager` installs the event tap.
4. The tap is re-enabled every 5 s if it was disabled by the system.

TCC caveat: launching from a terminal attributes the request to the terminal.
Always test permission behavior by launching the `.app` bundle (for example
with `open`).

### 4.2 Swipe state machine

The tap receives private CGS event type 30 (`DockControl`) with a horizontal
HID type. It suppresses the real event and builds a synthetic replacement.

| Phase | Value | Behavior |
|---|---:|---|
| began | 1 | Start tracking; read raw finger count; reset multi-Space state. Suppress. |
| changed | 2 | First nonzero progress: choose direction, compute initial steps, call `switchBy`. Later: update bidirectional distance. Suppress. |
| ended | 4 | If never fired, use velocity/progress as a fallback. Reset state. On macOS 27 pass a terminal event with fields cleared so the Dock can close its native gesture state. |
| cancelled | 8 | Reset state; suppress. |

Important invariants:

- The first switch happens on the first nonzero `changed` progress, not on
  ended. This is what makes it feel immediate.
- All subsequent real `changed` events are swallowed.
- On macOS 27 the real terminal event is passed through **cleared** so the
  Dock can close its state. Do not pass a terminal event with velocity/progress
  still set.
- Companion `kCGSEventGesture` (29) events belonging to a tracked swipe are
  suppressed.
- Synthetic events are tagged with `0x4653_5053` (“FSPS”). The tap must pass
  its own events through or it will intercept itself.

### 4.3 Multi-Space math

Inputs: normalized `gestureSwipeProgress` (real right swipe is positive),
`progressPerSpace` (default 0.20, clamped 0.08...0.30), `maxSpaces` (1...8).

```
threshold = effectiveProgressPerSpace
value = invertDirection ? -progress : progress
rawSteps = max(1, floor(abs(value) / threshold))
steps = multiSpaceEnabled ? min(rawSteps, maxSpaces) : 1
direction = sign(value)
anchor = value - direction * rawSteps * threshold
```

On later `changed` events:

```
rawDesired = trunc((value - anchor) / threshold)
desired = clamp(rawDesired, -maxSpaces, +maxSpaces)
if desired != netSteps:
    direction = sign(desired - netSteps)
    switchBy(steps: abs(desired - netSteps), direction: direction)
    netSteps = desired
```

`anchor` being on the threshold grid is why moving back retraces the count
instead of switching back one extra Space. The first switch is anchored to the
grid, not to the raw first sample.

Edge behavior: `switchBy` clamps the target and returns the **actual** number
of steps requested. `updateMultiSpace` advances `netSteps` even at an edge so
pushing into the edge does not queue a pile of reversals for the way back.

### 4.4 HUD

`SpaceHUDOverlay` is shown by `SpaceSwitcher.switchBy` after the synthetic
gesture is posted. It is a separate borderless `NSWindow` at `.screenSaver`
level with `.canJoinAllSpaces`, `.stationary`, and `.ignoresMouseEvents`.

- 164×58 pt pill, bottom-center of the display under the pointer.
- Two 58×34 tiles; current tile is blue, destination is gray.
- 0.18 s CALayer slide + 0.07 s fade for keyboard/menu/URL switches.
- During a real swipe, `waitForGestureEnd: true` keeps it visible until
  `SpaceSwitcher.noteGestureEnded()` or a 2 s safety timeout.
- Each additional Space calls `advance(to:direction:)`, which resets the
  layer model state and replays the slide with the previous destination as the
  new origin.
- A reversal repositions the two tiles and animates the other way.
- It never delays or synchronizes with the actual switch. It is cosmetic.

Do not turn the HUD into a native `Dock` animation or a screenshot overlay. See
§11 for why.

### 4.5 Keyboard path

`KeyboardSpaceShortcut.direction(for:)` accepts only:

- keycode 123 / 124 (left/right arrow),
- exactly Control (no Command/Option/Shift),
- live CGS symbolic hotkey 79/81 **enabled**,
- live registered keycode still 123/124,
- live registered flags containing the control bit (`0x40000`).

If any check fails, the key event is passed through. This deliberately respects
remapped or disabled macOS shortcuts. The keyDown is suppressed only when we
switch; keyUp is not intercepted.

### 4.6 Menu / URL / diagnostic paths

The URL scheme is `fasterspaces://`:

- `settings`, `diagnostics`, `onboarding`
- `switch?direction=right&count=2`
- `toggle`
- `status` (writes one line to the log)
- `snapshot` (renders the settings window to `~/Desktop/FasterSpaces-Settings.png`)

The menu’s left/right items call the same `switchBy` core.

### 4.7 Empty-desktop yank guard

Landing on a Space with no ordinary windows can make macOS activate an app whose
window lives elsewhere; the Dock then follows that window back out. The guard
runs on `NSWorkspace.activeSpaceDidChangeNotification`:

- if enabled and Accessibility is trusted,
- no own window is visible,
- after a 40 ms settle,
- and the active Space has no layer-0 windows,

then the app activates itself. It has no windows while idle, so nothing can
order an off-Space window in. Cost: keyboard focus goes to a windowless app on
an empty Space; keystrokes go nowhere (they were already going nowhere). The
guard is throttle-limited to 0.75 s. It is skipped while settings/onboarding/
diagnostics are visible.

---

## 5. Private APIs and constants

### 5.1 Event fields

`SpaceSwitcher.Field` contains the numeric `CGEventField` values. These are
undocumented and have been stable for years, but they are the first thing to
verify after a macOS update.

| Constant | Field | Use |
|---|---:|---|
| `cgsEventType` | 55 | Real CGS event type. |
| `gestureHIDType` | 110 | IOHID event type; 23 = dock swipe. |
| `swipeMask` | 115 | Appears in the 27 IOHID payload; not reliable as finger count. |
| `swipeMotion` | 123 | 1 = horizontal. |
| `swipeProgress` | 124 | Normalized cumulative travel. |
| `swipePositionX/Y` | 125/126 | Used by the 27 payload. |
| `swipeVelocityX/Y` | 129/130 | Terminal fling. |
| `gesturePhase` | 132 | 1/2/4/8. |
| IOHID payload | 4205 | Serialized raw payload appended on 27. |

CGS event types: 29 = gesture companion, 30 = DockControl. HID type 23 =
Dock swipe. Motion 1 = horizontal.

### 5.2 Magnitudes

- Posted progress is `±1e-4`, **not** zero (zero loses direction) and **not**
  `FLT_TRUE_MIN` (subnormal is flushed on Apple Silicon, losing the sign).
- macOS 27 terminal velocity is `±9999`; the legacy path uses `±2000`.
- The gesture sequence is **three phases**: began, changed, ended.
- On 27 each DockControl event is paired with a companion gesture event.
- The 27 IOHID payload is byte-exact: queue header 28 bytes + fluid-touch
  gesture 40 bytes + velocity 28 bytes, little-endian. Do not replace the
  manual byte writes with Swift structs; Swift does not guarantee C packing.
  One wrong offset makes the Dock silently ignore the swipe.

### 5.3 Direction conventions

These deliberately disagree on the write side:

- **Real** rightward swipe reports **positive** progress. This is true on 26 and
  27 and must not be flipped.
- **Posted** rightward swipe on 27 uses **negative** progress/velocity when
  Natural Scrolling is ON. The code computes `postedSwipeSign` from
  `com.apple.swipescrolldirection` at singleton init. Only the writer flips.
- On the legacy path, right is positive.
- `invertDirection` is a user-facing correction for unusual setups; it applies
  to the read side and multi-Space math.

If direction is backwards on only one OS, check which side changed. Do not
“make the signs agree.”

### 5.4 Space model and prediction

`SLSCopyManagedDisplaySpaces` returns an array of display dictionaries. We read
`Spaces[*].id64` / `ManagedSpaceID` and `Current Space`. Fullscreen Spaces are
included; `TileLayoutManager` marks them.

The Dock routes a Space swipe to the **display under the pointer**, not the
display with keyboard focus. `snapshot()` matches that with
`CGGetDisplaysWithPoint` and the cursor display UUID. `SLSGetActiveSpace` is
only the single-display/fallback path.

CGS updates lag the visual switch. `logicalCurrentIndex(for:)` trusts a
prediction for 0.45 s (27) / 0.30 s (legacy), keyed by display identifier. Rapid
gestures therefore chain correctly. `resetPrediction()` exists but is currently
not called; predictions expire by time. If you add a real snapshot observer,
clear predictions when the actual current Space catches up, not immediately
after posting.

Edge clamp is based on the display’s Space count; never post a switch past the
first/last Space, or the Dock rubber-bands.

### 5.5 OS gating

`needsAugmentation = macOSMajorVersion() >= 27`. The pre-27 path is kept for
older systems but is less tested. Keep new work behind that gate so a change
for 27 cannot regress the legacy path. Verify the 27 path on a real 27 machine;
the payload is only validated by the real Dock.

---

## 6. Finger-count policy

The macOS setting is read live:

```
com.apple.trackpad.threeFingerHorizSwipeGesture
  2 -> 3-finger Spaces gesture is selected
  0 -> 4-finger Spaces gesture is selected
```

This is a current-user/current-host preference. The four-finger key is often
left at 2 even when three is selected; do not use it as the selector.

The DockControl event does **not** reliably carry a finger count (the
`swipeMask` field is 0 most of the time). To honor the setting, the app loads
`/System/Library/PrivateFrameworks/MultitouchSupport.framework` with `dlopen`
and reads raw contacts via `MTDeviceCreateList` /
`MTRegisterContactFrameCallback` / `MTDeviceStart`. It counts touches in state
3 (touching) or 4 (active).

At gesture begin (and again at first changed if the count was 0), it compares
the count to `FingerConfiguration.macOSFingerCount`. A mismatch sets
`ignoreForFingerCount`; the whole gesture is suppressed, including the ended
fallback. If the count is unavailable (0), it allows the gesture rather than
blocking the user.

This is a fragile private API. On a future macOS:

- if `MultitouchSupport` disappears or the struct layout changes, count may be
  wrong/0; the fallback is to allow both counts;
- do not make the filter stricter without real-hardware testing;
- no extra permission was required for this on 27.0.1, but that can change.

Test both directions: set macOS to 3 and confirm 4 is ignored; set to 4 and
confirm 3 is ignored. The user-facing row is “3 or 4 fingers, following macOS”.

---

## 7. Ctrl+arrow policy

The default macOS symbolic hotkeys are:

- 79 = “Move left a space” (Ctrl+←)
- 81 = “Move right a space” (Ctrl+→)

`KeyboardSpaceShortcut` reads live state with
`CGSIsSymbolicHotKeyEnabled` and `CGSGetSymbolicHotKeyValue`, not just the
plist. This matters because System Settings changes are applied live.

We intercept only when all of these hold:

- keycode is exactly 123 or 124;
- event modifiers are exactly Control (no Shift/Option/Command);
- the corresponding hotkey is enabled;
- its registered keycode is still the arrow;
- its registered flags include the control bit (0x40000).

If you remap or disable the shortcut, Ctrl+arrow passes through. The app does
not disable or rewrite the macOS hotkey. It also does not support a remapped
non-arrow binding yet; that is future work.

Only `keyDown` is in the tap mask. We suppress the keyDown when we switch; the
keyUp is harmless. Key repeat is currently allowed, so holding Ctrl+arrow can
step multiple Spaces.

---

## 8. Permissions, signing, and TCC

### Required

- **Accessibility** — to create an active event tap and post synthetic events.

### Not required

- **Screen Recording** — not used. An experimental screenshot overlay existed
  during development and was removed. The release does not request it.
- Input Monitoring — not used on 27.0.1 for the MultitouchSupport listener.

### Code signing

The app is signed with a local self-signed code-signing certificate
(`Faster Spaces Development`) when `build/signing/dev.keychain` exists. TCC keys
the Accessibility grant to the certificate root, not the binary hash, so
rebuilds preserve the grant. A fresh checkout without the keychain falls back to
ad-hoc signing; every rebuild then changes the TCC identity.

Never commit `build/signing` (keychain, `.p12`, `.pem`, password file). It is
ignored by `.gitignore`.

Check:

```sh
codesign -d -r- "/Applications/Faster Spaces.app"
codesign --verify --deep --strict --verbose=2 "/Applications/Faster Spaces.app"
```

The designated requirement should be stable (`certificate root = H"..."`), not
a cdhash.

### Grant / reset

- On a new machine: launch the app, click **Grant Access…**, enable it in
  System Settings → Privacy & Security → Accessibility.
- If a stale entry cannot be removed: `tccutil reset Accessibility
  com.fasterplz.fasterspaces`, relaunch, grant again.
- Settings → Troubleshooting → **Reset Accessibility…** runs the same reset
  from inside the app, then requires quit/reopen.
- macOS caches trust per process in some situations; polling and tap creation
  are validated live on 27.0.1, so the app usually recovers without a restart.

### Distribution

The release is not notarized. First launch needs right-click → **Open**, or:

```sh
xattr -dr com.apple.quarantine "/Applications/Faster Spaces.app"
```

The app is **Apple Silicon (arm64)**, minimum macOS 13.0 according to the plist;
27.0.1 is the verified platform.

---

## 9. Build and release

### Build

```sh
./scripts/build.sh
open "dist/Faster Spaces.app"
```

The script:

1. kills any running `FasterSpaces`;
2. compiles all Swift files with `-swift-version 5`, `-O`,
   `-target arm64-apple-macos13.0`;
3. links `SkyLight`, AppKit, SwiftUI, Combine, ServiceManagement;
4. assembles `Resources/Info.plist` and `Resources/AppIcon.icns`;
5. signs with the local identity if present, otherwise ad-hoc;
6. verifies the signature.

It uses a workspace-local module cache because restricted/sandboxed build
environments may reject the default cache path. The UI deliberately avoids
SwiftUI `@State` macros in this repository (they can fail in a restricted
plugin-server environment); use `ObservableObject` state as the existing views
do.

### Version bump

Update **both**:

- `AppDelegate.version`
- `Resources/Info.plist` `CFBundleShortVersionString` and `CFBundleVersion`

Then rebuild, install, and package. Current version: **1.0.3**.

### Install for testing

```sh
pkill -x FasterSpaces || true
ditto "dist/Faster Spaces.app" "/Applications/Faster Spaces.app"
open "/Applications/Faster Spaces.app"
```

The stable signature should preserve Accessibility. Check the log for
`Gesture event tap installed`.

### Package and release

The release asset name is exactly `Faster-Spaces.zip` so the Pages
`releases/latest/download/...` link keeps working.

```sh
ditto -c -k --norsrc --keepParent "/Applications/Faster Spaces.app" \
  "dist/Faster-Spaces.zip"
shasum -a 256 dist/Faster-Spaces.zip | awk '{print $1"  Faster-Spaces.zip"}' \
  > dist/Faster-Spaces.zip.sha256

gh release create vX.Y.Z dist/Faster-Spaces.zip dist/Faster-Spaces.zip.sha256 \
  --title "Faster Spaces X.Y.Z" --notes-file build/release-notes-X.Y.Z.md
```

Release notes should include install steps, the exact SHA-256, arm64/macOS
caveats, and the website/source links. Then update `README.md` version references
if any and commit/push. Pages deploys from `main` / `docs`.

### Repository / Pages

- Source: https://github.com/PeterHindes/faster-spaces
- Pages: https://peterhindes.github.io/faster-spaces/
- Pages source: `main`, `/docs`
- The site is plain HTML/CSS/JS; no build step.
- `docs/.nojekyll` disables Jekyll processing.
- `docs/settings.png` is generated by `fasterspaces://snapshot`, not a screen
  recording.
- The download button points at the latest release asset named
  `Faster-Spaces.zip`.
- Push with the existing auth helper if SSH is unavailable:
  `GIT_ASKPASS` + `gh auth token` is used in this environment.

Do not upload `build/`, `dist/`, or signing material to the repository.

---

## 10. Testing

### Required manual matrix (real trackpad, real macOS)

1. **Single swipe**: exactly one Space, HUD slides once, no native animation.
2. **Multi-Space swipe**: HUD replays per extra Space; destination numbers
   advance; max cap respected.
3. **Reverse mid-swipe**: HUD reverses, Spaces retrace.
4. **Edges**: first/last Space does not rubber-band or double-switch.
5. **Finger setting**: set 3 → 4-finger ignored; set 4 → 3-finger ignored.
6. **Ctrl+←/→**: instant switch and HUD; then disable/remap the macOS shortcut
   and confirm the keys pass through.
7. **HUD lifetime**: hold fingers still; HUD stays until lift, then fades. If
   no end event arrives, it must fade after 2 s.
8. **Menu/URL switches**: switch left/right and multi-step `count`; HUD uses
   short lifetime.
9. **Permission**: fresh install, grant, revoke, regrant.
10. **Empty Space**: yank guard activates the app and does not leave a window.
11. **Multi-display** (if available): sway applies to the display under the
    pointer; HUD is on that display.
12. **Auto-rearrange Spaces** on: ordering can change; predictions still make
    rapid switches chain reasonably.

### Where to look

- Log: `~/Library/Logs/FasterSpaces.log`
- Diagnostics window: Settings → Troubleshooting → Diagnostics
- Turn on **Debug logging** in Settings to get phase/progress/mask/gap lines.
- `open "fasterspaces://status"` writes a one-line status to the log.
- `open "fasterspaces://switch?direction=right&count=2"` exercises the core
  without a trackpad.

### Do not trust terminal-launched TCC

A terminal-launched binary’s Accessibility request is attributed to the
terminal. Launch the `.app` bundle with `open` to test real permission
behavior.

### Frame-by-frame analysis (historical, removed)

A development-only ScreenCaptureKit recorder once existed and wrote frames to
the Desktop at native refresh. It was useful, but it is not in the current
source and must not ship enabled. If reintroducing it:

- capture at native refresh; record presentation timestamps;
- expect ~60 fps in practice, with dropped frames;
- include the HUD in the capture to judge timing;
- compare frame-to-frame differences and make a contact sheet;
- remember `activeSpaceDidChangeNotification` can fire **before** the
  destination is composited;
- avoid capturing the “new” Space while it is still the old one underneath.

The screenshot overlay path failed exactly because the “destination” capture
was still the old Space; the result was double exposure. See §11.

---

## 11. Lessons learned / failed approaches

These are not hypothetical. They cost debugging time.

### Native partial-slide cue (abandoned)

We tried to hold a synthetic Dock gesture at ~6% progress for 100 ms, commit,
then post an opposite partial gesture to “slide in.” It could be made to look
smooth in isolation, but a real gesture’s live `changed`/`ended` stream fought
it. The real terminal event reset the Dock mid-cue, causing three-frame glitches
and overshoot. Suppressing the terminal event during the cue helped only
sometimes. **Do not reintroduce a native partial-slide cue** unless you are
prepared to own the Dock’s gesture state machine. The HUD is deliberately
separate.

### Screenshot overlay (abandoned)

A full-screen screenshot of the outgoing Space was captured, shown before the
synthetic switch, then slid out. The “new” frame was captured below the overlay
after the switch. Problem: the Dock had not actually composited the destination
yet, so the “new” frame was still the old Space. The result was a ghosted
double exposure of the old screen; fading made it worse. Waiting for
`activeSpaceDidChange` was not sufficient on 27.0.1. Frame analysis confirmed
the duplicated content.

If you ever revisit this:

- synchronize on actual composited content, not the notification;
- do not capture “below the overlay” until the switch has truly landed;
- account for capture latency and frame drops;
- prefer a crossfade of two verified frames, or don’t do it at all.

### `FLT_TRUE_MIN` progress

Reference implementations use the smallest subnormal float. On Apple Silicon it
is flushed to zero, losing the sign, so all switches go one way. Use `1e-4`.

### Zero progress

`fixed1616(0)` serializes as zero in the IOHID payload; direction is lost. Use a
small nonzero magnitude.

### Sign “tidying”

The read side and write side deliberately disagree on 27. See §5.3. Flipping
the reader inverts every real swipe while Ctrl+arrow still works.

### `activeSpaceDidChange` is early

It is a state notification, not a compositor barrier. Do not use it as “the
destination is now visible.”

### LaunchAgent bootstrap while running

Calling `launchctl bootstrap` when enabling login-at-login immediately starts a
second copy. We only write the plist; launchd picks it up at next login. Do not
`bootout` on disable either: if the current process came from the agent, that
kills the app the user is using. Removing the plist is enough.

### Ad-hoc signing and TCC

Rebuilding an ad-hoc app changes its TCC identity. Use the stable local
certificate, or expect to regrant after every build. Reset with `tccutil` when
the old entry cannot be removed.

### NSHostingView + ScrollView sizing

A SwiftUI `ScrollView` can report its entire content height as the window’s
ideal height, producing a 3,800 px tall “settings” window. Set an explicit
frame on the root view, set the hosting view’s frame, and call
`setContentSize` after installing the content view. Onboarding is wrapped in a
`ScrollView` so the bottom button cannot be clipped on short screens.

### SwiftUI `@State` macros in restricted builds

The views use `ObservableObject`/`@ObservedObject` rather than `@State` because
the macro plugin server can fail in a restricted build sandbox. This is not a
product requirement; it is a build-environment workaround. Do not “modernize”
it without testing the actual build environment.

### Private `MultitouchSupport`

It works on 27.0.1 with no extra permission, but it is a private framework with
a pointer-layout struct. If it changes, finger filtering may silently stop
(count 0) and the app falls back to accepting both counts. That is a safe
degradation, but it is not the intended behavior. Test both macOS finger
settings after any OS update.

### Symbolic hotkey values

Do not read only `com.apple.symbolichotkeys`: live state is authoritative. Use
`CGSIsSymbolicHotKeyEnabled` and `CGSGetSymbolicHotKeyValue`. The control bit in
the registered flags is `0x40000`; requiring exactly Control in the event
prevents hijacking Ctrl+Shift+arrow.

---

## 12. Known limitations and future work

- **Pre-macOS 27 path is less tested.** The release is verified on 27.0.1.
- **Apple Silicon only.** The build target is `arm64-apple-macos13.0`.
- **Not notarized.** Right-click Open is required after download.
- **Private APIs can break in any macOS update.** The failure mode is usually
  silent.
- **Finger filtering is best-effort.** If raw touch tracking is unavailable,
  both counts may be accepted.
- **Ctrl+arrow only follows the default arrow binding.** A remapped hotkey on
  another key is passed through; supporting the remapped combo would require
  reading and hijacking its symbolic hotkey too.
- **HUD is directional, not a preview.** It does not show actual Space content.
  This is intentional after the screenshot experiments.
- **Multi-step `switchBy` from a menu/URL shows one HUD animation** for the
  whole jump. Real gestures normally call `advance` once per threshold; a very
  large progress jump can produce more than one step in one call.
- **No automated tests.** The multi-Space math, `KeyboardSpaceShortcut` parsing,
  and `FingerConfiguration` mapping are pure enough to unit-test.
- **Prediction reset is timer-based.** A future observer could clear predictions
  when the actual snapshot catches up.
- **HUD accessibility.** `prefers-reduced-motion` / Reduce Motion is not
  currently honored server-side. If adding it, keep the directional cue but
  shorten or crossfade.
- **Notarization/Developer ID** would improve first-launch UX.

---

## 13. Change checklist for agents

Before changing code:

1. Read this file and the relevant source comments.
2. Reproduce the behavior with a real trackpad if the change touches gestures.
3. Keep changes behind the macOS-version gate where the payload differs.
4. Do not rename/“tidy” the private field constants or sign conventions.
5. Do not add Screen Recording or screenshots without a new explicit design
   decision and privacy review.
6. Run `./scripts/build.sh`; it must sign and verify.
7. Install to `/Applications` and check the log for tap installation.
8. Re-test: single, multi-Space, reverse, edge, 3/4 fingers, Ctrl+arrow, HUD
   lifetime, menu/URL.
9. Bump `AppDelegate.version` and both Info.plist version strings.
10. Package `Faster-Spaces.zip`, generate/verify SHA-256, update release notes.
11. Update README/docs/site copy if behavior changed; snapshot the settings
    window if the UI changed.
12. Commit only source/docs; never commit `build/`, `dist/`, or signing
    material.
13. Push, confirm Pages is `built`, and verify the latest release asset hash.

### Quick commands

```sh
./scripts/build.sh
open "dist/Faster Spaces.app"
open "fasterspaces://status"
open "fasterspaces://switch?direction=right&count=2"
tail -f ~/Library/Logs/FasterSpaces.log
codesign --verify --deep --strict --verbose=2 "/Applications/Faster Spaces.app"
```

---

## 14. Upstream work and licenses

The technique is built on prior reverse engineering:

- [WhichSpace](https://github.com/gechr/WhichSpace) — menu-bar Spaces UI and
  synthetic Dock-swipe switching.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) —
  near-zero-progress three-phase switch.
- [noswoosh](https://github.com/mmathys/noswoosh) — macOS 27 IOHID payload,
  companion events, multi-display routing, empty-desktop guard.
- [iss](https://github.com/joshuarli/iss) — original macOS 27 payload and
  swipe interception.

See `THIRD_PARTY_NOTICES.md` for the full MIT/ISC texts. Faster Spaces itself is
MIT licensed; see `LICENSE`.

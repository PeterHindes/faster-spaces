# Faster Spaces — Maintainer & Agent Handbook

Last updated: 2026-10-30 · App version: 2.1.1 · Verified on macOS 27.0.1 (26A434), Apple Silicon

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
15. [2.0 integration (window switcher, Dock clicks, and keyboard)](#15-20-integration-window-switcher-dock-clicks-and-keyboard)

---

## 0. Read this first

Faster Spaces is not a normal macOS app:

- It relies on **undocumented CGEvent fields**, the Dock's private
  `DockControl` event stream, and (on macOS 27+) a byte-exact serialized IOHID
  payload.
- It works by **suppressing the system gesture before the Dock sees it** and
  posting a synthetic complete gesture through the same pipeline.
- It needs **Accessibility**. **Screen Recording is optional** and is used only
  for live window thumbnails; without it the switcher uses app icons.
- The release is **self-signed, not notarized**, and the app bundle is
  **arm64 only**.
- Most failures are silent: a switch simply does nothing, or the wrong Space is
  targeted. Use the log and test with a real trackpad.

If you only remember one thing: **the private constants, sign conventions,
event tags, and OS-version gates are load-bearing. Do not “clean them up.”**

2.0 adds three feature sets on top of the Spaces pipeline: the New Window Plz
window switcher, Dock click actions, and Superkey-style keyboard features. The
new event-tap routing, finger classification, and HID/Alert caveats are in
[§15](#15-20-integration-window-switcher-dock-clicks-and-keyboard). Read it
before touching `SwipeInterceptor.swift`, `WindowSwitchController.swift`, or
`Dock/`.

---

## 1. What the app is (and is not)

### It is

- A menu-bar accessory (`LSUIElement`) that switches macOS Spaces instantly.
- A replacement for the animated 3/4-finger Dock swipe and the animated
  Ctrl+←/→ shortcuts.
- A small visual direction HUD (two desktop tiles) that is independent of the
  switch.
- A multi-Space / bidirectional gesture mapper with a configurable distance.
- A current-Space window switcher (non-primary swipe, Option-Tab) with its own
  HUD and exact-window activation (from New Window Plz).
- Optional Dock click actions for apps (New Window / Bring Here / None by
  default, with Shift and Control overrides).
- Optional Superkey-style keyboard features: an editable Caps Lock layer and
  an Accessibility-only Seek.
- Optional live window thumbnails, captured only while the switcher is open and
  only with Screen Recording permission.
- A local-only utility: no network code and no telemetry. Keystrokes are
  processed locally for the opt-in layer and are never stored or transmitted.

### It is not

- A general window manager. The Spaces gesture never moves windows. The
  optional Dock **Bring Here** action can move an app's existing window to the
  current Space; that is a deliberate, user-triggered exception.
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

At gesture begin the count is compared to `FingerConfiguration.macOSFingerCount`
and the window count. A mismatch sets `ignoreForFingerCount`; the whole gesture
is suppressed, including the ended fallback. If the count is unavailable (0), it
allows the gesture rather than blocking the user. Because the raw count can lag
the first DockControl event, the count is re-read on `changed` events until a
non-zero sample arrives (or 250 ms pass).

Trackpad devices are not stable identities. A boot in clamshell mode enumerates
only a Bluetooth trackpad; opening the lid brings the built-in trackpad online
and can take the Bluetooth one away. `MultitouchTracker` therefore re-enumerates
every 3 s, registers devices it has not seen, and forces a re-registration after
`NSWorkspace.didWakeNotification`. A registered device that disappears leaves
the tracker at 0, and because 0 fails open to Spaces every four-finger swipe
silently becomes a Spaces swipe (logged as `fingers=0`). Frames also expire after
0.6 s, so a stale count can never classify a new gesture.

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

### Optional

- **Screen Recording** — only for live window thumbnails. The app uses
  `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`, captures
  only current-Space window IDs, and falls back to app icons when not granted.
  The onboarding and Settings both expose the grant.
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
2. compiles `Dock/WindowSpaceMove.c` with clang;
3. compiles every Swift file under `Sources/FasterSpaces/` with
   `-swift-version 5`, `-O`, `-target arm64-apple-macos13.0`;
4. links the C object plus `SkyLight`, AppKit, SwiftUI, Combine,
   ServiceManagement;
5. assembles `Resources/Info.plist` and `Resources/AppIcon.icns`;
6. signs with the local identity if present, otherwise ad-hoc;
7. verifies the signature.

It uses a workspace-local module cache because restricted/sandboxed build
environments may reject the default cache path. The UI deliberately avoids
SwiftUI `@State` macros in this repository (they can fail in a restricted
plugin-server environment); use `ObservableObject` state as the existing views
do.

### Version bump

Update **both**:

- `AppDelegate.version`
- `Resources/Info.plist` `CFBundleShortVersionString` and `CFBundleVersion`

Then rebuild, install, and package. Current version: **2.1.1**.

### Install for testing

```sh
pkill -x FasterSpaces || true
ditto "dist/Faster Spaces.app" "/Applications/Faster Spaces.app"
open "/Applications/Faster Spaces.app"
```

The stable signature should preserve Accessibility. Check the log for
`Gesture event tap installed`.

### Package and release

Releases are automated by `.github/workflows/release.yml`. Bump the version
(above), commit and push `main`, then push a matching tag:

```sh
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

The tag must match `CFBundleShortVersionString`. The workflow fails before
building if `vX.Y.Z`, the plist, and `AppInfo.version` disagree. It runs on
GitHub's arm64 macOS 27 image (`xcode-27`), executes `./scripts/build.sh` and
`--self-test`, then:

1. packages `dist/release/Faster-Spaces.zip` (with `Faster Spaces.app` at the
   archive root) and `Faster-Spaces.zip.sha256`;
2. creates or updates the GitHub Release for the tag (assets are clobbered on a
   re-run) with generated notes, install steps, the SHA-256, and the arm64
   caveats;
3. points the marked download anchors in `docs/index.html` at
   `releases/download/vX.Y.Z/Faster-Spaces.zip`, updates the visible version,
   commits that change to `main`, and requests a Pages rebuild;
4. attaches the zip and checksum to the Actions run as
   `faster-spaces-release`.

To use hand-written "what's new" notes, add `release-notes/X.Y.Z.md` (tracked;
`build/` is ignored) before tagging. Without it, GitHub's generated release
notes are used.

Each job requests only the permissions it needs (`contents: write` for the
release, plus `pages: write` for the site rebuild), so the repository default
can stay read-only. Pages must stay configured as `main` / `/docs` so the
rebuild request works.

### Release signing (optional, recommended)

Local builds sign with the self-signed **Faster Spaces Development** identity so
the Accessibility grant survives updates. CI has no access to that keychain and
falls back to ad-hoc signing, which makes macOS treat each release as a new app.
To keep the stable identity, add these repository secrets (Settings → Secrets
and variables → Actions):

- `FASTERSPACES_SIGNING_P12` — base64 of the identity's `.p12` export
  (`base64 -i build/signing/cert.p12 | pbcopy`)
- `FASTERSPACES_SIGNING_P12_PASSWORD` — the export password
- `FASTERSPACES_SIGNING_IDENTITY` — optional; defaults to
  `Faster Spaces Development`

The workflow imports it into a temporary keychain and passes
`FASTERSPACES_SIGN_IDENTITY` / `FASTERSPACES_SIGN_KEYCHAIN` to
`scripts/build.sh`. Without the secrets the release is still valid, just ad-hoc
signed.

Manual fallback, for example when Actions is unavailable:

```sh
ditto -c -k --norsrc --keepParent "/Applications/Faster Spaces.app" \
  "dist/Faster-Spaces.zip"
shasum -a 256 dist/Faster-Spaces.zip | awk '{print $1"  Faster-Spaces.zip"}' \
  > dist/Faster-Spaces.zip.sha256

gh release create vX.Y.Z dist/Faster-Spaces.zip dist/Faster-Spaces.zip.sha256 \
  --title "Faster Spaces X.Y.Z" --notes-file build/release-notes-X.Y.Z.md

python3 scripts/update-site-release.py --version X.Y.Z --tag vX.Y.Z
git commit -am "Site: download vX.Y.Z" && git push
```

The release asset name must stay `Faster-Spaces.zip`; the README, the site, and
the `releases/latest/download/...` fallback all depend on it. Pages deploys from
`main` / `docs`.

### Repository / Pages

- Source: https://github.com/PeterHindes/faster-spaces
- Pages: https://peterhindes.github.io/faster-spaces/
- Pages source: `main`, `/docs`
- The site is plain HTML/CSS/JS; no build step.
- `docs/.nojekyll` disables Jekyll processing; the release workflow restores it
  if it ever goes missing.
- `docs/settings.png` is generated by `fasterspaces://snapshot`, not a screen
  recording.
- The download buttons are updated by the release workflow to point at the
  release just built; the static fallback is
  `releases/latest/download/Faster-Spaces.zip`, so the name must stay
  `Faster-Spaces.zip`.
- The visible site version (`data-release-version` in `docs/index.html`) is
  updated by `scripts/update-site-release.py` during a release. Run it manually
  if a release is published outside Actions.
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
- **Finger routing is best-effort.** If raw touch tracking is unavailable the
  app cannot distinguish the two counts and falls back to Spaces; the window
  swipe is then inert rather than misrouting the primary gesture.
- **Ctrl+arrow only follows the default arrow binding.** A remapped hotkey on
  another key is passed through; supporting the remapped combo would require
  reading and hijacking its symbolic hotkey too.
- **HUD is directional, not a preview.** It does not show actual Space content.
  This is intentional after the screenshot experiments.
- **Multi-step `switchBy` from a menu/URL shows one HUD animation** for the
  whole jump. Real gestures normally call `advance` once per threshold; a very
  large progress jump can produce more than one step in one call.
- **Gesture and Dock paths still need a real trackpad/Dock.** The pure swipe
  and window-selection math has a `--self-test` target, but synthetic Dock
  gestures, multitouch finger routing, Dock hit-testing, and true activation
  behavior remain manual checks.
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
9. Bump `AppInfo.version` and both Info.plist version strings.
10. Cut the release by pushing a matching `vX.Y.Z` tag; the release workflow
    packages the zip and SHA-256 and updates the site. Use the manual fallback
    in [§9](#9-build-and-release) only when Actions is unavailable.
11. Update README/docs/site copy if behavior changed; snapshot the settings
    window if the UI changed.
12. Commit only source/docs; never commit `build/`, `dist/`, or signing
    material.
13. Push, confirm Pages is `built`, and verify the latest release asset hash.

### Quick commands

```sh
./scripts/build.sh
"dist/Faster Spaces.app/Contents/MacOS/FasterSpaces" --self-test
open "dist/Faster Spaces.app"
open "fasterspaces://status"
open "fasterspaces://switch?direction=right&count=2"
open "fasterspaces://hud"
open "fasterspaces://seek?query=hello"
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
- [New Window Plz](https://github.com/PeterHindes/NewWindowPlz) — current-Space
  window catalog, Option-Tab switcher, exact-window activation, previous-Space
  history, and Dock click pipeline.
- [Superkey](https://superkey.app) — behavioral inspiration for the Hyper key,
  keyboard presets, and Seek (no source code included).

See `THIRD_PARTY_NOTICES.md` for the full MIT/ISC texts. Faster Spaces itself is
MIT licensed; see `LICENSE`.


---

## 15. 2.0 integration (window switcher, Dock clicks, and keyboard)

This section was added when Faster Spaces absorbed three feature sets. It is the
map for the new code; the older sections still describe the Spaces core.

### 15.1 What was merged

| Source | Code now in this app | Notes |
|---|---|---|
| Faster Spaces 1.0.3 | `SwipeInterceptor`, `SpaceSwitcher`, `SpaceHUDOverlay`, `SettingsStore`, `Views` | Spaces core; unchanged event constants and sign conventions. |
| New Window Plz | `WindowSwitcher.swift`, `WindowSwitchController.swift`, `WindowSwitchHUD.swift`, `WindowSwitcherOverlay.swift`, `Overlay/`, `SpaceHistory`, `Dock/` | Catalog, Option-Tab, the Metal switcher, exact-window activation, previous Space, Dock clicks, window-space move backend. |
| New gesture | `SwipeMath`, the window branch in `SwipeInterceptor`, `WindowSwitchController` | The non-primary finger count drives the same window catalog without posting a Spaces gesture. |
| Superkey (behavior only) | `KeyboardEnhancer.swift`, `SeekController.swift` | No Superkey source code is included. Hyper key, presets, and an Accessibility-only Seek. |

### 15.2 Finger routing (the most likely thing to break)

`FingerConfiguration` reads the live trackpad preference from both storage
locations used by macOS:

- the per-host global keys `com.apple.trackpad.threeFingerHorizSwipeGesture`
  and `com.apple.trackpad.fourFingerHorizSwipeGesture`;
- `TrackpadThreeFingerHorizSwipeGesture` / `TrackpadFourFingerHorizSwipeGesture`
  in `com.apple.AppleMultitouchTrackpad` and the Bluetooth trackpad domain.

Values are `0` = off, `1` = pages, `2` = full-screen application/Spaces. The
install that prompted 2.0 reports both keys as `2`; the automatic choice is
therefore **3 fingers for Spaces, 4 fingers for windows**. The Settings UI
shows the live source string and a **Swap** button.

Routing happens in `SwipeInterceptor.classifyGesture()`:

```
observed = MultitouchTracker.shared.fingerCount
if observed == 0: fail open to Spaces         // private framework unavailable
else if windowSwipeEnabled && observed == windowFingers:
    windowGesture = true                      // swallow the Dock gesture
else:
    windowGesture = false
    ignoreForFingerCount = observed != spacesFingers
```

Invariants:

- The window count must **never** fall through to `beginSwitching`; otherwise a
  four-finger swipe would switch Spaces and windows.
- The Spaces count must **never** be classified as a window gesture.
- The raw count can lag the first `DockControl` event. `countRechecked` keeps
  re-reading it on `changed` events until a non-zero count arrives (bounded at
  250 ms) and can reclassify before anything has fired. Do not remove that
  recheck; it is what lets a freshly re-registered trackpad drive the first
  swipe after a device change.
- If the count is unavailable (`0`), the app deliberately allows Spaces. A
  missing `MultitouchSupport` must not disable the primary gesture.
- A window gesture calls `WindowSwitchController.beginSwipe()` and all later
  progress events go to `beginWindowSwitching` / `updateWindowSwitching`; the
  Spaces state (`fired`, `netSteps`, `anchorProgress`) stays untouched.
- The terminal event is still passed through **cleared** on macOS 27 so the Dock
  can close its native gesture state. This applies to window gestures too.

Overriding the counts is supported in Settings. `SettingsStore.windowFingers`
forces the two counts to differ even if a user picks the same one.

### 15.3 Window catalog, activation, and sessions

`CurrentSpaceWindows.snapshot()` is the New Window Plz enumeration:
`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`,
layer 0, alpha > 0.05, normal `.regular` apps, own PID/bundle excluded,
front-to-back order. `WindowCatalogService` caches it, refreshes on a 1.5 s
timer plus app/Space/screen notifications, and the interactive path reads the
cache. The synchronous scan is only a first-use fallback.

`WindowActivator` uses `_SLPSSetFrontProcessWithOptions` plus
`SLPSPostEventRecordTo` to focus the exact window, then `AXRaise` as a fallback.
Standard app activation is last because it can bring the whole window group
forward. The same helper is used by Dock "Bring Here" and the switcher.

`WindowSwitchController` keeps a session list stable for the duration of a
gesture. A swipe:

1. starts at index 0 (the frontmost window);
2. steps cyclically with `WindowSelection.advance`;
3. with `windowSwipeRaiseOnRelease` (default on), only moves the selection and
   raises the final target in `endSwipe`; with it off, activates each target
   immediately;
4. shows the selected display — the compact `WindowSwitchHUD` strip by default,
   or the full Metal switcher when `windowSwipeUIStyle == 1`;
5. hides after the gesture ends (safety timeout 2 s).

The raise-on-release default exists because raising every intermediate window
changes the WindowServer history: a two-step swipe would raise A then B, leaving
A between the original frontmost and B. It also makes the selection feel stable
while the fingers are down. `windowSwipeInvertDirection` is independent of the
Spaces `invertDirection`; both are applied in `SwipeMath.initial` on their own
paths.

Option-Tab uses the same session but is modal: begin on Option+Tab, advance on
Tab/arrows, commit on Option release or Return, cancel on Escape. The
`optionTabCancelled` latch in `SwipeInterceptor` stays closed until Option is
released so a committed/cancelled session cannot reopen from the key-up.

**Option-Tab now renders through the exact New Window Plz Metal surface.**
`WindowSwitcherOverlay` wraps `OverlayHost` and converts `[SwitchWindow]` to
`[AltTabWindow]` for the ported `OverlayRenderer` / `MetalOverlayView` /
`OverlayPanel`. That gives the centered card, app-icon row, window titles,
"SWITCH WINDOW" header, selection outline and the old footer hints. The shader
source is copied from `Resources/OverlayShaders.metal.txt` into the bundle;
without it the renderer throws `.noShaderSource` and Option-Tab falls back to
the strip. `MetalOverlayView` uses a 60 Hz main-run-loop timer instead of
`NSView.displayLink`, which is macOS 14+ while this app targets 13. Icon and
label textures are warmed on every `fasterSpacesWindowCatalogDidChange`, so the
reveal is an alpha flip. A newly activated window is promoted to index 0 before
the next Option-Tab, matching New Window Plz's "skip the window just raised"
rule.

The swipe can use either display. `SettingsStore.windowSwipeUIStyle` is
`0` for the compact strip and `1` for the full Metal switcher; Option-Tab always
uses the full switcher. The compact strip remains available because it is a
gesture cue rather than a modal switcher, and the old footer's Tab/release hints
would be wrong for a swipe. `WindowSwitchHUD` is an AppKit/CALayer strip,
click-through, joins all Spaces, and has a generation token so a fade-out
completion cannot clear a newly shown strip. If Metal is unavailable, both
paths fall back to this strip.

`WindowSwitcherOverlay` also owns `WindowSnapshotService`, which is copied from
New Window Plz. When `windowSnapshotsEnabled` is on and Screen Recording is
granted, it captures current-Space window images off-main after reveal and
feeds them to `OverlayRenderer.cacheWindowSnapshot`. The scene is shown with
`showSnapshots: true`, giving the old five-card preview layout and page slide.
Without permission the controller passes `showSnapshots: false`, so the same
switcher uses icons.

`SpaceHistory` polls the managed-display snapshot every 0.75 s and remembers the
previous Space per display. `SpaceSwitcher.switchToSpaceID` computes the index
delta and posts the existing synthetic gesture. Option-backtick calls this.

### 15.4 Keyboard features and Seek

All keyboard paths share the same session tap as the gesture. The tap mask now
includes `keyDown`, `keyUp`, and `flagsChanged`. Synthetic keyboard events are
tagged `0x4B45_5942` ("KEYB"); synthetic gestures keep "FSPS". The tap passes
both its own tags.

`KeyboardEnhancer`:

- Caps Lock is tracked by toggling on each `flagsChanged` for keycode 57. We
  swallow the event, so Caps Lock never reaches the system while it is the
  Hyper source. Quick-press behavior is measured separately; `capsSessionUsed`
  is set by any key while Caps is held.
- Right Command/Option/Control sources are tracked with `toggle()` on their
  `flagsChanged` events. That is robust even when the opposing modifier is held.
- The held-key layer is data-driven. `SettingsStore.layerMappings` is an
  ordered `[KeyboardLayerMapping]` (source key, action, target key, modifier
  flags) persisted as JSON. `KeyboardLayer.swift` owns the key catalog and
  quick presets. Unmapped keys follow `layerDefaultAction`: passthrough
  (default), add Hyper modifiers (legacy), or swallow.
- `KeyboardEnhancer.resolveLayer` checks the user mapping first, then the
  default. A `.send` mapping posts one shot and records the physical keyUp in
  `swallowedKeyUps`; `.forward` posts the original key with added flags and
  records `forwardedKeys`. `SwipeInterceptor.keyUp` must call
  `KeyboardEnhancer.handleKeyUp` **before** its Option-Tab `swallowedKeys`
  check, otherwise a forwarded key's keyUp is stolen and the key stays stuck.
  Do not reintroduce that ordering bug.
- The quick presets are just mappings: WASD/HJKL/IJKL arrows, home-row
  symbols/functions, Space=Return, Delete=Forward Delete. They can be edited or
  removed in Settings. The old toggle properties are migration inputs only.
- `toggleCapsLock()` posts a synthetic Caps Lock press and sets
  `ignoreCapsUntil` for 200 ms so the resulting system echo cannot look like a
  physical Caps press.
- Forward Delete used to be a global Hyper+Delete convenience; it is now the
  seeded layer mapping, so an editable `Delete` mapping wins. Shift+Delete
  remains a layer-independent convenience.
- Seek is checked before the layer. While `SeekController.isOpen` the tap
  passes all key events to the panel, but still sends `flagsChanged` to
  `KeyboardEnhancer` so a held layer key is released.

`SeekController.collectMatches` walks `AXWindows` depth-first with a node cap,
deadline, 0.2 s AX timeout, on-screen frame check, and text roles only. It
**does not skip ignored roles entirely**: roots are `AXWindow`, so ignored
roles must still be traversed. This exact bug produced zero matches in the
first 2.0 build.

Seek deliberately does not use OCR or Screen Recording. If you add OCR, it
needs an explicit privacy decision and a new permission path; do not quietly
turn on Screen Recording.

Known keyboard gaps (documented, not accidental):

- The layer does not modify click/drag/scroll events.
- The trackpad-edge "engage Hyper" gesture is not implemented.
- Mappings are single source key → single target key/shortcut; chords and
  sequences are not implemented, and Superkey's click modes are not ported.
- Seek selects the whole accessibility element; it does not place the caret on
  the exact word inside a text area.

### 15.5 Dock click actions

`Sources/FasterSpaces/Dock/` is the New Window Plz pipeline, adapted:

- `DockEventTap` is a dedicated `.cgSessionEventTap` on its own thread.
- `DockInspector` uses `AXSelectedChildren` plus a live frame check, with a
  position fallback; AX timeout 0.25 s.
- `DockClickController` scans Dock geometry every 1.5 s, serializes actions on
  `actionQueue`, and uses `NewWindowController` / `WindowMover`.
- `AppRulesStore` persists `dockClickRules.v1` and provides a thread-safe
  snapshot for the tap. On first launch it imports
  `com.peter.newwindowplz`'s `dockClickRules.v1` (the user's old per-app
  behaviors), and `SettingsStore` imports `showWindowSnapshots` and
  `disableControlClick`. If old rules exist, Dock clicks are enabled so those
  behaviors are live. The Dock tab has an explicit import button for a manual
  re-import.
- `ControlClickFilter` is a separate HID tap that strips Control from left
  mouse events. It runs only when `dockDisableControlClick` is on.
- `WindowSpaceMove.c` is compiled to `build/WindowSpaceMove.o`; Swift reaches
  `WSMoveBridged*` through `@_silgen_name`, so no bridging header is needed.
  The C backend is WhichSpace-derived; keep its symbol scans and range checks.

Policy invariants: only running, regular apps are intercepted; system
launchers, non-running apps, Command/Option clicks, and drags pass through. A
plain click runs the app's configured action; unlisted apps and apps set to
None keep the native Dock click. Shift-click overrides to New Window and
Control-click overrides to Bring Here, including for unlisted apps; when the
requested action already matches the configured action, the result is
unchanged. Control wins if both action modifiers are held. A click is cancelled
if the pointer moves more than 10 pt or the press lasts more than 2 s.

`DockClickPolicy` is pure and covered by the `--self-test` cases. Keep the
modifier precedence there rather than duplicating it in `DockEventTap`; the tap
uses `DockClickPolicy.modifier(for:)` only to label the status message.

`DockStatusModel` is the only place the controller publishes status. Writes
from the action/scan queues are hopped to main.

### 15.6 Build and CLI

`scripts/build.sh` now:

1. compiles `Sources/FasterSpaces/Dock/WindowSpaceMove.c` with clang;
2. compiles every Swift file under `Sources/FasterSpaces/` (including `Dock/`
   and `Overlay/`);
3. copies `Resources/OverlayShaders.metal.txt` into `Contents/Resources`;
4. links the C object plus Metal/CoreText/ImageIO with the Swift binary;
5. signs and verifies as before.

Useful non-GUI commands:

```sh
"dist/Faster Spaces.app/Contents/MacOS/FasterSpaces" --self-test
"dist/Faster Spaces.app/Contents/MacOS/FasterSpaces" --finger-info
"dist/Faster Spaces.app/Contents/MacOS/FasterSpaces" --window-list
"dist/Faster Spaces.app/Contents/MacOS/FasterSpaces" --version
```

### 15.7 New URL commands

User-facing: `switch`, `window?direction=next|previous`, `previous-space`,
`settings?tab=0..4`, `diagnostics`, `onboarding`, `toggle`, `status`, `hud`,
`seek?query=...`.

Development aids: `snapshot?tab=0..4`, `hud-snapshot`, `seek-snapshot`,
`seek-commit`, `seek-close`, `ax-dump?bundle=...`, `dock`, `dock-status`,
`dock-rules`, `dock-tiles`, `add-dock-app?bundle=...&action=...`,
`click-dock?title=...`, `test-option-tab?mode=cancel|commit`,
`test-gesture?fingers=3|4&progress=0.2`, `test-seek-trigger`.

`click-dock` and the `test-*` paths post real events and can change focus. They
are for a logged-in test session, not for docs screenshots or unattended runs.
If synthetic Spaces switching stops responding after a barrage of test events,
restart the Dock (`killall Dock`) and retry; a real physical swipe is the final
check.

### 15.8 Test matrix additions

In addition to §10:

1. **Window swipe**: 3-finger Spaces still switches; 4-finger moves one window;
   a long 4-finger swipe moves several; swiping back retraces; toggle off makes
   the non-primary count inert again.
2. **Finger swap**: change the macOS Spaces setting to 4; the app shows
   Spaces 4 / Windows 3 and the gestures swap.
3. **No windows**: the non-primary swipe does nothing and does not switch
   Spaces.
3b. **Reverse window direction**: turn it on and confirm the window swipe goes
    the other way while Spaces keeps its own direction.
3c. **Raise on release**: a two-step swipe must leave the intermediate window
    in place until release, then raise only the target.
4. **Option-Tab**: open, cycle, Shift-reverse, Return commit, Escape cancel,
   Option release commit; hold Option and type other keys — they must not leak.
5. **Previous Space**: switch two Spaces, Option-backtick returns to the prior
   one; repeat returns again.
6. **Window HUD**: no screen recording; icons/titles; no stale strip after a
   rapid second gesture. With raise-on-release on, the HUD/overlay must change
   selection without raising until the release, and the final target must be
   the only activation. Turn it off and confirm the old immediate behavior.
7. **Caps Lock layer**: enable it, confirm unmapped keys pass through, add a
   mapping, use the WASD/HJKL/IJKL/home-row presets, set the target modifiers,
   clear mappings, and switch the default to "Add Hyper modifiers" to confirm
   the legacy behavior. Quick Caps tap (Escape/Caps), Shift+Caps.
8. **Presets**: shift+delete, right-command+V, Home/End, quick shift parentheses.
9. **Seek**: open with Hyper+S and ⌃⌥⌘F, type, arrows, Return clicks, Escape
   restores the target app, text in images is absent by design.
10. **Dock clicks**: default New Window, default Bring Here, and None; Shift
    opens a new window; Control brings the window here; Shift/Control on an
    unlisted app; matching modifier/action pairs; Command/Option pass-through;
    Control+Shift; picker; drag cancel. Confirm the old New Window Plz rules
    were imported and that the per-app picker still works.
11. **Permissions**: revoke Accessibility while Dock clicks and the gesture tap
    are active; both stop and recover after regrant. Launch from the `.app`, not
    a terminal.


### 15.10 Settings, onboarding, Command-Tab, and legacy import

- `SettingsView` is a compact 720×720, five-section layout (Spaces, Windows,
  Keyboard, Dock, General). The window is intentionally smaller than the old
  long page; the content scrolls inside each section.
- `OnboardingView` is a four-step wizard: welcome, Accessibility, optional
  Screen Recording with live thumbnails, and shortcut choices. It uses
  `AppUIState.onboardingStep` (no SwiftUI `@State` macros) and a fixed dark
  gradient. Screen Recording is optional and the app falls back to icons.
- `AppDelegate` conforms to `NSWindowDelegate`. While Settings, onboarding, or
  diagnostics is visible, `updateActivationPolicy()` sets
  `.regular` so the window appears in **Command-Tab**; when the last real window
  closes it returns to `.accessory`. Do not count the Metal overlay panel in
  this check: it is a nonactivating panel, not an app window.
- `AppRulesStore.importLegacyRulesIfNeeded()` reads the old
  `com.peter.newwindowplz` `dockClickRules.v1`. `SettingsStore` imports the old
  snapshot and Control-click preferences. The import is marker-guarded so it
  runs once; the Dock tab button force-merges on demand.
- The first launch imports the old rules and enables Dock clicks only when
  rules were found. A fresh install with no old app keeps Dock clicks off.
- Screen Recording status is exposed through `ScreenCaptureStatusModel`; it
  refreshes on app activation. The Settings/Onboarding grant buttons call
  `CGRequestScreenCaptureAccess` and fall back to opening System Settings.
- macOS generally does not honor a new Screen Recording grant in the running
  process. `ScreenCaptureStatusModel` sets `needsRestart` when it sees the
  false→true transition. If previews are enabled and
  `autoRestartForScreenCapture` is on, `AppDelegate` saves the visible window
  (Settings or onboarding + step), spawns `AppRelauncher` (a detached
  `sh -c 'sleep 2; open <bundle>'`), and terminates. On launch,
  `consumeRelaunchContext()` reopens Settings or resumes onboarding at the saved
  step. If automatic restart is off, the same card shows a **Restart Now**
  button. The relaunch is intentionally delayed by one second so a TCC prompt
  can finish dismissing.


### 15.11 Screen Recording relaunch and window history

- The first 2.1 build raised each window as the swipe crossed it. That changes
  WindowServer's z-order history: the windows between the original frontmost
  and the target are left in reverse order. `windowSwipeRaiseOnRelease` defaults
  to on and defers activation to `endSwipe`. Do not move that activation back
  into `swipeStep` unless the user disables the option.
- The release activation is skipped when the final index is 0 (the original
  frontmost), so swiping one step and back does not re-raise anything.
- The **Reverse window direction** toggle is `windowSwipeInvertDirection`; it is
  independent of the Spaces `invertDirection`. Both flow through
  `SwipeMath.initial` with their own flag.
- `AppRelauncher` is deliberately a detached `/bin/sh` child: calling
  `NSWorkspace.open` immediately before `NSApp.terminate` loses the relaunch
  race. The shell waits two seconds, then opens the same bundle; the old process
  terminates after 0.4 s. If you change the timing, verify the duplicate-instance
  check does not kill the new process.
- `needsRestart` is only set for a false→true transition in the current
  process. A permission granted at launch needs no restart. Turning previews on
  after the grant checks `ScreenCaptureStatusModel.needsRestart` in the settings
  sink and relaunches too.
- `consumeRelaunchContext` clears all `relaunch.*` defaults; do not leave a
  pending flag behind or the next normal launch will reopen an old window.

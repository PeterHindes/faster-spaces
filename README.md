# Faster Spaces

**Your Spaces gesture, without the slide.**

Faster Spaces is a tiny macOS menu-bar app that removes the animation from switching between Spaces. It intercepts your normal three- or four-finger horizontal swipe, suppresses the animated Dock gesture, and switches instantly through the Dock's own Spaces pipeline.

Long swipes can cross several desktops, and swiping back during the same gesture retraces them.

<img src="docs/settings.png" width="430" alt="Faster Spaces settings window">

## Features

- **Instant switching** — no slide, blur, or wallpaper pan. The switch lands in one frame.
- **Direction HUD** — an optional 0.25 s cue with two small desktop tiles sliding in the direction of travel. Each additional Space crossed during one gesture replays the motion, so a long swipe visibly steps through the desktops. Turn it off for a hard cut.
- **3 or 4 fingers, automatically** — reads the current macOS Spaces finger setting and ignores the other count. A 4-finger swipe does nothing when macOS is set to 3, and vice versa. No second gesture to configure.
- **Multi-Space swipes** — keep swiping to cross up to 8 Spaces in one gesture. Set the distance per Space to taste.
- **Bidirectional** — swipe back without lifting your fingers and the Spaces retrace. You are never locked into the first direction.
- **Menu-bar controls** — see the current Space, switch left/right, pause, or open settings.
- **Ctrl+← / Ctrl+→** — the same instant switch from the keyboard, but only while macOS still has the “Move left/right a space” shortcut enabled and assigned to those keys. Remap or disable it in System Settings and the keys pass through untouched.
- **Launch at login** — backed by a per-user LaunchAgent; enabled during onboarding and toggleable in Settings.
- **Optional Space counter** in the menu bar.
- **Trackpad haptics** — a quiet tick for each Space crossed.
- **Empty-desktop guard** — prevents macOS from yanking you to another Space after landing on an empty one.
- **Local and private** — no telemetry, no network access, no account, no keystrokes, no screenshots, and no Screen Recording permission.

## Install

**Requires macOS 13 or later.** The release is Apple Silicon (arm64), tested on macOS 27.0.1. The macOS 27+ path includes the serialized IOHID payload that the Dock validates; a legacy path is included for older releases but has not been tested as widely.

1. Download `Faster-Spaces.zip` from the [latest release](https://github.com/PeterHindes/faster-spaces/releases/latest).
2. Unzip it and drag **Faster Spaces.app** to `/Applications`.
3. The release is self-signed, not notarized. On first launch, right-click the app and choose **Open**, or clear the quarantine flag:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Faster Spaces.app"
   ```
4. Open the app, click **Grant Access…**, and enable **Faster Spaces** in **System Settings → Privacy & Security → Accessibility**.
5. Swipe between Spaces normally.

The app is a menu-bar utility (`LSUIElement`); it has no Dock icon. Look for the small split-rectangle icon in the menu bar.

## How it works

macOS has no supported switch to remove only the Spaces slide. Faster Spaces takes the route used by [WhichSpace](https://github.com/gechr/WhichSpace), [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) and [noswoosh](https://github.com/mmathys/noswoosh):

1. A `CGEventTap` watches the private Dock-control gesture stream (CGS event types 29 and 30) before the Dock sees the animated swipe. A raw-touch listener checks the actual finger count against the macOS setting, so only the configured 3- or 4-finger gesture acts.
2. Horizontal Dock swipes are swallowed. Vertical swipes for Mission Control and App Exposé are passed through untouched.
3. A complete synthetic `began` + `changed` + `ended` Dock swipe is posted with near-zero progress and a strong terminal velocity. The Dock commits the switch, but there is no distance left to animate.
4. On macOS 27, the Dock validates synthetic swipes against a serialized raw IOHID queue payload. Faster Spaces attaches that payload and pairs each control event with a companion gesture event.
5. A small, borderless HUD shows two desktop tiles sliding in the direction of the switch for 0.25 s. It is independent of the Dock and never delays or blocks the switch.

This keeps Mission Control, focus, wallpaper, full-screen apps, and the Dock's own state consistent. It does **not** disable SIP, inject code, patch the Dock, or move windows.

### Multi-Space distance

The gesture's normalized travel is tracked in both directions. The first Space moves immediately; each additional threshold crossed moves one more. Swiping back walks the count down. The default is 20% of gesture travel per Space, with a maximum of 4 Spaces per gesture (both configurable in Settings).

### Why Accessibility?

macOS only allows trusted apps to replace synthetic input. Accessibility permission is required both to read the Dock gesture stream and to post the instant replacement. The app requests nothing else. It has no network code and does not read keystrokes or screen contents.

## Maintainer documentation

Architecture, private-API invariants, TCC/signing notes, release steps, testing
matrices, and the failed approaches we deliberately removed are documented in
[MAINTAINERS.md](MAINTAINERS.md). Read it before changing the gesture pipeline.

## Build from source

Requires Xcode 27 command-line tools (`swiftc`) and macOS 27 SDK to build. No Xcode project is needed.

```sh
git clone https://github.com/PeterHindes/faster-spaces.git
cd faster-spaces
./scripts/build.sh
open "dist/Faster Spaces.app"
```

The build produces `dist/Faster Spaces.app`. It is ad-hoc signed by default; if you have a local signing identity, set `FASTERSPACES_SIGN_IDENTITY` and optionally `FASTERSPACES_SIGN_KEYCHAIN`. A stable identity keeps the Accessibility grant across rebuilds.

The source is organized as:

```
Sources/FasterSpaces/
  FasterSpacesMain.swift    app entry point
  AppDelegate.swift         status item, windows, URL commands
  SwipeInterceptor.swift    event tap, Accessibility manager, gesture state
  SpaceSwitcher.swift       SkyLight space list + synthetic Dock gesture
  SettingsStore.swift       preferences
  LaunchAtLogin.swift       per-user LaunchAgent
  Views.swift               SwiftUI settings, onboarding, diagnostics
  Log.swift                 local log + in-app diagnostics
```

### Developer URL commands

The app registers the `fasterspaces://` scheme:

```sh
open "fasterspaces://settings"
open "fasterspaces://diagnostics"
open "fasterspaces://switch?direction=right&count=2"
open "fasterspaces://status"
```

## Troubleshooting

**The app is not listed in Accessibility.** Remove any old Faster Spaces entry with the “−” button, quit and reopen the app, then click **Grant Access…** again. If you rebuilt with a different signature, use **Settings → Troubleshooting → Reset Accessibility…** (then quit/reopen).

**Swipes do nothing.** Check `~/Library/Logs/FasterSpaces.log`. A `Gesture event tap installed` line means permission and the tap are healthy. A `waiting for Accessibility` or tap-creation error means the grant did not take. Toggle the Accessibility checkbox off/on, or reset the entry.

**Spaces switch in an unexpected order.** Turn off “Automatically rearrange Spaces based on most recent use” in **System Settings → Desktop & Dock**. macOS reorders Spaces as you use them, which makes any index-based prediction less intuitive.

**Too many or too few Spaces per swipe.** Open Settings → Multiple Spaces and change **Distance per Space** or **Maximum Spaces per swipe**.

**The direction HUD is missing.** Check **Settings → Gesture → Direction HUD (0.25 s)**. The HUD is purely visual and does not need Screen Recording; if Accessibility is healthy, the switch itself should still work.

**Ctrl+←/→ does nothing.** Faster Spaces only intercepts it while the macOS “Move left/right a space” shortcut is enabled and assigned to Ctrl+←/→. Check **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**. If it is remapped or disabled, the keys are deliberately left alone.

**The animation still appears occasionally.** The first frame of a gesture is the Dock's; Faster Spaces only gets control once the gesture stream reports a direction. If it is consistently animated, check that Accessibility is still enabled and that no other Spaces utility is intercepting the same events.

## Uninstall

1. Turn off **Launch at Login** in Settings.
2. Quit Faster Spaces.
3. Drag `/Applications/Faster Spaces.app` to the Trash.
4. Remove Faster Spaces from **System Settings → Privacy & Security → Accessibility**.
5. If needed, remove `~/Library/LaunchAgents/com.fasterplz.fasterspaces.login.plist`.

## Compatibility and caveats

- Tested on **macOS 27.0.1 (26A434), Apple Silicon**.
- The implementation relies on undocumented `CGEventField` indices, the Dock's private gesture event types, and (on macOS 27) a byte-exact IOHID payload layout. Apple can change these in any release.
- A future macOS update may silently stop the synthetic switches. The diagnostics log is the first place to look.
- The release is not notarized; macOS will warn on first launch. Build from source if you prefer.
- Multi-display behavior follows the Dock: a swipe applies to the display under the pointer, not the display with keyboard focus.

## Credits

This project stands on the work of people who reverse-engineered macOS Spaces and the Dock gesture pipeline:

- [WhichSpace](https://github.com/gechr/WhichSpace) — menu-bar Spaces utility and synthetic Dock-swipe technique.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) — near-zero-progress gesture and three-phase switch.
- [noswoosh](https://github.com/mmathys/noswoosh) — macOS 27 IOHID payload, companion events, multi-display routing, and the empty-desktop guard.
- [iss](https://github.com/joshuarli/iss) — original macOS 27 payload reverse engineering and swipe interception.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for license texts.

## License

MIT. See [LICENSE](LICENSE).

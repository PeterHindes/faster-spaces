#!/bin/bash
# Build Faster Spaces into a self-contained .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/Faster Spaces.app"
BIN="$APP/Contents/MacOS/FasterSpaces"
BUILD="$ROOT/build"
CACHE="$BUILD/modulecache"

mkdir -p "$BUILD" "$CACHE" "$ROOT/dist"

echo "==> Compiling"
# Kill an old instance so the linker can replace the binary cleanly.
pkill -x FasterSpaces 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# WhichSpace's window-to-Space move backend (MIT). Compiled as C so the
# bridged Objective-C runtime lookup and retain/release are explicit. Swift
# reaches the global WSMove* symbols through @_silgen_name.
echo "==> Compiling window-space backend"
clang -O2 -target arm64-apple-macos13.0 \
    -c Sources/FasterSpaces/Dock/WindowSpaceMove.c \
    -o "$BUILD/WindowSpaceMove.o"

SWIFT_SOURCES=$(find Sources/FasterSpaces -name '*.swift' | sort)

swiftc \
    -swift-version 5 \
    -O \
    -module-cache-path "$CACHE" \
    -target arm64-apple-macos13.0 \
    -F /System/Library/PrivateFrameworks \
    -framework SkyLight \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework ServiceManagement \
    -framework Metal \
    -framework MetalKit \
    -framework CoreText \
    -framework ImageIO \
    $SWIFT_SOURCES \
    "$BUILD/WindowSpaceMove.o" \
    -o "$BIN"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/OverlayShaders.metal.txt" "$APP/Contents/Resources/OverlayShaders.metal.txt"
chmod +x "$BIN"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Signing: use the local development identity when present so the
# Accessibility grant survives rebuilds (TCC keys on the certificate root,
# not the binary hash). Fall back to ad-hoc for a fresh checkout.
SIGN_IDENTITY="${FASTERSPACES_SIGN_IDENTITY:-}"
SIGN_KEYCHAIN="${FASTERSPACES_SIGN_KEYCHAIN:-$ROOT/build/signing/dev.keychain}"
if [ -z "$SIGN_IDENTITY" ] && [ -f "$SIGN_KEYCHAIN" ]; then
    SIGN_IDENTITY="Faster Spaces Development"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing as $SIGN_IDENTITY"
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
    if [ -f "$SIGN_KEYCHAIN" ]; then
        if [ -f "$ROOT/build/signing/.password" ]; then
            security unlock-keychain -p "$(cat "$ROOT/build/signing/.password")" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
        fi
        SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
    fi
    codesign "${SIGN_ARGS[@]}" "$BIN" >/dev/null
    codesign "${SIGN_ARGS[@]}" "$APP" >/dev/null
else
    echo "==> Signing (ad-hoc)"
    codesign --force --sign - --timestamp=none "$BIN" >/dev/null
    codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi
codesign --verify --strict "$APP"

echo "==> Built $APP"
du -sh "$APP"

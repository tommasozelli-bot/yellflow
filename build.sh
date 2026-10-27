#!/usr/bin/env bash
#
# Builds "Yell Flow.app" by hand (no Xcode required — Command Line Tools only)
# and produces a shareable zip. Everything heavy happens in /tmp to avoid
# hangs when the project lives on a synced Desktop/Dropbox folder.
#
set -euo pipefail

APP_NAME="Yell Flow"
BUNDLE_ID="com.yellflow.app"
VERSION="2.3"
MIN_OS="13.3"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="/tmp/yellflow-stage"
BUILD="/tmp/yellflow-build"
CACHE="$HOME/.cache/yellflow"
DIST="$HERE/dist"
# large-v3-turbo q5_0: ~547 MB (vs 466 MB of the old ggml-small) but a whole
# class better at Italian and at English terms embedded in Italian speech.
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
MODEL="$CACHE/ggml-large-v3-turbo-q5_0.bin"
MODEL_MIN_BYTES=500000000
# Core ML encoder (Neural Engine): halves the per-window cost (0.7 s vs 1.5 s on
# Metal, measured on an M3). whisper.cpp picks it up by name next to the model.
COREML_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip"
COREML_ZIP="$CACHE/ggml-large-v3-turbo-encoder.mlmodelc.zip"
COREML_DIR="$CACHE/ggml-large-v3-turbo-encoder.mlmodelc"
COREML_MIN_BYTES=1100000000
# Silero voice-activity detector (~1 MB): pieces with no speech never reach
# Whisper, which on silence writes "Grazie." / "Grazie a tutti".
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
VAD="$CACHE/ggml-silero-v5.1.2.bin"
FRAMEWORK_SRC="$HERE/vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework"

echo "▸ 1/6  Compiling (release, universal arm64+x86_64)…"
# No full Xcode here (CLT only), so SwiftPM's --arch multi-build is unavailable:
# build each slice with --triple and merge with lipo.
swift build -c release --triple arm64-apple-macosx13.3  --package-path "$HERE" --scratch-path "$BUILD/arm64"
swift build -c release --triple x86_64-apple-macosx13.3 --package-path "$HERE" --scratch-path "$BUILD/x86_64"
mkdir -p "$BUILD/universal"
BIN="$BUILD/universal/YellFlow"
lipo -create "$BUILD/arm64/release/YellFlow" "$BUILD/x86_64/release/YellFlow" -output "$BIN"
lipo -info "$BIN"

echo "▸ 2/6  Fetching model (large-v3-turbo q5_0, ~547 MB)…"
mkdir -p "$CACHE"
if [[ ! -f "$MODEL" || "$(stat -f%z "$MODEL")" -lt "$MODEL_MIN_BYTES" ]]; then
    curl -L --fail -o "$MODEL" "$MODEL_URL"
else
    echo "        cached: $MODEL"
fi

echo "▸ 2b/6 Fetching Core ML encoder (~1.17 GB)…"
# YELLFLOW_COREML=0 builds a Metal-only app (550 MB instead of 1.7 GB, ~2x slower per window).
if [[ "${YELLFLOW_COREML:-1}" == "0" ]]; then
    echo "        skipped (YELLFLOW_COREML=0)"
    COREML_DIR=""
elif [[ ! -d "$COREML_DIR" ]]; then
    if [[ ! -f "$COREML_ZIP" || "$(stat -f%z "$COREML_ZIP")" -lt "$COREML_MIN_BYTES" ]]; then
        curl -L --fail -o "$COREML_ZIP" "$COREML_URL"
    fi
    ( cd "$CACHE" && unzip -q -o "$COREML_ZIP" && rm -rf __MACOSX )
else
    echo "        cached: $COREML_DIR"
fi

echo "▸ 2c/6 Fetching Silero VAD (~1 MB)…"
if [[ ! -f "$VAD" || "$(stat -f%z "$VAD")" -lt 800000 ]]; then
    curl -L --fail -o "$VAD" "$VAD_URL"
else
    echo "        cached: $VAD"
fi

echo "▸ 3/6  Assembling app bundle…"
APP="$STAGE/$APP_NAME.app"
rm -rf "$STAGE" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/YellFlow"
cp "$MODEL" "$APP/Contents/Resources/whisper-model.bin"
cp "$VAD" "$APP/Contents/Resources/whisper-vad.bin"
[[ -n "$COREML_DIR" ]] && cp -R "$COREML_DIR" "$APP/Contents/Resources/whisper-model-encoder.mlmodelc"
cp -R "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/whisper.framework"
[[ -f "$HERE/assets/AppIcon.icns" ]] && cp "$HERE/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>YellFlow</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Yell Flow listens to your microphone while you hold the dictation key, and transcribes it on-device.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▸ 4/6  Fixing rpath so the app finds its framework…"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/YellFlow" 2>/dev/null || true

echo "▸ 5/6  Code signing…"
# Prefer the stable self-signed identity (see setup-signing.sh) so macOS permission
# grants survive rebuilds. Fall back to ad-hoc if it isn't set up.
SIGN_ID="-"
SIGN_KEYCHAIN="$HOME/Library/Keychains/yellflow-signing.keychain-db"
# The dedicated keychain must NOT stay in the user's search list: left there (and
# locked) it makes every app on the Mac prompt for the login password in a loop
# (24/08/2026). So it is added for the few seconds of signing only, unlocked, and
# the list is restored right after — also on failure, via the trap.
restore_keychain_list() { security list-keychains -d user -s login.keychain-db; }
if security find-identity "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "Yell Flow Local"; then
    security unlock-keychain -p yellflow "$SIGN_KEYCHAIN" 2>/dev/null || true
    trap restore_keychain_list EXIT
    security list-keychains -d user -s login.keychain-db "$SIGN_KEYCHAIN"
    SIGN_ID="Yell Flow Local"
    echo "        stable identity: $SIGN_ID (permissions will persist)"
else
    echo "        ad-hoc (run ./setup-signing.sh once for persistent permissions)"
fi
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/MacOS/YellFlow"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
restore_keychain_list
trap - EXIT

echo "▸ 6/6  Installing + zipping…"
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" "/Applications/$APP_NAME.app"

mkdir -p "$DIST"
# Delivery folder: the app + a README for whoever receives the zip.
DELIVERY="$STAGE/$APP_NAME"
rm -rf "$DELIVERY" && mkdir -p "$DELIVERY"
mv "$APP" "$DELIVERY/$APP_NAME.app"
cp "$HERE/README.md" "$DELIVERY/README.txt"
rm -f "$DIST/$APP_NAME.zip"
# ditto preserves the framework's symlinks and signatures inside the zip.
( cd "$STAGE" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$DIST/$APP_NAME.zip" )

echo ""
echo "✅ Done."
echo "   App installed: /Applications/$APP_NAME.app"
echo "   Shareable zip: $DIST/$APP_NAME.zip  ($(du -h "$DIST/$APP_NAME.zip" | cut -f1))"
echo ""
echo "   First launch: right-click the app → Open (unsigned app, one-time)."
echo "   Then grant Microphone, Accessibility and Input Monitoring when asked."

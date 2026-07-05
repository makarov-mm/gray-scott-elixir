#!/bin/zsh
# build.zsh — build GrayScottMetal.app from the command line, no Xcode project.
# Run from the directory with the sources:
#   client/ $ ./build.zsh
# Requires Xcode or Command Line Tools (xcrun, swiftc, metal).

set -euo pipefail

APP_NAME="GrayScottMetal"
BUNDLE_ID="com.makarov.grayscottmetal"
MIN_MACOS="13.0"
ARCH="$(uname -m)"                       # arm64 on Apple Silicon
BUILD="build"
APP="$BUILD/$APP_NAME.app"

echo "==> cleaning"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling Metal shaders"
if xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    xcrun -sdk macosx metal -c Shaders.metal -o "$BUILD/Shaders.air"
    xcrun -sdk macosx metallib "$BUILD/Shaders.air" -o "$APP/Contents/Resources/default.metallib"
    # the name default.metallib matters: device.makeDefaultLibrary() looks for it
else
    echo "    metal compiler not found (Command Line Tools only) —"
    echo "    shipping Shaders.metal as source, compiled at runtime"
    cp Shaders.metal "$APP/Contents/Resources/Shaders.metal"
fi

echo "==> compiling Swift ($ARCH, macOS $MIN_MACOS+)"
# Newer SDKs implement SwiftUI property wrappers as macros; Xcode passes
# the plugin paths automatically, bare swiftc does not. Add them if present.
SDK_PATH="$(xcrun --show-sdk-path)"
PLUGIN_FLAGS=()
for p in "$SDK_PATH/usr/lib/swift/host/plugins" \
         "$(xcrun --find swiftc | sed 's|/bin/swiftc||')/lib/swift/host/plugins"; do
    [ -d "$p" ] && PLUGIN_FLAGS+=(-plugin-path "$p")
done

swiftc -O \
    -parse-as-library \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    "${PLUGIN_FLAGS[@]}" \
    ./*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"
# -parse-as-library is required: without it swiftc treats the file as a
# script and the @main attribute fails to compile

echo "==> writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>LSMinimumSystemVersion</key>  <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc code signing"
codesign --force --deep -s - "$APP"

echo "==> done: $APP"
echo "    run the Elixir server first, then:  open $APP"

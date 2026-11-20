#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DroidDrop"
BUILD_DIR="$PROJECT_DIR/.build-clt"
MOD_CACHE="$BUILD_DIR/ModuleCache"
APP_BUNDLE="$PROJECT_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"

echo "Building ${APP_NAME} (${TARGET})..."
mkdir -p "$BUILD_DIR" "$MOD_CACHE"

# Auto-workaround for macOS CommandLineTools duplicate SwiftBridging modulemap bug
VFS_FLAGS=()
CLT_SWIFT_INC="/Library/Developer/CommandLineTools/usr/include/swift"
if [[ -f "$CLT_SWIFT_INC/module.modulemap" && -f "$CLT_SWIFT_INC/bridging.modulemap" ]]; then
    EMPTY_MAP="$BUILD_DIR/empty.modulemap"
    VFS_YAML="$BUILD_DIR/clt_vfs.yaml"
    echo "// Shadows duplicate CLT module.modulemap" > "$EMPTY_MAP"
    cat > "$VFS_YAML" << EOF
{
  "version": 0,
  "roots": [
    {
      "name": "$CLT_SWIFT_INC",
      "type": "directory",
      "contents": [
        {
          "name": "module.modulemap",
          "type": "file",
          "external-contents": "$EMPTY_MAP"
        }
      ]
    }
  ]
}
EOF
    VFS_FLAGS=(-Xcc -ivfsoverlay -Xcc "$VFS_YAML" -vfsoverlay "$VFS_YAML")
fi

# 1. Build DroidDropCore module
swiftc \
    -O \
    -whole-module-optimization \
    -swift-version 5 \
    -target "$TARGET" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$MOD_CACHE" \
    "${VFS_FLAGS[@]}" \
    -parse-as-library \
    -module-name DroidDropCore \
    -emit-module \
    -emit-module-path "$BUILD_DIR/DroidDropCore.swiftmodule" \
    -emit-object \
    -o "$BUILD_DIR/DroidDropCore.o" \
    "$PROJECT_DIR/Sources/DroidDropCore/"*.swift

# 2. Build DroidDrop executable linking DroidDropCore
swiftc \
    -O \
    -whole-module-optimization \
    -swift-version 5 \
    -target "$TARGET" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$MOD_CACHE" \
    "${VFS_FLAGS[@]}" \
    -parse-as-library \
    -I "$BUILD_DIR" \
    -framework SwiftUI \
    -framework AppKit \
    -framework UniformTypeIdentifiers \
    -framework Combine \
    "$BUILD_DIR/DroidDropCore.o" \
    "$PROJECT_DIR/Sources/DroidDrop/"*.swift \
    -o "$BUILD_DIR/${APP_NAME}"

echo "Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/${APP_NAME}" "$MACOS_DIR/${APP_NAME}"
chmod +x "$MACOS_DIR/${APP_NAME}"

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DroidDrop</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.trader.droiddrop</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DroidDrop</string>
    <key>CFBundleDisplayName</key>
    <string>DroidDrop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Generate a crisp native macOS app icon (.icns) using AppKit + iconutil
ICONSET_TMP="$(mktemp -d)"
ICONSET_DIR="$ICONSET_TMP/AppIcon.iconset"
ICON_SRC="$ICONSET_TMP/make_icon.swift"
ICON_BIN="$ICONSET_TMP/make_icon"
mkdir -p "$ICONSET_DIR"

cat > "$ICON_SRC" << 'SWIFT'
import AppKit
import Foundation

let iconsetPath = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func renderIcon(px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    let grad = NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.48, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.06, green: 0.45, blue: 0.62, alpha: 1.0)
    )
    grad?.draw(in: bg, angle: -45)

    NSColor.white.withAlphaComponent(0.22).setStroke()
    bg.lineWidth = max(1, s * 0.015)
    bg.stroke()

    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "arrow.left.arrow.right.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
    {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        NSColor.white.set()
        let symRect = NSRect(origin: .zero, size: sym.size)
        sym.draw(in: symRect)
        symRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let drawRect = NSRect(
            x: (s - sym.size.width) / 2,
            y: (s - sym.size.height) / 2,
            width: sym.size.width,
            height: sym.size.height
        )
        tinted.draw(in: drawRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (px, filename) in sizes {
    if let data = renderIcon(px: px) {
        let out = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
        try? data.write(to: out)
    }
}
SWIFT

if swiftc -swift-version 5 -target "$TARGET" -sdk "$SDK_PATH" -module-cache-path "$MOD_CACHE" "${VFS_FLAGS[@]}" -framework AppKit "$ICON_SRC" -o "$ICON_BIN" \
    && "$ICON_BIN" "$ICONSET_DIR" \
    && iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns" 2>/dev/null; then
    echo "Generated AppIcon.icns"
fi
rm -rf "$ICONSET_TMP"

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Done! Built: $APP_BUNDLE"
echo "Launch with: open \"$APP_BUNDLE\""

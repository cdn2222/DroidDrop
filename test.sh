#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build-clt"
MOD_CACHE="$BUILD_DIR/ModuleCache"
SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"

mkdir -p "$BUILD_DIR" "$MOD_CACHE"

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

swiftc \
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

swiftc \
    -swift-version 5 \
    -target "$TARGET" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$MOD_CACHE" \
    "${VFS_FLAGS[@]}" \
    -I "$BUILD_DIR" \
    "$BUILD_DIR/DroidDropCore.o" \
    "$PROJECT_DIR/Tests/RunTests.swift" \
    -o "$BUILD_DIR/run_tests"

"$BUILD_DIR/run_tests"

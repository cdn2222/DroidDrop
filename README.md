# DroidDrop — Simple ADB File Manager for macOS

A lightweight native macOS file manager (SwiftUI + AppKit) for copying, browsing, and deleting files to and from your Android phone over **ADB** (USB or Wi-Fi).

## Why ADB instead of MTP?
macOS has no native MTP driver and third-party MTP clients frequently stall, drop large transfers, or conflict with Photos/Image Capture. **ADB** is faster, more reliable, supports recursive folder transfers, live progress reporting, and works over both USB and Wi-Fi.

## Features
- **Two-way Drag & Drop**:
  - Drag files or folders **from Finder (or the built-in Mac pane)** onto the Android pane (or directly onto a subfolder) to copy to your phone (`adb push`).
  - Drag files or folders **from the Android pane directly to Finder / Desktop** (or to the Mac pane) to copy to your Mac (`adb pull`).
- **Dual-Pane or Single-Pane**: Toggle the Mac pane (`⌥⌘M`) to work side-by-side or Android-only with Finder.
- **Full File Actions**: Copy, Delete (with confirmation), New Folder (`⇧⌘N`), Rename, Quick Open on Mac (double-click any file), Filter/Search, Hidden files toggle (`⇧⌘.`), Clickable breadcrumbs & direct path entry.
- **Live Progress & Cancel**: Real-time transfer progress bar with cancel support.
- **Auto-Discovery**: Automatically finds `adb` (including `~/Library/Android/sdk/platform-tools/adb` and Homebrew) and auto-detects connected phones, plus optional **Wi-Fi ADB** (`ip:port`) in the gear menu.

## Run
Open the pre-built app bundle:
```bash
open DroidDrop.app
```

## Rebuild & Test
```bash
./test.sh
./build.sh
```

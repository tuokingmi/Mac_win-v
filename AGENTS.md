# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build

This is a native macOS SwiftUI app. Open `ClipboardMenuBar.xcodeproj` in Xcode or build from the command line:

```bash
xcodebuild -project ClipboardMenuBar.xcodeproj -scheme Mac_win+v -configuration Debug build
```

### Single-App Dev Workflow

To avoid duplicate app instances, duplicate Accessibility permission prompts, split clipboard history, and Launchpad confusion:

- Do not directly run `DerivedData/.../Mac_win+v.app`.
- After rebuilding, replace `/Applications/Mac_win+v.app` with the newly built app, then launch only `/Applications/Mac_win+v.app`.
- If an old `Mac_win+v` or legacy `ClipboardMenuBar` process is running, stop it before replacing the app.
- Treat `/Applications/Mac_win+v.app` as the only app the user should ever interact with during development and testing.

Typical flow after a rebuild:

```bash
pkill -f 'Mac_win+v.app/Contents/MacOS/Mac_win+v' || true
pkill -f 'ClipboardMenuBar.app/Contents/MacOS/ClipboardMenuBar' || true
rm -rf /Applications/Mac_win+v.app
ditto ~/Library/Developer/Xcode/DerivedData/ClipboardMenuBar-*/Build/Products/Debug/Mac_win+v.app /Applications/Mac_win+v.app
open /Applications/Mac_win+v.app
```

No package manager dependencies — the project uses only Apple frameworks (SwiftUI, SwiftData, AppKit, Carbon, CryptoKit, ServiceManagement).

- Deployment target: macOS 15.0
- Swift 5
- Bundle ID: `com.example.Mac-win-v`

## Architecture

Mac_win+v is a menu-bar-only clipboard history manager (LSUIElement = true). It runs as a status bar item and shows a floating panel for selecting past clipboard entries.

### Core flow

1. **ClipboardMonitor** polls `NSPasteboard.general` every 0.25s. On external change, it records the detection time, hashes the content (SHA256), reserves a capture in `ClipboardStore`, then commits text immediately or offloads image processing to a background task.
2. **ClipboardStore** persists items via SwiftData (`ClipboardItem` model). It deduplicates by comparing the signature of the latest item, tracks in-flight captures, and keeps all next-open promotion state in memory only.
3. **PanelController** owns the panel session lifecycle. It consumes eligible next-open promotions only when the panel transitions from hidden to visible, keeps that active snapshot stable for the session, and clears or requeues unfinished in-flight image promotions on every close path.
4. **PasteService** builds a paste plan, writes selected content to the system pasteboard, records internal pasteboard changeCounts, then uses AX insertion or synthesizes Cmd+V via CGEvent. This requires Accessibility permission for automatic paste.
5. **HotKeyManager** registers a global Option+V hotkey via Carbon EventHotKey API to toggle the panel.

### Key design details

- **Signature-based dedup**: `ClipboardMonitor` computes SHA256 signatures with a "text-" or "image-" prefix. If the latest stored item has the same signature, a new model is not created; that item gets a fresh next-open promotion window.
- **Next-open temporary promotion**: Each external copy has its own `copiedAt` and strict 3-minute eligibility window. Eligible records are promoted above permanent pinned items only on the next hidden-to-visible panel open, and opening once consumes the promotion. Copies made while the panel is visible belong to the next session.
- **Pasteboard suppression**: App-internal writes are suppressed by the final `NSPasteboard.changeCount`, not by content signature. Internal single or batch paste writes must never create history or refresh a promotion.
- **Image storage**: `ImageStorage` saves clipboard images as PNG files in `~/Library/Application Support/<bundleID>/Images/`. Each `ClipboardItem` stores only the relative filename; preview thumbnails (120px max) are stored inline as `previewData`.
- **Rename migration**: On first launch with Bundle ID `com.example.Mac-win-v`, the app copies `ClipboardHistory.store`, `-wal`, `-shm`, and `Images/` from the old `com.example.ClipboardMenuBar` application support directory if the new store does not exist. The old directory is left in place.
- **Panel positioning**: `PanelController` uses a non-activating `NSPanel` (HUD style, statusBar level) that floats above all windows and closes on resign-key. It remembers `targetApplication` before showing so it can re-activate it after paste.
- **Keyboard navigation and multi-select**: `ClipboardListView` embeds a `KeyView` (NSViewRepresentable) as first responder to handle arrow keys (↑↓), V key-down/up for temporary click-to-select mode, Enter (paste), and Escape (close). Holding V while clicking a row toggles multi-selection; Enter or the “粘贴 N 项” button pastes selected items in current display order.
- **Pin support**: Items can be pinned; pinned items sort before unpinned and are excluded from clear/trim operations. Max 100 unpinned items.

### Services singleton

`AppServices` (singleton, `@MainActor`) owns the entire object graph: `ModelContainer`, `ClipboardStore`, `PanelController`, `ClipboardMonitor`, `HotKeyManager`. It also manages system state polling (accessibility permission, launch-at-login via SMAppService) on a 1-second timer.

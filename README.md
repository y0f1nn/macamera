# Camera — macOS Camera App

A macOS camera app that replicates the iOS Camera UI/UX, built with SwiftUI and AVFoundation.

## Features

- **Capture Modes**: Photo, Video, Timelapse, Slo-Mo, HDR, QR Code Scanner
- **Video Recording**: Record video with audio, saved as .mov to Photos library
- **Timelapse**: Records video and speeds it up 8x in post-processing
- **Slo-Mo**: Captures at the highest frame rate the camera supports
- **HDR**: Maximum quality photo capture with best tone mapping
- **QR Code Scanner**: Real-time QR code detection with copy/open actions
- **Photos Integration**: Auto-saves photos as HEIC and videos as MOV to your Photos library
- **Thumbnail**: Shows most recent photo or video from Photos; tapping opens Photos app
- **Mirror / Flip**: Toggle horizontal flip on preview and captured photos
- **Center Stage**: Toggle hardware face-tracking on supported cameras (Continuity Camera)
- **Continuity Camera**: Auto-detects and prioritises iPhone cameras connected via Continuity
- **Photo Timer**: Countdown timer (3s / 10s) with large on-screen digits
- **Screen Flash**: White flash effect on photo capture
- **Camera Switching**: Switch between multiple connected cameras
- **Keyboard**: Press **Space** to capture photo or start/stop recording

## Requirements

- macOS 13.0+
- Xcode Command Line Tools (`xcode-select --install`)

## Build & Run

```zsh
./build.sh
open build/Camera.app
```

If Gatekeeper blocks the app:

```zsh
xattr -cr build/Camera.app
```

## Create DMG for Distribution

```zsh
./package.sh
```

This builds the app, creates a styled DMG with Camera.app and Applications shortcut for drag-install, and outputs:

```
build/Camera.dmg
```

Recipients open the DMG, drag Camera.app to Applications, then run:

```zsh
xattr -cr /Applications/Camera.app
```

For proper distribution without Gatekeeper warnings, you need an Apple Developer account ($99/year) to code-sign with a Developer ID and notarize the app.

## Project Structure

```
Camera/
├── Camera/
│   ├── Sources/
│   │   ├── AppEntry.swift          # @main SwiftUI App + AppDelegate
│   │   ├── CaptureMode.swift       # Capture mode enum (Photo, Video, Timelapse, etc.)
│   │   ├── CameraManager.swift     # AVFoundation session, photo/video capture, modes
│   │   ├── CameraPreview.swift     # NSViewRepresentable preview layer
│   │   └── ContentView.swift       # Full UI: mode selector, shutter, top bar, overlays
│   ├── Resources/
│   │   └── Assets.xcassets/        # App icon asset catalog
│   ├── Info.plist                  # Camera, microphone, Photos usage descriptions
│   └── Camera.entitlements         # Sandbox + camera + audio + Photos entitlements
├── build/                          # Output directory (Camera.app, Camera.dmg)
├── build.sh                        # Build script — compiles and signs Camera.app
├── package.sh                      # Package script — creates Camera.dmg
└── README.md
```

## Entitlements

| Entitlement | Purpose |
|---|---|
| `com.apple.security.app-sandbox` | App Sandbox |
| `com.apple.security.device.camera` | Camera access |
| `com.apple.security.device.audio-input` | Microphone for video recording |
| `com.apple.security.files.user-selected.read-write` | File access via save panels |
| `com.apple.security.personal-information.photos-library` | Read/write Photos library |

## Photos

- **Photos** are saved as HEIC (falls back to JPEG) to your Photos library
- **Videos** are saved as MOV to your Photos library
- **Timelapse** videos are sped up 8x before saving
- The thumbnail in the bottom-left shows the most recent photo or video and updates automatically

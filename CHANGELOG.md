# Changelog

[0.0.17] - 2026.03.09
- Added support for noise suppression on Android and iOS.

[0.0.16] - 2026.02.05
- Resolved an audio distortion issue (chipmunk effect) occurring with Bluetooth output devices such as AirPods.
- Fixed a Windows build error affecting Flutter desktop builds.

[0.0.15] - 2026.01.20
- Removed usage of non-public iOS APIs to ensure App Store compliance and improve production stability.

[0.0.14] - 2026.01.06
- Resolved an issue with switching audio output devices on iOS.

[0.0.13] - 2025.12.29
- Fixed Internal Bug

[0.0.12] - 2025.12.29
- Refactored the `startCaptureWith` logic and introduced OS-specific capture handling to ensure correct video resolution behavior on iOS.


[0.0.11] - 2025.09.15
- Introduced screen share audio support for Android devices.
- Updated the Android version.
- Enabled background camera access on iOS for Picture-in-Picture (PiP) mode.
- Replaced deprecated `onSurfaceDestroyed` in `SurfaceTextureRenderer` with `onSurfaceCleanup`.

[0.0.10] - 2025.05.23
- Fixed an issue of deadlock happening when creating a frame cryptor on iOS/macOS.

[0.0.9] - 2025.05.16
- fixed iOS Virtual Background Issue

[0.0.8] - 2025.04.08
- fixed MediaStream Dispose crash

[0.0.7] - 2025.03.31
- fixed windows crash

[0.0.6] - 2025.03.04
- get remote participent's track from the stream id.

[0.0.5] - 2025.02.24
- Dependencies updated to latest version.

[0.0.4] - 2024.10.18
- Dependencies updated to latest version.

[0.0.3] - 2024.07.17
[0.0.2] - 2024.07.17

- Windows Support Fix

[0.0.1] - 2024.07.17

- Initial release.

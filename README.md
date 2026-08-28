# Brightness Control

Native macOS app for reading and adjusting display brightness. It opens a
regular window and also provides a menu bar brightness control.

## Run During Development

```bash
swift run BrightnessControlApp
```

## Build App Bundle

```bash
./build_app.sh
open ".build/release/Brightness Control.app"
```

The build script embeds `Resources/AppIcon.icns` into the generated app bundle
and applies an ad-hoc signature. To build a universal app for both Apple Silicon
and Intel Macs:

```bash
./build_app.sh --arch arm64 --arch x86_64
open ".build/apple/Products/Release/Brightness Control.app"
```

`APP_VERSION` and `APP_BUILD_NUMBER` can be set to override the values embedded
in `Info.plist`.

## Automated macOS Builds

The `Build macOS App` GitHub Actions workflow runs the core tests and creates a
universal, ad-hoc-signed app archive on every push to `main`, pull request, and
manual run. Download `Brightness-Control-macOS-universal` from the workflow run's
Artifacts section.

Pushing a version tag also creates or updates a GitHub Release and attaches the
app archive and its SHA-256 checksum:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The automated build is not notarized with an Apple Developer ID. After
downloading it, macOS may require the first launch through Control-click > Open.

## Behavior

- Internal display brightness uses Apple's `DisplayServices` API for writes.
- Internal display status reads `corebrightnessdiag status-info`.
- External display detection uses `system_profiler SPDisplaysDataType -json`.
- External brightness control uses `m1ddc` first, then `ddcctl` when installed.
- External privacy power-off uses `m1ddc display <n> set standby 5` when
  available, with the app's built-in DDC/CI DPMS writer as a fallback. It does
  not use `displayplacer`.
- Display state refreshes automatically on launch, app activation, screen
  changes, wake/session events, and a short background interval. The app does
  not expose a manual refresh button.

## Tests

The installed Command Line Tools environment does not include `XCTest` or Swift
Testing, so this package uses a small executable test runner:

```bash
swift run BrightnessControlCoreTestRunner
```
# mac_brightness_control

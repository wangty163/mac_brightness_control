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

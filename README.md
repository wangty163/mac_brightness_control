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
- Privacy Mode also offers a one-shot action that powers off the external
  display once without entering the maintained Privacy Mode state, so manually
  waking the display does not trigger another power-off.
- Lid Sleep Protection registers a protected `SMAppService` launch daemon and
  requires approval in System Settings before external power-off. The daemon
  holds macOS `SleepDisabled` only while an authenticated app session needs it,
  continuously verifies the state, survives daemon restarts, and restores normal
  lid sleep after release, app exit, or connection loss. Launch daemons require a signed,
  notarized application bundle for distribution.

For a local package, `build_app.sh` uses ad-hoc signing by default; the
installer pins that exact local build's designated requirement and places
the daemon executable in `/Library/PrivilegedHelperTools`. A normal
`SMAppService` install fails closed without either that pinned requirement or a
Team ID. Set `BRIGHTNESS_CODE_SIGN_IDENTITY` to a Developer ID Application
identity and notarize the bundle before distribution.

Install a local build with:

```bash
./scripts/install_local_root.sh ".build/release/Brightness Control.app"
```

The script verifies and stages the app in `/private/tmp` before requesting
administrator authentication, so macOS Documents privacy does not block the
privileged installer. Use `--preflight` to validate the same staging path
without installing.

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

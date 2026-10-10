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

Multi-architecture `--arch` builds require full Xcode selected with
`xcode-select`. On a Command Line Tools-only machine, omit `--arch` for a local
current-architecture build or use the GitHub Actions universal artifact.

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
- Virtual displays identified by the `unkn/virt` vendor/product pair are excluded
  from hardware controls and DDC indices. Privacy actions are unavailable when
  no physical or previously known external display is available.
- Packaged Apple Silicon builds use the bundled `BrightnessControlDDC` tool
  (a pinned, hardened m1ddc source build) for external brightness and power.
  This avoids the older Homebrew tool's crashes when display metadata disappears
  after power-off. See `Vendor/m1ddc/README.md` for provenance and local changes.
- Power-off sends DPMS once; a crashed write is not replayed. Apple Silicon does
  not attempt the incompatible legacy IOFramebuffer fallback. Other builds keep
  the existing system m1ddc/ddcctl and legacy DDC behavior.
- A powered-off monitor may stop accepting DDC entirely; wake it with its power
  button when necessary. The app does not guarantee automatic external wake.
- Privacy Mode also offers a one-shot action that powers off the external
  display once without entering the maintained Privacy Mode state, so manually
  waking the display does not trigger another power-off. With no external
  display connected, the one-shot action dims the internal display once instead.
- Privacy Mode can stay enabled with only the internal display connected. In
  that case it keeps the internal display dimmed and does not start lid-sleep
  protection because no external display is being powered off.
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
./scripts/test_ddc.sh
```

## Diagnostics in a macOS agent sandbox

Observed in this repository on macOS 26.5.1 on 2026-10-08:

- A sandboxed `system_profiler SPDisplaysDataType -json` returned the GPU but
  omitted its connected displays, while `pgrep` could not access the process
  list. The same queries with host authorization found the physical monitor and
  running app. An empty sandbox result is not evidence that no screen is attached;
  use an authorized host query to establish the hardware and running binary.
- Swift compilation first failed to write its Clang module cache, then printed
  an SDK/compiler incompatibility diagnostic. A host-authorized build using the
  same toolchain passed that stage. Check the first cache/permission error before
  replacing the SDK; `--disable-sandbox` does not remove the parent agent sandbox.
- The local installer retains app backups with the same bundle identifier.
  Native UI selection by bundle identifier was ambiguous; selecting the full
  installed `.app` path resolved it. Compare installed/build executable hashes
  and the UI's backend name to distinguish the running app from a local build.

These observations apply to the agent sandbox and local installer layout, not
all macOS shells. Recheck after changes to the sandbox, toolchain, OS or installer.
Hardware-free DDC regressions and successful reads while a monitor is on do not
verify physical power-off or wake. Record manual wake separately from a successful
software wake; the 2026-10-08 repair was installed and read-verified without a
second physical power-off test.
# mac_brightness_control

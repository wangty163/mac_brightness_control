# Native Modern UI and App Icon Design

## Goal

Refresh Brightness Control with a more modern native macOS interface and add a proper application icon, without changing display detection, brightness setting, privacy mode, or external power-off behavior.

## Selected Direction

Use the native modern macOS style:

- SwiftUI controls and SF Symbols remain the visual base.
- The menu bar panel stays compact and task-focused.
- The detail window becomes a calmer utility panel with clearer grouping.
- The app icon is custom, but consistent with macOS app icon conventions.

## User Experience

### Menu Bar Panel

The menu panel should feel like a polished system utility:

- Header with a compact icon mark, app name, display count, and backend status.
- Privacy Mode shown as a distinct state row with a switch and clear active/off state.
- Display rows presented as light grouped sections, each with display type, resolution, brightness value, and slider.
- Quick presets remain available as icon-first buttons.
- External power-off remains a single clear action.
- Error text remains visible but restrained.

### Detail Window

The detail window should look less like a raw list and more like a native control surface:

- Top summary area with app title, display count, privacy state, and refresh activity.
- Action section for presets and external power-off.
- Display list with grouped rows and technical details shown quietly under each control row.
- Footer with backend and last-updated metadata.

## Icon

Add a bundled macOS `.icns` icon:

- Rounded-square macOS icon shape.
- Deep neutral base with a bright sun/display motif.
- Readable at Dock, Finder, and app switcher sizes.
- Use `CFBundleIconFile` in the generated app bundle.

The menu bar item should continue using a template SF Symbol so it adapts correctly to light/dark menu bar appearances.

## Implementation Boundaries

In scope:

- `Sources/BrightnessControlApp/Views.swift`
- `Sources/BrightnessControlApp/AppDelegate.swift` if window sizing or title/icon setup is needed
- `Sources/BrightnessControlCore/MenuPanelSizing.swift`
- App icon resources
- `build_app.sh`
- `README.md` if icon/build behavior needs a small note

Out of scope:

- Core brightness reads/writes
- DDC power-off behavior
- Privacy mode enforcement
- Display discovery semantics
- Reconnect behavior

## Verification

Run:

```bash
swift run BrightnessControlCoreTestRunner
swift build -c debug --product BrightnessControlApp
./build_app.sh
```

Also inspect the generated app bundle for the icon resource and `CFBundleIconFile`.

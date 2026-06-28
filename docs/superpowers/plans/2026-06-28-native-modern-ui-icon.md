# Native Modern UI Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh Brightness Control with a modern native macOS UI and a bundled application icon.

**Architecture:** Keep the app's existing SwiftPM/AppKit/SwiftUI structure. Limit UI work to SwiftUI view composition and sizing constants, and limit app icon work to deterministic local assets plus app bundle plist/resource wiring.

**Tech Stack:** Swift 6, SwiftUI, AppKit, SwiftPM executable target, shell bundle script, macOS `.icns` resources.

## Global Constraints

- Do not change display detection, brightness setting, privacy mode, external power-off, reconnect behavior, or DDC behavior.
- Keep the menu bar item as a template SF Symbol.
- Add a bundled `.icns` app icon and set `CFBundleIconFile` in the generated bundle.
- Verify with `swift run BrightnessControlCoreTestRunner`, `swift build -c debug --product BrightnessControlApp`, and `./build_app.sh`.

---

## File Structure

- Modify `Tests/BrightnessControlCoreTestRunner/main.swift`: add a sizing regression test for the refreshed menu panel.
- Modify `Sources/BrightnessControlCore/MenuPanelSizing.swift`: widen and retune menu panel sizing for the updated grouped UI.
- Modify `Sources/BrightnessControlApp/Views.swift`: modernize menu panel, detail window, rows, buttons, state styling, and supporting SwiftUI helpers.
- Modify `Sources/BrightnessControlApp/AppDelegate.swift`: adjust default window dimensions and optionally apply the app icon image to the window.
- Create `Resources/AppIcon.iconset/`: deterministic PNG icon sizes used to build the `.icns`.
- Create `Resources/AppIcon.icns`: bundled macOS app icon.
- Modify `build_app.sh`: copy icon resource into the app bundle and write `CFBundleIconFile`.
- Modify `README.md`: document that the build script embeds the icon.

### Task 1: Retune Menu Panel Sizing

**Files:**
- Modify: `Tests/BrightnessControlCoreTestRunner/main.swift`
- Modify: `Sources/BrightnessControlCore/MenuPanelSizing.swift`

**Interfaces:**
- Consumes: `MenuPanelSizing.width` and `MenuPanelSizing.height(displayCount:isLoading:hasError:)`
- Produces: same public API with updated constants

- [ ] **Step 1: Write the failing sizing test**

Add this test function to `Tests/BrightnessControlCoreTestRunner/main.swift` near the existing sizing tests:

```swift
func testModernMenuSizing() throws {
    try expect(MenuPanelSizing.width == 380.0, "modern menu width")
    try expect(
        MenuPanelSizing.height(displayCount: 2, isLoading: false, hasError: false) == 388.0,
        "modern menu height for two displays"
    )
    try expect(
        MenuPanelSizing.height(displayCount: 4, isLoading: false, hasError: true) == 520.0,
        "modern menu height remains bounded"
    )
}
```

Add it to the test list:

```swift
("modern menu sizing", testModernMenuSizing),
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift run BrightnessControlCoreTestRunner`

Expected: FAIL for `modern menu width` because current width is `360.0`.

- [ ] **Step 3: Update sizing constants**

Change `Sources/BrightnessControlCore/MenuPanelSizing.swift` to:

```swift
public enum MenuPanelSizing {
    public static let width = 380.0

    public static func height(displayCount: Int, isLoading: Bool, hasError: Bool) -> Double {
        if isLoading || displayCount == 0 {
            return hasError ? 304 : 274
        }

        let rowHeight = 76.0
        let fixedChrome = 236.0
        let errorHeight = hasError ? 34.0 : 0.0
        let rawHeight = fixedChrome + Double(displayCount) * rowHeight + errorHeight
        return min(max(rawHeight, 274), 520)
    }
}
```

- [ ] **Step 4: Run test and verify GREEN**

Run: `swift run BrightnessControlCoreTestRunner`

Expected: all tests pass.

### Task 2: Modernize SwiftUI Views

**Files:**
- Modify: `Sources/BrightnessControlApp/Views.swift`
- Modify: `Sources/BrightnessControlApp/AppDelegate.swift`

**Interfaces:**
- Consumes: existing `BrightnessAppState` properties and existing display actions
- Produces: no new public model API; view-only SwiftUI helpers in `Views.swift`

- [ ] **Step 1: Build baseline before UI edits**

Run: `swift build -c debug --product BrightnessControlApp`

Expected: build succeeds.

- [ ] **Step 2: Replace view styling while preserving actions**

In `Views.swift`, keep these action calls unchanged:

```swift
appState.setBrightness(percent, for: display)
appState.setAll(percent)
appState.disconnectExternalDisplays()
appState.setPrivacyModeEnabled($0)
NSApplication.shared.terminate(nil)
```

Add private SwiftUI helpers in the same file:

```swift
private struct PanelCard<Content: View>: View {
    var compact = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(compact ? 8 : 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}
```

Apply them to the header, privacy row, display rows, quick actions, error row, and detail window summary. Keep controls native and compact; do not add custom drawing that changes behavior.

- [ ] **Step 3: Adjust default window size**

In `AppDelegate.swift`, change the detail view minimum and initial size to fit the refreshed layout:

```swift
.frame(minWidth: 620, minHeight: 480)
```

and:

```swift
contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
```

- [ ] **Step 4: Build after UI edits**

Run: `swift build -c debug --product BrightnessControlApp`

Expected: build succeeds with no Swift errors.

### Task 3: Add App Icon Resources and Bundle Wiring

**Files:**
- Create: `Resources/AppIcon.iconset/`
- Create: `Resources/AppIcon.icns`
- Modify: `build_app.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: macOS `iconutil` command
- Produces: `Resources/AppIcon.icns` and `.build/release/Brightness Control.app/Contents/Resources/AppIcon.icns`

- [ ] **Step 1: Verify current bundle lacks icon configuration**

Run:

```bash
./build_app.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' '.build/release/Brightness Control.app/Contents/Info.plist'
```

Expected: `Print: Entry, ":CFBundleIconFile", Does Not Exist`.

- [ ] **Step 2: Generate deterministic iconset and `.icns`**

Create PNG icon sizes under `Resources/AppIcon.iconset/` using a local script or Swift/AppKit drawing. The visual should be a rounded deep neutral macOS tile with a display outline and sun motif.

Run:

```bash
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

Expected: `Resources/AppIcon.icns` exists.

- [ ] **Step 3: Wire icon into build script**

In `build_app.sh`, copy the icon after creating `Contents/Resources`:

```bash
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
```

Add to the plist:

```xml
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
```

- [ ] **Step 4: Document icon embedding**

Add one README sentence under Build App Bundle:

```markdown
The build script embeds `Resources/AppIcon.icns` into the generated app bundle.
```

- [ ] **Step 5: Verify icon configuration is GREEN**

Run:

```bash
./build_app.sh
test -f '.build/release/Brightness Control.app/Contents/Resources/AppIcon.icns'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' '.build/release/Brightness Control.app/Contents/Info.plist'
```

Expected: `AppIcon`

### Task 4: Final Verification and Cleanup

**Files:**
- All modified files

**Interfaces:**
- Consumes: completed Tasks 1-3
- Produces: verified local implementation

- [ ] **Step 1: Run core tests**

Run: `swift run BrightnessControlCoreTestRunner`

Expected: all tests pass.

- [ ] **Step 2: Run debug build**

Run: `swift build -c debug --product BrightnessControlApp`

Expected: build succeeds.

- [ ] **Step 3: Run release app bundle build**

Run: `./build_app.sh`

Expected: command prints `.build/release/Brightness Control.app`.

- [ ] **Step 4: Inspect git diff**

Run: `git diff --stat && git diff --check`

Expected: no whitespace errors; changed files match this plan.

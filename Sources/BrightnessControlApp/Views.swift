import AppKit
import BrightnessControlCore
import SwiftUI

struct MenuBarPanelView: View {
    @EnvironmentObject private var appState: BrightnessAppState
    let onOpenDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            PrivacyModeToggleView(compact: true)
                .environmentObject(appState)

            if appState.displays.isEmpty, appState.isRefreshing {
                ContentUnavailableView("Loading displays", systemImage: "display")
                    .frame(width: 320, height: 96)
            } else if appState.displays.isEmpty {
                ContentUnavailableView("No displays", systemImage: "display")
                    .frame(width: 320, height: 96)
            } else {
                ForEach(appState.displays) { display in
                    DisplayControlRow(status: display, compact: true) { percent in
                        appState.setBrightness(percent, for: display)
                    }
                    .disabled(appState.privacyModeEnabled)
                }
            }

            QuickActionsView(compact: true) { percent in
                appState.setAll(percent)
            }
            .disabled(appState.privacyModeEnabled)

            ExternalConnectionControls(compact: true)
                .environmentObject(appState)

            if let errorMessage = appState.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()

            HStack {
                Button {
                    onOpenDetails()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Details")

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: MenuPanelSizing.width)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "sun.max.fill")
                .font(.callout)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Brightness")
                    .font(.subheadline.weight(.semibold))
                Text("\(appState.displays.count) display\(appState.displays.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let externalBackendName = appState.externalBackendName {
                Text(externalBackendName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

struct DetailWindowView: View {
    @EnvironmentObject private var appState: BrightnessAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Brightness Control", systemImage: "display.2")
                    .font(.title2.weight(.semibold))
                Spacer()
                if appState.isRefreshing, appState.displays.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            PrivacyModeToggleView()
                .environmentObject(appState)

            DetailActionsSection()
                .environmentObject(appState)

            if let errorMessage = appState.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            List {
                ForEach(appState.displays) { display in
                    DetailDisplayRow(status: display) { percent in
                        appState.setBrightness(percent, for: display)
                    }
                    .disabled(appState.privacyModeEnabled)
                }
            }
            .listStyle(.inset)

            HStack {
                Text("External backend: \(appState.externalBackendName ?? "none")")
                Spacer()
                if let lastUpdated = appState.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct DetailActionsSection: View {
    @EnvironmentObject private var appState: BrightnessAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Presets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                QuickActionsView { percent in
                    appState.setAll(percent)
                }
                .disabled(appState.privacyModeEnabled)
            }

            HStack(spacing: 10) {
                Text("External")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                ExternalConnectionControls(compact: false)
                    .environmentObject(appState)
            }
        }
        .buttonStyle(.bordered)
    }
}

struct PrivacyModeToggleView: View {
    @EnvironmentObject private var appState: BrightnessAppState
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Label {
                VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                    Text("Privacy Mode")
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    Text(appState.privacyModeEnabled ? "Active" : "Off")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: appState.privacyModeEnabled ? "lock.fill" : "lock.open")
                    .font(compact ? .caption : .body)
                    .foregroundStyle(appState.privacyModeEnabled ? .red : .secondary)
                    .frame(width: compact ? 16 : 20)
            }

            Spacer()

            if appState.isPrivacyModeChanging {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { appState.privacyModeEnabled },
                    set: { appState.setPrivacyModeEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(appState.isPrivacyModeChanging)
        }
        .padding(compact ? 7 : 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: compact ? 6 : 8))
        .animation(.default, value: appState.privacyModeEnabled)
    }
}

struct ExternalConnectionControls: View {
    @EnvironmentObject private var appState: BrightnessAppState
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Button {
                appState.disconnectExternalDisplays()
            } label: {
                Label(compact ? "Power Off" : "Power Off External", systemImage: "power.circle")
                    .frame(maxWidth: compact ? .infinity : nil)
            }
            .help("Turn off external display power through DDC")
            .disabled(!appState.hasExternalDisplay || appState.externalPrivacyEnabled)
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
        .disabled(appState.privacyModeEnabled)
    }
}

struct DisplayControlRow: View {
    let status: DisplayStatus
    var compact = false
    let onSet: (Int) -> Void

    @State private var sliderValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack {
                Image(systemName: status.display.kind == .internal ? "laptopcomputer" : "display")
                    .font(compact ? .caption : .body)
                    .frame(width: compact ? 16 : 20)
                VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                    Text(status.display.name)
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(brightnessText)
                    .font(.system(compact ? .callout : .body, design: .rounded).monospacedDigit())
            }

            HStack(spacing: compact ? 6 : 8) {
                Slider(
                    value: $sliderValue,
                    in: 0...100,
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing {
                            onSet(Int(sliderValue.rounded()))
                        }
                    }
                )
                .disabled(!status.canChange)

                Button {
                    onSet(Int(sliderValue.rounded()))
                } label: {
                    Image(systemName: "checkmark")
                }
                .help("Set brightness")
                .disabled(!status.canChange)
                .controlSize(compact ? .small : .regular)
            }
            .controlSize(compact ? .small : .regular)

            if let note = status.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 7 : 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: compact ? 6 : 8))
        .onAppear {
            sliderValue = Double(status.brightnessPercent ?? 0)
        }
        .onChange(of: status.brightnessPercent) { _, newValue in
            sliderValue = Double(newValue ?? 0)
        }
    }

    private var brightnessText: String {
        guard let percent = status.brightnessPercent else { return "--%" }
        return "\(percent)%"
    }

    private var subtitle: String {
        let kind = status.display.kind == .internal ? "Internal" : "External"
        if let resolution = status.display.resolution {
            return "\(kind) - \(resolution)"
        }
        return kind
    }
}

struct DetailDisplayRow: View {
    let status: DisplayStatus
    let onSet: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisplayControlRow(status: status, onSet: onSet)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Type").foregroundStyle(.secondary)
                    Text(status.display.kind == .internal ? "Internal" : "External")
                }
                GridRow {
                    Text("Display ID").foregroundStyle(.secondary)
                    Text(status.display.displayID.map(String.init) ?? "-")
                }
                GridRow {
                    Text("External Index").foregroundStyle(.secondary)
                    Text(status.externalIndex.map(String.init) ?? "-")
                }
                GridRow {
                    Text("Source").foregroundStyle(.secondary)
                    Text(status.source ?? "-")
                }
                GridRow {
                    Text("Online").foregroundStyle(.secondary)
                    Text(status.display.online ? "Yes" : "No")
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
    }
}

struct QuickActionsView: View {
    var compact = false
    let onSet: (Int) -> Void

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            quickButton(0, "moon.fill")
            quickButton(10, "sun.min")
            quickButton(50, "sun.max")
            quickButton(100, "sun.max.fill")
        }
        .controlSize(compact ? .small : .regular)
    }

    private func quickButton(_ percent: Int, _ systemImage: String) -> some View {
        Button {
            onSet(percent)
        } label: {
            if compact {
                Label("\(percent)", systemImage: systemImage)
            } else {
                Label("\(percent)%", systemImage: systemImage)
            }
        }
        .help("Set all displays to \(percent)%")
    }
}

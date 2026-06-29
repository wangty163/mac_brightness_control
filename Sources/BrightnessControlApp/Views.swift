import AppKit
import BrightnessControlCore
import SwiftUI

struct MenuBarPanelView: View {
    @EnvironmentObject private var appState: BrightnessAppState
    let onOpenDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            PrivacyModeToggleView(compact: true)
                .environmentObject(appState)

            displaySection

            QuickActionsView(compact: true) { percent in
                appState.setAll(percent)
            }
            .disabled(appState.privacyModeEnabled)

            ExternalConnectionControls(compact: true)
                .environmentObject(appState)

            MenuErrorSlot(message: appState.errorMessage)

            Divider()

            HStack {
                Button {
                    onOpenDetails()
                } label: {
                    Label("Details", systemImage: "sidebar.right")
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: MenuPanelSizing.width, height: menuHeight, alignment: .topLeading)
        .background(Color.clear)
    }

    private var menuHeight: CGFloat {
        MenuPanelSizing.height(
            displayCount: appState.displays.count,
            isLoading: appState.isRefreshing,
            hasError: appState.errorMessage != nil
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Brightness")
                    .font(.subheadline.weight(.semibold))
                Text("\(appState.displays.count) display\(appState.displays.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appState.isRefreshing, appState.displays.isEmpty {
                ProgressView()
                    .controlSize(.small)
            } else if let externalBackendName = appState.externalBackendName {
                StatusPill(text: externalBackendName, systemImage: "bolt.horizontal", tint: .blue)
            }
        }
    }

    @ViewBuilder
    private var displaySection: some View {
        if appState.displays.isEmpty, appState.isRefreshing {
            EmptyStateView(title: "Loading displays", systemImage: "display", compact: true)
        } else if appState.displays.isEmpty {
            EmptyStateView(title: "No displays", systemImage: "display.slash", compact: true)
        } else {
            VStack(spacing: 8) {
                ForEach(appState.displays) { display in
                    DisplayControlRow(status: display, compact: true) { percent in
                        appState.setBrightness(percent, for: display)
                    }
                    .disabled(appState.privacyModeEnabled)
                }
            }
        }
    }
}

struct DetailWindowView: View {
    @EnvironmentObject private var appState: BrightnessAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            detailHeader

            PrivacyModeToggleView()
                .environmentObject(appState)

            DetailActionsSection()
                .environmentObject(appState)

            if let errorMessage = appState.errorMessage {
                ErrorMessageView(message: errorMessage)
            }

            displayList

            footer
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailHeader: some View {
        PanelCard {
            HStack(alignment: .center, spacing: 14) {
                AppGlyph(size: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Brightness Control")
                        .font(.title2.weight(.semibold))
                    Text("Display brightness and privacy controls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    StatusPill(
                        text: "\(appState.displays.count) display\(appState.displays.count == 1 ? "" : "s")",
                        systemImage: "display.2",
                        tint: .blue
                    )
                    StatusPill(
                        text: appState.privacyModeEnabled ? "Privacy On" : "Privacy Off",
                        systemImage: appState.privacyModeEnabled ? "lock.fill" : "lock.open",
                        tint: appState.privacyModeEnabled ? .red : .secondary
                    )
                    if appState.isRefreshing, appState.displays.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var displayList: some View {
        if appState.displays.isEmpty, appState.isRefreshing {
            EmptyStateView(title: "Loading displays", systemImage: "display")
                .frame(maxWidth: .infinity)
        } else if appState.displays.isEmpty {
            EmptyStateView(title: "No displays", systemImage: "display.slash")
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.displays) { display in
                        DetailDisplayRow(status: display) { percent in
                            appState.setBrightness(percent, for: display)
                        }
                        .disabled(appState.privacyModeEnabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("External backend: \(appState.externalBackendName ?? "none")", systemImage: "server.rack")
                .lineLimit(1)
            Spacer()
            if let lastUpdated = appState.lastUpdated {
                Label("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))", systemImage: "clock")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct DetailActionsSection: View {
    @EnvironmentObject private var appState: BrightnessAppState

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SectionLabel(title: "Presets", systemImage: "slider.horizontal.3")

                    QuickActionsView { percent in
                        appState.setAll(percent)
                    }
                    .disabled(appState.privacyModeEnabled)
                }

                Divider()

                HStack(spacing: 12) {
                    SectionLabel(title: "External", systemImage: "display")

                    ExternalConnectionControls(compact: false)
                        .environmentObject(appState)
                }
            }
        }
        .buttonStyle(.bordered)
    }
}

struct PrivacyModeToggleView: View {
    @EnvironmentObject private var appState: BrightnessAppState
    var compact = false

    var body: some View {
        PanelCard(compact: compact) {
            HStack(spacing: compact ? 8 : 12) {
                Image(systemName: appState.privacyModeEnabled ? "lock.fill" : "lock.open")
                    .font(compact ? .callout : .title3)
                    .foregroundStyle(appState.privacyModeEnabled ? .red : .secondary)
                    .frame(width: compact ? 22 : 28)

                VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                    Text("Privacy Mode")
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    Text(appState.privacyModeEnabled ? "Internal dimmed, external powered off" : "Display controls are available")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
        }
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
                Label(compact ? "Power Off" : "Power Off External", systemImage: "power.circle.fill")
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
        PanelCard(compact: compact) {
            DisplayControlContent(
                status: status,
                compact: compact,
                sliderValue: $sliderValue,
                onSet: onSet
            )
        }
    }
}

struct DetailDisplayRow: View {
    let status: DisplayStatus
    let onSet: (Int) -> Void

    @State private var sliderValue: Double = 0

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                DisplayControlContent(
                    status: status,
                    compact: false,
                    sliderValue: $sliderValue,
                    onSet: onSet
                )

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    technicalRow("Type", status.display.kind == .internal ? "Internal" : "External")
                    technicalRow("Display ID", status.display.displayID.map(String.init) ?? "-")
                    technicalRow("External Index", status.externalIndex.map(String.init) ?? "-")
                    technicalRow("Source", status.source ?? "-")
                    technicalRow("Online", status.display.online ? "Yes" : "No")
                }
                .font(.caption)
            }
        }
    }

    private func technicalRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
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
            Label {
                Text(compact ? "\(percent)" : "\(percent)%")
                    .monospacedDigit()
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(maxWidth: compact ? .infinity : nil)
        }
        .help("Set all displays to \(percent)%")
    }
}

private struct DisplayControlContent: View {
    let status: DisplayStatus
    var compact = false
    @Binding var sliderValue: Double
    let onSet: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: compact ? 8 : 10) {
                Image(systemName: status.display.kind == .internal ? "laptopcomputer" : "display")
                    .font(compact ? .callout : .title3)
                    .foregroundStyle(status.display.kind == .internal ? .blue : .secondary)
                    .frame(width: compact ? 20 : 26)

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
                    .font(.system(compact ? .callout : .title3, design: .rounded).monospacedDigit().weight(.semibold))
                    .foregroundStyle(status.canChange ? .primary : .secondary)
                    .frame(minWidth: compact ? 44 : 56, alignment: .trailing)
            }

            HStack(spacing: compact ? 7 : 10) {
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
                        .frame(width: compact ? 18 : 22)
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
                    .lineLimit(2)
            }
        }
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

private struct PanelCard<Content: View>: View {
    var compact = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(compact ? 8 : 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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

private struct AppGlyph: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.13, blue: 0.17),
                            Color(red: 0.18, green: 0.22, blue: 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sun.max.fill")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.yellow)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var compact = false

    var body: some View {
        PanelCard(compact: compact) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(compact ? .title3 : .title2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(minHeight: compact ? 52 : 72)
        }
    }
}

private struct ErrorMessageView: View {
    let message: String
    var compact = false

    var body: some View {
        PanelCard(compact: compact) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(compact ? .caption : .callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

private struct MenuErrorSlot: View {
    let message: String?

    var body: some View {
        ZStack(alignment: .leading) {
            if let message {
                ErrorMessageView(message: message, compact: true)
            } else {
                Color.clear
            }
        }
        .frame(height: 42)
        .accessibilityHidden(message == nil)
    }
}

private struct SectionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 92, alignment: .leading)
    }
}

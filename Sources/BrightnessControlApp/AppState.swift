import BrightnessControlCore
import Foundation

private enum RefreshOutcome: Sendable {
    case success(DisplaySnapshot)
    case failure(String)
}

private enum PrivacyModeOutcome: Sendable {
    case enabled(DisplayPrivacyModeSnapshot)
    case disabled
    case failure(String)
}

@MainActor
final class BrightnessAppState: ObservableObject {
    @Published private(set) var displays: [DisplayStatus] = []
    @Published private(set) var externalBackendName: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPrivacyModeChanging = false
    @Published private(set) var privacyModeEnabled = false
    @Published private(set) var externalPrivacyEnabled = false
    @Published var errorMessage: String?

    private let manager: DisplayManager
    private var privacyModeSnapshot: DisplayPrivacyModeSnapshot?
    private var privacyEnforcementTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    private let privacyEnforcementIntervalNanoseconds: UInt64 = 1_000_000_000
    private let automaticRefreshIntervalNanoseconds: UInt64 = 2_000_000_000
    private let refreshDebounceNanoseconds: UInt64 = 250_000_000

    init(manager: DisplayManager = DisplayManager()) {
        self.manager = manager
        refreshAsync(showActivity: true)
        startAutomaticRefreshLoop()
    }

    deinit {
        privacyEnforcementTask?.cancel()
        automaticRefreshTask?.cancel()
        scheduledRefreshTask?.cancel()
        refreshTask?.cancel()
    }

    var hasExternalDisplay: Bool {
        displays.contains { $0.display.kind == .external }
    }

    func refresh() {
        do {
            let snapshot = try manager.loadSnapshot()
            apply(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAsync(showActivity: Bool = false) {
        guard refreshTask == nil else {
            pendingRefresh = true
            return
        }

        let shouldShowActivity = showActivity || displays.isEmpty
        if shouldShowActivity {
            isRefreshing = true
        }

        let manager = manager
        refreshTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> RefreshOutcome in
                do {
                    return .success(try manager.loadSnapshot())
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            self.refreshTask = nil
            self.isRefreshing = false
            switch outcome {
            case let .success(snapshot):
                self.apply(snapshot)
            case let .failure(message):
                self.errorMessage = message
            }

            if self.pendingRefresh {
                self.pendingRefresh = false
                self.requestRefreshSoon()
            }
        }
    }

    func requestRefreshSoon() {
        scheduledRefreshTask?.cancel()
        let refreshDebounceNanoseconds = refreshDebounceNanoseconds
        scheduledRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: refreshDebounceNanoseconds)
            guard let self else { return }
            self.refreshAsync()
        }
    }

    func setAll(_ percent: Int) {
        guard allowDisplayConfigurationChange() else { return }
        for status in displays where status.canChange {
            setBrightness(percent, for: status, refreshAfterSet: false)
        }
        refresh()
    }

    func setBrightness(_ percent: Int, for status: DisplayStatus, refreshAfterSet: Bool = true) {
        guard allowDisplayConfigurationChange() else { return }
        do {
            try manager.setBrightness(max(0, min(100, percent)), for: status)
            errorMessage = nil
            if refreshAfterSet {
                refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectExternalDisplays() {
        guard allowDisplayConfigurationChange() else { return }
        guard hasExternalDisplay else { return }
        guard !externalPrivacyEnabled else { return }

        do {
            try manager.disconnectExternalDisplays()
            externalPrivacyEnabled = true
            errorMessage = nil
            refreshAsync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setPrivacyModeEnabled(_ enabled: Bool) {
        guard enabled != privacyModeEnabled else { return }
        guard !isPrivacyModeChanging else { return }

        isPrivacyModeChanging = true
        if !enabled {
            stopPrivacyEnforcementLoop()
        }

        let manager = manager
        let snapshot = privacyModeSnapshot
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> PrivacyModeOutcome in
                do {
                    if enabled {
                        return .enabled(try manager.enablePrivacyMode())
                    }

                    if let snapshot {
                        try manager.restorePrivacyMode(from: snapshot)
                    }
                    return .disabled
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            self.isPrivacyModeChanging = false
            switch outcome {
            case let .enabled(snapshot):
                self.privacyModeSnapshot = snapshot
                self.privacyModeEnabled = true
                self.externalPrivacyEnabled = true
                self.errorMessage = nil
                self.startPrivacyEnforcementLoop()
                self.refreshAsync()
            case .disabled:
                self.privacyModeSnapshot = nil
                self.privacyModeEnabled = false
                self.externalPrivacyEnabled = false
                self.errorMessage = nil
                self.refreshAsync()
            case let .failure(message):
                self.errorMessage = message
                if !enabled, self.privacyModeEnabled, self.privacyModeSnapshot != nil {
                    self.startPrivacyEnforcementLoop()
                }
            }
        }
    }

    private func apply(_ snapshot: DisplaySnapshot) {
        displays = snapshot.displays
        externalBackendName = snapshot.externalBackendName
        lastUpdated = Date()
        errorMessage = nil
        if snapshot.externalPresent, !privacyModeEnabled {
            externalPrivacyEnabled = false
        }
    }

    private func allowDisplayConfigurationChange() -> Bool {
        guard !privacyModeEnabled else {
            errorMessage = "Privacy Mode is on. Turn it off to change display settings."
            return false
        }
        return true
    }

    private func startPrivacyEnforcementLoop() {
        stopPrivacyEnforcementLoop()
        let manager = manager
        privacyEnforcementTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let snapshot = self.privacyModeSnapshot else { return }

                let message = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        try manager.enforcePrivacyMode(using: snapshot)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value

                if Task.isCancelled {
                    return
                }
                if let message {
                    self.errorMessage = message
                }
                try? await Task.sleep(nanoseconds: privacyEnforcementIntervalNanoseconds)
            }
        }
    }

    private func stopPrivacyEnforcementLoop() {
        privacyEnforcementTask?.cancel()
        privacyEnforcementTask = nil
    }

    private func startAutomaticRefreshLoop() {
        automaticRefreshTask?.cancel()
        let automaticRefreshIntervalNanoseconds = automaticRefreshIntervalNanoseconds
        automaticRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: automaticRefreshIntervalNanoseconds)
                guard let self else { return }
                self.requestRefreshSoon()
            }
        }
    }
}

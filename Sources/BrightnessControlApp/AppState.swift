import BrightnessControlCore
import Foundation

private let lastKnownExternalDisplayIndicesDefaultsKey = "LastKnownExternalDisplayIndices"

private func loadLastKnownExternalDisplayIndices() -> [Int] {
    (UserDefaults.standard.array(forKey: lastKnownExternalDisplayIndicesDefaultsKey) ?? [])
        .compactMap { ($0 as? NSNumber)?.intValue }
        .filter { $0 > 0 }
}

private enum RefreshOutcome: Sendable {
    case success(DisplaySnapshot)
    case failure(String)
}

private enum PrivacyModeOutcome: Sendable {
    case disabled
    case failure(String)
}

private enum SleepProtectionOutcome: Sendable {
    case success
    case failure(String)
}

private enum ProtectedDisplayActionOutcome: Sendable {
    case externalPowerDisabled
    case privacyEnabled(DisplayPrivacyModeSnapshot)
    case failure(String)
}

private enum SleepProtectionReason: Hashable {
    case manual
    case privacyMode
    case externalPowerOff
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
    @Published private(set) var clamshellSleepProtectionEnabled = false
    @Published private(set) var clamshellSleepProtectionRequestedEnabled: Bool?
    @Published private(set) var isClamshellSleepProtectionChanging = false
    @Published var errorMessage: String?

    private let manager: DisplayManager
    private let clamshellSleepController: ClamshellSleepController
    private var privacyModeSnapshot: DisplayPrivacyModeSnapshot?
    private var lastKnownExternalDisplayIndices = loadLastKnownExternalDisplayIndices()
    private var sleepProtectionReasons: Set<SleepProtectionReason> = []
    private var privacyEnforcementTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var sleepProtectionStatusTask: Task<Void, Never>?
    private var pendingRefresh = false
    private let privacyEnforcementIntervalNanoseconds: UInt64 = 1_000_000_000
    private let automaticRefreshIntervalNanoseconds: UInt64 = 2_000_000_000
    private let refreshDebounceNanoseconds: UInt64 = 250_000_000

    init(
        manager: DisplayManager = DisplayManager(),
        clamshellSleepController: ClamshellSleepController = ClamshellSleepController()
    ) {
        self.manager = manager
        self.clamshellSleepController = clamshellSleepController
        refreshAsync(showActivity: true)
        startAutomaticRefreshLoop()
    }

    deinit {
        privacyEnforcementTask?.cancel()
        automaticRefreshTask?.cancel()
        scheduledRefreshTask?.cancel()
        refreshTask?.cancel()
        sleepProtectionStatusTask?.cancel()
        try? clamshellSleepController.disable()
    }

    var hasExternalDisplay: Bool {
        displays.contains { $0.display.kind == .external }
    }

    var hasKnownExternalDisplay: Bool {
        hasExternalDisplay || !lastKnownExternalDisplayIndices.isEmpty
    }

    var clamshellSleepProtectionToggleValue: Bool {
        clamshellSleepProtectionRequestedEnabled ?? clamshellSleepProtectionEnabled
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
        guard hasKnownExternalDisplay else { return }
        guard !externalPrivacyEnabled else { return }
        guard !isPrivacyModeChanging else { return }
        guard !isClamshellSleepProtectionChanging else { return }

        isClamshellSleepProtectionChanging = true
        let manager = manager
        let controller = clamshellSleepController
        let expectedDisplayIndices = lastKnownExternalDisplayIndices
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> ProtectedDisplayActionOutcome in
                do {
                    let protectionStarted = try controller.enable()
                    do {
                        try manager.disconnectExternalDisplays(expectedDisplayIndices: expectedDisplayIndices)
                        return .externalPowerDisabled
                    } catch {
                        if protectionStarted {
                            try? controller.disable()
                        }
                        return .failure(error.localizedDescription)
                    }
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            self.isClamshellSleepProtectionChanging = false
            switch outcome {
            case .externalPowerDisabled:
                self.sleepProtectionReasons.insert(.externalPowerOff)
                self.clamshellSleepProtectionEnabled = true
                self.externalPrivacyEnabled = true
                self.errorMessage = nil
                self.refreshAsync()
            case .privacyEnabled:
                break
            case let .failure(message):
                self.clamshellSleepProtectionEnabled = controller.isEnabled
                self.errorMessage = message
            }
        }
    }

    func runPrivacyModeOnce() {
        disconnectExternalDisplays()
    }

    func setClamshellSleepProtectionEnabled(_ enabled: Bool) {
        guard enabled != clamshellSleepProtectionEnabled else { return }
        guard !isPrivacyModeChanging else { return }
        guard !isClamshellSleepProtectionChanging else { return }
        guard !privacyModeEnabled || enabled else { return }

        clamshellSleepProtectionRequestedEnabled = enabled

        if enabled {
            startClamshellSleepProtection(reason: .manual)
            return
        }

        sleepProtectionReasons.remove(.manual)
        sleepProtectionReasons.remove(.externalPowerOff)
        stopClamshellSleepProtectionIfUnused()
    }

    func shutdown() {
        stopPrivacyEnforcementLoop()
        sleepProtectionReasons.removeAll()
        try? clamshellSleepController.disable()
        clamshellSleepProtectionEnabled = false
        clamshellSleepProtectionRequestedEnabled = nil
    }

    func setPrivacyModeEnabled(_ enabled: Bool) {
        guard enabled != privacyModeEnabled else { return }
        guard !isPrivacyModeChanging else { return }
        guard !isClamshellSleepProtectionChanging else { return }

        if enabled {
            enablePrivacyModeWithSleepProtection()
            return
        }

        isPrivacyModeChanging = true
        stopPrivacyEnforcementLoop()

        let manager = manager
        let snapshot = privacyModeSnapshot
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> PrivacyModeOutcome in
                do {
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
            case .disabled:
                self.privacyModeSnapshot = nil
                self.privacyModeEnabled = false
                self.externalPrivacyEnabled = false
                self.sleepProtectionReasons.remove(.privacyMode)
                self.errorMessage = nil
                self.refreshAsync()
                self.stopClamshellSleepProtectionIfUnused()
            case let .failure(message):
                self.errorMessage = message
                if self.privacyModeEnabled, self.privacyModeSnapshot != nil {
                    self.startPrivacyEnforcementLoop()
                }
            }
        }
    }

    private func enablePrivacyModeWithSleepProtection() {
        isPrivacyModeChanging = true
        isClamshellSleepProtectionChanging = true
        let manager = manager
        let controller = clamshellSleepController
        let expectedExternalDisplayIndices = lastKnownExternalDisplayIndices

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> ProtectedDisplayActionOutcome in
                do {
                    let protectionStarted = try controller.enable()
                    do {
                        return .privacyEnabled(
                            try manager.enablePrivacyMode(
                                expectedExternalDisplayIndices: expectedExternalDisplayIndices
                            )
                        )
                    } catch {
                        if protectionStarted {
                            try? controller.disable()
                        }
                        return .failure(error.localizedDescription)
                    }
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            self.isPrivacyModeChanging = false
            self.isClamshellSleepProtectionChanging = false
            switch outcome {
            case let .privacyEnabled(snapshot):
                self.privacyModeSnapshot = snapshot
                self.privacyModeEnabled = true
                self.externalPrivacyEnabled = true
                self.sleepProtectionReasons.insert(.privacyMode)
                self.clamshellSleepProtectionEnabled = true
                self.errorMessage = nil
                self.startPrivacyEnforcementLoop()
                self.refreshAsync()
            case .externalPowerDisabled:
                self.errorMessage = "Privacy Mode did not return a display snapshot."
            case let .failure(message):
                self.clamshellSleepProtectionEnabled = controller.isEnabled
                self.errorMessage = message
            }
        }
    }

    private func startClamshellSleepProtection(reason: SleepProtectionReason) {
        guard !isClamshellSleepProtectionChanging else { return }
        isClamshellSleepProtectionChanging = true
        let controller = clamshellSleepController

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> SleepProtectionOutcome in
                do {
                    _ = try controller.enable()
                    return .success
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            switch outcome {
            case .success:
                self.sleepProtectionReasons.insert(reason)
                self.clamshellSleepProtectionEnabled = true
                self.errorMessage = nil
            case let .failure(message):
                self.clamshellSleepProtectionEnabled = controller.isEnabled
                self.errorMessage = message
            }
            self.clamshellSleepProtectionRequestedEnabled = nil
            self.isClamshellSleepProtectionChanging = false
        }
    }

    private func stopClamshellSleepProtectionIfUnused() {
        guard sleepProtectionReasons.isEmpty else {
            clamshellSleepProtectionEnabled = true
            clamshellSleepProtectionRequestedEnabled = nil
            return
        }
        guard clamshellSleepController.isEnabled else {
            clamshellSleepProtectionEnabled = false
            clamshellSleepProtectionRequestedEnabled = nil
            return
        }
        guard !isClamshellSleepProtectionChanging else { return }

        isClamshellSleepProtectionChanging = true
        let controller = clamshellSleepController
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> SleepProtectionOutcome in
                do {
                    try controller.disable()
                    return .success
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            self.clamshellSleepProtectionEnabled = controller.isEnabled
            self.clamshellSleepProtectionRequestedEnabled = nil
            self.isClamshellSleepProtectionChanging = false
            switch outcome {
            case .success:
                self.errorMessage = nil
            case let .failure(message):
                self.errorMessage = message
            }
        }
    }

    private func apply(_ snapshot: DisplaySnapshot) {
        displays = snapshot.displays
        let discoveredExternalDisplayIndices = snapshot.displays.compactMap { status in
            status.display.kind == .external ? status.externalIndex : nil
        }
        if !discoveredExternalDisplayIndices.isEmpty {
            lastKnownExternalDisplayIndices = discoveredExternalDisplayIndices
            UserDefaults.standard.set(
                discoveredExternalDisplayIndices,
                forKey: lastKnownExternalDisplayIndicesDefaultsKey
            )
        }
        externalBackendName = snapshot.externalBackendName
        lastUpdated = Date()
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
                        try manager.enforcePrivacyMode(
                            using: snapshot,
                            powerOffExternalDisplays: false
                        )
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
                self.refreshClamshellSleepProtectionStatus()
            }
        }
    }

    private func refreshClamshellSleepProtectionStatus() {
        guard clamshellSleepProtectionEnabled else { return }
        guard sleepProtectionStatusTask == nil else { return }
        let controller = clamshellSleepController

        sleepProtectionStatusTask = Task { [weak self] in
            let enabled = await Task.detached(priority: .utility) {
                controller.reportedIsEnabled
            }.value
            guard let self else { return }
            self.sleepProtectionStatusTask = nil
            if self.clamshellSleepProtectionEnabled, enabled == false {
                self.clamshellSleepProtectionEnabled = false
                self.clamshellSleepProtectionRequestedEnabled = nil
                self.sleepProtectionReasons.removeAll()
                self.errorMessage = "Lid-sleep protection stopped unexpectedly. Do not power off the external display until it is enabled again."
            }
        }
    }
}

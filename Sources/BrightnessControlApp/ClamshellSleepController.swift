import BrightnessControlCore
import Darwin
import Foundation
import ServiceManagement

enum ClamshellSleepProtectionError: LocalizedError {
    case helperMissing
    case approvalRequired
    case serviceRegistrationFailed(String)
    case serviceConnectionFailed(String)
    case activationTimedOut
    case deactivationTimedOut

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The lid-sleep service is missing. Rebuild the application bundle."
        case .approvalRequired:
            return "Approve Brightness Control in System Settings > General > Login Items, then try again. The external display was left on."
        case let .serviceRegistrationFailed(message):
            return "Could not register the protected lid-sleep service: \(message)"
        case let .serviceConnectionFailed(message):
            return "Could not reach the protected lid-sleep service: \(message)"
        case .activationTimedOut:
            return "Lid-sleep protection did not start. The external display was left on."
        case .deactivationTimedOut:
            return "The lid-sleep service did not confirm that normal sleep behavior was restored."
        }
    }
}

final class ClamshellSleepController: @unchecked Sendable {
    private static let daemonPlistName = "local.wty.BrightnessControl.SleepHelper.plist"
    private static let machServiceName = "local.wty.BrightnessControl.SleepHelper"
    private static let installedDaemonPlistPath = "/Library/LaunchDaemons/local.wty.BrightnessControl.SleepHelper.plist"
    private static let installedHelperPath = "/Library/PrivilegedHelperTools/local.wty.BrightnessControl.SleepHelper"
    private static let installedRequirementPath = "/Library/PrivilegedHelperTools/local.wty.BrightnessControl.SleepHelper.caller.requirement"

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var sessionID: String?

    deinit {
        try? disable()
    }

    var isEnabled: Bool {
        reportedIsEnabled == true
    }

    var reportedIsEnabled: Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let connection, let sessionID else { return false }
        return queryStatus(connection: connection, sessionID: sessionID)
    }

    @discardableResult
    func enable() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let connection, let sessionID {
            if queryStatus(connection: connection, sessionID: sessionID) == true {
                return false
            }
            connection.invalidate()
            self.connection = nil
            self.sessionID = nil
        }

        if !secureLegacyServiceIsInstalled() {
            try ensureServiceEnabled()
        }
        let connection = makeConnection()
        do {
            let sessionID = try beginProtection(connection: connection)
            self.connection = connection
            self.sessionID = sessionID
            return true
        } catch {
            connection.invalidate()
            throw error
        }
    }

    func disable() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let connection, let sessionID else { return }

        do {
            try endProtection(connection: connection, sessionID: sessionID)
            connection.invalidate()
            self.connection = nil
            self.sessionID = nil
        } catch {
            connection.invalidate()
            if !secureLegacyServiceIsInstalled() {
                try ensureServiceEnabled()
            }
            let recoveryConnection = makeConnection()
            do {
                let recoverySessionID = try beginProtection(connection: recoveryConnection)
                self.connection = recoveryConnection
                self.sessionID = recoverySessionID
                try endProtection(connection: recoveryConnection, sessionID: recoverySessionID)
                recoveryConnection.invalidate()
                self.connection = nil
                self.sessionID = nil
            } catch {
                recoveryConnection.invalidate()
                throw error
            }
        }
    }

    private func secureLegacyServiceIsInstalled() -> Bool {
        guard secureRootOwnedItem(at: "/Library/LaunchDaemons", type: S_IFDIR)
            && secureRootOwnedItem(at: Self.installedDaemonPlistPath, type: S_IFREG)
            && secureRootOwnedItem(at: "/Library/PrivilegedHelperTools", type: S_IFDIR)
            && secureRootOwnedItem(at: Self.installedHelperPath, type: S_IFREG, mustBeExecutable: true)
            && secureRootOwnedItem(at: Self.installedRequirementPath, type: S_IFREG)
        else {
            return false
        }

        guard
            let data = FileManager.default.contents(atPath: Self.installedDaemonPlistPath),
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = propertyList as? [String: Any],
            dictionary["Label"] as? String == Self.machServiceName,
            let arguments = dictionary["ProgramArguments"] as? [String],
            arguments == [Self.installedHelperPath],
            let machServices = dictionary["MachServices"] as? [String: Any],
            machServices[Self.machServiceName] as? Bool == true
        else {
            return false
        }
        return true
    }

    private func secureRootOwnedItem(
        at path: String,
        type expectedType: mode_t,
        mustBeExecutable: Bool = false
    ) -> Bool {
        var itemStatus = stat()
        guard lstat(path, &itemStatus) == 0 else { return false }
        guard itemStatus.st_uid == 0 else { return false }
        guard itemStatus.st_mode & S_IFMT == expectedType else { return false }
        guard itemStatus.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
        if mustBeExecutable, itemStatus.st_mode & S_IXUSR == 0 { return false }
        return true
    }

    private func ensureServiceEnabled() throws {
        let service = SMAppService.daemon(plistName: Self.daemonPlistName)
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw ClamshellSleepProtectionError.approvalRequired
        case .notFound:
            throw ClamshellSleepProtectionError.helperMissing
        case .notRegistered:
            do {
                try service.register()
            } catch {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    throw ClamshellSleepProtectionError.approvalRequired
                }
                throw ClamshellSleepProtectionError.serviceRegistrationFailed(error.localizedDescription)
            }

            guard service.status == .enabled else {
                SMAppService.openSystemSettingsLoginItems()
                throw ClamshellSleepProtectionError.approvalRequired
            }
        @unknown default:
            throw ClamshellSleepProtectionError.helperMissing
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: Self.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SleepProtectionServiceProtocol.self)
        connection.activate()
        return connection
    }

    private func beginProtection(connection: NSXPCConnection) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var sessionID: String?
        var failureMessage: String?

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            resultLock.lock()
            failureMessage = error.localizedDescription
            resultLock.unlock()
            semaphore.signal()
        }
        guard let service = proxy as? SleepProtectionServiceProtocol else {
            throw ClamshellSleepProtectionError.serviceConnectionFailed("invalid XPC service")
        }

        service.beginProtection { identifier, message in
            resultLock.lock()
            sessionID = identifier
            failureMessage = message
            resultLock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw ClamshellSleepProtectionError.activationTimedOut
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        guard let sessionID else {
            throw ClamshellSleepProtectionError.serviceConnectionFailed(
                failureMessage ?? "the service rejected the request"
            )
        }
        return sessionID
    }

    private func endProtection(connection: NSXPCConnection, sessionID: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var succeeded = false
        var failureMessage: String?

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            resultLock.lock()
            failureMessage = error.localizedDescription
            resultLock.unlock()
            semaphore.signal()
        }
        guard let service = proxy as? SleepProtectionServiceProtocol else {
            throw ClamshellSleepProtectionError.serviceConnectionFailed("invalid XPC service")
        }

        service.endProtection(sessionID: sessionID) { success, message in
            resultLock.lock()
            succeeded = success
            failureMessage = message
            resultLock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw ClamshellSleepProtectionError.deactivationTimedOut
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        guard succeeded else {
            throw ClamshellSleepProtectionError.serviceConnectionFailed(
                failureMessage ?? "the service rejected the cleanup request"
            )
        }
    }

    private func queryStatus(connection: NSXPCConnection, sessionID: String) -> Bool? {
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var enabled: Bool?

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            semaphore.signal()
        }
        guard let service = proxy as? SleepProtectionServiceProtocol else {
            return nil
        }
        service.protectionStatus(sessionID: sessionID) { active, _ in
            resultLock.lock()
            enabled = active
            resultLock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 2) == .success else { return nil }
        resultLock.lock()
        defer { resultLock.unlock() }
        return enabled
    }
}

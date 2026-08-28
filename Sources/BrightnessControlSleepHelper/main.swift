import BrightnessControlCore
import Darwin
import Foundation
import Security

private enum ProtectionPhase: String, Codable {
    case active
    case restoring
}

private struct PersistedProtectionState: Codable {
    var originalSleepDisabled: Bool
    var sessions: [String: ProtectionLease]
    var phase: ProtectionPhase = .active
}

private struct ProtectionLease: Codable {
    let processID: Int32
    let processStartTime: UInt64
}

private enum SleepServiceError: LocalizedError {
    case commandFailed(String)
    case stateUnavailable
    case stateDidNotChange(Bool)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return message
        case .stateUnavailable:
            return "Could not read the macOS SleepDisabled state."
        case let .stateDidNotChange(enabled):
            return "SleepDisabled did not change to \(enabled ? "Yes" : "No")."
        case let .persistenceFailed(message):
            return "Could not persist sleep-protection ownership: \(message)"
        }
    }
}

private final class SleepProtectionCoordinator: @unchecked Sendable {
    private let stateDirectoryURL = URL(
        fileURLWithPath: "/private/var/db/local.wty.BrightnessControl.SleepHelper",
        isDirectory: true
    )
    private var stateURL: URL {
        stateDirectoryURL.appendingPathComponent("state.json")
    }
    private let lock = NSLock()
    private var state: PersistedProtectionState?
    private var monitor: DispatchSourceTimer?

    init() {
        guard Self.ensureSecureStateDirectory(at: stateDirectoryURL.path) else {
            FileHandle.standardError.write(Data("Sleep helper state directory is not secure.\n".utf8))
            exit(EXIT_FAILURE)
        }
        do {
            state = try loadState()
        } catch {
            FileHandle.standardError.write(Data("Sleep helper state could not be loaded securely: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
        recoverPersistedState()
        startMonitor()
    }

    deinit {
        monitor?.cancel()
    }

    func begin(processID: pid_t) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try pruneDeadSessionsLocked()

        let sessionID = UUID().uuidString
        if state == nil {
            state = PersistedProtectionState(
                originalSleepDisabled: try readSleepDisabled(),
                sessions: [:]
            )
        }
        var sessions = state?.sessions ?? [:]
        sessions = sessions.filter { $0.value.processID != processID }
        state?.sessions = sessions
        state?.phase = .active
        state?.sessions[sessionID] = ProtectionLease(
            processID: processID,
            processStartTime: try processStartTime(processID)
        )

        do {
            try persistStateLocked()
            try setSleepDisabled(true)
            return sessionID
        } catch {
            state?.sessions.removeValue(forKey: sessionID)
            try? finishIfIdleLocked()
            throw error
        }
    }

    func end(sessionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        state?.sessions.removeValue(forKey: sessionID)
        try finishIfIdleLocked()
    }

    func isActive(sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state?.sessions[sessionID] != nil else { return false }
        guard (try? readSleepDisabled()) == true else { return false }
        return true
    }

    func sessionIDs(processID: pid_t) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let startTime = try? processStartTime(processID) else { return [] }
        return Set(
            (state?.sessions ?? [:]).compactMap { sessionID, lease in
                lease.processID == processID && lease.processStartTime == startTime
                    ? sessionID
                    : nil
            }
        )
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard state != nil else { return }
        state?.sessions.removeAll()
        do {
            try finishIfIdleLocked()
        } catch {
            FileHandle.standardError.write(Data("Sleep helper shutdown cleanup failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func startMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.reconcileState()
        }
        monitor = timer
        timer.activate()
    }

    private func recoverPersistedState() {
        lock.lock()
        defer { lock.unlock() }
        guard state != nil else { return }
        do {
            try pruneDeadSessionsLocked()
            if state?.sessions.isEmpty == false {
                state?.phase = .active
                try persistStateLocked()
                try setSleepDisabled(true)
            }
        } catch {
            FileHandle.standardError.write(Data("Sleep helper recovery failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func reconcileState() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try pruneDeadSessionsLocked()
            if state?.sessions.isEmpty == false {
                try setSleepDisabled(true)
            } else {
                try finishIfIdleLocked()
            }
        } catch {
            FileHandle.standardError.write(Data("Sleep helper reconciliation failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func pruneDeadSessionsLocked() throws {
        guard var currentState = state else { return }
        currentState.sessions = currentState.sessions.filter { _, lease in
            guard processIsRunning(pid_t(lease.processID)) else { return false }
            return (try? processStartTime(pid_t(lease.processID))) == lease.processStartTime
        }
        state = currentState
        if currentState.sessions.isEmpty {
            try finishIfIdleLocked()
        } else {
            try persistStateLocked()
        }
    }

    private func finishIfIdleLocked() throws {
        guard let currentState = state, currentState.sessions.isEmpty else {
            try persistStateLocked()
            return
        }

        state?.phase = .restoring
        try persistStateLocked()
        if !currentState.originalSleepDisabled {
            try setSleepDisabled(false)
        }
        try removeStateFileLocked()
        state = nil
    }

    private func loadState() throws -> PersistedProtectionState? {
        let descriptor = open(stateURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor == -1, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw SleepServiceError.persistenceFailed(String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var itemStatus = stat()
        guard fstat(descriptor, &itemStatus) == 0 else {
            throw SleepServiceError.persistenceFailed(String(cString: strerror(errno)))
        }
        guard
            itemStatus.st_uid == 0,
            itemStatus.st_mode & S_IFMT == S_IFREG,
            itemStatus.st_mode & (S_IRWXG | S_IRWXO) == 0,
            itemStatus.st_nlink == 1,
            itemStatus.st_size >= 0,
            itemStatus.st_size <= 1_048_576
        else {
            throw SleepServiceError.persistenceFailed("state.json has unsafe ownership, type, permissions, or size")
        }
        guard let data = try handle.readToEnd() else {
            throw SleepServiceError.persistenceFailed("state.json could not be read")
        }
        return try JSONDecoder().decode(PersistedProtectionState.self, from: data)
    }

    private static func ensureSecureStateDirectory(at path: String) -> Bool {
        var itemStatus = stat()
        if lstat(path, &itemStatus) != 0 {
            guard errno == ENOENT else { return false }
            guard mkdir(path, 0o700) == 0 else { return false }
            guard chown(path, 0, 0) == 0 else { return false }
            guard lstat(path, &itemStatus) == 0 else { return false }
        }
        return itemStatus.st_uid == 0
            && itemStatus.st_mode & S_IFMT == S_IFDIR
            && itemStatus.st_mode & 0o777 == 0o700
    }

    private func persistStateLocked() throws {
        guard let state else {
            try removeStateFileLocked()
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateURL.path
            )
        } catch {
            throw SleepServiceError.persistenceFailed(error.localizedDescription)
        }
    }

    private func removeStateFileLocked() throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        try FileManager.default.removeItem(at: stateURL)
    }

    private func readSleepDisabled() throws -> Bool {
        let result = try ProcessCommandRunner().run([
            "/usr/sbin/ioreg",
            "-r",
            "-n",
            "IOPMrootDomain",
            "-d",
            "1",
            "-k",
            "SleepDisabled"
        ])
        guard result.exitCode == 0 else {
            throw SleepServiceError.commandFailed(result.stderr)
        }
        guard let value = SleepDisabledStateParser.parse(result.stdout) else {
            throw SleepServiceError.stateUnavailable
        }
        return value
    }

    private func setSleepDisabled(_ enabled: Bool) throws {
        if try readSleepDisabled() == enabled { return }
        let result = try ProcessCommandRunner().run([
            "/usr/bin/pmset",
            "disablesleep",
            enabled ? "1" : "0"
        ])
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SleepServiceError.commandFailed(detail)
        }

        let deadline = Date().addingTimeInterval(3)
        repeat {
            if try readSleepDisabled() == enabled { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw SleepServiceError.stateDidNotChange(enabled)
    }

    private func processIsRunning(_ processID: pid_t) -> Bool {
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func processStartTime(_ processID: pid_t) throws -> UInt64 {
        var processInfo = proc_bsdinfo()
        let bytesRead = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard bytesRead == MemoryLayout<proc_bsdinfo>.size else {
            throw SleepServiceError.stateUnavailable
        }
        return UInt64(processInfo.pbi_start_tvsec) * 1_000_000
            + UInt64(processInfo.pbi_start_tvusec)
    }
}

private final class SleepProtectionConnection: NSObject, SleepProtectionServiceProtocol {
    private let coordinator: SleepProtectionCoordinator
    private let processID: pid_t
    private let lock = NSLock()
    private var sessionIDs: Set<String> = []
    private var invalidated = false

    init(coordinator: SleepProtectionCoordinator, processID: pid_t) {
        self.coordinator = coordinator
        self.processID = processID
    }

    func beginProtection(withReply reply: @escaping (String?, String?) -> Void) {
        do {
            let sessionID = try coordinator.begin(processID: processID)
            lock.lock()
            guard !invalidated else {
                lock.unlock()
                try? coordinator.end(sessionID: sessionID)
                reply(nil, "The XPC connection was invalidated.")
                return
            }
            sessionIDs.insert(sessionID)
            lock.unlock()
            reply(sessionID, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func adoptPersistedSessions() {
        let identifiers = coordinator.sessionIDs(processID: processID)
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        sessionIDs.formUnion(identifiers)
        lock.unlock()
    }

    func endProtection(sessionID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        let ownsSession = sessionIDs.contains(sessionID)
        lock.unlock()
        guard ownsSession else {
            reply(false, "This XPC connection does not own the requested session.")
            return
        }

        do {
            try coordinator.end(sessionID: sessionID)
            lock.lock()
            sessionIDs.remove(sessionID)
            lock.unlock()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func protectionStatus(sessionID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        let ownsSession = sessionIDs.contains(sessionID)
        lock.unlock()
        guard ownsSession else {
            reply(false, "This XPC connection does not own the requested session.")
            return
        }

        let active = coordinator.isActive(sessionID: sessionID)
        reply(active, active ? nil : "SleepDisabled is not active for this session.")
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let identifiers = sessionIDs
        sessionIDs.removeAll()
        lock.unlock()
        for identifier in identifiers {
            try? coordinator.end(sessionID: identifier)
        }
    }
}

private final class SleepProtectionListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let coordinator = SleepProtectionCoordinator()

    func shutdown() {
        coordinator.shutdown()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var consoleStatus = stat()
        guard stat("/dev/console", &consoleStatus) == 0 else { return false }
        guard connection.effectiveUserIdentifier == consoleStatus.st_uid else { return false }

        let service = SleepProtectionConnection(
            coordinator: coordinator,
            processID: connection.processIdentifier
        )
        service.adoptPersistedSessions()
        connection.exportedInterface = NSXPCInterface(with: SleepProtectionServiceProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [service] in
            service.invalidate()
        }
        connection.activate()
        return true
    }
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("BrightnessControlSleepHelper must run as root.\n".utf8))
    exit(EXIT_FAILURE)
}

private let delegate = SleepProtectionListenerDelegate()
private let listener = NSXPCListener(machServiceName: "local.wty.BrightnessControl.SleepHelper")
listener.delegate = delegate
if let installedRequirement = installedCallerRequirement() {
    listener.setConnectionCodeSigningRequirement(installedRequirement)
} else if let teamIdentifier = currentTeamIdentifier() {
    listener.setConnectionCodeSigningRequirement(
        "anchor apple generic and identifier \"local.wty.BrightnessControl\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    )
} else {
    FileHandle.standardError.write(Data("BrightnessControlSleepHelper requires a Team ID or installed caller requirement.\n".utf8))
    exit(EXIT_FAILURE)
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
private let terminationSignals = [SIGTERM, SIGINT].map { signalNumber in
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
    source.setEventHandler {
        delegate.shutdown()
        exit(EXIT_SUCCESS)
    }
    source.activate()
    return source
}
listener.resume()
dispatchMain()

private func installedCallerRequirement() -> String? {
    let directoryPath = "/Library/PrivilegedHelperTools"
    let requirementPath = "\(directoryPath)/local.wty.BrightnessControl.SleepHelper.caller.requirement"
    var directoryStatus = stat()
    guard
        lstat(directoryPath, &directoryStatus) == 0,
        directoryStatus.st_uid == 0,
        directoryStatus.st_mode & S_IFMT == S_IFDIR,
        directoryStatus.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
        return nil
    }

    let descriptor = open(requirementPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var itemStatus = stat()
    guard
        fstat(descriptor, &itemStatus) == 0,
        itemStatus.st_uid == 0,
        itemStatus.st_mode & S_IFMT == S_IFREG,
        itemStatus.st_mode & (S_IRWXG | S_IRWXO) == 0,
        itemStatus.st_nlink == 1,
        itemStatus.st_size > 0,
        itemStatus.st_size <= 16_384,
        let data = try? handle.readToEnd(),
        let requirement = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !requirement.isEmpty
    else {
        return nil
    }
    return requirement
}

private func currentTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess,
        let values = information as? [String: Any]
    else {
        return nil
    }
    return values[kSecCodeInfoTeamIdentifier as String] as? String
}

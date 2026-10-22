import Foundation
import Darwin
import HogCore

public enum HelperConstants {
    public static let service = "local.memoryhogkiller.helper"
    public static let executable = "/Library/PrivilegedHelperTools/local.memoryhogkiller.helper"
    public static let plist = "/Library/LaunchDaemons/local.memoryhogkiller.helper.plist"
    public static let supportDirectory = "/Library/Application Support/MemoryHogKiller"
    public static let trustFile = supportDirectory + "/Trust.plist"
    public static let packageName = "Hogtied Admin Helper.pkg"
    public static let protocolVersion = 2
}

@objc public protocol HogHelperProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func updatePolicy(_ data: Data, withReply reply: @escaping (String?) -> Void)
    func performCheck(_ data: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

public struct HelperPolicy: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let settings: HogSettings
    public let retries: [UUID: RetryState]
    public init(revision: UInt64, settings: HogSettings, retries: [UUID: RetryState] = [:]) {
        self.revision = revision; self.settings = settings; self.retries = retries
    }

    public var isValid: Bool {
        settings.rules.count <= 100
            && Set(settings.rules.map(\.id)).count == settings.rules.count
            && (1_000_000...1_000_000_000_000).contains(settings.limitBytes)
            && settings.intervalSeconds.isFinite && (5...86_400).contains(settings.intervalSeconds)
            && (1...100).contains(settings.maximumAttempts)
            && settings.cooldownSeconds.isFinite && (60...86_400).contains(settings.cooldownSeconds)
            && retries.count <= 100
            && retries.allSatisfy { id, state in
                settings.rules.contains { $0.id == id } && (0...100).contains(state.failures)
                    && (state.pausedAt?.timeIntervalSince1970.isFinite ?? true)
                    && (state.lastIssue?.utf8.count ?? 0) <= 4096
            }
            && settings.rules.allSatisfy {
                !$0.name.isEmpty && $0.name.utf8.count <= 1024
                    && ($0.executablePath?.utf8.count ?? 0) <= 4096
                    && !["*", ".*"].contains($0.name)
            }
    }
}

public struct HelperCheckRequest: Codable, Sendable {
    public let version: Int
    public let policy: HelperPolicy
    public let apps: [RunningApp]
    public let enforce: Bool
    public init(policy: HelperPolicy, apps: [RunningApp], enforce: Bool) {
        version = HelperConstants.protocolVersion
        self.policy = policy; self.apps = apps; self.enforce = enforce
    }
}

public typealias HelperCheckResponse = CheckReport

public struct HelperTrust: Codable, Sendable {
    public var ClientCodeHash: String
    public var HelperCodeHash: String
    public var AllowedUserID: UInt32
    public init(clientCodeHash: String, helperCodeHash: String, allowedUserID: UInt32) {
        ClientCodeHash = clientCodeHash; HelperCodeHash = helperCodeHash; AllowedUserID = allowedUserID
    }
    public var isValid: Bool {
        func validHash(_ value: String) -> Bool {
            value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return validHash(ClientCodeHash) && validHash(HelperCodeHash) && AllowedUserID >= 501
    }
    public var clientRequirement: String { "identifier \"local.memoryhogkiller.app\" and cdhash H\"\(ClientCodeHash)\"" }
    public var helperRequirement: String { "identifier \"local.memoryhogkiller.helper\" and cdhash H\"\(HelperCodeHash)\"" }

    public static func load() throws -> HelperTrust {
        for path in ["/Library", "/Library/Application Support", "/Library/PrivilegedHelperTools", "/Library/LaunchDaemons",
                     HelperConstants.supportDirectory, HelperConstants.trustFile, HelperConstants.executable, HelperConstants.plist] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw HelperError("Administrator helper is not installed, or its files have unsafe permissions.")
            }
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: HelperConstants.trustFile))
        let trust = try PropertyListDecoder().decode(HelperTrust.self, from: data)
        guard trust.isValid else { throw HelperError("Administrator helper configuration is invalid. Reinstall the helper.") }
        return trust
    }
}

public struct HelperError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ description: String) { errorDescription = description }
}

// One worker is created for each authenticated XPC connection. New policy
// revisions invalidate scans that are already in flight on that connection.
public final class HelperWorker: NSObject, HogHelperProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var policy: HelperPolicy?
    private var active = true
    private var checking = false
    private let clientUID: UInt32
    private let clientPID: Int32

    public init(clientUID: UInt32, clientPID: Int32) { self.clientUID = clientUID; self.clientPID = clientPID }

    public func invalidate() { lock.lock(); active = false; policy = nil; lock.unlock() }

    public func ping(withReply reply: @escaping (String) -> Void) { reply("Hogtied helper 1.2.0 · protocol 2") }

    private func accept(_ value: HelperPolicy) -> Bool {
        guard value.isValid else { return false }
        lock.lock(); defer { lock.unlock() }
        guard active, value.revision >= (policy?.revision ?? 0) else { return false }
        // A revision identifies one immutable configuration.
        if let existing = policy, existing.revision == value.revision, existing != value { return false }
        policy = value
        return true
    }

    public func updatePolicy(_ data: Data, withReply reply: @escaping (String?) -> Void) {
        guard data.count <= 256_000,
              let value = try? JSONDecoder().decode(HelperPolicy.self, from: data), value.isValid else {
            // Never leave an old armed policy active after an invalid update.
            invalidate()
            reply("Rejected an invalid monitoring policy; the connection has been disarmed."); return
        }
        guard accept(value) else {
            reply("Rejected an invalid or outdated monitoring policy."); return
        }
        reply(nil)
    }

    public func isCurrent(_ value: HelperPolicy) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && policy == value
            && value.settings.enabled && value.settings.administratorEnabled
    }

    public func performCheck(_ data: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        guard data.count <= 2_000_000,
              let request = try? JSONDecoder().decode(HelperCheckRequest.self, from: data),
              request.version == HelperConstants.protocolVersion, request.apps.count <= 4096,
              accept(request.policy) else {
            reply(nil, "Rejected an invalid or outdated monitoring request."); return
        }
        lock.lock()
        guard !checking else { lock.unlock(); reply(nil, "A check is already in progress."); return }
        checking = true
        lock.unlock()
        // Keep XPC's incoming queue free for policy changes and cancellation.
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { lock.lock(); checking = false; lock.unlock() }
            let response = CheckEngine.perform(settings: request.policy.settings, apps: request.apps,
                retries: request.policy.retries, enforce: request.enforce,
                watchUserIDs: [clientUID, 0], terminationUserIDs: [clientUID, 0], protectedPIDs: [clientPID],
                shouldContinue: { self.isCurrent(request.policy) })
            do { reply(try JSONEncoder().encode(response), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }
}

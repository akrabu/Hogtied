import Foundation
import Darwin

public enum TargetKind: String, Codable, Hashable, Sendable {
    case automatic, application, process
}

public struct WatchRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bundleIdentifier: String?
    public var targetKind: TargetKind?
    public var executablePath: String?

    public init(id: UUID = UUID(), name: String, bundleIdentifier: String? = nil,
                targetKind: TargetKind? = nil, executablePath: String? = nil) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleIdentifier = bundleIdentifier
        self.targetKind = targetKind
        self.executablePath = executablePath
    }

    public static func normalized(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if result.hasSuffix(".app") { result.removeLast(4) }
        return result
    }

    public func matches(_ app: RunningApp) -> Bool {
        guard targetKind != .process else { return false }
        if let executablePath, !executablePath.isEmpty { return app.executablePath == executablePath }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier.caseInsensitiveCompare(app.bundleIdentifier ?? "") == .orderedSame
        }
        let target = Self.normalized(name)
        guard !target.isEmpty else { return false }
        return target == Self.normalized(app.name)
            || target == Self.normalized(URL(fileURLWithPath: app.bundlePath).lastPathComponent)
            || target == (app.bundleIdentifier ?? "").lowercased()
    }

    public func matches(_ process: ProcessRecord) -> Bool {
        guard bundleIdentifier == nil, targetKind != .application else { return false }
        if let executablePath, !executablePath.isEmpty { return process.path == executablePath }
        let target = Self.normalized(name)
        guard !target.isEmpty else { return false }
        return target == Self.normalized(process.name)
            || (!process.path.isEmpty && target == Self.normalized(URL(fileURLWithPath: process.path).lastPathComponent))
    }
}

public struct HogSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var limitBytes: UInt64 = 1_000_000_000
    public var intervalSeconds: Double = 300
    public var includeHelpers = true
    public var rules: [WatchRule] = []
    // Optional for compatibility with settings saved by version 1.0.
    public var useAdministratorHelper: Bool?
    public var administratorEnabled: Bool { useAdministratorHelper ?? false }
    public var alertsEnabled = false
    public var maximumAttempts = 3
    public var automaticallyResume = false
    public var cooldownSeconds: Double = 1_800
    public var monitoringActive: Bool { alertsEnabled || (enabled && !rules.isEmpty) }
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, limitBytes, intervalSeconds, includeHelpers, rules, useAdministratorHelper
        case alertsEnabled, maximumAttempts, automaticallyResume, cooldownSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        limitBytes = try c.decodeIfPresent(UInt64.self, forKey: .limitBytes) ?? 1_000_000_000
        intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 300
        includeHelpers = try c.decodeIfPresent(Bool.self, forKey: .includeHelpers) ?? true
        rules = try c.decodeIfPresent([WatchRule].self, forKey: .rules) ?? []
        useAdministratorHelper = try c.decodeIfPresent(Bool.self, forKey: .useAdministratorHelper)
        alertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? false
        maximumAttempts = try c.decodeIfPresent(Int.self, forKey: .maximumAttempts) ?? 3
        automaticallyResume = try c.decodeIfPresent(Bool.self, forKey: .automaticallyResume) ?? false
        cooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .cooldownSeconds) ?? 1_800
    }

    public mutating func validate() {
        limitBytes = min(max(limitBytes, 1_000_000), 1_000_000_000_000)
        if !intervalSeconds.isFinite { intervalSeconds = 300 }
        intervalSeconds = min(max(intervalSeconds, 5), 86_400)
        maximumAttempts = min(max(maximumAttempts, 1), 100)
        if !cooldownSeconds.isFinite { cooldownSeconds = 1_800 }
        cooldownSeconds = min(max(cooldownSeconds, 60), 86_400)
        var seen = Set<UUID>()
        rules = Array(rules.filter {
            !Self.invalidName($0.name) && $0.name.utf8.count <= 1024
                && ($0.executablePath?.utf8.count ?? 0) <= 4096
                && seen.insert($0.id).inserted
        }.prefix(100))
    }

    private static func invalidName(_ name: String) -> Bool {
        let normalized = WatchRule.normalized(name)
        return normalized.isEmpty || ["*", ".*"].contains(normalized)
    }
}

public struct RunningApp: Codable, Sendable {
    public let pid: Int32
    public let name: String
    public let bundleIdentifier: String?
    public let bundlePath: String
    public let executablePath: String?
    public let launchTime: Double?
    public let isRegular: Bool

    public init(pid: Int32, name: String, bundleIdentifier: String?, bundlePath: String,
                executablePath: String? = nil, launchTime: Double? = nil, isRegular: Bool = true) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.launchTime = launchTime
        self.isRegular = isRegular
    }
}

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public struct ProcessRecord: Codable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let uid: UInt32
    public let path: String
    public let memoryBytes: UInt64?
    public let name: String
    public var pid: Int32 { identity.pid }

    public init(identity: ProcessIdentity, parentPID: Int32, uid: UInt32, path: String, memoryBytes: UInt64?, name: String? = nil) {
        self.identity = identity
        self.parentPID = parentPID
        self.uid = uid
        self.path = path
        self.memoryBytes = memoryBytes
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    }
}

public struct MemorySample: Codable, Sendable {
    public let ruleID: UUID
    public let roots: [ProcessRecord]
    public let processes: [ProcessRecord]
    public let missingRoots: Int
    public var bytes: UInt64 { processes.compactMap(\.memoryBytes).reduce(0, +) }
    public var unavailableCount: Int { processes.filter { $0.memoryBytes == nil }.count + missingRoots }
    public var isRunning: Bool { !roots.isEmpty || missingRoots > 0 }
    public var isMeasurable: Bool { !roots.isEmpty && processes.contains { $0.memoryBytes != nil } }
    public var requiresAdministratorAccess: Bool { processes.contains { $0.uid != getuid() } }
    public var isRootOwned: Bool { roots.contains { $0.uid == 0 } }

    public init(ruleID: UUID, roots: [ProcessRecord], processes: [ProcessRecord], missingRoots: Int = 0) {
        self.ruleID = ruleID
        self.roots = roots
        self.processes = processes
        self.missingRoots = missingRoots
    }

    public func shouldTerminate(enabled: Bool, limitBytes: UInt64) -> Bool {
        enabled && isMeasurable && bytes > limitBytes
    }
}

public enum ActivityKind: String, Codable, Sendable {
    case alert, quit, pendingRecovery, recovered, paused, resumed, skipped
}

public struct ActivityEntry: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public let app: String
    public let bytes: UInt64
    public let message: String
    public let succeeded: Bool
    // Optional additions retain compatibility with activity saved by 1.0/1.1.
    public var kind: ActivityKind?
    public var process: ProcessRecord?
    public var ruleID: UUID?
    public var limitBytes: UInt64?
    public init(app: String, bytes: UInt64, message: String, succeeded: Bool,
                kind: ActivityKind? = nil, process: ProcessRecord? = nil,
                ruleID: UUID? = nil, limitBytes: UInt64? = nil) {
        self.app = app
        self.bytes = bytes
        self.message = message
        self.succeeded = succeeded
        self.kind = kind
        self.process = process
        self.ruleID = ruleID
        self.limitBytes = limitBytes
    }
}

public enum MemoryText {
    public static func format(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
    public static func interval(_ seconds: Double) -> String {
        if seconds >= 3600 && seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            let value = Int(seconds / 3600)
            return "\(value) \(value == 1 ? "hour" : "hours")"
        }
        if seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let value = Int(seconds / 60)
            return "\(value) \(value == 1 ? "minute" : "minutes")"
        }
        return "\(Int(seconds)) seconds"
    }
}

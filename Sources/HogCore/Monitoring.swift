import Foundation
import Darwin

public struct ProcessInventory: Codable, Sendable {
    public let processes: [ProcessRecord]
    public let enumerationComplete: Bool
    public var unreadableCount: Int { processes.filter { $0.memoryBytes == nil }.count }
    public init(processes: [ProcessRecord], enumerationComplete: Bool) {
        self.processes = processes; self.enumerationComplete = enumerationComplete
    }
}

public struct ScanReport: Codable, Sendable {
    public let inventory: ProcessInventory
    public let samples: [MemorySample]
    public init(inventory: ProcessInventory, samples: [MemorySample]) {
        self.inventory = inventory; self.samples = samples
    }
}

public struct SpikeTracker: Codable, Sendable {
    public private(set) var active: Set<ProcessIdentity> = []
    public init() {}
    public mutating func reset() { active.removeAll() }
    public mutating func update(_ inventory: ProcessInventory, limitBytes: UInt64) -> [ProcessRecord] {
        if inventory.enumerationComplete {
            active.formIntersection(Set(inventory.processes.map(\.identity)))
        }
        var spikes: [ProcessRecord] = []
        for process in inventory.processes {
            guard let bytes = process.memoryBytes else { continue }
            if bytes > limitBytes {
                if active.insert(process.identity).inserted { spikes.append(process) }
            } else { active.remove(process.identity) }
        }
        return spikes.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }
}

public enum RecoveryOutcome: String, Codable, Sendable {
    case recovered, failed, exited, unavailable, cancelled, skipped
}

public enum RecoveryVerification {
    public static func classify(_ sample: MemorySample, inventoryComplete: Bool, limitBytes: UInt64) -> RecoveryOutcome {
        if sample.isMeasurable && sample.bytes > limitBytes { return .failed }
        if sample.isRunning {
            return inventoryComplete && sample.isMeasurable && sample.unavailableCount == 0 ? .recovered : .unavailable
        }
        return inventoryComplete ? .exited : .unavailable
    }
}

public struct RetryState: Codable, Equatable, Sendable {
    public var failures = 0
    public var pendingRecovery = false
    public var pausedAt: Date?
    public var lastIssue: String?
    public var isPaused: Bool { pausedAt != nil }
    public init() {}
    public mutating func resume() { self = RetryState() }
    public func resumeDate(settings: HogSettings) -> Date? {
        guard settings.automaticallyResume, let pausedAt else { return nil }
        return pausedAt.addingTimeInterval(settings.cooldownSeconds)
    }

    // Preview scans may observe a healthy restart, but an exit is only settled
    // at the next enforcement check, leaving time for launchd to replace it.
    public mutating func observe(_ sample: MemorySample, inventoryComplete: Bool,
                                 settlePending: Bool, settings: HogSettings, now: Date) -> [ActivityKind] {
        var events: [ActivityKind] = []
        if let deadline = resumeDate(settings: settings), now >= deadline {
            resume(); events.append(.resumed)
        }
        guard !isPaused else { return events }
        let outcome = RecoveryVerification.classify(sample, inventoryComplete: inventoryComplete, limitBytes: settings.limitBytes)
        if outcome == .recovered || (outcome == .exited && settlePending) {
            if failures > 0 || pendingRecovery { events.append(.recovered) }
            failures = 0; pendingRecovery = false; lastIssue = nil
        } else if pendingRecovery && settlePending && outcome == .failed {
            failures += 1; pendingRecovery = false
        }
        if settlePending && failures >= settings.maximumAttempts {
            pausedAt = now; events.append(.paused)
        }
        return events
    }

    public mutating func record(_ attempt: QuitAttempt, settings: HogSettings, now: Date) -> Bool {
        guard attempt.attempted > 0, attempt.outcome != .cancelled, attempt.outcome != .skipped else { return false }
        lastIssue = nil
        switch attempt.outcome {
        case .recovered: failures = 0; pendingRecovery = false
        case .failed: failures += 1; pendingRecovery = false
        case .exited, .unavailable: pendingRecovery = true
        case .cancelled, .skipped: break
        }
        if failures >= settings.maximumAttempts { pausedAt = now; return true }
        return false
    }
}

public struct QuitAttempt: Codable, Sendable {
    public let ruleID: UUID
    public let beforeBytes: UInt64
    public let attempted: Int
    public let signaled: Int
    public var outcome: RecoveryOutcome
    public var detail: String
    public init(ruleID: UUID, beforeBytes: UInt64, attempted: Int, signaled: Int,
                outcome: RecoveryOutcome, detail: String) {
        self.ruleID = ruleID; self.beforeBytes = beforeBytes; self.attempted = attempted
        self.signaled = signaled; self.outcome = outcome; self.detail = detail
    }
}

public struct CheckReport: Codable, Sendable {
    public let version: Int
    public let inventory: ProcessInventory
    public let samples: [MemorySample]
    public let retries: [UUID: RetryState]
    public let attempts: [QuitAttempt]
    public let activity: [ActivityEntry]
    public init(inventory: ProcessInventory, samples: [MemorySample], retries: [UUID: RetryState],
                attempts: [QuitAttempt], activity: [ActivityEntry]) {
        version = 2; self.inventory = inventory; self.samples = samples
        self.retries = retries; self.attempts = attempts; self.activity = activity
    }
}

public enum WatchPromotion {
    public static func refusalReason(_ process: ProcessRecord, userID: UInt32, controllerPID: Int32) -> String? {
        if process.uid != userID && process.uid != 0 { return "another user's process is outside the helper's scope" }
        if process.path.hasSuffix("/Contents/MacOS/Hogtied") || process.path.hasSuffix("/local.memoryhogkiller.helper") {
            return "Hogtied and its helper are protected"
        }
        return ProcessTerminator.refusalReason(for: process, allowedUserIDs: [userID, 0], protectedPIDs: [controllerPID])
    }
    public static func rule(for process: ProcessRecord) -> WatchRule {
        WatchRule(name: process.name.isEmpty ? URL(fileURLWithPath: process.path).lastPathComponent : process.name,
                  targetKind: .process, executablePath: process.path.isEmpty ? nil : process.path)
    }
}

public enum NotificationPermission: Sendable { case authorized, denied, notRequested }
public enum NotificationPolicy {
    public static func shouldDeliver(alertsEnabled: Bool, permission: NotificationPermission) -> Bool {
        alertsEnabled && permission == .authorized
    }
}

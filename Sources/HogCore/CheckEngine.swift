import Foundation
import Darwin

public enum CheckEngine {
    public typealias Signal = (MemorySample, Set<UInt32>, Set<Int32>, () -> Bool) -> TerminationResult

    // Both execution modes use this engine. Test seams replace the inventory,
    // signal operation, and verification delay; production never injects them.
    public static func perform(settings: HogSettings, apps: [RunningApp], retries saved: [UUID: RetryState],
                               enforce: Bool, watchUserIDs: Set<UInt32>? = nil,
                               terminationUserIDs: Set<UInt32>? = nil, protectedPIDs: Set<Int32> = [],
                               shouldContinue: @escaping () -> Bool = { true },
                               inventoryProvider: () -> ProcessInventory = { ProcessScanner.inventory() },
                               signal: Signal = { ProcessTerminator.terminate($0, allowedUserIDs: $1, protectedPIDs: $2, shouldContinue: $3) },
                               wait: (UInt32) -> Void = { usleep($0) }, verificationPasses: Int = 8,
                               now: Date = Date()) -> CheckReport {
        let watchUIDs = watchUserIDs ?? [getuid(), 0]
        let killUIDs = terminationUserIDs ?? [getuid()]
        let initial = ProcessScanner.report(rules: settings.rules, apps: apps, includeHelpers: settings.includeHelpers,
            allowedUserIDs: watchUIDs, inventory: inventoryProvider())
        if enforce && settings.enabled && !shouldContinue() {
            return CheckReport(inventory: initial.inventory, samples: initial.samples, retries: saved, attempts: [], activity: [])
        }
        var samples = initial.samples
        let ruleIDs = Set(settings.rules.map(\.id))
        var retries = saved.filter { ruleIDs.contains($0.key) }
        var activity: [ActivityEntry] = []
        var attempts: [QuitAttempt] = []
        var originals: [UUID: MemorySample] = [:]
        var targets: [UUID: MemorySample] = [:]
        var handled = Set<ProcessIdentity>()

        func event(_ kind: ActivityKind, rule: WatchRule, sample: MemorySample, state: RetryState) -> ActivityEntry {
            let message: String
            switch kind {
            case .paused: message = "Watcher paused after \(state.failures) unsuccessful quit attempts. Resume manually" + (settings.automaticallyResume ? " or after the \(MemoryText.interval(settings.cooldownSeconds)) cooldown." : ".")
            case .resumed: message = "Cooldown finished; watcher resumed with a fresh attempt count."
            default: message = "Memory recovered below the limit or the process remained exited. Attempt count reset."
            }
            return ActivityEntry(app: rule.name, bytes: sample.measuredBytes(mode: settings.quitMode), message: message,
                succeeded: kind != .paused, kind: kind, process: sample.roots.first,
                ruleID: rule.id, limitBytes: settings.limitBytes)
        }

        for sample in initial.samples {
            guard let rule = settings.rules.first(where: { $0.id == sample.ruleID }) else { continue }
            var state = retries[rule.id] ?? RetryState()
            for kind in state.observe(sample, inventoryComplete: initial.inventory.enumerationComplete,
                settlePending: enforce && settings.enabled, settings: settings, now: now) {
                activity.append(event(kind, rule: rule, sample: sample, state: state))
            }
            retries[rule.id] = state
            guard enforce, settings.enabled, !state.isPaused, shouldContinue(),
                  sample.shouldTerminate(enabled: true, limitBytes: settings.limitBytes, mode: settings.quitMode) else { continue }
            let candidates = sample.terminationTargets(limitBytes: settings.limitBytes, mode: settings.quitMode)
            let selected = candidates.selecting(candidates.processes.filter { !handled.contains($0.identity) })
            guard !selected.processes.isEmpty else { continue }
            if let reason = selected.processes.compactMap({
                ProcessTerminator.refusalReason(for: $0, allowedUserIDs: killUIDs, protectedPIDs: protectedPIDs)
            }).first {
                if state.lastIssue != reason {
                    activity.append(ActivityEntry(app: rule.name, bytes: selected.measuredBytes(mode: settings.quitMode),
                        message: "Quit skipped: \(reason). No retry used.", succeeded: false,
                        kind: .skipped, process: selected.processes.first, ruleID: rule.id, limitBytes: settings.limitBytes))
                }
                state.lastIssue = reason; retries[rule.id] = state
                continue
            }
            let result = signal(selected, killUIDs, protectedPIDs, shouldContinue)
            handled.formUnion(selected.processes.map(\.identity))
            guard result.attempted > 0 else { continue }
            originals[rule.id] = sample
            targets[rule.id] = selected
            attempts.append(QuitAttempt(ruleID: rule.id, beforeBytes: selected.measuredBytes(mode: settings.quitMode),
                attempted: result.attempted, signaled: result.killed,
                outcome: result.cancelled ? .cancelled : .unavailable,
                detail: result.failures.joined(separator: "; ")))
        }

        // Verify all attempted groups together, not two seconds per watch rule.
        if !attempts.isEmpty {
            for pass in 0...max(0, verificationPasses) {
                guard shouldContinue() else {
                    for i in attempts.indices { attempts[i].outcome = .cancelled }
                    break
                }
                if pass > 0 { wait(250_000) }
                let inventory = inventoryProvider()
                for i in attempts.indices where attempts[i].outcome != .recovered && attempts[i].outcome != .cancelled {
                    guard let original = originals[attempts[i].ruleID], let selected = targets[original.ruleID],
                          let rule = settings.rules.first(where: { $0.id == original.ruleID }) else { continue }
                    let descriptors = ProcessScanner.recoveryApps(original: apps, sample: original, inventory: inventory)
                    let sample = ProcessScanner.report(rules: [rule], apps: descriptors, includeHelpers: settings.includeHelpers,
                        allowedUserIDs: watchUIDs, inventory: inventory).samples[0]
                    let scope = RecoveryVerification.scope(sample, original: original, targets: selected, mode: settings.quitMode)
                    attempts[i].outcome = RecoveryVerification.classify(scope,
                        inventoryComplete: inventory.enumerationComplete, limitBytes: settings.limitBytes, mode: settings.quitMode)
                    if let index = samples.firstIndex(where: { $0.ruleID == sample.ruleID }) { samples[index] = sample }
                }
                if attempts.allSatisfy({ $0.outcome == .recovered || $0.outcome == .cancelled }) { break }
            }
        }

        for attempt in attempts {
            guard let rule = settings.rules.first(where: { $0.id == attempt.ruleID }),
                  let original = originals[rule.id], let selected = targets[rule.id] else { continue }
            var state = retries[rule.id] ?? RetryState()
            let paused = state.record(attempt, settings: settings, now: now)
            retries[rule.id] = state
            let message: String
            let kind: ActivityKind
            switch attempt.outcome {
            case .recovered:
                message = "Memory is back below \(MemoryText.format(settings.limitBytes)) after the quit attempt. A healthy service restart counts as recovery."
                kind = .recovered
            case .failed:
                message = "Attempt \(state.failures) of \(settings.maximumAttempts): memory remains over \(MemoryText.format(settings.limitBytes))."
                kind = .quit
            case .exited:
                message = "Force-quit \(attempt.signaled) processes; awaiting the next check to confirm a healthy restart or continued exit."
                kind = .pendingRecovery
            case .unavailable:
                message = "Quit attempted; recovery memory is not readable yet. No failure is counted until an over-limit reading is available."
                kind = .pendingRecovery
            default:
                message = "Quit interrupted by changed settings. The retry state was not advanced."
                kind = .quit
            }
            let scopeDetail = settings.quitMode == .offendingProcesses
                ? " Individual-process mode; selected PID\(selected.processes.count == 1 ? "" : "s") \(selected.processes.map { String($0.pid) }.joined(separator: ", "))."
                : ""
            activity.append(ActivityEntry(app: rule.name, bytes: attempt.beforeBytes,
                message: message + scopeDetail + (attempt.detail.isEmpty ? "" : " " + attempt.detail), succeeded: attempt.outcome == .recovered,
                kind: kind, process: selected.processes.max { ($0.memoryBytes ?? 0) < ($1.memoryBytes ?? 0) }, ruleID: rule.id, limitBytes: settings.limitBytes))
            if paused { activity.append(event(.paused, rule: rule, sample: original, state: state)) }
        }
        if enforce && settings.enabled && !shouldContinue() {
            retries = saved
            activity.removeAll { $0.kind == .paused || $0.kind == .resumed }
        }
        return CheckReport(inventory: initial.inventory, samples: samples, retries: retries, attempts: attempts, activity: activity)
    }
}

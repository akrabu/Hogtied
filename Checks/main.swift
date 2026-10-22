import Foundation
import Darwin
import HogCore
import HogIPC
import Security

// A dependency-free test runner, so checks also run with Command Line Tools
// on Macs that do not have the full Xcode/XCTest installation.
final class HogCoreChecks {
    private let rootID: Int32 = 99001
    private func process(_ pid: Int32, parent: Int32 = 1, path: String = "/Applications/Hog.app/Contents/MacOS/Hog",
                         bytes: UInt64? = 100, start: UInt64 = 123) -> ProcessRecord {
        ProcessRecord(identity: ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0),
                      parentPID: parent, uid: getuid(), path: path, memoryBytes: bytes)
    }
    private func app(_ pid: Int32 = 99001, name: String = "Hog", bundleID: String = "test.hog",
                     bundlePath: String = "/Applications/Hog.app", regular: Bool = true) -> RunningApp {
        RunningApp(pid: pid, name: name, bundleIdentifier: bundleID, bundlePath: bundlePath, isRegular: regular)
    }

    func testDefaultsAndSettingsRoundTrip() throws {
        var settings = HogSettings()
        XCTAssertEqual(settings.limitBytes, 1_000_000_000)
        XCTAssertEqual(settings.intervalSeconds, 300)
        XCTAssertEqual(settings.quitMode, .watchedGroup)
        XCTAssertFalse(settings.enabled)
        settings.enabled = true
        settings.rules = [WatchRule(name: "Safari")]
        settings.intervalSeconds = 600
        settings.quitMode = .offendingProcesses
        let restored = try JSONDecoder().decode(HogSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
    }

    func testInvalidStoredSettingsAreClamped() {
        var settings = HogSettings()
        settings.limitBytes = 0
        settings.intervalSeconds = -.infinity
        settings.rules = [WatchRule(name: "   ")]
        settings.validate()
        XCTAssertEqual(settings.limitBytes, 1_000_000)
        XCTAssertEqual(settings.intervalSeconds, 300)
        XCTAssertTrue(settings.rules.isEmpty)
        let duplicate = WatchRule(name: "Hog")
        settings.rules = [duplicate, duplicate, WatchRule(name: "*")]
        settings.maximumAttempts = 999; settings.cooldownSeconds = 1
        settings.validate()
        XCTAssertEqual(settings.rules.count, 1)
        XCTAssertEqual(settings.maximumAttempts, 100)
        XCTAssertEqual(settings.cooldownSeconds, 60)
    }

    func testExactCaseInsensitiveNamesAndBundleIdentifiers() {
        XCTAssertTrue(WatchRule(name: "  HOG.APP  ").matches(app()))
        XCTAssertFalse(WatchRule(name: "Ho").matches(app()))
        XCTAssertFalse(WatchRule(name: "").matches(app()))
        XCTAssertTrue(WatchRule(name: "test.hog").matches(app()))
        XCTAssertTrue(WatchRule(name: "Renamed", bundleIdentifier: "test.hog").matches(app()))
        XCTAssertFalse(WatchRule(name: "Hog", bundleIdentifier: "other.app").matches(app()))
    }

    func testHelpersAreSummedOnceAndUnrelatedAppsExcluded() {
        let rule = WatchRule(name: "Hog")
        let records: [Int32: ProcessRecord] = [
            rootID: process(rootID, bytes: 600),
            99002: process(99002, parent: rootID, path: "/Applications/Hog.app/Contents/Helpers/Worker", bytes: 300),
            99003: process(99003, parent: 99002, path: "/usr/bin/worker", bytes: 200),
            99004: process(99004, parent: rootID, path: "/Applications/Other.app/Contents/MacOS/Other", bytes: 900),
            99005: process(99005, parent: 99004, path: "/usr/bin/other-worker", bytes: 900),
            99006: process(99006, path: "/Applications/Hog.app/Contents/Helpers/Reparented", bytes: 50),
            99007: process(99007, path: "/Applications/Hog.app.evil/Contents/Fake", bytes: 900)
        ]
        let samples = ProcessScanner.aggregate(rules: [rule],
            apps: [app(), app(99004, name: "Other", bundleID: "other.app", bundlePath: "/Applications/Other.app")],
            records: records, includeHelpers: true)
        XCTAssertEqual(samples[0].bytes, 1150)
        XCTAssertEqual(Set(samples[0].processes.map(\.pid)), [99001, 99002, 99003, 99006])
        let mainOnly = ProcessScanner.aggregate(rules: [rule], apps: [app()], records: records, includeHelpers: false)
        XCTAssertEqual(mainOnly[0].bytes, 600)
    }

    func testStrictThresholdAndDisabledEnforcement() {
        let rule = WatchRule(name: "Hog")
        let root = process(rootID, bytes: 1_000_000_000)
        let sample = MemorySample(ruleID: rule.id, roots: [root], processes: [root])
        XCTAssertFalse(sample.shouldTerminate(enabled: true, limitBytes: 1_000_000_000))
        XCTAssertTrue(sample.shouldTerminate(enabled: true, limitBytes: 999_999_999))
        XCTAssertFalse(sample.shouldTerminate(enabled: false, limitBytes: 1))
        XCTAssertFalse(MemorySample(ruleID: rule.id, roots: [], processes: []).shouldTerminate(enabled: true, limitBytes: 1))
    }

    func testMissingMemoryDoesNotPretendToBeAValidZeroReading() {
        let rule = WatchRule(name: "Hog")
        let root = process(rootID, bytes: nil)
        let sample = MemorySample(ruleID: rule.id, roots: [root], processes: [root])
        XCTAssertFalse(sample.isMeasurable)
        XCTAssertEqual(sample.unavailableCount, 1)
        XCTAssertFalse(sample.shouldTerminate(enabled: true, limitBytes: 1))
    }

    func testReusedRootPIDIsRejectedByPathAndLaunchTime() {
        let rule = WatchRule(name: "Hog")
        let target = RunningApp(pid: rootID, name: "Hog", bundleIdentifier: "test.hog", bundlePath: "/Applications/Hog.app",
                                executablePath: "/Applications/Hog.app/Contents/MacOS/Hog", launchTime: 123)
        let wrongPath = ProcessScanner.aggregate(rules: [rule], apps: [target],
            records: [rootID: process(rootID, path: "/usr/bin/unrelated")], includeHelpers: true)[0]
        XCTAssertFalse(wrongPath.isMeasurable)
        XCTAssertEqual(wrongPath.missingRoots, 1)
        let wrongStart = ProcessScanner.aggregate(rules: [rule], apps: [target],
            records: [rootID: process(rootID, start: 456)], includeHelpers: true)[0]
        XCTAssertFalse(wrongStart.isMeasurable)
    }

    func testSelfProtectionAndStaleIdentityNeverSignals() throws {
        let own = try XCTUnwrap(ProcessScanner.record(for: getpid()))
        let sample = MemorySample(ruleID: UUID(), roots: [own], processes: [own])
        XCTAssertEqual(ProcessTerminator.terminate(sample).killed, 0)
        XCTAssertFalse(ProcessTerminator.terminate(sample).failures.isEmpty)
        let root = process(rootID, start: 0)
        let stale = MemorySample(ruleID: UUID(), roots: [root], processes: [root])
        XCTAssertEqual(ProcessTerminator.terminate(stale).killed, 0)
    }

    func testLiveFootprintAndForceQuitOnlyDisposableProcess() throws {
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        target.arguments = ["-e", "my $memory = 'x' x (80 * 1024 * 1024); sleep 30;"]
        let companion = Process()
        companion.executableURL = URL(fileURLWithPath: "/bin/sleep")
        companion.arguments = ["30"]
        try target.run()
        defer {
            if target.isRunning { target.terminate() }
            if companion.isRunning { companion.terminate() }
            target.waitUntilExit()
            companion.waitUntilExit()
        }
        try companion.run()
        let companionRecord = try XCTUnwrap(ProcessScanner.record(for: companion.processIdentifier))
        let wrongIdentity = ProcessRecord(identity: ProcessIdentity(pid: companionRecord.pid, startSeconds: 0, startMicroseconds: 0),
                                          parentPID: companionRecord.parentPID, uid: getuid(), path: companionRecord.path, memoryBytes: 100)
        let staleSample = MemorySample(ruleID: UUID(), roots: [wrongIdentity], processes: [wrongIdentity])
        XCTAssertEqual(ProcessTerminator.terminate(staleSample).killed, 0)
        XCTAssertTrue(companion.isRunning, "A process whose PID was reused must not be signaled.")
        var reading: ProcessRecord?
        for _ in 0..<100 {
            reading = ProcessScanner.record(for: target.processIdentifier)
            if let bytes = reading?.memoryBytes, bytes > 50_000_000 { break }
            usleep(50_000)
        }
        let record = try XCTUnwrap(reading)
        XCTAssertGreaterThan(try XCTUnwrap(record.memoryBytes), 50_000_000)
        let rule = WatchRule(name: "Disposable Memory Hog")
        let targetApp = RunningApp(pid: target.processIdentifier, name: rule.name, bundleIdentifier: nil,
                                   bundlePath: "", executablePath: record.path)
        let sample = try XCTUnwrap(ProcessScanner.scan(rules: [rule], apps: [targetApp], includeHelpers: false).first)
        XCTAssertTrue(sample.shouldTerminate(enabled: true, limitBytes: 32_000_000))
        var alertSettings = HogSettings(); alertSettings.alertsEnabled = true; alertSettings.limitBytes = 32_000_000
        let alertReport = CheckEngine.perform(settings: alertSettings, apps: [], retries: [:], enforce: true)
        XCTAssertTrue(alertReport.inventory.processes.contains { $0.identity == record.identity })
        var tracker = SpikeTracker()
        XCTAssertTrue(tracker.update(alertReport.inventory, limitBytes: alertSettings.limitBytes).contains { $0.identity == record.identity })
        XCTAssertTrue(target.isRunning, "Alert-only scanning never terminates the disposable process.")
        let result = ProcessTerminator.terminate(sample)
        XCTAssertEqual(result.killed, 1)
        XCTAssertTrue(result.failures.isEmpty)
        target.waitUntilExit()
        XCTAssertEqual(target.terminationReason, .uncaughtSignal)
        XCTAssertEqual(target.terminationStatus, SIGKILL)
        XCTAssertTrue(companion.isRunning, "An unrelated companion process must stay alive.")
    }

    func testLegacySettingsAndBackgroundProcessMatching() throws {
        let legacy = """
        {"enabled":true,"limitBytes":1000000000,"intervalSeconds":300,"includeHelpers":true,"rules":[{"id":"11111111-1111-1111-1111-111111111111","name":"Old App"}]}
        """
        let restored = try JSONDecoder().decode(HogSettings.self, from: Data(legacy.utf8))
        XCTAssertFalse(restored.administratorEnabled)
        XCTAssertEqual(restored.quitMode, .watchedGroup, "Older preferences retain whole-group behavior.")
        XCTAssertEqual(restored.rules.first?.name, "Old App")
        let background = ProcessRecord(identity: ProcessIdentity(pid: 99010, startSeconds: 123, startMicroseconds: 0),
            parentPID: 1, uid: 0, path: "/Library/Application Support/Vendor/Daemon.app/Contents/MacOS/ExampleDaemon",
            memoryBytes: nil, name: "ExampleDaemon")
        let rule = WatchRule(name: "exampledaemon", targetKind: .process)
        let sample = ProcessScanner.aggregate(rules: [rule], apps: [], records: [background.pid: background], includeHelpers: false)[0]
        XCTAssertTrue(sample.isRunning)
        XCTAssertTrue(sample.isRootOwned)
        XCTAssertTrue(sample.requiresAdministratorAccess)
        XCTAssertFalse(sample.isMeasurable)
        XCTAssertEqual(sample.roots.count, 1)
        XCTAssertFalse(WatchRule(name: "Example", targetKind: .process).matches(background))
        XCTAssertFalse(WatchRule(name: "ExampleDaemon", targetKind: .application).matches(background))
        XCTAssertTrue(WatchRule(name: "Pinned", targetKind: .process, executablePath: background.path).matches(background))
        XCTAssertFalse(WatchRule(name: "ExampleDaemon", targetKind: .process, executablePath: "/different/path").matches(background))
        let pinned = WatchRule(name: "ExampleDaemon", executablePath: background.path)
        XCTAssertFalse(pinned.matches(app(name: "ExampleDaemon")))
    }

    func testAdministratorBoundariesAndTrustRequirements() throws {
        let root = ProcessRecord(identity: ProcessIdentity(pid: 99020, startSeconds: 123, startMicroseconds: 0),
            parentPID: 1, uid: 0, path: "/Library/ThirdParty/Daemon", memoryBytes: 2_000_000_000)
        XCTAssertTrue(ProcessTerminator.refusalReason(for: root, allowedUserIDs: [getuid()], protectedPIDs: []) != nil)
        XCTAssertEqual(ProcessTerminator.refusalReason(for: root, allowedUserIDs: [getuid(), 0], protectedPIDs: []), nil)
        XCTAssertTrue(ProcessTerminator.refusalReason(for: root, allowedUserIDs: [getuid(), 0], protectedPIDs: [root.pid]) != nil)
        let system = ProcessRecord(identity: root.identity, parentPID: 1, uid: 0, path: "/usr/libexec/securityd", memoryBytes: root.memoryBytes)
        XCTAssertTrue(ProcessTerminator.refusalReason(for: system, allowedUserIDs: [0], protectedPIDs: []) != nil)
        let trust = HelperTrust(clientCodeHash: String(repeating: "a", count: 40), helperCodeHash: String(repeating: "b", count: 40), allowedUserID: 501)
        XCTAssertTrue(trust.isValid)
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(trust.clientRequirement as CFString, [], &requirement), errSecSuccess)
        XCTAssertFalse(HelperTrust(clientCodeHash: "invalid", helperCodeHash: trust.HelperCodeHash, allowedUserID: 501).isValid)
        XCTAssertFalse(HelperTrust(clientCodeHash: trust.ClientCodeHash, helperCodeHash: trust.HelperCodeHash, allowedUserID: 0).isValid)
        var settings = HogSettings()
        settings.enabled = true; settings.useAdministratorHelper = true
        let worker = HelperWorker(clientUID: getuid(), clientPID: getpid())
        let first = HelperPolicy(revision: 1, settings: settings)
        var updateError: String?
        worker.updatePolicy(try JSONEncoder().encode(first)) { updateError = $0 }
        XCTAssertEqual(updateError, nil)
        XCTAssertTrue(worker.isCurrent(first))
        settings.enabled = false
        worker.updatePolicy(try JSONEncoder().encode(HelperPolicy(revision: 2, settings: settings))) { updateError = $0 }
        XCTAssertFalse(worker.isCurrent(first))
        worker.updatePolicy(try JSONEncoder().encode(first)) { updateError = $0 }
        XCTAssertTrue(updateError != nil)
        worker.invalidate()
        XCTAssertFalse(worker.isCurrent(first))
        let invalidated = HelperWorker(clientUID: getuid(), clientPID: getpid())
        invalidated.updatePolicy(try JSONEncoder().encode(first)) { _ in }
        settings.enabled = true; settings.limitBytes = 0
        invalidated.updatePolicy(try JSONEncoder().encode(HelperPolicy(revision: 2, settings: settings))) { updateError = $0 }
        XCTAssertTrue(updateError != nil)
        XCTAssertFalse(invalidated.isCurrent(first), "An invalid replacement must disarm the previous policy.")
    }


    func testAlertInventoryAndSpikeLifecycle() throws {
        var settings = HogSettings()
        XCTAssertFalse(settings.alertsEnabled)
        XCTAssertEqual(settings.maximumAttempts, 3)
        XCTAssertFalse(settings.automaticallyResume)
        XCTAssertEqual(settings.cooldownSeconds, 1800)
        settings.alertsEnabled = true
        XCTAssertTrue(settings.monitoringActive, "Alerts schedule checks with an empty watch list.")
        settings.maximumAttempts = 0; settings.cooldownSeconds = .infinity; settings.validate()
        XCTAssertEqual(settings.maximumAttempts, 1); XCTAssertEqual(settings.cooldownSeconds, 1800)
        var tracker = SpikeTracker()
        let hot = process(99100, bytes: 101)
        let inventory = ProcessInventory(processes: [hot], enumerationComplete: true)
        var signals = 0
        let result = CheckEngine.perform(settings: settings, apps: [], retries: [:], enforce: true,
            inventoryProvider: { inventory }, signal: { _, _, _, _ in signals += 1; return TerminationResult(killed: 1, attempted: 1) })
        XCTAssertEqual(result.samples.count, 0)
        XCTAssertEqual(result.inventory.processes.count, 1)
        XCTAssertEqual(signals, 0)
        XCTAssertEqual(tracker.update(inventory, limitBytes: 100).count, 1)
        XCTAssertEqual(tracker.update(inventory, limitBytes: 100).count, 0)
        let unknown = ProcessInventory(processes: [process(99100, bytes: nil)], enumerationComplete: true)
        XCTAssertEqual(tracker.update(unknown, limitBytes: 100).count, 0)
        XCTAssertEqual(tracker.update(inventory, limitBytes: 100).count, 0, "An unreadable measurement does not re-arm the spike.")
        _ = tracker.update(ProcessInventory(processes: [], enumerationComplete: false), limitBytes: 100)
        XCTAssertEqual(tracker.update(inventory, limitBytes: 100).count, 0, "An incomplete listing does not claim the process exited.")
        let restored = try JSONDecoder().decode(SpikeTracker.self, from: JSONEncoder().encode(tracker))
        XCTAssertEqual(restored.active, tracker.active)
        _ = tracker.update(ProcessInventory(processes: [process(99100, bytes: 100)], enumerationComplete: true), limitBytes: 100)
        XCTAssertEqual(tracker.update(inventory, limitBytes: 100).count, 1)
        XCTAssertEqual(tracker.update(ProcessInventory(processes: [process(99100, bytes: 101, start: 456)], enumerationComplete: true), limitBytes: 100).count, 1)
        XCTAssertEqual(tracker.active.count, 1, "A reused PID has a distinct identity.")
        _ = tracker.update(ProcessInventory(processes: [], enumerationComplete: true), limitBytes: 100)
        XCTAssertTrue(tracker.active.isEmpty)
        XCTAssertFalse(NotificationPolicy.shouldDeliver(alertsEnabled: true, permission: .denied))
        XCTAssertTrue(NotificationPolicy.shouldDeliver(alertsEnabled: true, permission: .authorized))
        XCTAssertFalse(NotificationPolicy.shouldDeliver(alertsEnabled: false, permission: .authorized))
        XCTAssertEqual(tracker.update(inventory, limitBytes: 100).count, 1, "Spike logging is independent of notification permission.")
    }

    func testPromotionAndActivityMigration() throws {
        let target = process(99110, path: "/Applications/Exact.app/Contents/MacOS/Exact", bytes: 2_000_000_000)
        let rule = WatchPromotion.rule(for: target)
        XCTAssertEqual(rule.targetKind, .process)
        XCTAssertEqual(rule.executablePath, target.path)
        XCTAssertTrue(rule.matches(target))
        XCTAssertFalse(rule.matches(process(99111, path: "/different/Exact")))
        let appRule = WatchRule(name: "Hog", bundleIdentifier: "test.hog", targetKind: .application)
        let main = process(rootID)
        let helper = process(99112, parent: rootID, path: "/usr/bin/shared-worker")
        let group = MemorySample(ruleID: appRule.id, roots: [main], processes: [main, helper])
        XCTAssertTrue(WatchPromotion.isCovered(helper, by: appRule, sample: group))
        XCTAssertFalse(WatchPromotion.isCovered(process(99113, path: helper.path), by: appRule, sample: group), "An unrelated process sharing a helper executable remains eligible for promotion.")
        XCTAssertTrue(WatchPromotion.isCovered(process(99114, path: main.path), by: appRule, sample: nil, applicationExecutablePath: main.path))
        XCTAssertTrue(WatchPromotion.isCovered(target, by: rule, sample: nil))
        XCTAssertEqual(WatchPromotion.refusalReason(target, userID: getuid(), controllerPID: getpid()), nil)
        let protected = ProcessRecord(identity: target.identity, parentPID: 1, uid: 0, path: "/usr/libexec/systemservice", memoryBytes: 2_000_000_000)
        XCTAssertTrue(WatchPromotion.refusalReason(protected, userID: getuid(), controllerPID: getpid()) != nil)
        let foreign = ProcessRecord(identity: target.identity, parentPID: 1, uid: getuid() + 1, path: target.path, memoryBytes: target.memoryBytes)
        XCTAssertTrue(WatchPromotion.refusalReason(foreign, userID: getuid(), controllerPID: getpid()) != nil)
        let legacy = Data("{\"id\":\"11111111-1111-1111-1111-111111111111\",\"date\":0,\"app\":\"Legacy\",\"bytes\":123,\"message\":\"Old log\",\"succeeded\":true}".utf8)
        let old = try JSONDecoder().decode(ActivityEntry.self, from: legacy)
        XCTAssertEqual(old.kind, nil); XCTAssertEqual(old.process?.path, nil)
        let entry = ActivityEntry(app: target.name, bytes: target.memoryBytes!, message: "Alert", succeeded: true, kind: .alert, process: target, ruleID: rule.id, limitBytes: 1_000_000_000)
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.process?.identity, target.identity)
        XCTAssertEqual(decoded.process?.path, target.path)
        XCTAssertEqual(decoded.kind, .alert)
        XCTAssertEqual(decoded.ruleID, rule.id)
    }

    func testRetryCapPersistenceAndIsolation() throws {
        var settings = HogSettings(); settings.enabled = true; settings.includeHelpers = false; settings.limitBytes = 100
        let rule = WatchRule(name: "Hog", targetKind: .process)
        let other = WatchRule(name: "Other", targetKind: .process)
        settings.rules = [rule, other]
        let inventory = ProcessInventory(processes: [process(rootID, bytes: 200), process(99120, path: "/Applications/Other.app/Contents/MacOS/Other", bytes: 50)], enumerationComplete: true)
        var retries: [UUID: RetryState] = [:]
        var calls = 0
        for expected in 1...3 {
            let result = CheckEngine.perform(settings: settings, apps: [], retries: retries, enforce: true,
                inventoryProvider: { inventory }, signal: { _, _, _, _ in calls += 1; return TerminationResult(killed: 0, failures: ["Operation not permitted"], attempted: 1) }, wait: { _ in }, verificationPasses: 0)
            XCTAssertEqual(result.attempts.count, 1)
            XCTAssertEqual(result.retries[rule.id]?.failures, expected)
            XCTAssertEqual(result.retries[rule.id]?.isPaused, expected == 3)
            retries = result.retries
        }
        XCTAssertEqual(calls, 3)
        XCTAssertFalse(retries[other.id]!.isPaused)
        let persisted = try JSONDecoder().decode([UUID: RetryState].self, from: JSONEncoder().encode(retries))
        let paused = CheckEngine.perform(settings: settings, apps: [], retries: persisted, enforce: true,
            inventoryProvider: { inventory }, signal: { _, _, _, _ in calls += 1; return TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertTrue(paused.attempts.isEmpty)
        XCTAssertEqual(calls, 3)
        var resumed = persisted[rule.id]!
        resumed.resume()
        XCTAssertEqual(resumed.failures, 0); XCTAssertFalse(resumed.isPaused); XCTAssertFalse(resumed.pendingRecovery)
        let cancelled = CheckEngine.perform(settings: settings, apps: [], retries: persisted, enforce: true,
            shouldContinue: { false }, inventoryProvider: { inventory })
        XCTAssertEqual(cancelled.retries, persisted)
        XCTAssertTrue(cancelled.attempts.isEmpty)
    }

    func testHealthyRestartAndLaterLeak() {
        var settings = HogSettings(); settings.enabled = true; settings.includeHelpers = false; settings.limitBytes = 100
        let rule = WatchRule(name: "Hog", targetKind: .process); settings.rules = [rule]
        let hot = ProcessInventory(processes: [process(rootID, bytes: 200)], enumerationComplete: true)
        let healthy = ProcessInventory(processes: [process(99130, bytes: 50, start: 456)], enumerationComplete: true)
        var previous = RetryState(); previous.failures = 2
        var reads = 0
        let result = CheckEngine.perform(settings: settings, apps: [], retries: [rule.id: previous], enforce: true,
            inventoryProvider: { reads += 1; return reads == 1 ? hot : healthy },
            signal: { _, _, _, _ in TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(result.attempts.first?.outcome, .recovered)
        XCTAssertEqual(result.retries[rule.id]?.failures, 0)
        XCTAssertFalse(result.retries[rule.id]!.isPaused)
        XCTAssertEqual(result.samples[0].roots.first?.pid, 99130)
        let leakingAgain = ProcessInventory(processes: [process(99130, bytes: 200, start: 456)], enumerationComplete: true)
        let later = CheckEngine.perform(settings: settings, apps: [], retries: result.retries, enforce: true,
            inventoryProvider: { leakingAgain }, signal: { _, _, _, _ in TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(later.retries[rule.id]?.failures, 1, "A later leak starts a fresh incident.")
        let descriptor = app()
        let appRule = WatchRule(name: "Hog", bundleIdentifier: "test.hog", targetKind: .application)
        settings.rules = [appRule]
        reads = 0
        let application = CheckEngine.perform(settings: settings, apps: [descriptor], retries: [:], enforce: true,
            inventoryProvider: { reads += 1; return reads == 1 ? hot : healthy },
            signal: { _, _, _, _ in TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(application.attempts.first?.outcome, .recovered, "App replacements are verified by executable path even with stale app descriptors.")
    }

    func testExitPendingAndUnhealthyRelaunch() throws {
        var settings = HogSettings(); settings.enabled = true; settings.includeHelpers = false; settings.limitBytes = 100
        let rule = WatchRule(name: "Hog", targetKind: .process); settings.rules = [rule]
        let hot = ProcessInventory(processes: [process(rootID, bytes: 200)], enumerationComplete: true)
        let exited = ProcessInventory(processes: [], enumerationComplete: true)
        var reads = 0, signals = 0
        let first = CheckEngine.perform(settings: settings, apps: [], retries: [:], enforce: true,
            inventoryProvider: { reads += 1; return reads == 1 ? hot : exited },
            signal: { _, _, _, _ in signals += 1; return TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(first.attempts.first?.outcome, .exited)
        XCTAssertTrue(first.retries[rule.id]!.pendingRecovery)
        XCTAssertEqual(first.retries[rule.id]?.failures, 0)
        let persisted = try JSONDecoder().decode([UUID: RetryState].self, from: JSONEncoder().encode(first.retries))
        let preview = CheckEngine.perform(settings: settings, apps: [], retries: persisted, enforce: false, inventoryProvider: { hot })
        XCTAssertTrue(preview.retries[rule.id]!.pendingRecovery)
        XCTAssertEqual(preview.retries[rule.id]?.failures, 0)
        let second = CheckEngine.perform(settings: settings, apps: [], retries: persisted, enforce: true,
            inventoryProvider: { hot }, signal: { _, _, _, _ in signals += 1; return TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(second.retries[rule.id]?.failures, 2, "An unhealthy relaunch settles the first failed recovery; this check makes one further attempt.")
        let third = CheckEngine.perform(settings: settings, apps: [], retries: second.retries, enforce: true,
            inventoryProvider: { hot }, signal: { _, _, _, _ in signals += 1; return TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(signals, 3); XCTAssertTrue(third.retries[rule.id]!.isPaused)
        let gone = CheckEngine.perform(settings: settings, apps: [], retries: persisted, enforce: true, inventoryProvider: { exited })
        XCTAssertFalse(gone.retries[rule.id]!.pendingRecovery); XCTAssertEqual(gone.retries[rule.id]?.failures, 0)
        let unknown = MemorySample(ruleID: rule.id, roots: [process(rootID, bytes: nil)], processes: [process(rootID, bytes: nil)])
        XCTAssertEqual(RecoveryVerification.classify(unknown, inventoryComplete: true, limitBytes: 100), .unavailable)
        let readable = MemorySample(ruleID: rule.id, roots: [process(rootID, bytes: 50)], processes: [process(rootID, bytes: 50)])
        XCTAssertEqual(RecoveryVerification.classify(readable, inventoryComplete: false, limitBytes: 100), .unavailable)
        XCTAssertEqual(RecoveryVerification.classify(MemorySample(ruleID: rule.id, roots: [], processes: []), inventoryComplete: false, limitBytes: 100), .unavailable)
    }

    func testCooldownAndProtectedSkips() {
        var settings = HogSettings(); settings.enabled = true; settings.limitBytes = 100
        let rule = WatchRule(name: "SystemService", targetKind: .process); settings.rules = [rule]
        let root = ProcessRecord(identity: ProcessIdentity(pid: 99140, startSeconds: 123, startMicroseconds: 0), parentPID: 1, uid: 0, path: "/usr/libexec/SystemService", memoryBytes: 200)
        let inventory = ProcessInventory(processes: [root], enumerationComplete: true)
        var calls = 0
        let skipped = CheckEngine.perform(settings: settings, apps: [], retries: [:], enforce: true,
            terminationUserIDs: [getuid(), 0], inventoryProvider: { inventory },
            signal: { _, _, _, _ in calls += 1; return TerminationResult(killed: 1, attempted: 1) })
        XCTAssertEqual(calls, 0); XCTAssertEqual(skipped.retries[rule.id]?.failures, 0)
        XCTAssertEqual(skipped.activity.first?.kind, .skipped)
        let repeated = CheckEngine.perform(settings: settings, apps: [], retries: skipped.retries, enforce: true,
            terminationUserIDs: [getuid(), 0], inventoryProvider: { inventory })
        XCTAssertTrue(repeated.activity.isEmpty, "A protected target does not fill the log on every check.")
        let start = Date(timeIntervalSince1970: 1_000)
        var state = RetryState(); state.failures = 3; state.pausedAt = start
        let empty = MemorySample(ruleID: rule.id, roots: [], processes: [])
        _ = state.observe(empty, inventoryComplete: true, settlePending: true, settings: settings, now: start.addingTimeInterval(9999))
        XCTAssertTrue(state.isPaused, "Manual resume is the default, even after a process exits.")
        settings.automaticallyResume = true
        _ = state.observe(empty, inventoryComplete: true, settlePending: true, settings: settings, now: start.addingTimeInterval(1799))
        XCTAssertTrue(state.isPaused)
        let events = state.observe(empty, inventoryComplete: true, settlePending: true, settings: settings, now: start.addingTimeInterval(1800))
        XCTAssertEqual(events.first, .resumed); XCTAssertFalse(state.isPaused); XCTAssertEqual(state.failures, 0)
        state.failures = 3; state.pausedAt = start; settings.cooldownSeconds = 60
        _ = state.observe(empty, inventoryComplete: true, settlePending: false, settings: settings, now: start.addingTimeInterval(61))
        XCTAssertFalse(state.isPaused, "Edited cooldowns apply from the persisted pause timestamp.")
    }

    func testIndividualModeSelectionAndGroupCompatibility() {
        var settings = HogSettings(); settings.enabled = true; settings.limitBytes = 100
        settings.quitMode = .offendingProcesses
        let rule = WatchRule(name: "Hog", targetKind: .process); settings.rules = [rule]
        let records = [process(rootID, bytes: 200), process(99151, bytes: 80),
                       process(99152, bytes: 80), process(99153, bytes: 100), process(99154, bytes: nil)]
        let inventory = ProcessInventory(processes: records, enumerationComplete: true)
        var selected: [ProcessIdentity] = []
        let result = CheckEngine.perform(settings: settings, apps: [], retries: [:], enforce: true,
            inventoryProvider: { inventory }, signal: { sample, _, _, _ in
                selected = sample.processes.map(\.identity)
                return TerminationResult(killed: 0, attempted: sample.processes.count)
            }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(selected, [records[0].identity], "Only the individual offender is selected, even with same-name siblings and unreadable memory.")
        XCTAssertEqual(result.attempts.first?.beforeBytes, 200)
        XCTAssertEqual(result.activity.first?.process?.pid, rootID)
        XCTAssertEqual(result.samples[0].processes.count, 5, "UI samples retain the full group.")
        let healthy = ProcessInventory(processes: Array(records[1...3]), enumerationComplete: true)
        var calls = 0
        let individual = CheckEngine.perform(settings: settings, apps: [], retries: [:], enforce: true,
            inventoryProvider: { healthy }, signal: { _, _, _, _ in calls += 1; return TerminationResult(killed: 0, attempted: 3) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertTrue(individual.attempts.isEmpty)
        XCTAssertEqual(calls, 0, "A combined total over the limit does not trigger individual mode.")
        settings.quitMode = .watchedGroup
        let legacy = CheckEngine.perform(settings: settings, apps: [], retries: [:], enforce: true,
            inventoryProvider: { healthy }, signal: { sample, _, _, _ in
                selected = sample.processes.map(\.identity)
                return TerminationResult(killed: 0, attempted: sample.processes.count)
            }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(Set(selected), Set(healthy.processes.map(\.identity)))
        XCTAssertEqual(legacy.attempts.count, 1)
    }

    func testIndividualHelpersAndRecoveryScope() {
        var settings = HogSettings(); settings.enabled = true; settings.limitBytes = 100
        settings.quitMode = .offendingProcesses
        let rule = WatchRule(name: "Hog", bundleIdentifier: "test.hog", targetKind: .application); settings.rules = [rule]
        let main = process(rootID, bytes: 80)
        let worker = process(99160, parent: rootID, path: "/Applications/Hog.app/Contents/Helpers/Worker", bytes: 200)
        let sibling = process(99161, parent: rootID, path: worker.path, bytes: 80)
        let hot = ProcessInventory(processes: [main, worker, sibling], enumerationComplete: true)
        let gone = ProcessInventory(processes: [main, sibling], enumerationComplete: true)
        var reads = 0
        var selected: [ProcessIdentity] = []
        let exited = CheckEngine.perform(settings: settings, apps: [app()], retries: [:], enforce: true,
            inventoryProvider: { reads += 1; return reads == 1 ? hot : gone }, signal: { sample, _, _, _ in
                selected = sample.processes.map(\.identity)
                return TerminationResult(killed: 1, attempted: 1)
            }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(selected, [worker.identity], "The healthy main process and sibling helper must stay running.")
        XCTAssertEqual(exited.attempts.first?.outcome, .exited, "An existing healthy sibling cannot stand in for a healthy restart.")
        XCTAssertTrue(exited.retries[rule.id]!.pendingRecovery)
        let confirmed = CheckEngine.perform(settings: settings, apps: [app()], retries: exited.retries, enforce: true,
            inventoryProvider: { gone })
        XCTAssertFalse(confirmed.retries[rule.id]!.pendingRecovery)
        XCTAssertTrue(confirmed.attempts.isEmpty, "A healthy combined total above the limit is not a new incident in individual mode.")
        let healthyWorker = process(99162, parent: rootID, path: worker.path, bytes: 80, start: 456)
        let healthy = ProcessInventory(processes: [main, sibling, healthyWorker], enumerationComplete: true)
        var previous = RetryState(); previous.failures = 2
        reads = 0
        let recovered = CheckEngine.perform(settings: settings, apps: [app()], retries: [rule.id: previous], enforce: true,
            inventoryProvider: { reads += 1; return reads == 1 ? hot : healthy },
            signal: { _, _, _, _ in TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(recovered.attempts.first?.outcome, .recovered)
        XCTAssertEqual(recovered.retries[rule.id]?.failures, 0)
        let unhealthy = ProcessInventory(processes: [main, sibling, process(99162, parent: rootID, path: worker.path, bytes: 200, start: 456)], enumerationComplete: true)
        reads = 0
        let failed = CheckEngine.perform(settings: settings, apps: [app()], retries: [rule.id: previous], enforce: true,
            inventoryProvider: { reads += 1; return reads == 1 ? hot : unhealthy },
            signal: { _, _, _, _ in TerminationResult(killed: 1, attempted: 1) }, wait: { _ in }, verificationPasses: 0)
        XCTAssertEqual(failed.attempts.first?.outcome, .failed)
        XCTAssertTrue(failed.retries[rule.id]!.isPaused)
        settings.includeHelpers = false
        let excluded = CheckEngine.perform(settings: settings, apps: [app()], retries: [:], enforce: true,
            inventoryProvider: { hot }, signal: { _, _, _, _ in
                XCTAssertTrue(false, "Excluded helpers must not be signaled.")
                return TerminationResult(killed: 0, attempted: 0)
            })
        XCTAssertTrue(excluded.attempts.isEmpty)
        var paused = previous; paused.pausedAt = Date()
        let retained = CheckEngine.perform(settings: settings, apps: [app()], retries: [rule.id: paused], enforce: true,
            inventoryProvider: { hot })
        XCTAssertTrue(retained.retries[rule.id]!.isPaused, "Changing quit mode does not discard a persisted pause.")
    }

    func testIndividualModeLiveSameExecutableSiblings() throws {
        var fixtures: [Process] = []
        defer {
            for fixture in fixtures { if fixture.isRunning { fixture.terminate() } }
            for fixture in fixtures { fixture.waitUntilExit() }
        }
        for megabytes in [80, 2, 2, 2] {
            let fixture = Process()
            fixture.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            fixture.arguments = ["-e", "my $memory = 'x' x (\(megabytes) * 1024 * 1024); sleep 30;"]
            try fixture.run(); fixtures.append(fixture)
        }
        for _ in 0..<100 {
            let readings = fixtures.compactMap { ProcessScanner.record(for: $0.processIdentifier) }
            if readings.count == 4 && (readings[0].memoryBytes ?? 0) > 50_000_000
                && readings.allSatisfy({ $0.path.hasSuffix("/perl") && ($0.memoryBytes ?? 0) > 1_000_000 }) { break }
            usleep(50_000)
        }
        var settings = HogSettings(); settings.enabled = true; settings.limitBytes = 32_000_000
        settings.quitMode = .offendingProcesses; settings.includeHelpers = false
        let rule = WatchRule(name: "Disposable siblings \(UUID().uuidString)", targetKind: .application); settings.rules = [rule]
        let descriptors = try fixtures.map { fixture -> RunningApp in
            let record = try XCTUnwrap(ProcessScanner.record(for: fixture.processIdentifier))
            return RunningApp(pid: record.pid, name: rule.name, bundleIdentifier: nil, bundlePath: "", executablePath: record.path)
        }
        let report = CheckEngine.perform(settings: settings, apps: descriptors, retries: [:], enforce: true,
            inventoryProvider: { ProcessInventory(processes: fixtures.compactMap { ProcessScanner.record(for: $0.processIdentifier) }, enumerationComplete: true) })
        XCTAssertEqual(report.attempts.first?.signaled, 1)
        fixtures[0].waitUntilExit()
        XCTAssertEqual(fixtures[0].terminationStatus, SIGKILL)
        XCTAssertTrue(fixtures.dropFirst().allSatisfy(\.isRunning), "All smaller instances of the very same executable stay alive.")
    }

    func testReadOnlySystemProcessDiscovery() throws {
        let visible = ProcessScanner.visibleProcessRecords(allowedUserIDs: [getuid(), 0])
        XCTAssertTrue(visible.contains { $0.pid == getpid() }, "Read-only process metadata should include this test process.")
        let rootProcess = try XCTUnwrap(visible.first { $0.uid == 0 && ["logd", "syslogd"].contains($0.name) }
            ?? visible.first { $0.uid == 0 && !$0.name.isEmpty })
        XCTAssertEqual(rootProcess.memoryBytes, nil)
        let rule = WatchRule(name: rootProcess.name, targetKind: .process)
        let samples = ProcessScanner.scan(rules: [rule], apps: [], includeHelpers: false)
        XCTAssertTrue(samples.first?.isRunning == true)
        XCTAssertTrue(samples.first?.requiresAdministratorAccess == true)
    }

    func testAuthenticatedXPCAndDisposableProcessEnforcement() throws {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        let runningCode = try XCTUnwrap(code)
        XCTAssertEqual(SecCodeCopyStaticCode(runningCode, [], &staticCode), errSecSuccess)
        var information: CFDictionary?
        let fileCode = try XCTUnwrap(staticCode)
        XCTAssertEqual(SecCodeCopySigningInformation(fileCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information), errSecSuccess)
        let dictionary = try XCTUnwrap(information as? [String: Any])
        let codeHash = try XCTUnwrap(dictionary[kSecCodeInfoUnique as String] as? Data).map { String(format: "%02x", $0) }.joined()
        let requirement = "cdhash H\"\(codeHash)\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
            throw HelperError("The test's code-signing requirement could not be parsed.")
        }
        let delegate = CheckListener(requirement: requirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HogHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate(); listener.invalidate(); withExtendedLifetime(delegate) {} }
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        target.arguments = ["-e", "my $memory = 'x' x (80 * 1024 * 1024); sleep 30;"]
        try target.run()
        defer { if target.isRunning { target.terminate() }; target.waitUntilExit() }
        let companion = Process()
        companion.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        companion.arguments = ["-e", "my $memory = 'x' x (2 * 1024 * 1024); sleep 30;"]
        try companion.run()
        defer { if companion.isRunning { companion.terminate() }; companion.waitUntilExit() }
        var record: ProcessRecord?
        for _ in 0..<100 {
            record = ProcessScanner.record(for: target.processIdentifier)
            if (record?.memoryBytes ?? 0) > 50_000_000 { break }
            usleep(50_000)
        }
        let measured = try XCTUnwrap(record)
        var settings = HogSettings()
        settings.enabled = true; settings.useAdministratorHelper = true; settings.limitBytes = 32_000_000
        settings.quitMode = .offendingProcesses; settings.includeHelpers = false
        let rule = WatchRule(name: "MHK XPC Fixture \(UUID().uuidString)", targetKind: .application)
        settings.rules = [rule]
        let descriptor = RunningApp(pid: measured.pid, name: rule.name, bundleIdentifier: nil, bundlePath: "", executablePath: measured.path)
        let companionRecord = try XCTUnwrap(ProcessScanner.record(for: companion.processIdentifier))
        let companionDescriptor = RunningApp(pid: companionRecord.pid, name: rule.name, bundleIdentifier: nil, bundlePath: "", executablePath: companionRecord.path)
        let remote = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { _ in } as? HogHelperProtocol)
        let staleReply = CheckReply()
        let staleRequest = HelperCheckRequest(policy: HelperPolicy(revision: 1, settings: settings), apps: [descriptor], enforce: true)
        var staleObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(staleRequest)) as? [String: Any])
        staleObject["version"] = HelperConstants.protocolVersion - 1
        remote.performCheck(try JSONSerialization.data(withJSONObject: staleObject)) { staleReply.finish(data: $0, error: $1) }
        XCTAssertEqual(staleReply.semaphore.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(staleReply.error != nil, "Older helper policies must be rejected before enforcement.")
        XCTAssertTrue(target.isRunning)
        var pausedState = RetryState(); pausedState.failures = 3; pausedState.pausedAt = Date()
        let pausedReply = CheckReply()
        let pausedRequest = HelperCheckRequest(policy: HelperPolicy(revision: 1, settings: settings, retries: [rule.id: pausedState]), apps: [descriptor], enforce: true)
        remote.performCheck(try JSONEncoder().encode(pausedRequest)) { pausedReply.finish(data: $0, error: $1) }
        XCTAssertEqual(pausedReply.semaphore.wait(timeout: .now() + 15), .success)
        XCTAssertEqual(pausedReply.error, nil)
        let pausedReport = try JSONDecoder().decode(HelperCheckResponse.self, from: XCTUnwrap(pausedReply.data))
        XCTAssertTrue(pausedReport.attempts.isEmpty)
        XCTAssertTrue(target.isRunning, "A paused watch policy must not signal its process through XPC.")
        var alertsOnly = settings; alertsOnly.enabled = false; alertsOnly.alertsEnabled = true; alertsOnly.rules = []
        let alertReply = CheckReply()
        let alertRequest = HelperCheckRequest(policy: HelperPolicy(revision: 2, settings: alertsOnly), apps: [], enforce: true)
        remote.performCheck(try JSONEncoder().encode(alertRequest)) { alertReply.finish(data: $0, error: $1) }
        XCTAssertEqual(alertReply.semaphore.wait(timeout: .now() + 15), .success)
        XCTAssertEqual(alertReply.error, nil)
        let alertReport = try JSONDecoder().decode(HelperCheckResponse.self, from: XCTUnwrap(alertReply.data))
        XCTAssertTrue(alertReport.inventory.processes.contains { $0.identity == measured.identity })
        XCTAssertTrue(alertReport.attempts.isEmpty)
        XCTAssertTrue(target.isRunning, "All-process inventory through XPC is read-only, even with enforce requested.")
        let request = HelperCheckRequest(policy: HelperPolicy(revision: 3, settings: settings), apps: [descriptor, companionDescriptor], enforce: true)
        let result = CheckReply()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in result.finish(data: nil, error: String(describing: error as NSError)) } as? HogHelperProtocol
        try XCTUnwrap(proxy).performCheck(JSONEncoder().encode(request)) { result.finish(data: $0, error: $1) }
        guard result.semaphore.wait(timeout: .now() + 15) == .success else {
            throw HelperError("Authenticated XPC check timed out.")
        }
        XCTAssertEqual(result.error, nil)
        XCTAssertEqual(delegate.acceptedConnections, 1)
        let response = try JSONDecoder().decode(HelperCheckResponse.self, from: XCTUnwrap(result.data))
        XCTAssertEqual(response.version, HelperConstants.protocolVersion)
        XCTAssertEqual(response.activity.count, 1)
        let outcome = try XCTUnwrap(response.attempts.first?.outcome)
        XCTAssertTrue(outcome == .exited || outcome == .recovered)
        XCTAssertEqual(response.attempts.first?.signaled, 1)
        XCTAssertEqual(response.retries[rule.id]!.pendingRecovery, outcome == .exited)
        XCTAssertEqual(response.activity.first?.kind, outcome == .exited ? .pendingRecovery : .recovered)
        target.waitUntilExit()
        XCTAssertEqual(target.terminationReason, .uncaughtSignal)
        XCTAssertEqual(target.terminationStatus, SIGKILL)
        XCTAssertTrue(companion.isRunning, "The authenticated helper leaves a smaller same-executable sibling running.")
        let deniedListener = NSXPCListener.anonymous()
        let wrongRequirement = "cdhash H\"\(String(repeating: "0", count: 40))\""
        let deniedDelegate = CheckListener(requirement: wrongRequirement)
        deniedListener.delegate = deniedDelegate
        deniedListener.setConnectionCodeSigningRequirement(wrongRequirement)
        deniedListener.resume()
        let deniedConnection = NSXPCConnection(listenerEndpoint: deniedListener.endpoint)
        deniedConnection.remoteObjectInterface = NSXPCInterface(with: HogHelperProtocol.self)
        deniedConnection.setCodeSigningRequirement(requirement)
        deniedConnection.resume()
        defer { deniedConnection.invalidate(); deniedListener.invalidate(); withExtendedLifetime(deniedDelegate) {} }
        let rejected = CheckReply()
        let deniedProxy = deniedConnection.remoteObjectProxyWithErrorHandler {
            rejected.finish(data: nil, error: $0.localizedDescription)
        } as? HogHelperProtocol
        try XCTUnwrap(deniedProxy).ping { rejected.finish(data: Data($0.utf8), error: nil) }
        XCTAssertEqual(rejected.semaphore.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(rejected.error != nil, "A mismatched signing identity must be rejected.")
        XCTAssertEqual(deniedDelegate.acceptedConnections, 0)
    }
}

private final class CheckReply: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    var data: Data?
    var error: String?
    func finish(data: Data?, error: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true; self.data = data; self.error = error; semaphore.signal()
    }
}
private final class CheckListener: NSObject, NSXPCListenerDelegate {
    let requirement: String
    var acceptedConnections = 0
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        acceptedConnections += 1
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: HogHelperProtocol.self)
        connection.exportedObject = HelperWorker(clientUID: getuid(), clientPID: getpid())
        connection.resume()
        return true
    }
}

private struct CheckFailure: Error {}
private var failures = 0
private var assertions = 0
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    assertions += 1
    if !value() { failures += 1; print("FAIL \(file):\(line): expected true. \(message)") }
}
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(!value(), message, file: file, line: line)
}
private func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    let value = actual()
    XCTAssertTrue(value == expected, "\(value) != \(expected). \(message)", file: file, line: line)
}
private func XCTAssertGreaterThan<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(actual > expected, "\(actual) must be greater than \(expected)", file: file, line: line)
}
private func XCTUnwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else {
        XCTAssertTrue(false, "Unexpected nil", file: file, line: line)
        throw CheckFailure()
    }
    return value
}
private func run(_ name: String, _ check: () throws -> Void) {
    let before = failures
    do { try check() }
    catch { if failures == before { failures += 1; print("FAIL \(name): \(error)") } }
    print("\(failures == before ? "PASS" : "FAIL") \(name)")
}

let checks = HogCoreChecks()
run("Defaults and settings persistence", checks.testDefaultsAndSettingsRoundTrip)
run("Invalid settings validation", checks.testInvalidStoredSettingsAreClamped)
run("Exact app and bundle matching", checks.testExactCaseInsensitiveNamesAndBundleIdentifiers)
run("Helper accounting and unrelated-app boundaries", checks.testHelpersAreSummedOnceAndUnrelatedAppsExcluded)
run("Strict threshold and disabled enforcement", checks.testStrictThresholdAndDisabledEnforcement)
run("Missing memory measurements", checks.testMissingMemoryDoesNotPretendToBeAValidZeroReading)
run("Reused PID identity and path verification", checks.testReusedRootPIDIsRejectedByPathAndLaunchTime)
run("Self protection and stale identity", checks.testSelfProtectionAndStaleIdentityNeverSignals)
run("LIVE disposable memory allocation, measurement, and SIGKILL", checks.testLiveFootprintAndForceQuitOnlyDisposableProcess)
run("Legacy settings and root-owned background process matching", checks.testLegacySettingsAndBackgroundProcessMatching)
run("Administrator policy, cancellation, and code-signing requirements", checks.testAdministratorBoundariesAndTrustRequirements)
run("LIVE read-only root process discovery", checks.testReadOnlySystemProcessDiscovery)
run("LIVE authenticated XPC and disposable-process enforcement", checks.testAuthenticatedXPCAndDisposableProcessEnforcement)
run("Independent alerts, spike lifecycle, and notification denial", checks.testAlertInventoryAndSpikeLifecycle)
run("Watch promotion and activity migration", checks.testPromotionAndActivityMigration)
run("Retry cap, persistence, cancellation, and watcher isolation", checks.testRetryCapPersistenceAndIsolation)
run("Healthy service restart and later independent leak", checks.testHealthyRestartAndLaterLeak)
run("Pending exit and continuously unhealthy relaunch", checks.testExitPendingAndUnhealthyRelaunch)
run("Cooldown and protected-process skips", checks.testCooldownAndProtectedSkips)
run("Individual process selection and whole-group compatibility", checks.testIndividualModeSelectionAndGroupCompatibility)
run("Individual helpers, replacement recovery, and preserved pauses", checks.testIndividualHelpersAndRecoveryScope)
run("LIVE individual offender and same-executable siblings", checks.testIndividualModeLiveSameExecutableSiblings)
print("\(assertions) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)

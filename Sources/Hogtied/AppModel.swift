import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import HogCore
import HogIPC

private final class CheckToken: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func cancel() { lock.lock(); active = false; lock.unlock() }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: HogSettings
    @Published private(set) var samples: [UUID: MemorySample] = [:]
    @Published private(set) var history: [ActivityEntry]
    @Published private(set) var retries: [UUID: RetryState]
    @Published private(set) var lastCheck: Date?
    @Published private(set) var nextCheck: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var helperAvailable = false
    @Published private(set) var helperStatus = "Not installed"
    @Published private(set) var notificationStatus = "Checking notification permission…"
    @Published private(set) var coverage = "Waiting for a process scan"
    @Published var message: String?
    @Published var settingsTab = 0
    @Published var focusedActivityID: UUID?
    var showSettings: (() -> Void)?
    var stateDidChange: (() -> Void)?
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var token = CheckToken()
    private var scanAgain = false
    private var enforceAgain = false
    private let helper = HelperClient()
    private let notifications = NotificationManager()
    private let defaults: UserDefaults
    private var spikes: SpikeTracker
    private var workspaceObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var restored = defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(HogSettings.self, from: $0) } ?? HogSettings()
        restored.validate()
        settings = restored
        history = defaults.data(forKey: "history").flatMap { try? JSONDecoder().decode([ActivityEntry].self, from: $0) } ?? []
        let storedRetries = defaults.data(forKey: "retries.v1").flatMap { try? JSONDecoder().decode([UUID: RetryState].self, from: $0) } ?? [:]
        retries = storedRetries.filter { id, state in
            restored.rules.contains { $0.id == id } && (0...100).contains(state.failures)
                && (state.pausedAt?.timeIntervalSince1970.isFinite ?? true)
        }
        spikes = defaults.data(forKey: "spikes.v1").flatMap { try? JSONDecoder().decode(SpikeTracker.self, from: $0) } ?? SpikeTracker()
        helper.connectionDidFail = { [weak self] in self?.helperStatus = $0 }
        notifications.statusChanged = { [weak self] in self?.notificationStatus = $0 }
        notifications.openActivity = { [weak self] id in self?.openActivity(id: id) }
        refreshLoginStatus()
        migrateLoginRegistration()
        refreshHelperStatus()
        schedule()
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.schedule()
                await self.notifications.refresh()
                await self.scan(enforce: self.settings.enabled)
            }
        })
        Task {
            await notifications.refresh()
            await scan(enforce: settings.enabled)
        }
    }

    var statusLabel: String {
        let paused = settings.rules.filter { retries[$0.id]?.isPaused == true }.count
        if !settings.monitoringActive { return "Automatic quitting and alerts paused" }
        let watching = settings.enabled && !settings.rules.isEmpty ? "Watching \(settings.rules.count - paused) targets" : "Automatic quitting paused"
        return watching + (paused > 0 ? " · \(paused) paused" : "") + (settings.alertsEnabled ? " · alerts on" : "")
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    private func invalidatePolicy() {
        token.cancel()
        generation += 1
        helper.updatePolicy(settings: settings, revision: generation, retries: retries)
        stateDidChange?()
    }

    func update(_ change: (inout HogSettings) -> Void, refreshReadings: Bool = true) {
        let old = settings
        var value = old
        change(&value); value.validate()
        guard value != old else { return }
        retries = retries.filter { id, _ in value.rules.contains { $0.id == id } }
        for rule in value.rules where old.rules.first(where: { $0.id == rule.id }) != rule { retries[rule.id] = nil }
        settings = value
        scanAgain = false; enforceAgain = false
        if !value.alertsEnabled { spikes.reset(); persist(spikes, key: "spikes.v1") }
        persist(value, key: "settings"); persist(retries, key: "retries.v1")
        invalidatePolicy(); schedule()
        if refreshReadings { Task { await scan(enforce: !old.enabled && value.enabled) } }
    }

    func setEnabled(_ value: Bool) { update { $0.enabled = value } }
    func setAlertsEnabled(_ value: Bool) {
        update({ $0.alertsEnabled = value }, refreshReadings: false)
        Task {
            if value { await notifications.requestIfNeeded() }
            await scan(enforce: false)
        }
    }
    func refreshNotificationStatus() { Task { await notifications.refresh() } }
    func removeRule(_ id: UUID) { update { $0.rules.removeAll { $0.id == id } } }
    func resumeRule(_ id: UUID) {
        guard let rule = settings.rules.first(where: { $0.id == id }) else { return }
        retries[id] = RetryState()
        persist(retries, key: "retries.v1"); invalidatePolicy()
        addActivity(ActivityEntry(app: rule.name, bytes: samples[id]?.measuredBytes(mode: settings.quitMode) ?? 0,
            message: "Watcher resumed manually; attempt count reset. Eligible at the next check.",
            succeeded: true, kind: .resumed, ruleID: id))
        Task { await scan(enforce: false) }
    }
    func pauseDetail(_ id: UUID) -> String? {
        guard let state = retries[id], state.isPaused else { return nil }
        if let deadline = state.resumeDate(settings: settings) {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            return remaining == 0 ? "Paused · cooldown finished; resumes at next check" : "Paused · resumes in \(Int(ceil(remaining / 60))) min"
        }
        return "Paused after \(state.failures) failed attempts · resume manually"
    }

    @discardableResult
    func saveRule(id: UUID? = nil, name: String, bundleIdentifier: String? = nil,
                  targetKind: TargetKind? = nil, executablePath: String? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !WatchRule.normalized(name).isEmpty, !["*", ".*"].contains(name) else { message = "Enter a complete application or process name."; return false }
        guard name.utf8.count <= 1024, (path?.utf8.count ?? 0) <= 4096 else { message = "The name or executable path is too long."; return false }
        guard id != nil || settings.rules.count < 100 else { message = "The watch list supports up to 100 targets."; return false }
        guard path?.isEmpty != false || path!.hasPrefix("/") else { message = "Use an absolute executable path."; return false }
        let selfNames = ["Hogtied", "HogtiedHelper", "Memory Hog Killer", "MemoryHogKiller", "MemoryHogKillerHelper", "local.memoryhogkiller.helper", Bundle.main.bundleIdentifier ?? ""]
        guard !selfNames.contains(where: { WatchRule.normalized($0) == WatchRule.normalized(name) }),
              bundleIdentifier == nil || bundleIdentifier != Bundle.main.bundleIdentifier else { message = "Hogtied cannot watch itself."; return false }
        let rule = WatchRule(id: id ?? UUID(), name: name, bundleIdentifier: bundleIdentifier,
            targetKind: targetKind, executablePath: path?.isEmpty == false ? path : nil)
        guard !settings.rules.contains(where: {
            $0.id != rule.id && (($0.executablePath != nil && $0.executablePath == rule.executablePath)
                || (bundleIdentifier != nil && $0.bundleIdentifier == bundleIdentifier)
                || ($0.executablePath == nil && rule.executablePath == nil && WatchRule.normalized($0.name) == WatchRule.normalized(name)))
        }) else { message = "That target is already watched."; return false }
        update {
            if let index = $0.rules.firstIndex(where: { $0.id == rule.id }) { $0.rules[index] = rule }
            else { $0.rules.append(rule) }
        }
        return true
    }

    func watchedRule(for process: ProcessRecord) -> WatchRule? {
        settings.rules.first { rule in
            var executable: String?
            if let id = rule.bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                executable = Bundle(url: url)?.executableURL?.path
            }
            return WatchPromotion.isCovered(process, by: rule, sample: samples[rule.id], applicationExecutablePath: executable)
        }
    }
    func promotionReason(_ process: ProcessRecord) -> String? {
        WatchPromotion.refusalReason(process, userID: getuid(), controllerPID: getpid())
    }
    func watchProcess(_ process: ProcessRecord) {
        guard watchedRule(for: process) == nil else { return }
        if let reason = promotionReason(process) { message = reason; return }
        let rule = WatchPromotion.rule(for: process)
        _ = saveRule(name: rule.name, targetKind: .process, executablePath: rule.executablePath)
    }

    func chooseApplications() {
        let panel = NSOpenPanel(); panel.title = "Choose apps to watch"; panel.prompt = "Add apps"
        panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            saveRule(name: name, bundleIdentifier: bundle?.bundleIdentifier, targetKind: .application)
        }
    }
    func runningApplications() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.processIdentifier != getpid(), let url = app.bundleURL else { return nil }
            return RunningApp(pid: app.processIdentifier, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: app.bundleIdentifier, bundlePath: url.path, executablePath: app.executableURL?.path,
                launchTime: app.launchDate?.timeIntervalSince1970, isRegular: app.activationPolicy == .regular)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func schedule() {
        timer?.invalidate(); timer = nil; nextCheck = nil
        guard settings.monitoringActive else { return }
        nextCheck = Date().addingTimeInterval(settings.intervalSeconds)
        let timer = Timer(timeInterval: settings.intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; await self.scan(enforce: self.settings.enabled) }
        }
        timer.tolerance = min(10, settings.intervalSeconds * 0.05)
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func checkNow() { schedule(); Task { await scan(enforce: settings.enabled) } }

    private func scan(enforce: Bool) async {
        guard !isChecking else { scanAgain = true; enforceAgain = enforceAgain || enforce; return }
        isChecking = true
        let version = generation, configuration = settings, savedRetries = retries
        let apps = runningApplications()
        let currentToken = CheckToken(); token = currentToken
        let report: CheckReport
        if configuration.administratorEnabled && helperAvailable {
            do {
                report = try await helper.check(settings: configuration, revision: version, apps: apps,
                    enforce: enforce, retries: savedRetries)
                helperStatus = "Connected · administrator checks available"
            } catch {
                helper.disconnect(); helperStatus = error.localizedDescription
                // A lost reply may follow actual signals. Never duplicate an
                // uncertain privileged attempt with a second local attempt.
                report = await Task.detached(priority: .utility) {
                    CheckEngine.perform(settings: configuration, apps: apps, retries: savedRetries, enforce: false)
                }.value
            }
        } else {
            report = await Task.detached(priority: .utility) {
                CheckEngine.perform(settings: configuration, apps: apps, retries: savedRetries,
                    enforce: enforce, shouldContinue: { currentToken.isActive })
            }.value
        }
        // Completed signal operations remain auditable after a settings change;
        // stale recovery/pause decisions and alerts must never overwrite state.
        for entry in report.activity where entry.kind == .quit || entry.kind == .pendingRecovery || entry.kind == .recovered {
            addActivity(entry)
        }
        if generation == version {
            samples = Dictionary(uniqueKeysWithValues: report.samples.map { ($0.ruleID, $0) })
            lastCheck = Date()
            let readable = report.inventory.processes.count - report.inventory.unreadableCount
            coverage = report.inventory.enumerationComplete
                ? "Memory measured for \(readable) of \(report.inventory.processes.count) visible processes" + (report.inventory.unreadableCount > 0 ? " · some memory is unavailable" : "")
                : "Process listing is incomplete; unavailable processes cannot be checked."
            if retries != report.retries {
                retries = report.retries; persist(retries, key: "retries.v1"); invalidatePolicy()
            }
            for entry in report.activity where entry.kind != .quit && entry.kind != .pendingRecovery && entry.kind != .recovered { addActivity(entry) }
            if configuration.alertsEnabled {
                for process in spikes.update(report.inventory, limitBytes: configuration.limitBytes) {
                    let entry = ActivityEntry(app: process.name, bytes: process.memoryBytes ?? 0,
                        message: "Process exceeds the \(MemoryText.format(configuration.limitBytes)) limit. This alert does not quit it; automatic quitting follows the watch list and quit mode.",
                        succeeded: true, kind: .alert, process: process, limitBytes: configuration.limitBytes)
                    addActivity(entry); notifications.deliver(entry, enabled: settings.alertsEnabled)
                }
                persist(spikes, key: "spikes.v1")
            }
            if let date = timer?.fireDate { nextCheck = date > Date() ? date : Date().addingTimeInterval(settings.intervalSeconds) }
            stateDidChange?()
        } else { scanAgain = true }
        isChecking = false
        if scanAgain {
            let enforce = enforceAgain
            scanAgain = false; enforceAgain = false
            Task { await scan(enforce: enforce) }
        }
    }

    private func addActivity(_ entry: ActivityEntry) {
        guard !history.contains(where: { $0.id == entry.id }) else { return }
        history.insert(entry, at: 0); history = Array(history.prefix(100)); persist(history, key: "history")
    }
    func openActivity(id: UUID? = nil) {
        settingsTab = 1; focusedActivityID = id; showSettings?()
    }
    func clearHistory() { history = []; defaults.removeObject(forKey: "history") }

    func refreshHelperStatus() {
        let result = helper.availability(); helperAvailable = result.0; helperStatus = result.1
    }
    func setAdministratorHelper(_ enabled: Bool) {
        refreshHelperStatus()
        guard !enabled || helperAvailable else { message = "Install the optional administrator helper first."; return }
        update { $0.useAdministratorHelper = enabled }
    }
    func installAdministratorHelper() {
        let nearby = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(HelperConstants.packageName)
        if FileManager.default.fileExists(atPath: nearby.path) { NSWorkspace.shared.open(nearby); return }
        let panel = NSOpenPanel(); panel.title = "Choose the Hogtied administrator installer"; panel.prompt = "Open installer"
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg") ?? .data]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { NSWorkspace.shared.open(url) }
    }
    func uninstallAdministratorHelper() {
        setAdministratorHelper(false)
        let url = URL(fileURLWithPath: HelperConstants.supportDirectory + "/Uninstall Admin Helper.command")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }
    private func migrateLoginRegistration() {
        guard launchAtLogin, defaults.string(forKey: "loginBundlePath") != Bundle.main.bundleURL.path else { return }
        do {
            if loginStatus == .enabled { try SMAppService.mainApp.unregister() }
            try SMAppService.mainApp.register()
            defaults.set(Bundle.main.bundleURL.path, forKey: "loginBundlePath")
        } catch { message = "Review Launch at login after moving Hogtied: \(error.localizedDescription)" }
        refreshLoginStatus()
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                else if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                defaults.set(Bundle.main.bundleURL.path, forKey: "loginBundlePath")
            } else { try SMAppService.mainApp.unregister(); defaults.removeObject(forKey: "loginBundlePath") }
        } catch { message = "Could not change launch at login: \(error.localizedDescription)" }
        refreshLoginStatus()
    }
}

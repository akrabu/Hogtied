import SwiftUI
import AppKit
import ServiceManagement
import HogCore

private let hogPink = Color(red: 0.84, green: 0.28, blue: 0.42)
private typealias ViewState<Value> = SwiftUI.State<Value>

struct PigBadge: View {
    var size: CGFloat = 44
    var body: some View {
        Image(nsImage: PigArtwork.image(side: size * 2)).resizable()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                PigBadge()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hogtied").font(.system(size: 18, weight: .semibold))
                    Text(model.statusLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Circle().fill(model.settings.monitoringActive ? Color.green : Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
            }
            Toggle("Automatic quitting", isOn: Binding(get: { model.settings.enabled }, set: model.setEnabled))
            Toggle("Alert on any process", isOn: Binding(get: { model.settings.alertsEnabled }, set: model.setAlertsEnabled))
            Text("Over \(MemoryText.format(model.settings.limitBytes)) · every \(MemoryText.interval(model.settings.intervalSeconds))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            if model.settings.rules.isEmpty {
                Text("Add apps or processes to allow automatic force-quitting. Alerts work with an empty watch list.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Add targets…") { model.settingsTab = 0; model.showSettings?() }.controlSize(.small)
            } else {
                ForEach(Array(model.settings.rules.prefix(6))) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if model.retries[rule.id]?.isPaused == true {
                                Text("Watcher paused").font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if model.retries[rule.id]?.isPaused == true {
                            Button("Resume") { model.resumeRule(rule.id) }.controlSize(.small)
                        } else {
                            Text(usage(rule)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.settings.rules.count > 6 { Text("+\(model.settings.rules.count - 6) more in Settings").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            HStack {
                if let date = model.lastCheck { Text("Checked \(date, style: .relative) ago").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button(model.isChecking ? "Checking…" : "Check now") { model.checkNow() }.disabled(model.isChecking).controlSize(.small)
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin)).controlSize(.small)
            if model.loginStatus == .requiresApproval {
                Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }.font(.system(size: 11))
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { model.message = nil }.font(.system(size: 11))
            }
            HStack {
                Button("Settings…") { model.showSettings?() }.keyboardShortcut(",")
                Button("Activity…") { model.openActivity() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }.toggleStyle(.switch).tint(hogPink).font(.system(size: 12))
            .padding(20).frame(width: 370).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { model.refreshLoginStatus() }
    }
    private func usage(_ rule: WatchRule) -> String {
        guard let sample = model.samples[rule.id] else { return "—" }
        guard sample.isRunning else { return "No visible match" }
        guard sample.isMeasurable else { return "Needs access" }
        return (sample.unavailableCount > 0 ? "≥ " : "") + MemoryText.format(sample.bytes)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var editor: RuleEditorItem?
    @ViewState private var limitText = "1"
    @ViewState private var limitUnit: Double = 1_000_000_000
    @ViewState private var intervalText = "5"
    @ViewState private var intervalUnit: Double = 60
    @ViewState private var cooldownText = "30"
    @ViewState private var limitError: String?
    @ViewState private var intervalError: String?
    @ViewState private var cooldownError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                PigBadge(size: 60)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Hogtied").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Keep the memory hogs in check.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("1.2.0").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(24)
            Picker("View", selection: $model.settingsTab) { Text("Watch list").tag(0); Text("Activity").tag(1) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.bottom, 18)
            Divider()
            if model.settingsTab == 0 { configuration } else { activity }
            Divider()
            HStack {
                Text(model.statusLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let next = model.nextCheck { Text("Next: \(next, style: .time)").font(.system(size: 11)).foregroundStyle(.secondary) }
                Button(model.isChecking ? "Checking…" : "Check now") { model.checkNow() }.disabled(model.isChecking).controlSize(.small)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }.frame(minWidth: 700, idealWidth: 760, maxWidth: .infinity, minHeight: 680)
            .background(Color(nsColor: .windowBackgroundColor)).tint(hogPink)
            .onAppear { loadFields(); model.refreshLoginStatus(); model.refreshHelperStatus(); model.refreshNotificationStatus() }
            .sheet(item: $editor) { RuleEditor(model: model, item: $0) }
            .alert("Hogtied", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK") { model.message = nil }
            } message: { Text(model.message ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshLoginStatus(); model.refreshHelperStatus(); model.refreshNotificationStatus()
            }
    }

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Automatically quit watched apps over the limit", isOn: Binding(get: { model.settings.enabled }, set: model.setEnabled))
                    Toggle("Alert on any process over the limit", isOn: Binding(get: { model.settings.alertsEnabled }, set: model.setAlertsEnabled))
                    Text("All-process alerts log and notify once per spike. Only watched entries can be automatically force-quit.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.settings.alertsEnabled {
                        Text(model.notificationStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(model.coverage).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).font(.system(size: 13)).card()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Memory limit").font(.system(size: 12, weight: .medium))
                            HStack(spacing: 6) {
                                TextField("1", text: $limitText).frame(width: 65).textFieldStyle(.roundedBorder).accessibilityLabel("Memory limit amount").onSubmit(saveLimit)
                                Picker("Memory unit", selection: $limitUnit) { Text("MB").tag(1_000_000.0); Text("GB").tag(1_000_000_000.0) }.labelsHidden().frame(width: 70)
                                Button("Apply", action: saveLimit).controlSize(.small)
                            }
                            if let limitError { Text(limitError).font(.system(size: 11)).foregroundStyle(.red) }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Check every").font(.system(size: 12, weight: .medium))
                            HStack(spacing: 6) {
                                TextField("5", text: $intervalText).frame(width: 55).textFieldStyle(.roundedBorder).accessibilityLabel("Check interval amount").onSubmit(saveInterval)
                                Picker("Interval unit", selection: $intervalUnit) { Text("sec").tag(1.0); Text("min").tag(60.0); Text("hr").tag(3600.0) }.labelsHidden().frame(width: 75)
                                Button("Apply", action: saveInterval).controlSize(.small)
                            }
                            if let intervalError { Text(intervalError).font(.system(size: 11)).foregroundStyle(.red) }
                        }
                        Spacer(minLength: 0)
                    }
                    Toggle("Include helper and child processes for watched targets", isOn: Binding(get: { model.settings.includeHelpers }, set: { value in model.update { $0.includeHelpers = value } })).font(.system(size: 12))
                    Text("Watched entries share a limit with their helpers. All-process alerts measure each process individually.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.card()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recovery & retries").font(.system(size: 14, weight: .semibold))
                    Stepper("Maximum quit attempts: \(model.settings.maximumAttempts)", value: Binding(get: { model.settings.maximumAttempts }, set: { value in model.update { $0.maximumAttempts = value } }), in: 1...100).font(.system(size: 12))
                    Text("One attempt per check. A restart below the limit resets the count. Entries that exhaust their attempts pause until resumed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("Automatically resume paused entries after a cooldown", isOn: Binding(get: { model.settings.automaticallyResume }, set: { value in model.update { $0.automaticallyResume = value } })).font(.system(size: 12))
                    HStack {
                        Text("Cooldown").font(.system(size: 12))
                        TextField("30", text: $cooldownText).frame(width: 65).textFieldStyle(.roundedBorder).accessibilityLabel("Cooldown minutes").onSubmit(saveCooldown)
                        Text("minutes").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Apply", action: saveCooldown).controlSize(.small)
                        Spacer()
                    }.disabled(!model.settings.automaticallyResume)
                    if let cooldownError { Text(cooldownError).font(.system(size: 11)).foregroundStyle(.red) }
                }.card()
                watchList
                administrator
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin)).font(.system(size: 12))
                    if model.loginStatus == .requiresApproval {
                        Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }.font(.system(size: 11))
                    }
                    Text("Applied settings save automatically.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
    }

    private var watchList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Watched apps & processes").font(.system(size: 14, weight: .semibold))
                Text("\(model.settings.rules.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Choose from Applications…") { model.chooseApplications() }
                    Button("Enter app or process name…") { editor = RuleEditorItem(rule: nil) }
                    Menu("Add a running app") {
                        ForEach(model.runningApplications().filter(\.isRegular), id: \.pid) { app in
                            Button(app.name) { model.saveRule(name: app.name, bundleIdentifier: app.bundleIdentifier, targetKind: .application) }
                        }
                    }
                } label: { Label("Add target", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
            }
            if model.settings.rules.isEmpty {
                Text("Your watch list is empty. Add targets here or use ‘Watch this process’ in Activity.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.settings.rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Divider().padding(.leading, 14) }
                        HStack(spacing: 12) {
                            Image(systemName: model.retries[rule.id]?.isPaused == true ? "pause.circle.fill" : "app.fill").font(.system(size: 22)).foregroundStyle(hogPink)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.name).font(.system(size: 12, weight: .medium))
                                Text(model.pauseDetail(rule.id) ?? sampleDetail(rule)).font(.system(size: 11)).foregroundStyle(.secondary)
                                if let path = rule.executablePath { Text(path).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(path) }
                                if let state = model.retries[rule.id], !state.isPaused, state.failures > 0 {
                                    Text("\(state.failures) of \(model.settings.maximumAttempts) failed attempts").font(.system(size: 11)).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 5)
                            Text(sampleUsage(rule)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            if model.retries[rule.id]?.isPaused == true { Button("Resume") { model.resumeRule(rule.id) }.controlSize(.small) }
                            Button { editor = RuleEditorItem(rule: rule) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit \(rule.name)").accessibilityLabel("Edit \(rule.name)")
                            Button { model.removeRule(rule.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove \(rule.name)").accessibilityLabel("Remove \(rule.name)")
                        }.padding(14)
                    }
                }.background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            }
            Label("Force-quitting can lose unsaved changes.", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var administrator: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("System process access", systemImage: "lock.shield").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(model.helperAvailable ? "Reinstall helper…" : "Install helper…") { model.installAdministratorHelper() }.controlSize(.small)
            }
            Toggle("Use administrator helper", isOn: Binding(get: { model.settings.administratorEnabled && model.helperAvailable }, set: model.setAdministratorHelper)).font(.system(size: 12)).disabled(!model.helperAvailable)
            Text(model.helperStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Improves memory visibility and permits quitting third-party root-owned processes. Installation asks for administrator approval.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.helperAvailable { Button("Uninstall helper…") { model.uninstallAdministratorHelper() }.controlSize(.small) }
        }.card()
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent activity").font(.system(size: 14, weight: .semibold))
                Spacer()
                if !model.history.isEmpty { Button("Clear history") { model.clearHistory() }.controlSize(.small) }
            }
            if model.history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bell.badge").font(.system(size: 32, weight: .light)).foregroundStyle(hogPink)
                    Text("No activity yet").font(.system(size: 15, weight: .medium))
                    Text("Memory alerts, quit attempts, and paused watchers appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.history) { entry in
                                activityRow(entry).id(entry.id)
                            }
                        }
                    }.onAppear { if let id = model.focusedActivityID { proxy.scrollTo(id, anchor: .center) } }
                        .onChange(of: model.focusedActivityID) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func activityRow(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: activityIcon(entry)).foregroundStyle(activityColor(entry)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(entry.app).font(.system(size: 12, weight: .semibold))
                    Text(MemoryText.format(entry.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(entry.message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                if let process = entry.process {
                    if !process.path.isEmpty { Text(process.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack(spacing: 12) {
                        Text("PID \(process.pid) · \(process.uid == 0 ? "root" : "UID \(process.uid)")").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if let rule = model.watchedRule(for: process) {
                            Text("Already watched").font(.system(size: 11)).foregroundStyle(.secondary)
                            if model.retries[rule.id]?.isPaused == true { Button("Resume watcher") { model.resumeRule(rule.id) }.controlSize(.small) }
                        } else if let reason = model.promotionReason(process) {
                            Label("Alert only · \(reason)", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Button("Watch this process") { model.watchProcess(process) }.controlSize(.small)
                        }
                    }
                } else if let id = entry.ruleID, model.retries[id]?.isPaused == true {
                    Button("Resume watcher") { model.resumeRule(id) }.controlSize(.small)
                }
            }
        }.padding(14).background(RoundedRectangle(cornerRadius: 10).fill(entry.id == model.focusedActivityID ? hogPink.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
    }
    private func activityIcon(_ entry: ActivityEntry) -> String {
        switch entry.kind {
        case .alert: return "bell.fill"
        case .paused: return "pause.circle.fill"
        case .resumed: return "play.circle.fill"
        case .pendingRecovery: return "clock"
        case .skipped: return "lock.shield"
        default: return entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle"
        }
    }
    private func activityColor(_ entry: ActivityEntry) -> Color {
        if entry.kind == .alert || entry.kind == .pendingRecovery { return .blue }
        return entry.succeeded ? .green : .orange
    }
    private func sampleUsage(_ rule: WatchRule) -> String {
        guard let sample = model.samples[rule.id], sample.isRunning else { return "—" }
        return sample.isMeasurable ? (sample.unavailableCount > 0 ? "≥ " : "") + MemoryText.format(sample.bytes) : "Unavailable"
    }
    private func sampleDetail(_ rule: WatchRule) -> String {
        guard let sample = model.samples[rule.id] else { return "Waiting for a check" }
        guard sample.isRunning else { return "No visible match" }
        if sample.requiresAdministratorAccess && !(model.settings.administratorEnabled && model.helperAvailable) { return sample.isRootOwned ? "Running as root · administrator helper required" : "Additional process access required" }
        if sample.unavailableCount > 0 { return "\(sample.processes.count) processes · some memory unavailable" }
        if model.retries[rule.id]?.pendingRecovery == true { return "Awaiting the next recovery check" }
        return "\(sample.processes.count) processes" + (sample.isRootOwned ? " · root" : "")
    }
    private func loadFields() {
        limitUnit = model.settings.limitBytes >= 1_000_000_000 ? 1_000_000_000 : 1_000_000
        limitText = number(Double(model.settings.limitBytes) / limitUnit)
        let seconds = model.settings.intervalSeconds
        intervalUnit = seconds >= 3600 && seconds.truncatingRemainder(dividingBy: 3600) == 0 ? 3600 : (seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? 60 : 1)
        intervalText = number(seconds / intervalUnit)
        cooldownText = number(model.settings.cooldownSeconds / 60)
    }
    private func number(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(format: "%.3g", value) }
    private func parse(_ value: String) -> Double? { Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) }
    private func saveLimit() {
        guard let value = parse(limitText), value.isFinite, value * limitUnit >= 1_000_000, value * limitUnit <= 1_000_000_000_000 else { limitError = "Use 1 MB to 1,000 GB."; return }
        limitError = nil; model.update { $0.limitBytes = UInt64(value * limitUnit) }
    }
    private func saveInterval() {
        guard let value = parse(intervalText), value.isFinite, value * intervalUnit >= 5, value * intervalUnit <= 86_400, (value * intervalUnit).rounded() == value * intervalUnit else { intervalError = "Use whole seconds, from 5 sec to 24 hr."; return }
        intervalError = nil; model.update { $0.intervalSeconds = value * intervalUnit }
    }
    private func saveCooldown() {
        guard let value = parse(cooldownText), value.isFinite, (1...1440).contains(value), value.rounded() == value else { cooldownError = "Use 1 to 1,440 whole minutes."; return }
        cooldownError = nil; model.update { $0.cooldownSeconds = value * 60 }
    }
}

private extension View {
    func card() -> some View { padding(17).background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))) }
}

struct RuleEditorItem: Identifiable {
    let id = UUID()
    let rule: WatchRule?
}

struct RuleEditor: View {
    @ObservedObject var model: AppModel
    let item: RuleEditorItem
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var localError: String?
    @ViewState private var useBundleIdentity = true
    @ViewState private var kind: TargetKind = .automatic
    @ViewState private var executablePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.rule == nil ? "Add an app or process" : "Edit target").font(.system(size: 18, weight: .semibold))
            Text("Enter the exact app or process name shown in Activity Monitor. Name matching ignores capitalization.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("App or process name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if let bundleID = item.rule?.bundleIdentifier {
                Toggle("Match by app identity", isOn: $useBundleIdentity).font(.system(size: 12))
                Text(bundleID).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if item.rule?.bundleIdentifier == nil || !useBundleIdentity {
                Picker("Match", selection: $kind) {
                    Text("App or process").tag(TargetKind.automatic)
                    Text("App").tag(TargetKind.application)
                    Text("Process").tag(TargetKind.process)
                }.pickerStyle(.segmented)
                if kind != .application {
                    TextField("Full executable path (optional)", text: $executablePath).textFieldStyle(.roundedBorder)
                    Text("Pin a path to distinguish processes that have the same name.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let localError { Text(localError).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(item.rule == nil ? "Add target" : "Save", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(hogPink).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(25).frame(width: 420).onAppear {
            name = item.rule?.name ?? ""
            kind = item.rule?.targetKind ?? .automatic
            executablePath = item.rule?.executablePath ?? ""
        }
    }
    private func save() {
        if model.saveRule(id: item.rule?.id, name: name,
                          bundleIdentifier: useBundleIdentity ? item.rule?.bundleIdentifier : nil,
                          targetKind: useBundleIdentity && item.rule?.bundleIdentifier != nil ? .application : kind,
                          executablePath: executablePath) { dismiss() }
        else { localError = model.message; model.message = nil }
    }
}

import Foundation
import Darwin

public enum ProcessScanner {
    public static func identity(for pid: Int32, includeOtherUsers: Bool = false) -> ProcessIdentity? {
        guard let info = bsdInfo(pid), includeOtherUsers || info.pbi_uid == getuid() else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return info
    }

    public static func record(for pid: Int32, includeOtherUsers: Bool = false) -> ProcessRecord? {
        guard pid > 1, let info = bsdInfo(pid), info.pbi_status != SZOMB,
              includeOtherUsers || info.pbi_uid == getuid() else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro Swift cannot import.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0 ? String(cString: nameBuffer) : URL(fileURLWithPath: path).lastPathComponent
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        let identity = ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        // Re-read the identity so a recycled PID cannot combine two different processes.
        guard self.identity(for: pid, includeOtherUsers: includeOtherUsers) == identity else { return nil }
        return ProcessRecord(identity: identity, parentPID: Int32(info.pbi_ppid), uid: info.pbi_uid,
                             path: path, memoryBytes: result == 0 ? usage.ri_phys_footprint : nil, name: name)
    }

    // Basic sysctl process metadata remains readable when libproc refuses
    // details for a root-owned process. These entries deliberately have no
    // memory measurement, so discovery never grants termination authority.
    public static func visibleProcessRecords(allowedUserIDs: Set<UInt32>? = nil) -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            let stride = MemoryLayout<kinfo_proc>.stride
            var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 128)
            size = infos.count * stride
            let status = infos.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
            if status != 0 { if errno == ENOMEM { continue }; return [] }
            return infos.prefix(size / stride).compactMap { info in
                let uid = info.kp_eproc.e_ucred.cr_uid
                guard (allowedUserIDs == nil || allowedUserIDs!.contains(uid)),
                      info.kp_proc.p_pid > 1, info.kp_proc.p_stat != SZOMB else { return nil }
                var proc = info.kp_proc
                let name = withUnsafePointer(to: &proc.p_comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
                }
                let start = proc.p_un.__p_starttime
                var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let pathLength = proc_pidpath(proc.p_pid, &pathBuffer, UInt32(pathBuffer.count))
                return ProcessRecord(identity: ProcessIdentity(pid: proc.p_pid,
                    startSeconds: UInt64(max(0, start.tv_sec)), startMicroseconds: UInt64(max(0, start.tv_usec))),
                    parentPID: info.kp_eproc.e_ppid, uid: uid,
                    path: pathLength > 0 ? String(cString: pathBuffer) : "", memoryBytes: nil, name: name)
            }
        }
        return []
    }

    public static func scan(rules: [WatchRule], apps: [RunningApp], includeHelpers: Bool,
                            allowedUserIDs: Set<UInt32>? = nil) -> [MemorySample] {
        report(rules: rules, apps: apps, includeHelpers: includeHelpers, allowedUserIDs: allowedUserIDs).samples
    }

    // Inventory is read-only and deliberately includes every readable user.
    // Termination and watched-group attribution retain their narrower UID scope.
    public static func inventory() -> ProcessInventory {
        let visible = visibleProcessRecords()
        var records: [Int32: ProcessRecord] = [:]
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 256)
        var pids = [Int32](repeating: 0, count: estimatedCount * 2)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let identifiers = Set(visible.map(\.pid)).union(count > 0 ? pids.prefix(min(Int(count), pids.count)) : [])
        for pid in identifiers where pid > 1 {
            if let record = record(for: pid, includeOtherUsers: true) { records[pid] = record }
        }
        for fallback in visible where records[fallback.pid] == nil {
            records[fallback.pid] = fallback
        }
        return ProcessInventory(processes: records.values.sorted { $0.pid < $1.pid }, enumerationComplete: !visible.isEmpty)
    }

    public static func report(rules: [WatchRule], apps: [RunningApp], includeHelpers: Bool,
                              allowedUserIDs: Set<UInt32>? = nil, inventory: ProcessInventory? = nil) -> ScanReport {
        let inventory = inventory ?? self.inventory()
        let allowedUIDs = allowedUserIDs ?? [getuid(), 0]
        let records = Dictionary(uniqueKeysWithValues: inventory.processes.filter { allowedUIDs.contains($0.uid) }.map { ($0.pid, $0) })
        return ScanReport(inventory: inventory, samples: aggregate(rules: rules, apps: apps, records: records, includeHelpers: includeHelpers))
    }

    public static func recoveryApps(original: [RunningApp], sample: MemorySample, inventory: ProcessInventory) -> [RunningApp] {
        let records = Dictionary(uniqueKeysWithValues: inventory.processes.map { ($0.pid, $0) })
        // Retain inaccessible current roots, but discard descriptors for exited
        // or recycled processes. New launchd instances are verified by path.
        var apps = original.filter { app in
            guard let record = records[app.pid] else { return !inventory.enumerationComplete }
            if let root = sample.roots.first(where: { $0.pid == app.pid }), root.identity != record.identity { return false }
            guard let time = app.launchTime else { return true }
            return abs(Double(record.identity.startSeconds) + Double(record.identity.startMicroseconds) / 1_000_000 - time) <= 2
        }
        for root in sample.roots where !root.path.isEmpty {
            guard let descriptor = original.first(where: { $0.pid == root.pid }) else { continue }
            for record in inventory.processes where record.path == root.path && !apps.contains(where: { $0.pid == record.pid }) {
                apps.append(RunningApp(pid: record.pid, name: descriptor.name, bundleIdentifier: descriptor.bundleIdentifier,
                    bundlePath: descriptor.bundlePath, executablePath: record.path,
                    launchTime: Double(record.identity.startSeconds) + Double(record.identity.startMicroseconds) / 1_000_000,
                    isRegular: descriptor.isRegular))
            }
        }
        return apps
    }

    public static func aggregate(rules: [WatchRule], apps: [RunningApp], records: [Int32: ProcessRecord],
                                 includeHelpers: Bool) -> [MemorySample] {
        let independentAppPIDs = Set(apps.filter(\.isRegular).map(\.pid))
        return rules.map { rule in
            let matches = apps.filter { $0.pid != getpid() && rule.matches($0) }
            let verifiedApps = matches.filter { app in
                guard let record = records[app.pid] else { return false }
                if let expected = app.executablePath, !expected.isEmpty, record.path != expected { return false }
                if let launchTime = app.launchTime,
                   abs(Double(record.identity.startSeconds) + Double(record.identity.startMicroseconds) / 1_000_000 - launchTime) > 2 {
                    return false
                }
                return true
            }
            var roots = verifiedApps.compactMap { records[$0.pid] }
            // Processes launched by launchd often have no NSRunningApplication.
            // Match their exact executable/process names independently of app bundles.
            let knownRoots = Set(roots.map(\.pid))
            let appMatchPIDs = Set(matches.map(\.pid))
            roots.append(contentsOf: records.values.filter {
                $0.pid != getpid() && !knownRoots.contains($0.pid) && !appMatchPIDs.contains($0.pid) && rule.matches($0)
            })
            let rootPIDs = Set(roots.map(\.pid))
            let bundlePaths = Set(verifiedApps.map(\.bundlePath).filter { !$0.isEmpty })
            let owned = records.values.filter { record in
                if rootPIDs.contains(record.pid) { return true }
                guard includeHelpers else { return false }
                // A separate foreground app launched by a watched app is never a helper.
                if independentAppPIDs.contains(record.pid) { return false }
                if bundlePaths.contains(where: { record.path.hasPrefix($0 + "/") }) { return true }
                var parent = record.parentPID
                var visited = Set<Int32>()
                while parent > 1 && visited.insert(parent).inserted {
                    if rootPIDs.contains(parent) { return true }
                    if independentAppPIDs.contains(parent) { return false }
                    guard let ancestor = records[parent] else { return false }
                    parent = ancestor.parentPID
                }
                return false
            }.sorted { $0.pid < $1.pid }
            return MemorySample(ruleID: rule.id, roots: roots, processes: owned,
                                missingRoots: matches.count - verifiedApps.count)
        }
    }
}

public struct TerminationResult: Codable, Sendable {
    public let killed: Int
    public let alreadyExited: Int
    public let failures: [String]
    public let attempted: Int
    public let cancelled: Bool
    public init(killed: Int, alreadyExited: Int = 0, failures: [String] = [], attempted: Int, cancelled: Bool = false) {
        self.killed = killed; self.alreadyExited = alreadyExited; self.failures = failures
        self.attempted = attempted; self.cancelled = cancelled
    }
}

public enum ProcessTerminator {
    public static func refusalReason(for process: ProcessRecord, allowedUserIDs: Set<UInt32>, protectedPIDs: Set<Int32>) -> String? {
        if process.pid <= 1 || process.pid == getpid() || protectedPIDs.contains(process.pid) { return "protected process" }
        if !allowedUserIDs.contains(process.uid) { return "administrator helper required" }
        // The optional helper is for third-party applications and daemons.
        // macOS's own root services are outside its scope.
        if process.uid == 0 {
            let systemPaths = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/"]
            if process.path.isEmpty || systemPaths.contains(where: { process.path.hasPrefix($0) }) {
                return "macOS system service is protected"
            }
        }
        return nil
    }

    public static func terminate(_ sample: MemorySample, allowedUserIDs: Set<UInt32>? = nil,
                                  protectedPIDs: Set<Int32> = [], shouldContinue: () -> Bool = { true }) -> TerminationResult {
        let allowedUIDs = allowedUserIDs ?? [getuid()]
        let rootPIDs = Set(sample.roots.map(\.pid))
        let ordered = sample.processes.sorted { !rootPIDs.contains($0.pid) && rootPIDs.contains($1.pid) }
        var killed = 0
        var alreadyExited = 0
        var failures: [String] = []
        var attempted = 0
        var cancelled = false
        for process in ordered {
            guard shouldContinue() else { cancelled = true; break }
            if let reason = refusalReason(for: process, allowedUserIDs: allowedUIDs, protectedPIDs: protectedPIDs) {
                failures.append("PID \(process.pid): \(reason)")
                continue
            }
            guard let current = ProcessScanner.record(for: process.pid, includeOtherUsers: getuid() == 0),
                  current.identity == process.identity, current.uid == process.uid,
                  current.path == process.path else {
                alreadyExited += 1
                continue
            }
            attempted += 1
            if kill(process.pid, SIGKILL) == 0 { killed += 1 }
            else if errno == ESRCH { alreadyExited += 1 }
            else { failures.append("PID \(process.pid): \(String(cString: strerror(errno)))") }
        }
        return TerminationResult(killed: killed, alreadyExited: alreadyExited, failures: failures,
                                 attempted: attempted, cancelled: cancelled)
    }
}

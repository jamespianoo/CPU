import AppKit
import SwiftUI
import Darwin
import IOKit
import UserNotifications

@_silgen_name("IOHIDEventSystemClientCreate") func IOHIDEventSystemClientCreate(_ allocator: UnsafeRawPointer?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ match: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent") func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

// MARK: - Model

struct SubRow: Identifiable {
    let id: String
    var label: String
    var caption = ""
    var kind: Int          // 0 session, 1 tab, 2 background
    var cpu: Double
    var memMB: Double
    var pids: [Int32]
    var gpu: Double = 0
    var gpuTime: Double = 0
}

struct AppRow: Identifiable {
    let id: String
    let name: String
    var cpu: Double = 0
    var memMB: Double = 0
    var subs: [SubRow] = []
    var bundlePath: String?
    var diskMB: Double?
    var gpu: Double = 0
    var gpuTime: Double = 0
    var isGUI = false
    var pids: [Int32] { subs.flatMap(\.pids) }
}

struct Proc {
    let pid: Int32, ppid: Int32
    let cpu: Double, memMB: Double
    let cmd: String
}

@MainActor
final class Monitor: ObservableObject {
    @Published var cpu: Double = 0
    @Published var ram: Double = 0
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var disk: Double = 0
    @Published var diskUsedGB: Double = 0
    @Published var diskTotalGB: Double = 0
    @Published var rows: [AppRow] = []
    @Published var coreMode = false
    var onChange: (() -> Void)?
    var detailed = false

    let chip = Monitor.sysctlString("machdep.cpu.brand_string") ?? "Mac"
    let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let perfCores = Monitor.sysctlInt("hw.perflevel0.physicalcpu")
    let effCores = Monitor.sysctlInt("hw.perflevel1.physicalcpu")

    private var prevTicks: [UInt32]?
    private var diskCache: [String: Double] = [:]
    private var pendingDisk: Set<String> = []
    private var cwdCache: [Int32: String] = [:]
    private var pendingCwd: Set<Int32> = []
    private var timer: Timer?

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func sysctlInt(_ name: String) -> Int {
        var v: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        readCPU(); readRAM(); readDisk()
        readNet(); readHeat(); readGPU()
        onChange?()
        if detailed { refreshProcesses() }
    }

    private func readCPU() {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS, let info else { return }
        var ticks = [UInt32](repeating: 0, count: 4)
        for i in 0..<Int(n) { for s in 0..<4 { ticks[s] &+= UInt32(bitPattern: info[i * 4 + s]) } }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        if let p = prevTicks {
            let d = (0..<4).map { Double(ticks[$0] &- p[$0]) }
            let total = d.reduce(0, +)
            if total > 0 { cpu = (total - d[Int(CPU_STATE_IDLE)]) / total * 100 }
        }
        prevTicks = ticks
    }

    private func readRAM() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        ramUsedGB = used / 1e9; ramTotalGB = total / 1e9
        ram = used / total * 100
    }

    private func readDisk() {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return }
        let used = Double(total) - Double(free)
        diskTotalGB = Double(total) / 1e9; diskUsedGB = used / 1e9
        disk = used / Double(total) * 100
    }

    // MARK: network

    @Published var netDown: Double = 0   // bytes/s
    @Published var netUp: Double = 0
    @Published var totalDown: Double = 0
    @Published var totalUp: Double = 0
    private var prevNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var prevNetTime: Date?

    private func readNet() {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return }
        defer { freeifaddrs(ifap) }
        var cur: [String: (rx: UInt32, tx: UInt32)] = [:]
        var p = ifap
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let data = a.pointee.ifa_data else { continue }
            let name = String(cString: a.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            cur[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        let now = Date()
        if let t = prevNetTime {
            let dt = max(0.1, now.timeIntervalSince(t))
            var rx = 0.0, tx = 0.0
            for (n, c) in cur { if let p = prevNet[n] { rx += Double(c.rx &- p.rx); tx += Double(c.tx &- p.tx) } }
            netDown = rx / dt; netUp = tx / dt
            totalDown += rx; totalUp += tx
        }
        prevNet = cur; prevNetTime = now
    }

    static let warm = 80.0, hot = 90.0
    var level: Int { heatMax >= Monitor.hot || thermalState == "Critical" ? 2 : (heatMax >= Monitor.warm || thermalState == "Serious" ? 1 : 0) }

    // MARK: GPU + temperature

    @Published var gpu: Double = 0
    @Published var gpuName = "GPU"
    @Published var gpuStats: [(String, String)] = []
    @Published var temps: [(String, Double)] = []
    @Published var heat: Double = 0
    @Published var heatMax: Double = 0
    @Published var thermalState = "Nominal"

    @Published var gpuByPid: [Int32: Double] = [:]   // % busy
    var gpuTimeByPid: [Int32: Double] = [:]          // accumulated seconds
    private var prevGPU: [Int32: Double] = [:]
    private var prevGPUTime: Date?

    private func readGPUClients(_ svc: io_object_t) {
        var cit: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(svc, kIOServicePlane, &cit) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(cit) }
        var acc: [Int32: Double] = [:]
        var c = IOIteratorNext(cit)
        while c != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(c, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any],
               let creator = d["IOUserClientCreator"] as? String,
               let r = creator.range(of: "pid "),
               let pid = Int32(creator[r.upperBound...].prefix { $0.isNumber }),
               let usage = d["AppUsage"] as? [[String: Any]] {
                for u in usage { acc[pid, default: 0] += ((u["accumulatedGPUTime"] as? NSNumber)?.doubleValue ?? 0) }
            }
            IOObjectRelease(c)
            c = IOIteratorNext(cit)
        }
        let now = Date()
        if let t = prevGPUTime {
            let dt = max(0.1, now.timeIntervalSince(t))
            var pct: [Int32: Double] = [:]
            for (pid, ns) in acc { if let p = prevGPU[pid], ns >= p { pct[pid] = min(100, (ns - p) / (dt * 1e9) * 100) } }
            gpuByPid = pct
        }
        gpuTimeByPid = acc.mapValues { $0 / 1e9 }
        prevGPU = acc; prevGPUTime = now
    }

    private func readGPU() {
        guard let match = IOServiceMatching("IOAccelerator") else { return }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var svc = IOIteratorNext(it)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any],
               let ps = d["PerformanceStatistics"] as? [String: Any] {
                func num(_ k: String) -> Double? { (ps[k] as? NSNumber)?.doubleValue }
                gpu = num("Device Utilization %") ?? 0
                gpuName = (d["model"] as? String) ?? "GPU"
                var out: [(String, String)] = []
                if let c = (d["gpu-core-count"] as? NSNumber)?.intValue { out.append(("Cores", "\(c)")) }
                if let v = num("Device Utilization %") { out.append(("Utilization", String(format: "%.0f%%", v))) }
                if let v = num("Renderer Utilization %") { out.append(("Renderer", String(format: "%.0f%%", v))) }
                if let v = num("Tiler Utilization %") { out.append(("Tiler", String(format: "%.0f%%", v))) }
                if let v = num("In use system memory") { out.append(("Memory in use", fmtMB(v / 1_048_576))) }
                if let v = num("Alloc system memory") { out.append(("Memory allocated", fmtMB(v / 1_048_576))) }
                gpuStats = out
                readGPUClients(svc)
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
    }

    private func readHeat() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = "Nominal"
        case .fair: thermalState = "Fair"
        case .serious: thermalState = "Serious"
        case .critical: thermalState = "Critical"
        @unknown default: thermalState = "Unknown"
        }
        guard let client = IOHIDEventSystemClientCreate(nil)?.takeRetainedValue() else { return }
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let arr = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return }
        var found: [(String, Double)] = []
        for svc in arr {
            let name = (IOHIDServiceClientCopyProperty(svc, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Sensor"
            guard let ev = IOHIDServiceClientCopyEvent(svc, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(ev, 15 << 16)
            if v > 0 && v < 150 { found.append((Monitor.sensorName(name), v)) }
        }
        found.sort { $0.1 > $1.1 }
        temps = found
        let dies = found.filter { $0.0.hasPrefix("CPU") }
        let pool = dies.isEmpty ? found : dies
        if !pool.isEmpty { heat = pool.reduce(0) { $0 + $1.1 } / Double(pool.count); heatMax = pool.map(\.1).max() ?? 0 }
    }

    static func sensorName(_ raw: String) -> String {
        let l = raw.lowercased()
        let digits = raw.filter(\.isNumber)
        if l.contains("tdie") { return "CPU die " + digits }
        if l.contains("tdev") { return "Device " + digits }
        if l.contains("battery") { return "Battery" }
        if l.contains("nand") { return "SSD " + digits }
        return raw
    }

    // MARK: processes

    func refreshProcesses() {
        var gui: [Int32: String] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            if let u = a.bundleURL { gui[a.processIdentifier] = u.deletingPathExtension().lastPathComponent }
        }
        let cwds = cwdCache
        DispatchQueue.global(qos: .utility).async {
            let out = Monitor.run("/bin/ps", ["-x", "-o", "pid=,ppid=,pcpu=,rss=,command="])
            var procs: [Int32: Proc] = [:]
            for line in out.split(separator: "\n") {
                let p = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                guard p.count == 5, let pid = Int32(p[0]), let ppid = Int32(p[1]), let cpu = Double(p[2]), let rss = Double(p[3]) else { continue }
                procs[pid] = Proc(pid: pid, ppid: ppid, cpu: cpu, memMB: rss / 1024, cmd: String(p[4]))
            }
            var groups: [String: AppRow] = [:]
            var needCwd: [Int32] = []
            func exeName(_ p: Proc) -> String { (Monitor.exePath(p.cmd) as NSString).lastPathComponent }
            let sessionPids = Set(procs.values.filter { exeName($0) == "claude" }.map(\.pid))
            // work started by a Claude session (shells, node, builds) is counted towards that session
            var extra: [Int32: (cpu: Double, mem: Double, pids: [Int32])] = [:]
            var absorbed = Set<Int32>()
            var inst: [Int32: (name: String, label: String, caption: String, cpu: Double, mem: Double, pids: [Int32])] = [:]
            for pr in procs.values where !sessionPids.contains(pr.pid) {
                var cur = pr.ppid, hops = 0
                while cur > 1 && hops < 20 {
                    if sessionPids.contains(cur) {
                        var e = extra[cur] ?? (0, 0, [])
                        e.cpu += pr.cpu; e.mem += pr.memMB; e.pids.append(pr.pid)
                        extra[cur] = e; absorbed.insert(pr.pid); break
                    }
                    cur = procs[cur]?.ppid ?? 0; hops += 1
                }
            }
            for pr in procs.values where !absorbed.contains(pr.pid) {
                let en = exeName(pr)
                var name = en, bundle: String?, viaGUI = gui[pr.pid] != nil
                if let r = pr.cmd.range(of: ".app/") {
                    bundle = String(pr.cmd[..<r.lowerBound]) + ".app"
                    name = ((bundle! as NSString).lastPathComponent as NSString).deletingPathExtension
                    var cur = pr.ppid, hops = 0
                    while cur > 1 && hops < 12 {
                        if let g = gui[cur] { name = g; viaGUI = true; break }
                        cur = procs[cur]?.ppid ?? 0; hops += 1
                    }
                }
                let isSession = sessionPids.contains(pr.pid)
                if isSession && name == "claude" { name = "Claude Code" }
                var cpu = pr.cpu, mem = pr.memMB, pids = [pr.pid]
                var sub: SubRow?
                // a helper app started by a script (e.g. headless Chrome from node): one row per launcher
                var root: Int32? = nil, launcher: Proc? = nil
                if let b = bundle, !viaGUI, !isSession {
                    var cur = pr.pid, hops = 0
                    while hops < 10, let par = procs[procs[cur]?.ppid ?? 0], par.cmd.hasPrefix(b) { cur = par.pid; hops += 1 }
                    if let l = procs[procs[cur]?.ppid ?? 0], !l.cmd.contains(".app/") { root = cur; launcher = l }
                }
                if let root, let launcher {
                    var a = inst[root] ?? (name, Monitor.launcherLabel(launcher.cmd), pr.cmd.contains("--headless") ? "\(name) · headless" : name, 0, 0, [])
                    a.cpu += cpu; a.mem += mem; a.pids += pids
                    inst[root] = a
                    sub = nil
                } else if isSession {
                    if let e = extra[pr.pid] { cpu += e.cpu; mem += e.mem; pids += e.pids }
                    if cwds[pr.pid] == nil { needCwd.append(pr.pid) }
                    let info = Monitor.sessionInfo(Monitor.flag(pr.cmd, "resume"), cwd: cwds[pr.pid])
                    let project = Monitor.project(cwds[pr.pid] ?? info?.cwd)
                    sub = SubRow(id: "s\(pr.pid)", label: info?.title ?? project ?? "Session", caption: info == nil ? "" : (project ?? ""), kind: 0, cpu: cpu, memMB: mem, pids: pids)
                } else if Monitor.flag(pr.cmd, "type") == "renderer" {
                    sub = SubRow(id: "t\(pr.pid)", label: Monitor.isBrowser(name) ? "Renderer · tab" : "Renderer · window", kind: 1, cpu: cpu, memMB: mem, pids: pids)
                } else {
                    sub = SubRow(id: "b\(pr.pid)", label: Monitor.processLabel(pr, exeName: en, appName: name), kind: 2, cpu: cpu, memMB: mem, pids: pids)
                }
                var row = groups[name] ?? AppRow(id: name, name: name)
                row.cpu += cpu; row.memMB += mem
                if gui[pr.pid] != nil { row.isGUI = true }
                if row.bundlePath == nil { row.bundlePath = bundle }
                if let sub { row.subs.append(sub) }
                groups[name] = row
            }
            for (root, a) in inst {
                var caption = a.caption
                if let rp = procs[root], let page = Monitor.devtoolsPages(rp.cmd).first {
                    let u = URL(string: page.url)
                    caption = page.title.isEmpty ? (u?.host ?? page.url) : "\(page.title) · \(u?.host ?? "")"
                }
                groups[a.name]?.subs.append(SubRow(id: "i\(root)", label: a.label, caption: caption, kind: 3, cpu: a.cpu, memMB: a.mem, pids: a.pids))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.publish(groups); self.fetchCwd(needCwd) } }
        }
    }

    nonisolated static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func exePath(_ cmd: String) -> String {
        if let r = cmd.range(of: " --") { return String(cmd[..<r.lowerBound]) }
        if cmd.hasPrefix("/") && !cmd.contains(".app/") { return String(cmd.split(separator: " ", maxSplits: 1).first ?? "") }
        return String(cmd.split(separator: " ", maxSplits: 1).first ?? "")
    }

    nonisolated static func flag(_ cmd: String, _ f: String) -> String? {
        guard let r = cmd.range(of: " --\(f)=") else { return nil }
        return String(cmd[r.upperBound...].prefix { $0 != " " })
    }

    nonisolated static func processLabel(_ p: Proc, exeName: String, appName: String) -> String {
        if let t = flag(p.cmd, "type") {
            switch t {
            case "gpu-process": return "GPU process"
            case "utility":
                let raw = flag(p.cmd, "utility-sub-type")?.split(separator: ".").last.map(String.init) ?? "Utility"
                var out = ""
                for (i, ch) in raw.enumerated() { if i > 0, ch.isUppercase { out += " " }; out.append(ch) }
                return out
            default: return t.capitalized + " process"
            }
        }
        if exeName.contains("crashpad") { return "Crash reporter" }
        if exeName == "disclaimer" { return "Launcher" }
        if exeName == appName { return "Main process" }
        return exeName
    }

    nonisolated static func devtoolsPages(_ cmd: String) -> [(title: String, url: String)] {
        guard let dir = flag(cmd, "user-data-dir"),
              let port = (try? String(contentsOfFile: dir + "/DevToolsActivePort", encoding: .utf8))?.split(separator: "\n").first,
              let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 0.5
        let sem = DispatchSemaphore(value: 0)
        var result: [(String, String)] = []
        URLSession.shared.dataTask(with: req) { d, _, _ in
            if let d, let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                result = arr.filter { ($0["type"] as? String) == "page" }.map { (($0["title"] as? String) ?? "", ($0["url"] as? String) ?? "") }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 0.8)
        return result
    }

    nonisolated static func isBrowser(_ n: String) -> Bool {
        ["chrome", "safari", "firefox", "brave", "edge", "arc", "opera", "vivaldi"].contains { n.lowercased().contains($0) }
    }

    // "node scripts/job.js --tag foo ..." -> "job.js · foo"
    nonisolated static func launcherLabel(_ cmd: String) -> String {
        let t = cmd.split(separator: " ").map(String.init)
        guard let first = t.first else { return cmd }
        let exe = (first as NSString).lastPathComponent
        var label = exe
        if ["node", "python", "python3", "ruby", "bash", "sh", "zsh", "deno", "bun"].contains(exe), t.count > 1, !t[1].hasPrefix("-") {
            label = (t[1] as NSString).lastPathComponent
        }
        for key in ["--tag", "--name", "--station", "--id"] {
            if let i = t.firstIndex(of: key), i + 1 < t.count { label += " · " + t[i + 1]; break }
        }
        return label
    }

    nonisolated static func project(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let parts = cwd.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "GitHub"), i + 1 < parts.count { return parts[i + 1] }
        return parts.last
    }

    // Claude desktop keeps each session's title in claude-code-sessions/*/*/local_*.json, keyed by cliSessionId
    nonisolated(unsafe) static var sessionCache: [String: (title: String, cwd: String?)] = [:]
    nonisolated(unsafe) static var fileSeen: [String: Date] = [:]
    nonisolated(unsafe) static var byCwd: [String: (title: String, act: Double)] = [:]
    static let cacheLock = NSLock()

    nonisolated static func sessionInfo(_ id: String?, cwd: String? = nil) -> (title: String, cwd: String?)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let id, let hit = sessionCache[id] { return hit }
        let base = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
        let fm = FileManager.default
        for acct in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
            for sub in (try? fm.contentsOfDirectory(atPath: base + "/" + acct)) ?? [] {
                let dir = base + "/" + acct + "/" + sub
                for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("local_") && f.hasSuffix(".json") {
                    let path = dir + "/" + f
                    let mod = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
                    if let mod, fileSeen[path] == mod { continue }
                    fileSeen[path] = mod
                    guard let d = fm.contents(atPath: path),
                          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let cid = j["cliSessionId"] as? String, let t = j["title"] as? String else { continue }
                    sessionCache[cid] = (t, j["cwd"] as? String)
                    if (j["isArchived"] as? Bool) != true, let c = j["cwd"] as? String {
                        let act = (j["lastActivityAt"] as? Double) ?? 0
                        if act >= (byCwd[c]?.act ?? 0) { byCwd[c] = (t, act) }
                    }
                }
            }
        }
        if let id, let hit = sessionCache[id] { return hit }
        if id == nil, let cwd, let t = byCwd[cwd] { return (t.title, cwd) }
        return nil
    }

    nonisolated static func collapse(_ subs: [SubRow]) -> [SubRow] {
        let order = [0: 0, 3: 1, 4: 2, 1: 3]
        var out = subs.filter { $0.kind != 2 }.sorted { (order[$0.kind]!, -$0.cpu) < (order[$1.kind]!, -$1.cpu) }
        var byLabel: [String: [SubRow]] = [:]
        for r in subs where r.kind == 2 { byLabel[r.label, default: []].append(r) }
        let total: ([SubRow]) -> Double = { $0.reduce(0) { $0 + $1.cpu } }
        for (l, rs) in byLabel.sorted(by: { total($0.value) > total($1.value) }) {
            out.append(SubRow(id: "b" + l, label: rs.count > 1 ? "\(l) ×\(rs.count)" : l, kind: 2, cpu: total(rs), memMB: rs.reduce(0) { $0 + $1.memMB }, pids: rs.flatMap(\.pids), gpu: rs.reduce(0) { $0 + $1.gpu }, gpuTime: rs.reduce(0) { $0 + $1.gpuTime }))
        }
        return out
    }

    @Published var tabs: [String: [(title: String, host: String)]] = [:]

    func refreshTabs() {
        let browsers = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL?.deletingPathExtension().lastPathComponent }
            .filter { ["Google Chrome", "Brave Browser", "Microsoft Edge", "Arc", "Safari"].contains($0) }
        guard !browsers.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var found: [String: [(String, String)]] = [:]
            for b in browsers {
                let nameProp = b == "Safari" ? "name" : "title"
                let script = "with timeout of 3 seconds\ntell application \"\(b)\"\nset out to \"\"\nrepeat with w in windows\nrepeat with t in tabs of w\nset out to out & (\(nameProp) of t) & \"\\t\" & (URL of t) & \"\\n\"\nend repeat\nend repeat\nreturn out\nend tell\nend timeout"
                let out = Monitor.run("/usr/bin/osascript", ["-e", script])
                found[b] = out.split(separator: "\n").compactMap {
                    let p = $0.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard p.count == 2 else { return nil }
                    return (p[0], URL(string: p[1])?.host ?? p[1])
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.tabs = found.mapValues { $0.map { (title: $0.0, host: $0.1) } } } }
        }
    }

    private func fetchCwd(_ pids: [Int32]) {
        let todo = pids.filter { !pendingCwd.contains($0) }
        guard !todo.isEmpty else { return }
        todo.forEach { pendingCwd.insert($0) }
        DispatchQueue.global(qos: .background).async {
            let out = Monitor.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", todo.map(String.init).joined(separator: ",")])
            var map: [Int32: String] = [:]; var cur: Int32 = 0
            for l in out.split(separator: "\n") {
                if l.hasPrefix("p") { cur = Int32(l.dropFirst()) ?? 0 } else if l.hasPrefix("n") { map[cur] = String(l.dropFirst()) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { map.forEach { self.cwdCache[$0] = $1 } } }
        }
    }

    private func publish(_ groups: [String: AppRow]) {
        var rows = Array(groups.values)
        for i in rows.indices {
            if let t = tabs[rows[i].name] {
                for (n, tab) in t.prefix(40).enumerated() {
                    rows[i].subs.append(SubRow(id: "tab\(rows[i].name)\(n)", label: tab.title.isEmpty ? tab.host : tab.title, caption: tab.host, kind: 4, cpu: -1, memMB: -1, pids: []))
                }
            }
            for j in rows[i].subs.indices {
                rows[i].subs[j].gpu = rows[i].subs[j].pids.reduce(0) { $0 + (gpuByPid[$1] ?? 0) }
                rows[i].subs[j].gpuTime = rows[i].subs[j].pids.reduce(0) { $0 + (gpuTimeByPid[$1] ?? 0) }
            }
            rows[i].gpu = rows[i].subs.reduce(0) { $0 + $1.gpu }
            rows[i].gpuTime = rows[i].subs.reduce(0) { $0 + $1.gpuTime }
            rows[i].subs = Monitor.collapse(rows[i].subs)
            if let b = rows[i].bundlePath {
                if let d = diskCache[b] { rows[i].diskMB = d } else { measure(b) }
            }
        }
        self.rows = rows
    }

    private func measure(_ bundle: String) {
        guard !pendingDisk.contains(bundle) else { return }
        pendingDisk.insert(bundle)
        DispatchQueue.global(qos: .background).async {
            let s = Monitor.run("/usr/bin/du", ["-sk", bundle])
            let kb = Double(s.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") ?? 0
            DispatchQueue.main.async { MainActor.assumeIsolated { self.diskCache[bundle] = kb / 1024 } }
        }
    }

    func quit(app row: AppRow, force: Bool) {
        let running = NSWorkspace.shared.runningApplications.filter { row.pids.contains($0.processIdentifier) && $0.activationPolicy == .regular }
        if !running.isEmpty {
            for a in running { if force { _ = a.forceTerminate() } else { _ = a.terminate() } }
        } else {
            row.pids.forEach { kill($0, force ? SIGKILL : SIGTERM) }
        }
        later()
    }

    func quit(pids: [Int32], force: Bool) { pids.forEach { kill($0, force ? SIGKILL : SIGTERM) }; later() }
    private func later() { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshProcesses() } }
}

// MARK: - UI

enum SortKey: String, CaseIterable { case cpu = "CPU", ram = "RAM", disk = "Disk", gpu = "GPU" }

func solid(_ alpha: CGFloat) -> Color {
    Color(nsColor: NSColor(name: nil) { a in
        let dark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
    })
}
let ink = solid(1)
let inkSoft = solid(0.88)

func rate(_ bps: Double) -> String {
    if bps >= 1e9 { return String(format: "%.1f GB/s", bps / 1e9) }
    if bps >= 1e6 { return String(format: "%.1f MB/s", bps / 1e6) }
    return String(format: "%.0f KB/s", bps / 1e3)
}

func fmtMB(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb) }

struct Gauge: View {
    let title: String, value: Double, usedColor: Color, amount: String, percent: String
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(ink)
                Spacer()
                Text(amount).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(inkSoft).monospacedDigit()
                Text(percent).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(ink).monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(solid(0.18))
                    Capsule().fill(value > 85 ? Color.red : usedColor).frame(width: max(6, g.size.width * min(max(value, 0), 100) / 100))
                }
            }.frame(height: 6)
        }
    }
}

struct ContentView: View {
    @ObservedObject var m: Monitor
    @State var sort: SortKey = .cpu
    @State var hover: String?
    @State var open: Set<String> = []

    var specLine: String {
        let c = m.perfCores > 0 ? "\(m.cores) cores (\(m.perfCores)P + \(m.effCores)E)" : "\(m.cores) cores"
        return "\(c) · \(Int(m.ramTotalGB.rounded())) GB · \(Int(m.diskTotalGB.rounded())) GB disk"
    }

    // MARK: per-app numbers for the selected tab: (amount, percent)
    func figures(cpu: Double, mem: Double, disk: Double?, gpu: Double, gpuTime: Double) -> (String, String) {
        switch sort {
        case .gpu:
            return (gpuTime >= 60 ? String(format: "%.1f min", gpuTime / 60) : String(format: "%.1f s", gpuTime), String(format: "%.1f%%", gpu))
        case .cpu:
            let cores = cpu / 100
            return (cores >= 10 ? String(format: "%.0f cores", cores) : String(format: "%.2f cores", cores), String(format: "%.1f%%", cpu / Double(m.cores)))
        case .ram:
            return (fmtMB(mem), String(format: "%.1f%%", mem / (m.ramTotalGB * 1024) * 100))
        default:
            guard let d = disk, m.diskTotalGB > 0 else { return ("–", "–") }
            return (fmtMB(d), String(format: "%.1f%%", d * 1_048_576 / (m.diskTotalGB * 1e9) * 100))
        }
    }

    func shown(cpu: Double, mem: Double, gpu: Double) -> Bool {
        switch sort {
        case .gpu: return gpu >= 0.1
        case .cpu: return cpu / Double(m.cores) >= 0.1
        case .ram: return mem >= 10
        default: return true
        }
    }

    func visibleSubs(_ r: AppRow) -> [SubRow] {
        guard sort != .disk else { return [] }
        let measured = r.subs.filter { $0.cpu >= 0 && shown(cpu: $0.cpu, mem: $0.memMB, gpu: $0.gpu) }.sorted {
            switch sort {
            case .ram: return $0.memMB > $1.memMB
            case .gpu: return $0.gpu > $1.gpu
            default: return $0.cpu > $1.cpu
            }
        }
        return measured + (sort == .cpu ? r.subs.filter { $0.cpu < 0 } : [])
    }

    var sorted: [AppRow] {
        m.rows.filter { shown(cpu: $0.cpu, mem: $0.memMB, gpu: $0.gpu) && (sort != .disk || $0.diskMB != nil) }.sorted {
            switch sort {
            case .ram: return $0.memMB > $1.memMB
            case .disk: return ($0.diskMB ?? -1) > ($1.diskMB ?? -1)
            case .gpu: return $0.gpu > $1.gpu
            default: return $0.cpu > $1.cpu
            }
        }.prefix(40).map { $0 }
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").font(.system(size: 28)).foregroundStyle(inkSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.chip).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    Text(specLine).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(inkSoft)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: m.level == 2 ? "exclamationmark.triangle.fill" : (m.heatMax >= 65 ? "thermometer.high" : m.heatMax >= 45 ? "thermometer.medium" : "thermometer.low"))
                        Text(m.heatMax > 0 ? String(format: "%.0f°C", m.heatMax) : "–").monospacedDigit()
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(m.level == 2 ? Color.red : m.level == 1 ? Color.orange : ink)
                    HStack(spacing: 8) {
                        HStack(spacing: 2) { Image(systemName: "arrow.down").foregroundStyle(Color.green); Text(rate(m.netDown)).foregroundStyle(ink) }
                        HStack(spacing: 2) { Image(systemName: "arrow.up").foregroundStyle(Color.red); Text(rate(m.netUp)).foregroundStyle(ink) }
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            if m.level > 0 {
                Text(m.level == 2 ? "Too hot — close heavy apps to cool down" : "Running warm")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(m.level == 2 ? Color.red : Color.orange))
            }
            Divider().opacity(0.6)
            Gauge(title: "CPU", value: m.cpu, usedColor: .blue,
                  amount: String(format: "%.1f / %d cores", m.cpu * Double(m.cores) / 100, m.cores), percent: String(format: "%.0f%%", m.cpu))
            Gauge(title: "Memory", value: m.ram, usedColor: .purple,
                  amount: String(format: "%.1f / %.0f GB", m.ramUsedGB, m.ramTotalGB), percent: String(format: "%.0f%%", m.ram))
            Gauge(title: "Disk", value: m.disk, usedColor: .orange,
                  amount: String(format: "%.0f / %.0f GB", m.diskUsedGB, m.diskTotalGB), percent: String(format: "%.0f%%", m.disk))
            Gauge(title: "GPU", value: m.gpu, usedColor: .teal, amount: m.gpuName, percent: String(format: "%.0f%%", m.gpu))
            Picker("", selection: $sort) { ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch sort {
                    default:
                        ForEach(sorted) { r in
                            appRow(r)
                            if open.contains(r.id) { ForEach(visibleSubs(r).prefix(60)) { subRow($0) } }
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
            .frame(height: 330)
            HStack {
                Spacer()
                Button("Quit CPU") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Color.blue).font(.system(size: 13, weight: .medium, design: .rounded))
            }
        }
        .padding(16).frame(width: 560)
    }

    func appRow(_ r: AppRow) -> some View {
        let expandable = r.subs.count > 1 && !visibleSubs(r).isEmpty
        let f = figures(cpu: r.cpu, mem: r.memMB, disk: r.diskMB, gpu: r.gpu, gpuTime: r.gpuTime)
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: open.contains(r.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(inkSoft).frame(width: 12).opacity(expandable ? 1 : 0)
                Text(r.name).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if expandable { if open.contains(r.id) { open.remove(r.id) } else { open.insert(r.id) } } }
            col(f.0, false, 14, 84)
            col(f.1, true, 14, 62)
            xButton(id: "a\(r.id)", help: "Quit \(r.name) (⌥ to force)") { m.quit(app: r, force: NSEvent.modifierFlags.contains(.option)) }
        }
        .padding(.vertical, 7).padding(.horizontal, 4)
    }

    func subRow(_ s: SubRow) -> some View {
        let f = s.cpu < 0 ? ("–", "–") : figures(cpu: s.cpu, mem: s.memMB, disk: nil, gpu: s.gpu, gpuTime: s.gpuTime)
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.label).font(.system(size: 13, weight: s.kind == 0 ? .semibold : .medium, design: .rounded)).foregroundStyle(s.kind == 2 ? inkSoft : ink).lineLimit(1)
                if !s.caption.isEmpty { Text(s.caption).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(inkSoft).lineLimit(1) }
            }
            .help(s.pids.map(String.init).joined(separator: ", "))
            Spacer(minLength: 4)
            col(f.0, false, 13, 84)
            col(f.1, true, 13, 62)
            xButton(id: s.id, help: "Quit (⌥ to force)") { m.quit(pids: s.pids, force: NSEvent.modifierFlags.contains(.option)) }
                .opacity(s.pids.isEmpty ? 0 : 1).disabled(s.pids.isEmpty)
        }
        .padding(.vertical, 4).padding(.leading, 22).padding(.trailing, 4)
        .background(solid(0.07))
    }

    func xButton(id: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                .foregroundStyle(hover == id ? Color.red : inkSoft)
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 ? id : nil }
    }

    func col(_ s: String, _ strong: Bool, _ size: CGFloat, _ w: CGFloat) -> some View {
        Text(s).font(.system(size: size - 1, weight: strong ? .bold : .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(strong ? ink : inkSoft).frame(width: w, alignment: .trailing)
    }
}

// MARK: - App

@MainActor
final class Delegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let monitor = Monitor()
    var item: NSStatusItem!
    let menu = NSMenu()
    var alerted = false

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let host = NSHostingView(rootView: ContentView(m: monitor))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: host.fittingSize.height)
        let mi = NSMenuItem(); mi.view = host
        menu.addItem(mi)
        menu.delegate = self
        item.menu = menu
        if let img = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "CPU") {
            img.isTemplate = true
            item.button?.image = img
            item.button?.imagePosition = .imageLeading
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        monitor.onChange = { [weak self] in self?.updateTitle() }
        monitor.start()
    }

    func updateTitle() {
        let f = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let hot = monitor.level == 2
        item.button?.attributedTitle = NSAttributedString(string: String(format: " %2.0f%%", monitor.cpu),
                                                          attributes: [.font: f, .foregroundColor: hot ? NSColor.systemRed : NSColor.labelColor])
        if hot {
            if !alerted { alerted = true; notifyHot() }
        } else if monitor.heatMax < Monitor.warm - 5 { alerted = false }
    }

    func notifyHot() {
        let c = UNMutableNotificationContent()
        c.title = "Your Mac is running hot"
        c.body = String(format: "CPU is at %.0f°C (thermal pressure: %@). Close heavy apps to cool down.", monitor.heatMax, monitor.thermalState)
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hot", content: c, trigger: nil))
    }

    func menuWillOpen(_ menu: NSMenu) { monitor.detailed = true; monitor.refreshProcesses(); monitor.refreshTabs() }
    func menuDidClose(_ menu: NSMenu) { monitor.detailed = false }
}

let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

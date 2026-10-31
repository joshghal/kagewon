import Foundation
import Darwin

var networksetup = "/usr/sbin/networksetup" // a variable only so the tests can point it at a stand-in

private final class Collected: @unchecked Sendable { var data = Data() }

/// Runs a program and returns its exit status and output. A program that does not finish within `timeout` seconds is stopped
/// and reported as a failure (status -2), so one stuck command can never freeze the app.
@discardableResult
func shell(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    do { try p.run() } catch { return (-1, "\(error)") }

    let collected = Collected()
    let finishedReading = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
        finishedReading.signal()
    }

    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        p.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
    }
    let readAll = finishedReading.wait(timeout: .now() + 2) == .success
    if timedOut { return (-2, "\((path as NSString).lastPathComponent) timed out after \(Int(timeout)) seconds") }
    let text = readAll ? String(decoding: collected.data, as: UTF8.self) : ""
    return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// True when a networksetup answer is a real answer: it exited normally and printed no error line.
/// networksetup often reports a failure only in its text ("** Error: ..."), with a normal exit status.
func answerOK(status: Int32, output: String) -> Bool {
    if status != 0 { return false }
    return !output.split(separator: "\n").contains {
        $0.hasPrefix("** Error") || $0.hasPrefix("Error:") || $0.contains("is not a recognized network service")
    }
}

/// networksetup (or its stand-in) with the answer checked, so a failure is never mistaken for an empty or "off" answer.
private func nsRun(_ args: [String]) -> (ok: Bool, output: String) {
    let r = shell(networksetup, args)
    return (answerOK(status: r.status, output: r.output), r.output)
}

/// Creates a file that only this user can read, in one step: the private mode is given when the file is made,
/// so there is no moment at which it can be read by others. Fails if the file already exists.
@discardableResult
func createPrivateFile(atPath path: String, contents: Data = Data()) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return writeAll(fd, contents)
}

/// Appends to a file that only this user can read, creating it with that mode if it is missing.
/// When the file would grow past `maxBytes` it is emptied first and starts again with a note, so a long session cannot fill the disk.
@discardableResult
func appendPrivate(_ data: Data, toPath path: String, maxBytes: Int = 2_000_000) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var info = stat()
    if fstat(fd, &info) == 0, Int(info.st_size) + data.count > maxBytes, ftruncate(fd, 0) == 0 {
        _ = writeAll(fd, Data("(the earlier part of this log was removed because it reached \(maxBytes / 1_000_000) MB)\n".utf8))
    }
    return writeAll(fd, data)
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
        while offset < buffer.count {
            let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n < 0 { if errno == EINTR { continue }; return false }
            offset += n
        }
        return true
    }
}

/// A sticky time for display: "30 s", "5 min" or "1 min 30 s". Minutes are never turned into hours ("90 min").
func formatDuration(seconds: Int) -> String {
    let m = seconds / 60, s = seconds % 60
    if m == 0 { return "\(s) s" }
    return s == 0 ? "\(m) min" : "\(m) min \(s) s"
}

/// The proxy port from config.json, used before the helper is running. Anything out of range falls back to the default.
/// A port written as text ("8888") is accepted, because the helper accepts it too.
func readConfigPort(_ dir: String) -> Int {
    guard let data = FileManager.default.contents(atPath: dir + "/config.json"),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 8888 }
    let port: Int?
    switch obj["port"] {
    case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
        port = n.doubleValue == n.doubleValue.rounded() ? n.intValue : nil
    case let s as String:
        port = Int(s.trimmingCharacters(in: .whitespaces))
    default:
        port = nil
    }
    guard let p = port, (1024...65535).contains(p) else { return 8888 }
    return p
}

/// The macOS network services (Wi-Fi, Ethernet, a USB hotspot...). Disabled ones are left out.
/// Nil means the list could not be read, which is not the same as having no services.
func listNetworkServicesChecked() -> [String]? {
    let r = shell(networksetup, ["-listallnetworkservices"])
    guard answerOK(status: r.status, output: r.output) else { return nil }
    return r.output
        .split(separator: "\n")
        .dropFirst() // "An asterisk (*) denotes that a network service is disabled."
        .map(String.init)
        .filter { !$0.hasPrefix("*") && !$0.isEmpty }
}

func listNetworkServices() -> [String] { listNetworkServicesChecked() ?? [] }

// MARK: - Recognising our own helper

/// How long a process has been running, as `ps -o etime=` prints it: "05:07", "1:02:03" or "2-03:04:05" (days-hours:minutes:seconds).
/// Unlike the start date, which `ps` writes in the order and language of the Mac's region, this looks the same everywhere.
func parseElapsed(_ text: String) -> TimeInterval? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var days = 0.0
    var rest = t
    if let dash = t.firstIndex(of: "-") {
        guard let d = Double(t[..<dash]), d >= 0 else { return nil }
        days = d
        rest = String(t[t.index(after: dash)...])
    }
    let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
    guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
    let n = parts.map { $0! }
    let seconds = n.count == 3 ? n[0] * 3600 + n[1] * 60 + n[2] : n[0] * 60 + n[1]
    return days * 86400 + seconds
}

/// True if a process is a node binary running this folder's proxy.mjs. A pid that was reused by some other program
/// (an editor with the file open, for example) must never be mistaken for the helper.
func isOurHelper(exe: String, command: String, proxyDir: String) -> Bool {
    (exe == "node" || exe.hasSuffix("/node")) && command.hasSuffix(" " + proxyDir + "/proxy.mjs")
}

// MARK: - Reading networksetup answers

/// The "Key: value" lines of a networksetup answer, split at the first colon so a URL value stays whole.
func parseFields(_ text: String) -> [String: String] {
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if fields[key] == nil { fields[key] = value }
    }
    return fields
}

/// True when a `-getwebproxy` or `-getsecurewebproxy` answer is switched on and names exactly 127.0.0.1 and this port.
/// The fields are compared whole: port 3000 must never match 30000, nor "127.0.0.10" match "127.0.0.1".
func answerPoints(_ answer: String, port: Int) -> Bool {
    let f = parseFields(answer)
    return f["Enabled"] == "Yes" && f["Server"] == "127.0.0.1" && Int(f["Port"] ?? "") == port
}

// MARK: - macOS system proxy

/// What Kagewon found on a network before it changed anything, so that it can put it back: the automatic proxy settings,
/// which can route traffic around a manual proxy and are switched off while Kagewon is on, and the bypass entries that
/// Kagewon added (and so must remove again, leaving the ones the user had).
struct AutoConfig: Codable, Equatable {
    var pacURL: String?
    var pacEnabled: Bool
    var discovery: Bool
    var addedBypass: [String]

    init(pacURL: String?, pacEnabled: Bool, discovery: Bool, addedBypass: [String] = []) {
        self.pacURL = pacURL
        self.pacEnabled = pacEnabled
        self.discovery = discovery
        self.addedBypass = addedBypass
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pacURL = try c.decodeIfPresent(String.self, forKey: .pacURL)
        pacEnabled = try c.decode(Bool.self, forKey: .pacEnabled)
        discovery = try c.decode(Bool.self, forKey: .discovery)
        addedBypass = try c.decodeIfPresent([String].self, forKey: .addedBypass) ?? [] // a record from an older version has none
    }

    static func parse(pacAnswer: String, discoveryAnswer: String) -> AutoConfig {
        let pac = parseFields(pacAnswer)
        let url = pac["URL"]
        return AutoConfig(pacURL: (url == nil || url == "(null)" || url == "") ? nil : url,
                          pacEnabled: pac["Enabled"] == "Yes",
                          discovery: parseFields(discoveryAnswer)["Auto Proxy Discovery"] == "On")
    }
}

/// What was changed, written to disk before the first change so that a crash or force quit can be undone at the next launch,
/// even if the port was changed in Settings in between. It holds network names and, if you use one, your PAC address:
/// it is kept next to config.json with the same private permissions and is not published.
struct ProxyRecord: Codable, Equatable {
    var port: Int
    var services: [String: AutoConfig]
}

/// A saved PAC address is only put back if it is an ordinary one: a hand-edited record must not be able to set anything else.
func isSafePACURL(_ text: String) -> Bool {
    guard let u = URL(string: text), let scheme = u.scheme?.lowercased() else { return false }
    return ["http", "https", "ftp", "file"].contains(scheme)
}

/// Every change to the Mac's network settings goes through this one queue, so turning on, turning off, quitting and the
/// background checks never run at the same time. `closeForQuit` makes later changes fail, so nothing is switched on while the app exits.
private let networkQueue = DispatchQueue(label: "app.kagewon.network")
private var networkClosed = false

/// Points every active network at the local proxy, so a second network (Ethernet, a hotspot) cannot bypass it.
/// Turning it off only touches networks that still point at *our* port, so a proxy you set yourself is left alone.
/// Every networksetup answer is checked. A network that cannot be read is "unknown", never "off": nothing is changed
/// without a recovery record on disk, and turning off reports whether it could be confirmed.
struct SystemProxy {
    /// Addresses that must never reach a provider: this Mac and the local network. The helper refuses the same ones
    /// (it reports its list in /api/status, and the app uses that when it is there).
    static let defaultBypass = [
        "localhost", "127.0.0.0/8", "0.0.0.0/8", "169.254/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "100.64.0.0/10", "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255",
        "*.local", "*.localhost", "*.lan", "*.internal", "*.home.arpa", "*.localdomain",
        "*.home", "*.corp", "*.box", "*.intranet", "*.private", "*.test", "*.invalid",
    ]

    let port: Int
    /// For tests: act on these networks only, instead of every active one.
    var servicesOverride: [String]? = nil
    /// Where the record of what was changed is kept. Without it nothing is written (tests).
    var recordPath: String? = nil
    var bypass: [String] = SystemProxy.defaultBypass

    /// After this, `enable` and `apply` refuse to change anything. Waits for a change that is already running.
    static func closeForQuit() { networkQueue.sync { networkClosed = true } }

    /// Switches the proxy on for every active network. If anything fails, what was already switched on is switched off again.
    func enable() -> (error: String?, applied: [String]) {
        networkQueue.sync {
            guard let all = servicesOverride ?? listNetworkServicesChecked() else {
                return ("Could not read the list of network services, so nothing was changed.", [])
            }
            return applyLocked(to: all)
        }
    }

    /// Switches the proxy on for the given networks, for example one that appeared after the proxy was turned on.
    func apply(to targets: [String]) -> (error: String?, applied: [String]) {
        networkQueue.sync { applyLocked(to: targets) }
    }

    /// Switches the proxy off where it still points at us, puts back the automatic settings that were switched off, and removes
    /// the bypass entries that were added. Returns true only when it could be confirmed that nothing points at us any more;
    /// otherwise the recovery record is kept so that a later try can finish the job.
    @discardableResult
    func disable() -> Bool { networkQueue.sync { disableLocked() } }

    /// Like `disable`, queued right now and finished in the background. Because it is queued at once, nothing queued later
    /// (a turn-on, for example) can run before it.
    func disableInBackground(completion: @escaping @Sendable (Bool) -> Void) {
        networkQueue.async { completion(disableLocked()) }
    }

    /// True if any network is still pointed at our local port (or at the port of an earlier, unfinished run).
    var pointsAtUs: Bool {
        networkQueue.sync {
            let ports = knownPorts(loadRecord())
            return (servicesOverride ?? listNetworkServicesChecked() ?? []).contains { pointsLocked($0, ports) == true }
        }
    }

    /// True unless BOTH halves stopped pointing at us or an automatic setting has been switched back on, which is how a VPN client
    /// or System Settings can send traffic around us. A network that cannot be read is not reported as changed.
    func fullyPoints(at service: String) -> Bool {
        networkQueue.sync {
            for verb in ["-getwebproxy", "-getsecurewebproxy"] {
                let r = nsRun([verb, service])
                if r.ok && !answerPoints(r.output, port: port) { return false }
            }
            guard let auto = readAuto(service) else { return true }
            return !auto.pacEnabled && !auto.discovery
        }
    }

    /// True if either half points at us.
    func points(at service: String) -> Bool { networkQueue.sync { pointsLocked(service, [port]) == true } }

    // MARK: Everything below runs on networkQueue

    private func knownPorts(_ record: ProxyRecord?) -> Set<Int> {
        var ports: Set<Int> = [port]
        if let r = record { ports.insert(r.port) }
        return ports
    }

    /// Whether either half of the manual proxy points at one of the ports. Nil when it could not be read and nothing else says yes.
    private func pointsLocked(_ service: String, _ ports: Set<Int>) -> Bool? {
        var unknown = false
        for verb in ["-getwebproxy", "-getsecurewebproxy"] {
            let r = nsRun([verb, service])
            if !r.ok { unknown = true; continue }
            if ports.contains(where: { answerPoints(r.output, port: $0) }) { return true }
        }
        return unknown ? nil : false
    }

    private func readAuto(_ service: String) -> AutoConfig? {
        let pac = nsRun(["-getautoproxyurl", service])
        let discovery = nsRun(["-getproxyautodiscovery", service])
        guard pac.ok, discovery.ok else { return nil }
        return AutoConfig.parse(pacAnswer: pac.output, discoveryAnswer: discovery.output)
    }

    private func readBypass(_ service: String) -> [String]? {
        let r = nsRun(["-getproxybypassdomains", service])
        guard r.ok else { return nil }
        return r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("There aren") }
    }

    private func writeBypass(_ service: String, _ list: [String]) -> Bool {
        nsRun(["-setproxybypassdomains", service] + (list.isEmpty ? ["Empty"] : list)).ok
    }

    private func applyLocked(to targets: [String]) -> (error: String?, applied: [String]) {
        if networkClosed { return ("Kagewon is quitting", []) }
        if targets.isEmpty { return ("No network service was found", []) }

        var record = loadRecord() ?? ProxyRecord(port: port, services: [:])
        if record.port != port { // left over from a run that used another port: undo it first
            guard disableLocked() else { return ("Settings left by an earlier run could not be undone, so nothing was changed.", []) }
            record = ProxyRecord(port: port, services: [:])
        }

        // Read everything first. A failed read means "unknown", never "off" or "empty", and nothing has been changed yet,
        // so a failed read can never lead to the user's own bypass list being overwritten.
        var bypassNow: [String: [String]] = [:]
        var missing: [String: [String]] = [:]
        for service in targets {
            guard let current = readBypass(service) else {
                return ("Could not read the proxy bypass list of \(service), so nothing was changed.", [])
            }
            bypassNow[service] = current
            missing[service] = bypass.filter { !current.contains($0) }
            if record.services[service] == nil { // a network that is already ours keeps its record: reading now would only see what we changed
                guard let auto = readAuto(service) else {
                    return ("Could not read the automatic proxy settings of \(service), so nothing was changed.", [])
                }
                record.services[service] = auto
            }
            let known = record.services[service]?.addedBypass ?? []
            record.services[service]?.addedBypass = known + (missing[service] ?? []).filter { !known.contains($0) }
        }
        // The record is written before the first change. Without it a crash could not be undone, so there is no change without it.
        guard saveRecord(record) else {
            return ("Could not write the recovery file, so nothing was changed.", [])
        }

        var done: [String] = []
        func failure(_ service: String, _ detail: String) -> (error: String?, applied: [String]) {
            var restored = true
            for s in [service] + done {
                if restoreService(s, record.services[s], onlyIfUntouched: false) { record.services[s] = nil } else { restored = false }
            }
            if record.services.isEmpty { removeRecord() } else { saveRecord(record) }
            let base = detail.isEmpty ? "networksetup failed for \(service)" : detail
            return (restored ? base : base + " The earlier settings could not be fully restored.", [])
        }
        for service in targets {
            for verb in ["-setwebproxy", "-setsecurewebproxy"] {
                let r = nsRun([verb, service, "127.0.0.1", "\(port)"])
                if !r.ok { return failure(service, r.output) }
            }
            if !nsRun(["-setautoproxystate", service, "off"]).ok || !nsRun(["-setproxyautodiscovery", service, "off"]).ok {
                return failure(service, "Could not switch off the automatic proxy settings of \(service).")
            }
            if let add = missing[service], !add.isEmpty, !writeBypass(service, (bypassNow[service] ?? []) + add) {
                return failure(service, "Could not set the proxy bypass list of \(service).")
            }
            done.append(service)
        }
        return (nil, done)
    }

    private func disableLocked() -> Bool {
        let record = loadRecord()
        let ports = knownPorts(record)
        guard let current = servicesOverride ?? listNetworkServicesChecked() else { return false } // unknown, so keep the record
        var ok = true
        var changed: [String] = [] // only what was switched off here needs a second look; the rest was read as not pointing at us
        for service in current {
            // The manual proxy: each half is switched off only where it points at us.
            for (get, set) in [("-getwebproxy", "-setwebproxystate"), ("-getsecurewebproxy", "-setsecurewebproxystate")] {
                let r = nsRun([get, service])
                if !r.ok { ok = false; continue }
                if ports.contains(where: { answerPoints(r.output, port: $0) }) {
                    changed.append(service)
                    if !nsRun([set, service, "off"]).ok { ok = false }
                }
            }
            // The automatic settings and the bypass entries come back from the record, whether or not the manual proxy still
            // pointed at us: something else may have switched it off first, or the helper's watchdog did after a crash.
            if let saved = record?.services[service] {
                if !restoreAuto(service, saved, onlyIfUntouched: true) { ok = false }
                if !removeBypass(service, saved.addedBypass) { ok = false }
            }
        }
        // Only a second look can say that it worked. Keep the record unless nothing points at us any more.
        for service in Set(changed) where pointsLocked(service, ports) != false { ok = false }
        if ok { removeRecord() }
        return ok
    }

    /// Puts one network back as it was: the manual proxy off, the automatic settings as saved, the added bypass entries removed.
    private func restoreService(_ service: String, _ saved: AutoConfig?, onlyIfUntouched: Bool) -> Bool {
        var ok = nsRun(["-setwebproxystate", service, "off"]).ok
        ok = nsRun(["-setsecurewebproxystate", service, "off"]).ok && ok
        if let saved {
            ok = restoreAuto(service, saved, onlyIfUntouched: onlyIfUntouched) && ok
            ok = removeBypass(service, saved.addedBypass) && ok
        }
        return ok
    }

    /// Puts the automatic proxy settings back as saved. With `onlyIfUntouched`, only if they are still as Kagewon left them
    /// (off): if the user or another program changed them meanwhile, that change is theirs and is left alone.
    private func restoreAuto(_ service: String, _ saved: AutoConfig, onlyIfUntouched: Bool) -> Bool {
        if saved.pacURL == nil && !saved.pacEnabled && !saved.discovery { return true } // nothing was switched off
        guard let now = readAuto(service) else { return false }
        if onlyIfUntouched && (now.pacEnabled || now.discovery) { return true }
        var ok = true
        var urlUsable = saved.pacURL == nil
        if let url = saved.pacURL, isSafePACURL(url) {
            ok = nsRun(["-setautoproxyurl", service, url]).ok // also switches it on
            urlUsable = true
        }
        ok = nsRun(["-setautoproxystate", service, saved.pacEnabled && urlUsable ? "on" : "off"]).ok && ok
        ok = nsRun(["-setproxyautodiscovery", service, saved.discovery ? "on" : "off"]).ok && ok
        return ok
    }

    /// Removes exactly the bypass entries that Kagewon added, and keeps everything else in the list.
    private func removeBypass(_ service: String, _ added: [String]) -> Bool {
        if added.isEmpty { return true }
        guard let current = readBypass(service) else { return false }
        let remaining = current.filter { !added.contains($0) }
        if remaining.count == current.count { return true }
        return writeBypass(service, remaining)
    }

    // MARK: The record on disk

    private func loadRecord() -> ProxyRecord? {
        guard let path = recordPath, let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ProxyRecord.self, from: data)
    }

    /// Writes the record in one private step (never created readable and then restricted). Without a path there is nothing to write.
    @discardableResult
    private func saveRecord(_ record: ProxyRecord) -> Bool {
        guard let path = recordPath else { return true }
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let tmp = path + ".tmp"
        unlink(tmp)
        guard createPrivateFile(atPath: tmp, contents: data) else { return false }
        guard rename(tmp, path) == 0 else { unlink(tmp); return false }
        return true
    }

    private func removeRecord() {
        if let path = recordPath { try? FileManager.default.removeItem(atPath: path) }
    }
}

// MARK: - Holding the port for the kill switch

/// Listens on the proxy port and drops every connection. With the kill switch on, the Mac stays pointed at the proxy
/// after the helper has stopped: apps get no connection, and no other program can take the port over and receive the
/// traffic that is still being sent to it.
final class PortHolder {
    private var source: DispatchSourceRead?
    private var closed: DispatchSemaphore?

    var isHolding: Bool { source != nil }

    /// Returns false if the port could not be taken (another program already listens there).
    @discardableResult
    func hold(port: Int) -> Bool {
        release()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard bound, listen(fd, 16) == 0 else { close(fd); return false }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let done = DispatchSemaphore(value: 0)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "app.kagewon.holder"))
        src.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                close(client)
            }
        }
        src.setCancelHandler { close(fd); done.signal() }
        src.resume()
        source = src
        closed = done
        return true
    }

    /// Gives the port back. It returns only once the port is free, so the helper can bind it right afterwards.
    func release() {
        guard let src = source else { return }
        source = nil
        src.cancel()
        closed?.wait()
        closed = nil
    }
}

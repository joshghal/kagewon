import Foundation
import Darwin

var networksetup = "/usr/sbin/networksetup" // a variable only so the tests can point it at a stand-in

@discardableResult
func shell(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
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
func listNetworkServices() -> [String] {
    shell(networksetup, ["-listallnetworkservices"]).output
        .split(separator: "\n")
        .dropFirst() // "An asterisk (*) denotes that a network service is disabled."
        .map(String.init)
        .filter { !$0.hasPrefix("*") && !$0.isEmpty }
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

/// The automatic proxy settings of a network, which can route traffic around a manual proxy.
/// They are switched off while Kagewon is on and put back exactly as they were when it is turned off.
struct AutoConfig: Codable, Equatable {
    var pacURL: String?
    var pacEnabled: Bool
    var discovery: Bool

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

/// Every change to the Mac's network settings goes through this one queue, so turning on, turning off, quitting and the
/// background checks never run at the same time. `closeForQuit` makes later changes fail, so nothing is switched on while the app exits.
private let networkQueue = DispatchQueue(label: "app.kagewon.network")
private var networkClosed = false

/// Points every active network at the local proxy, so a second network (Ethernet, a hotspot) cannot bypass it.
/// Turning it off only touches networks that still point at *our* port, so a proxy you set yourself is left alone.
struct SystemProxy {
    let port: Int
    /// For tests: act on these networks only, instead of every active one.
    var servicesOverride: [String]? = nil
    /// Where the record of what was changed is kept. Without it nothing is written (tests).
    var recordPath: String? = nil

    private var services: [String] { servicesOverride ?? listNetworkServices() }

    /// After this, `enable` and `apply` refuse to change anything. Waits for a change that is already running.
    static func closeForQuit() { networkQueue.sync { networkClosed = true } }

    /// Switches the proxy on for every active network. If anything fails, what was already switched on is switched off again.
    func enable() -> (error: String?, applied: [String]) {
        networkQueue.sync { applyLocked(to: services) }
    }

    /// Switches the proxy on for the given networks, for example one that appeared after the proxy was turned on.
    func apply(to targets: [String]) -> (error: String?, applied: [String]) {
        networkQueue.sync { applyLocked(to: targets) }
    }

    /// Switches the proxy off where it still points at us and restores the automatic settings that were switched off.
    func disable() { networkQueue.sync { disableLocked() } }

    /// True if any network is still pointed at our local port (or at the port of an earlier, unfinished run).
    var pointsAtUs: Bool {
        networkQueue.sync {
            let ports = knownPorts(loadRecord())
            return services.contains { s in ports.contains { pointsLocked(s, $0) } }
        }
    }

    /// True only if BOTH the web and the secure web proxy still point at us and no automatic setting has been
    /// switched back on, which is how a VPN client or System Settings can send traffic around us.
    func fullyPoints(at service: String) -> Bool {
        networkQueue.sync {
            let both = ["-getwebproxy", "-getsecurewebproxy"].allSatisfy { answerPoints(shell(networksetup, [$0, service]).output, port: port) }
            guard both else { return false }
            let auto = readAuto(service)
            return !auto.pacEnabled && !auto.discovery
        }
    }

    /// True if either half points at us.
    func points(at service: String) -> Bool { networkQueue.sync { pointsLocked(service, port) } }

    // MARK: Everything below runs on networkQueue

    private func knownPorts(_ record: ProxyRecord?) -> Set<Int> {
        var ports: Set<Int> = [port]
        if let r = record { ports.insert(r.port) }
        return ports
    }

    private func pointsLocked(_ service: String, _ port: Int) -> Bool {
        ["-getwebproxy", "-getsecurewebproxy"].contains { answerPoints(shell(networksetup, [$0, service]).output, port: port) }
    }

    private func readAuto(_ service: String) -> AutoConfig {
        AutoConfig.parse(pacAnswer: shell(networksetup, ["-getautoproxyurl", service]).output,
                         discoveryAnswer: shell(networksetup, ["-getproxyautodiscovery", service]).output)
    }

    private func applyLocked(to targets: [String]) -> (error: String?, applied: [String]) {
        if networkClosed { return ("Kagewon is quitting", []) }
        if targets.isEmpty { return ("No network service was found", []) }

        var record = loadRecord() ?? ProxyRecord(port: port, services: [:])
        if record.port != port { // left over from a run that used another port: undo it first
            disableLocked()
            record = ProxyRecord(port: port, services: [:])
        }
        // Remember the automatic settings first, and write them down before the first change.
        // A network that is already ours keeps the record it has: reading it now would only see what we changed.
        for service in targets where record.services[service] == nil { record.services[service] = readAuto(service) }
        saveRecord(record)

        var done: [String] = []
        func rollBack(_ extra: String) {
            for service in [extra] + done { restore(service, record.services[service]); record.services[service] = nil }
            if record.services.isEmpty { removeRecord() } else { saveRecord(record) }
        }
        for service in targets {
            for verb in ["-setwebproxy", "-setsecurewebproxy"] {
                let r = shell(networksetup, [verb, service, "127.0.0.1", "\(port)"])
                if r.status != 0 || r.output.contains("Error") {
                    rollBack(service)
                    return (r.output.isEmpty ? "networksetup failed for \(service)" : r.output, [])
                }
            }
            shell(networksetup, ["-setautoproxystate", service, "off"])
            shell(networksetup, ["-setproxyautodiscovery", service, "off"])
            ensureBypass(service)
            done.append(service)
        }
        return (nil, done)
    }

    private func disableLocked() {
        let record = loadRecord()
        let ports = knownPorts(record)
        let current = services
        for service in current where ports.contains(where: { pointsLocked(service, $0) }) {
            restore(service, record?.services[service])
        }
        // Keep the record while anything still points at us, so a later try can finish the job.
        if !current.contains(where: { s in ports.contains { pointsLocked(s, $0) } }) { removeRecord() }
    }

    /// Switches the manual proxy off and puts the automatic settings back as they were (nothing is touched without a record).
    private func restore(_ service: String, _ saved: AutoConfig?) {
        shell(networksetup, ["-setwebproxystate", service, "off"])
        shell(networksetup, ["-setsecurewebproxystate", service, "off"])
        guard let saved else { return }
        if let url = saved.pacURL { shell(networksetup, ["-setautoproxyurl", service, url]) } // also switches it on
        shell(networksetup, ["-setautoproxystate", service, saved.pacEnabled ? "on" : "off"])
        shell(networksetup, ["-setproxyautodiscovery", service, saved.discovery ? "on" : "off"])
    }

    /// Keep this Mac and the local network off the proxy: a provider could never reach them, and would see the requests.
    private func ensureBypass(_ service: String) {
        let wanted = ["localhost", "127.0.0.1", "*.local", "169.254/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                      "100.64.0.0/10", "*.lan", "*.internal", "*.home.arpa", "*.localdomain"]
        let current = shell(networksetup, ["-getproxybypassdomains", service]).output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("There aren") }
        let missing = wanted.filter { !current.contains($0) }
        if !missing.isEmpty {
            shell(networksetup, ["-setproxybypassdomains", service] + current + missing)
        }
    }

    // MARK: The record on disk

    private func loadRecord() -> ProxyRecord? {
        guard let path = recordPath, let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ProxyRecord.self, from: data)
    }

    private func saveRecord(_ record: ProxyRecord) {
        guard let path = recordPath, let data = try? JSONEncoder().encode(record) else { return }
        let tmp = path + ".tmp"
        try? FileManager.default.removeItem(atPath: tmp)
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        rename(tmp, path)
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

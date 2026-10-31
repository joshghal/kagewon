import Foundation

let networksetup = "/usr/sbin/networksetup"

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
func readConfigPort(_ dir: String) -> Int {
    guard let data = FileManager.default.contents(atPath: dir + "/config.json"),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = obj["port"] as? Int, (1024...65535).contains(port) else { return 8888 }
    return port
}

/// The macOS network services (Wi-Fi, Ethernet, a USB hotspot...). Disabled ones are left out.
func listNetworkServices() -> [String] {
    shell(networksetup, ["-listallnetworkservices"]).output
        .split(separator: "\n")
        .dropFirst() // "An asterisk (*) denotes that a network service is disabled."
        .map(String.init)
        .filter { !$0.hasPrefix("*") && !$0.isEmpty }
}

// MARK: - macOS system proxy

/// Points every active network at the local proxy, so a second network (Ethernet, a hotspot) cannot bypass it.
/// Turning it off only touches networks that still point at *our* port, so a proxy you set yourself is left alone.
struct SystemProxy {
    let port: Int
    /// For tests: act on these networks only, instead of every active one.
    var servicesOverride: [String]? = nil

    private var services: [String] { servicesOverride ?? listNetworkServices() }

    /// Switches the proxy on for every active network. If anything fails, what was already switched on is switched off again.
    func enable() -> (error: String?, applied: [String]) { apply(to: services) }

    /// Switches the proxy on for the given networks, for example one that appeared after the proxy was turned on.
    func apply(to targets: [String]) -> (error: String?, applied: [String]) {
        if targets.isEmpty { return ("No network service was found", []) }
        var done: [String] = []
        for service in targets {
            for verb in ["-setwebproxy", "-setsecurewebproxy"] {
                let r = shell(networksetup, [verb, service, "127.0.0.1", "\(port)"])
                if r.status != 0 || r.output.contains("Error") {
                    off(service)
                    done.forEach(off)
                    return (r.output.isEmpty ? "networksetup failed for \(service)" : r.output, [])
                }
            }
            ensureBypass(service)
            done.append(service)
        }
        return (nil, done)
    }

    func disable() {
        for service in services where points(at: service) { off(service) }
    }

    /// True if any network is still pointed at our local port.
    var pointsAtUs: Bool { services.contains(where: points) }

    /// True only if BOTH the web and the secure web proxy of this network still point at us (used to notice tampering).
    func fullyPoints(at service: String) -> Bool {
        ["-getwebproxy", "-getsecurewebproxy"].allSatisfy { verb in
            let out = shell(networksetup, [verb, service]).output
            return out.contains("Enabled: Yes") && out.contains("Server: 127.0.0.1") && out.contains("Port: \(port)")
        }
    }

    /// True if either half still points at us (used to find what to switch off).
    func points(at service: String) -> Bool {
        for verb in ["-getwebproxy", "-getsecurewebproxy"] {
            let out = shell(networksetup, [verb, service]).output
            if out.contains("Enabled: Yes") && out.contains("Server: 127.0.0.1") && out.contains("Port: \(port)") { return true }
        }
        return false
    }

    private func off(_ service: String) {
        shell(networksetup, ["-setwebproxystate", service, "off"])
        shell(networksetup, ["-setsecurewebproxystate", service, "off"])
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
}

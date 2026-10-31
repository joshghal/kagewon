import AppKit
import SwiftUI

// MARK: - API types (JSON from the local control API)

struct Empty: Decodable {}
struct ErrorBody: Decodable { var error: String }
struct IPBody: Decodable { var ip: String }

struct APIStatus: Decodable {
    var state: String
    var rotation: String
    var stickyMinutes: Int
    var port: Int
    var listenPort: Int?
    var refreshMinutes: Int
    var verbose: Bool
    var rotateOpenConnections: Bool?
    var killSwitch: Bool?
    var lastError: String?
    var providers: [ProviderInfo]
    var sites: [SiteInfo]
}

struct ProviderInfo: Decodable, Identifiable, Equatable {
    struct Runtime: Decodable, Equatable {
        var status: String
        var error: String?
        var count: Int
        var healthy: Int
        var skipped: Int
    }
    var id: String
    var type: String
    var name: String
    var enabled: Bool
    var weight: Int
    var apiKey: String?
    var countries: [String]?
    var socksPort: Int?
    var exitCountries: [String]?
    var runtime: Runtime
}

struct SiteInfo: Decodable, Identifiable {
    var site: String
    var provider: String
    var proxy: String
    var expiresIn: Int
    var id: String { site }
}

struct LogLine: Decodable, Identifiable {
    var n: Int
    var t: Double
    var level: String
    var msg: String
    var id: Int { n }
}
struct LogResponse: Decodable {
    var lines: [LogLine]
    var next: Int
}

struct TestResult: Decodable {
    var ok: Bool
    var count: Int?
    var ip: String?
    var ms: Int?
    var error: String?
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Phase: Equatable {
    case launching, off, starting, on
    case error(String)
}

enum Tab: String { case home, providers, activity, settings }

enum TestState: Equatable {
    case running
    case done(ok: Bool, text: String)
}

/// What the Add/Edit form edits. Kept in the model so it survives the popover closing, and cleared when the form ends.
struct ProviderDraft {
    var id: String?
    var type = "webshare"
    var name = ""
    var enabled = true
    var weight = 1
    var apiKey = ""
    var countries = ""
    var socksPort = "9250"
    var exitCountries = ""
    /// Masked hint of the stored key, shown as a placeholder while editing.
    var apiKeyHint = ""

    init(type: String) { self.type = type }

    init(from p: ProviderInfo) {
        id = p.id
        type = p.type
        name = p.name
        enabled = p.enabled
        weight = p.weight
        countries = (p.countries ?? []).joined(separator: ", ")
        socksPort = p.socksPort.map(String.init) ?? "9250"
        exitCountries = (p.exitCountries ?? []).joined(separator: ", ")
        apiKeyHint = p.apiKey ?? ""
    }

    func body() -> [String: Any] {
        var b: [String: Any] = ["type": type, "name": name, "enabled": enabled, "weight": weight]
        if let id { b["id"] = id }
        if type == "tor" {
            b["socksPort"] = Int(socksPort) ?? 0
            b["exitCountries"] = exitCountries
        } else {
            b["apiKey"] = apiKey
            b["countries"] = countries
        }
        return b
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    let proxyDir: String
    let controlPort: Int
    private(set) var systemProxy: SystemProxy
    /// What was actually switched on, so turning off always undoes the right port.
    private var activeProxy: SystemProxy?
    /// Set for a second copy of the app that is about to quit: it must not touch the first copy's proxy settings.
    var isDuplicate = false
    /// The networks the proxy was switched on for, so a network that appears later (a hotspot) can be covered too.
    private var activeServices: [String] = []
    private var isQuitting = false
    private var lastKillSwitch = false
    /// Holds the proxy port after the proxy stopped, while the kill switch keeps the Mac offline.
    private let holder = PortHolder()
    /// The previous turn-off, which turning on again must wait for (otherwise its stop request could end the new session).
    private var stopTask: Task<Void, Never>?
    private var tick = 0
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kagewon.log")
    let logQueue = DispatchQueue(label: "log")

    @Published var phase: Phase = .launching
    @Published var status: APIStatus?
    @Published var exitIP: String?
    @Published var ipBusy = false
    @Published var ipCheckedAt: Date?
    /// Set by the app shell while the dashboard is on screen, so the exit IP is only re-checked when someone can see it.
    var popoverOpen = false
    @Published var tab: Tab = .home
    @Published var logLines: [LogLine] = []
    /// Set when traffic from this Mac still arrives with its real IP address although the proxy is on.
    @Published var leakWarning: String?

    @Published var draft = ProviderDraft(type: "webshare")
    @Published var isEditing = false
    @Published var isSaving = false
    @Published var formError: String?
    @Published var tests: [String: TestState] = [:]
    @Published var pendingDelete: String?
    @Published var torGuideOpen = false

    struct SettingsDraft {
        var port = "8888"
        var refreshMinutes = 15
        var verbose = false
        var killSwitch = false
    }
    @Published var settings = SettingsDraft()
    @Published var settingsMessage: String?
    @Published var settingsOK = true

    var activityVisible = false
    private var daemon: Process?
    private var daemonReady = false
    private var startAfterLaunch = false
    private var recentLines: [String] = []
    private var logSince = 0
    private var pollTimer: Timer?
    private var launchTimeout: Task<Void, Never>?
    private let session: URLSession

    var isOn: Bool { phase == .on }
    var isBusy: Bool { phase == .launching || phase == .starting }

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        proxyDir = (info["ProxyDir"] as? String)
            ?? ProcessInfo.processInfo.environment["KAGEWON_DIR"]
            ?? NSHomeDirectory() + "/kagewon"
        controlPort = Int(ProcessInfo.processInfo.environment["CONTROL_PORT"] ?? "") ?? 8889
        systemProxy = SystemProxy(port: readConfigPort(proxyDir), recordPath: proxyDir + "/.system-proxy.json")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:] // the control API is local: never route it through a proxy
        session = URLSession(configuration: cfg)
    }

    // MARK: App lifecycle

    /// A helper that survived a crash of the app. It is found by the pid file it wrote and only stopped
    /// if that pid is still our own helper: pids get reused, so it is never killed by name or pattern alone.
    private func stopStaleHelper() {
        let pidFile = proxyDir + "/.helper.pid"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        let command = shell("/bin/ps", ["-o", "command=", "-p", String(pid)]).output
        if command.hasSuffix(" " + proxyDir + "/proxy.mjs") {
            kill(pid, SIGTERM)
            // It holds the control port until it has stopped Tor (a few seconds at most), so wait for it to be gone.
            for _ in 0..<50 where kill(pid, 0) == 0 { usleep(100_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL); usleep(300_000) }
        }
    }

    func start() {
        // Clean up after a previous crash or force-quit.
        stopStaleHelper()
        systemProxy.disable() // undoes a crashed run, using the record it wrote, and restores the automatic settings
        launchDaemon()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.verifySystemProxy()
                await self?.refreshStatus()
                if self?.activityVisible == true { await self?.refreshLog() }
                if let self, self.isOn, self.popoverOpen, Date().timeIntervalSince(self.ipCheckedAt ?? .distantPast) > 30 {
                    await self.refreshIP() // so the tile shows the IP after a sticky time has run out
                }
            }
        }
    }

    func shutdown() {
        if isDuplicate { return } // the first copy owns the proxy settings and the helper
        isQuitting = true
        pollTimer?.invalidate()
        SystemProxy.closeForQuit() // waits for a change that is already running, and refuses any later one
        disableSystemProxy() // first, so the Mac keeps its internet
        if let p = daemon {
            daemon = nil
            p.terminationHandler = nil
            p.terminate()
            for _ in 0..<50 where p.isRunning { usleep(100_000) } // up to 5 s, so it can stop Tor cleanly
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    func popoverShown() {
        popoverOpen = true
        Task {
            await refreshStatus()
            if isOn, Date().timeIntervalSince(ipCheckedAt ?? .distantPast) > 5 { await refreshIP() }
            if activityVisible { await refreshLog() }
        }
    }

    // MARK: Background service (the Node process)

    private func nodePath() -> String? {
        let fm = FileManager.default
        if let baked = Bundle.main.infoDictionary?["NodePath"] as? String, fm.isExecutableFile(atPath: baked) { return baked }
        for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] where fm.isExecutableFile(atPath: p) { return p }
        let found = shell("/bin/zsh", ["-lc", "command -v node"]).output
        return fm.isExecutableFile(atPath: found) ? found : nil
    }

    func launchDaemon() {
        guard daemon == nil else { return }
        guard let node = nodePath() else { phase = .error("Node.js was not found"); return }
        guard FileManager.default.fileExists(atPath: proxyDir + "/proxy.mjs") else { phase = .error("proxy.mjs not found in \(proxyDir)"); return }

        logQueue.sync {
            try? FileManager.default.removeItem(at: logURL)
            FileManager.default.createFile(atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        recentLines = []
        clearLog() // a new helper numbers its log lines from the start again
        daemonReady = false
        phase = .launching

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [proxyDir + "/proxy.mjs"]
        p.currentDirectoryURL = URL(fileURLWithPath: proxyDir)
        // The helper gets only what it needs, not everything this app inherited (tokens in the login environment, proxy variables...).
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "USER"] { if let v = inherited[key] { env[key] = v } }
        env["AUTOSTART"] = "false"
        env["CONTROL_TOKEN"] = token
        env["CONTROL_PORT"] = String(controlPort)
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.appendLog(data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.handleOutput(text, from: p) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in self?.daemonEnded(proc) }
        }
        do { try p.run() } catch { phase = .error("Could not start: \(error.localizedDescription)"); return }
        daemon = p

        launchTimeout?.cancel()
        launchTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .launching else { return }
            let why = self.recentLines.last ?? "no response"
            self.stopDaemon()
            self.phase = .error("Helper did not start: \(why)")
        }
    }

    private func stopDaemon() {
        if let p = daemon {
            daemon = nil
            p.terminationHandler = nil
            p.terminate()
        }
        daemonReady = false
    }

    private func handleOutput(_ text: String, from p: Process) {
        guard p === daemon else { return }
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            recentLines.append(l)
            if recentLines.count > 10 { recentLines.removeFirst() }
            if l.contains("Control API listening"), !daemonReady { becameReady() }
        }
    }

    private func becameReady() {
        daemonReady = true
        launchTimeout?.cancel()
        if phase == .launching { phase = .off }
        Task { await refreshStatus() }
        if startAfterLaunch {
            startAfterLaunch = false
            turnOn()
        }
    }

    private func daemonEnded(_ p: Process) {
        guard p === daemon else { return }
        daemon = nil
        daemonReady = false
        launchTimeout?.cancel()
        let keepBlocking = proxyLost()
        exitIP = nil
        status = nil
        let reason = p.terminationReason == .uncaughtSignal
            ? "killed (signal \(p.terminationStatus))"
            : (recentLines.last ?? "exit code \(p.terminationStatus)")
        phase = .error(keepBlocking
            ? "Helper stopped (\(reason)). The kill switch is on, so the internet stays blocked until you press Try Again or quit the app."
            : "Helper stopped: \(reason). Your traffic is going direct.")
    }

    nonisolated func appendLog(_ data: Data) {
        logQueue.async {
            if let h = try? FileHandle(forWritingTo: self.logURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: self.logURL.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
    }

    // MARK: API

    func api<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 10) async throws -> T {
        guard let url = URL(string: "http://127.0.0.1:\(controlPort)\(path)") else { throw APIError(message: "Invalid request") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(token, forHTTPHeaderField: "X-Control-Token")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError(message: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func refreshStatus() async {
        guard daemonReady else { return }
        guard let s: APIStatus = try? await api("GET", "/api/status") else { return }
        status = s
        lastKillSwitch = s.killSwitch ?? false
        if phase != .on { systemProxy = SystemProxy(port: s.listenPort ?? s.port, recordPath: systemProxy.recordPath) }
        if phase == .on, s.state != "running" {
            let keepBlocking = proxyLost()
            exitIP = nil
            let why = s.lastError ?? "The proxy stopped unexpectedly"
            phase = .error(keepBlocking ? "\(why). The kill switch is on, so the internet stays blocked until you press Try Again." : why)
        }
    }

    /// The proxy stopped while the Mac was pointed at it. With the kill switch on, the settings stay and this app holds the port,
    /// so the Mac is offline and nothing else can listen there. Otherwise the settings are switched off. Returns true if blocking.
    private func proxyLost() -> Bool {
        if lastKillSwitch, let active = activeProxy {
            holder.hold(port: active.port)
            return true
        }
        disableSystemProxy()
        return false
    }

    /// Every 15 seconds while on: is the Mac still pointed at the proxy? Something else (a VPN client, System Settings)
    /// can switch it off, and then traffic would go direct while this app still says "On".
    private func verifySystemProxy() async {
        tick += 1
        guard phase == .on, tick % 5 == 0, let active = activeProxy else { return }
        let known = activeServices
        let check = await Task.detached { () -> (added: [String], lost: [String]) in
            let current = listNetworkServices()
            return (current.filter { !known.contains($0) }, known.filter { current.contains($0) && !active.fullyPoints(at: $0) })
        }.value
        guard phase == .on else { return }
        if !check.lost.isEmpty {
            exitIP = nil
            phase = .error("The proxy settings for \(check.lost.joined(separator: ", ")) were changed by something else, so that traffic may be going direct. Press Try Again to switch them back on.")
            return
        }
        if !check.added.isEmpty { // a hotspot or Ethernet that appeared after turning on would otherwise stay unprotected
            let result = await Task.detached { active.apply(to: check.added) }.value
            if result.error == nil { activeServices += result.applied }
        }
    }

    private func clearLog() {
        logLines = []
        logSince = 0
    }

    func refreshLog() async {
        guard daemonReady, let r: LogResponse = try? await api("GET", "/api/log?since=\(logSince)") else { return }
        logSince = r.next
        if !r.lines.isEmpty {
            logLines = Array((logLines + r.lines).suffix(200))
        }
    }

    func refreshIP() async {
        guard phase == .on, !ipBusy else { return }
        ipBusy = true
        defer { ipBusy = false; ipCheckedAt = Date() }
        do {
            let r: IPBody = try await api("POST", "/api/ip", timeout: 30)
            exitIP = r.ip
        } catch {
            exitIP = "unavailable"
        }
    }

    // MARK: Power

    func togglePower() {
        switch phase {
        case .off: turnOn()
        case .on: turnOff()
        case .error:
            if daemonReady { turnOn() } else { startAfterLaunch = true; launchDaemon() }
        case .launching, .starting: break
        }
    }

    func turnOn() {
        guard daemonReady else { startAfterLaunch = true; launchDaemon(); return }
        phase = .starting
        leakWarning = nil
        let previousStop = stopTask
        Task {
            await previousStop?.value // a turn-off that is still finishing must be done first
            holder.release() // the helper needs the port that the kill switch was holding
            // The real IP is looked up now, while the proxy is still off, and while the helper loads its providers.
            let direct = Task.detached { await AppModel.lookupIP(viaSystemSettings: false) }
            do {
                let _: Empty = try await api("POST", "/api/proxy/start", timeout: 150)
                await refreshStatus() // the port the helper is really using
                let sp = systemProxy
                let result = await Task.detached { sp.enable() }.value
                if let err = result.error {
                    let _: Empty? = try? await api("POST", "/api/proxy/stop")
                    phase = .error("System proxy: \(err)")
                    return
                }
                // The helper may have died, or the app started quitting, while the settings were being applied.
                guard daemonReady, !isQuitting, phase == .starting else {
                    await Task.detached { sp.disable() }.value
                    return
                }
                activeProxy = sp
                activeServices = result.applied
                phase = .on
                await refreshStatus()
                await refreshIP()
                await checkForLeak(realIP: await direct.value)
            } catch {
                phase = .error(error.localizedDescription)
                // Still pointed at a stopped proxy from before (kill switch): keep holding the port, or switch it off.
                if activeProxy != nil { if lastKillSwitch { holder.hold(port: activeProxy?.port ?? systemProxy.port) } else { disableSystemProxy() } }
                await refreshStatus()
            }
        }
    }

    /// Switches the macOS proxy off, but only where it still points at us.
    func disableSystemProxy() {
        holder.release()
        let active = activeProxy ?? systemProxy
        active.disable()
        if active.port != systemProxy.port { systemProxy.disable() }
        activeProxy = nil
    }

    func turnOff() {
        let active = activeProxy ?? systemProxy
        let current = systemProxy
        holder.release()
        activeProxy = nil
        exitIP = nil
        leakWarning = nil
        clearLog() // the lines name the sites that were visited, so they end with the session
        phase = .off
        stopTask = Task {
            await Task.detached {
                active.disable()
                if active.port != current.port { current.disable() }
            }.value
            let _: Empty? = try? await api("POST", "/api/proxy/stop")
            await refreshStatus()
        }
    }

    // MARK: Leak check

    /// The address a public echo service sees. Going direct (empty proxy list) gives the real IP; following the Mac's
    /// settings gives the one that apps get. No app name is sent: it is a plain request, like any browser would make.
    nonisolated static func lookupIP(viaSystemSettings: Bool) async -> String? {
        let cfg = URLSessionConfiguration.ephemeral
        if !viaSystemSettings { cfg.connectionProxyDictionary = [:] }
        cfg.timeoutIntervalForRequest = 8
        cfg.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0"]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        for address in ["https://api.ipify.org", "https://icanhazip.com"] {
            guard let url = URL(string: address),
                  let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let text = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if (3...45).contains(text.count), text.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) { return text }
        }
        return nil
    }

    /// Compares what apps get through the Mac's own proxy settings with the real IP found before turning on.
    /// An unknown answer (offline, blocked check site) shows nothing: only a match proves a leak.
    private func checkForLeak(realIP: String?) async {
        guard let real = realIP else { return }
        for attempt in 0..<2 {
            guard phase == .on, let seen = await AppModel.lookupIP(viaSystemSettings: true) else { return }
            if seen != real { return }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) } // macOS may need a moment to publish the new settings
        }
        guard phase == .on else { return }
        leakWarning = "Traffic from this Mac is still reaching the internet with your real IP address (\(real)). A VPN or another network setting may be routing around Kagewon."
    }

    // MARK: Settings

    func setRotation(_ r: String) {
        status?.rotation = r
        Task {
            let _: Empty? = try? await api("PUT", "/api/settings", body: ["rotation": r])
            await refreshStatus()
        }
    }

    func setRotateOpenConnections(_ on: Bool) {
        status?.rotateOpenConnections = on
        Task {
            let _: Empty? = try? await api("PUT", "/api/settings", body: ["rotateOpenConnections": on])
            await refreshStatus()
        }
    }

    func setStickyMinutes(_ n: Int) {
        status?.stickyMinutes = n
        Task {
            let _: Empty? = try? await api("PUT", "/api/settings", body: ["stickyMinutes": n])
        }
    }

    // MARK: Providers

    func beginAdd(_ type: String) {
        draft = ProviderDraft(type: type)
        formError = nil
        tests["draft"] = nil
        isEditing = true
        tab = .providers
    }

    func beginEdit(_ p: ProviderInfo) {
        draft = ProviderDraft(from: p)
        formError = nil
        tests["draft"] = nil
        isEditing = true
    }

    func cancelEdit() {
        isEditing = false
        formError = nil
        draft = ProviderDraft(type: draft.type) // pasted keys must not linger in memory
    }

    func saveDraft() {
        formError = nil
        isSaving = true
        let d = draft
        Task {
            defer { isSaving = false }
            do {
                if let id = d.id {
                    let _: Empty = try await api("PUT", "/api/providers/\(id)", body: d.body(), timeout: 150)
                } else {
                    let _: Empty = try await api("POST", "/api/providers", body: d.body(), timeout: 150)
                }
                isEditing = false
                draft = ProviderDraft(type: d.type)
                await refreshStatus()
            } catch {
                formError = error.localizedDescription
            }
        }
    }

    func setEnabled(_ p: ProviderInfo, _ on: Bool) {
        Task {
            let _: Empty? = try? await api("PUT", "/api/providers/\(p.id)", body: ["enabled": on], timeout: 60)
            await refreshStatus()
        }
    }

    func deleteProvider(_ id: String) {
        pendingDelete = nil
        Task {
            let _: Empty? = try? await api("DELETE", "/api/providers/\(id)", timeout: 60)
            await refreshStatus()
        }
    }

    func testDraft() { runTest(key: "draft", body: draft.body()) }
    func testSaved(_ id: String) { runTest(key: id, body: ["id": id]) }

    private func runTest(key: String, body: [String: Any]) {
        tests[key] = .running
        Task {
            do {
                let r: TestResult = try await api("POST", "/api/providers/test", body: body, timeout: 150)
                if r.ok {
                    tests[key] = .done(ok: true, text: "Works: \(r.count ?? 0) proxies, exit IP \(r.ip ?? "?") (\(r.ms ?? 0) ms)")
                } else {
                    tests[key] = .done(ok: false, text: r.error ?? "Test failed")
                }
            } catch {
                tests[key] = .done(ok: false, text: error.localizedDescription)
            }
        }
    }

    // MARK: Misc actions

    func openConfigFolder() { shell("/usr/bin/open", ["-R", proxyDir + "/config.json"]) }

    // MARK: Settings screen

    func showSettings() {
        tab = .settings
        loadSettingsDraft()
    }

    func loadSettingsDraft() {
        settings = SettingsDraft(port: String(status?.port ?? systemProxy.port),
                                 refreshMinutes: status?.refreshMinutes ?? 15,
                                 verbose: status?.verbose ?? false,
                                 killSwitch: status?.killSwitch ?? false)
        settingsMessage = nil
    }

    func saveSettings() {
        let s = settings
        Task {
            do {
                let _: Empty = try await api("PUT", "/api/settings", body: [
                    "port": Int(s.port) ?? 0,
                    "refreshMinutes": s.refreshMinutes,
                    "verbose": s.verbose,
                    "killSwitch": s.killSwitch,
                ])
                settingsOK = true
                settingsMessage = isOn ? "Saved. The port applies the next time you turn the proxy on." : "Saved."
                await refreshStatus()
            } catch {
                settingsOK = false
                settingsMessage = error.localizedDescription
            }
        }
    }
    func openLogFile() { shell("/usr/bin/open", [logURL.path]) }
}

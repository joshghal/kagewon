import AppKit
import Network
import SwiftUI

// MARK: - API types (JSON from the local control API)

struct Empty: Decodable {}
struct ErrorBody: Decodable { var error: String }
struct IPBody: Decodable { var ip: String }

struct APIStatus: Decodable {
    var state: String
    /// While the helper is starting: "loading", "checking" or "listening".
    var stage: String?
    var rotation: String
    var stickyMinutes: Int
    /// The sticky time in seconds, in steps of 30 (older helpers send only stickyMinutes).
    var stickySeconds: Int?
    var port: Int
    var listenPort: Int?
    var refreshMinutes: Int
    var verbose: Bool
    var rotateOpenConnections: Bool?
    var killSwitch: Bool?
    var lastError: String?
    /// The bypass list the helper wants applied to the Mac's proxy settings (older helpers do not send it).
    var bypass: [String]?
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

/// A value written by a background task and read after it has finished.
final class Flag: @unchecked Sendable { var value = false }

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
    /// What the proxy settings need to bypass; the helper's own list when it reports one.
    private var bypassList = SystemProxy.defaultBypass
    /// The Mac's real address found before turning on, kept for the later leak re-checks (which make no direct request).
    private var realIP: String?
    /// Status polls in a row that the helper did not answer while the proxy is on.
    private var failedPolls = 0
    /// The kill switch could not take the proxy port (something else listens there); the poll keeps trying.
    private var needsHoldRetry = false
    /// Counts clears of the activity log, so a reply that was in flight when the log was cleared is thrown away.
    private var logGeneration = 0
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var recheckTask: Task<Void, Never>?
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
    /// What the app itself is doing while connecting (the helper reports its own steps).
    @Published var startDetail: String?

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

    /// How long each site keeps its IP, in seconds. An older helper reports whole minutes only.
    var stickySeconds: Int { status?.stickySeconds ?? (status?.stickyMinutes ?? 10) * 60 }

    /// The line under the app name while connecting, so a long wait shows what it is waiting for.
    var connectingText: String {
        if let detail = startDetail { return detail }
        switch status?.stage {
        case "loading": return "Loading proxy lists..."
        case "checking": return "Checking the proxies..."
        case "listening": return "Starting the proxy..."
        default: return "Connecting..."
        }
    }
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

    /// A helper that survived a crash of the app. It is found by the pid file it wrote and only stopped if that pid is still
    /// our own helper. Pids get reused, so it must be a node binary running this folder's proxy.mjs, and it must have been
    /// started no later than the pid file was written (a program that reused the pid is newer than the file).
    nonisolated static func stopStaleHelper(proxyDir: String) {
        let pidFile = proxyDir + "/.helper.pid"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        let command = shell("/bin/ps", ["-o", "command=", "-p", String(pid)]).output
        let exe = shell("/bin/ps", ["-o", "comm=", "-p", String(pid)]).output
        guard isOurHelper(exe: exe, command: command, proxyDir: proxyDir),
              let elapsed = parseElapsed(shell("/bin/ps", ["-o", "etime=", "-p", String(pid)]).output),
              let written = (try? FileManager.default.attributesOfItem(atPath: pidFile))?[.modificationDate] as? Date,
              Date().addingTimeInterval(-elapsed) <= written.addingTimeInterval(3) else { return }
        kill(pid, SIGTERM)
        // It holds the control port until it has stopped Tor (a few seconds at most), so wait for it to be gone.
        for _ in 0..<50 where kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL); usleep(300_000) }
    }

    /// Shown when the proxy settings could not be confirmed to be back to normal.
    private static let notConfirmed = "Could not confirm that the proxy settings are back to normal. Check System Settings, Network, Proxies, or use the recovery command in the README."

    func start() {
        // Clean up after a previous crash or force-quit, in the background so that launching is never held up by it. The settings
        // cleanup is queued right now, so nothing that turns the proxy on later can run before it.
        systemProxy.disableInBackground { [weak self] confirmed in
            Task { @MainActor [weak self] in self?.settingsRestored(confirmed) }
        }
        let dir = proxyDir
        Task { [weak self] in
            await Task.detached { AppModel.stopStaleHelper(proxyDir: dir) }.value
            self?.launchDaemon()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.verifySystemProxy()
                await self?.refreshStatus()
                self?.retryHold()
                if self?.activityVisible == true { await self?.refreshLog() }
                if let self, self.isOn, self.popoverOpen, Date().timeIntervalSince(self.ipCheckedAt ?? .distantPast) > 30 {
                    await self.refreshIP() // so the tile shows the IP after a sticky time has run out
                }
            }
        }
        watchTheNetwork()
    }

    /// Switches the proxy settings off and stops the helper. The work runs in the background and quitting waits for it for at
    /// most about 15 seconds, so a stuck command cannot freeze the app. Returns false if it could not be confirmed that the
    /// proxy settings are off.
    @discardableResult
    func shutdown() -> Bool {
        if isDuplicate { return true } // the first copy owns the proxy settings and the helper
        isQuitting = true
        pollTimer?.invalidate()
        recheckTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        holder.release()
        let active = activeProxy ?? systemProxy
        let current = systemProxy
        activeProxy = nil
        let helper = daemon
        daemon = nil
        helper?.terminationHandler = nil

        let confirmed = Flag()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            SystemProxy.closeForQuit() // waits for a change that is already running, and refuses any later one
            var ok = active.disable() // first, so the Mac keeps its internet
            if active.port != current.port { ok = current.disable() && ok }
            confirmed.value = ok
            group.leave()
        }
        if let p = helper {
            group.enter()
            DispatchQueue.global().async {
                p.terminate()
                for _ in 0..<50 where p.isRunning { usleep(100_000) } // up to 5 s, so it can stop Tor cleanly
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                group.leave()
            }
        }
        if group.wait(timeout: .now() + 15) == .timedOut { return false }
        return confirmed.value
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
            createPrivateFile(atPath: logURL.path) // private from the moment it exists
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
        let outcome = proxyLost()
        exitIP = nil
        status = nil
        clearLog()
        let reason = p.terminationReason == .uncaughtSignal
            ? "killed (signal \(p.terminationStatus))"
            : (recentLines.last ?? "exit code \(p.terminationStatus)")
        phase = .error(lostMessage(outcome, "Helper stopped (\(reason))."))
    }

    nonisolated func appendLog(_ data: Data) {
        logQueue.async { appendPrivate(data, toPath: self.logURL.path) }
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
        let s: APIStatus
        do { s = try await api("GET", "/api/status", timeout: 4) } catch {
            if phase == .on { helperDidNotAnswer() }
            return
        }
        failedPolls = 0
        status = s
        lastKillSwitch = s.killSwitch ?? false
        if let list = s.bypass, let clean = AppModel.sanitizedBypass(list) { bypassList = clean }
        if phase != .on { systemProxy = SystemProxy(port: s.listenPort ?? s.port, recordPath: systemProxy.recordPath, bypass: bypassList) }
        if phase == .on, s.state != "running" {
            let outcome = proxyLost()
            exitIP = nil
            clearLog()
            let why = s.lastError ?? "The proxy stopped unexpectedly"
            phase = .error(lostMessage(outcome, why.hasSuffix(".") ? why : why + "."))
        }
    }

    /// The helper's list is only used if every entry looks like a host name, a wildcard name or an address range.
    nonisolated static func sanitizedBypass(_ list: [String]) -> [String]? {
        guard !list.isEmpty, list.count <= 200 else { return nil }
        let ok = list.allSatisfy { $0.count <= 80 && $0.range(of: #"^[A-Za-z0-9*._/:\-]+$"#, options: .regularExpression) != nil }
        return ok ? list : nil
    }

    private enum Lost {
        case blocked   // the kill switch keeps the Mac offline and this app holds the port
        case unheld    // the kill switch is on, but another program already listens on the port
        case direct    // the settings are being switched off, so traffic goes direct
    }

    /// The proxy stopped while the Mac was pointed at it. With the kill switch on, the settings stay and this app holds the port,
    /// so the Mac is offline and nothing else can listen there. Otherwise the settings are switched off in the background.
    private func proxyLost() -> Lost {
        if lastKillSwitch, let active = activeProxy {
            if holder.hold(port: active.port) { needsHoldRetry = false; return .blocked }
            needsHoldRetry = true
            return .unheld
        }
        needsHoldRetry = false
        holder.release()
        restoreSettingsInBackground()
        return .direct
    }

    private func lostMessage(_ outcome: Lost, _ headline: String) -> String {
        switch outcome {
        case .blocked:
            return "\(headline) The kill switch is on, so the internet stays blocked until you press Try Again or quit the app."
        case .unheld:
            return "\(headline) The kill switch is on, but another program is using the proxy port, so traffic may be going to it. Press Try Again, or turn the proxy off."
        case .direct:
            return "\(headline) Your traffic is going direct."
        }
    }

    /// Switches the settings off without holding up the app. If that cannot be confirmed, the screen says so.
    private func restoreSettingsInBackground() {
        let active = activeProxy ?? systemProxy
        let current = systemProxy
        activeProxy = nil
        let finish: @Sendable (Bool) -> Void = { [weak self] confirmed in Task { @MainActor [weak self] in self?.settingsRestored(confirmed) } }
        active.disableInBackground { first in
            if active.port != current.port {
                current.disableInBackground { second in finish(first && second) }
            } else {
                finish(first)
            }
        }
    }

    /// The result of switching the settings off. A failure is shown, unless the user has already turned the proxy on again.
    private func settingsRestored(_ confirmed: Bool) {
        guard !confirmed, !isQuitting else { return }
        switch phase {
        case .error(let message): if !message.contains(AppModel.notConfirmed) { phase = .error(message + " " + AppModel.notConfirmed) }
        case .off, .launching: phase = .error(AppModel.notConfirmed)
        case .starting, .on: break
        }
    }

    /// After the kill switch could not take the port, try again now and then: the other program may have gone.
    private func retryHold() {
        guard needsHoldRetry, let active = activeProxy, !holder.isHolding else { return }
        if holder.hold(port: active.port) {
            needsHoldRetry = false
            phase = .error("The kill switch is holding the proxy port again, so the internet stays blocked until you press Try Again or quit the app.")
        }
    }

    /// The helper is alive but does not answer: after about three polls in a row, stop it, and only then treat the proxy as lost.
    /// A stuck helper still holds the proxy port, so the kill switch can only take the port over once that process is gone.
    private func helperDidNotAnswer() {
        failedPolls += 1
        guard failedPolls >= 3, phase == .on else { return }
        failedPolls = 0
        let stuck = daemon
        stopDaemon() // from now on nothing polls it, and its exit is not reported as a crash
        Task { [weak self] in
            if let p = stuck { await Task.detached { AppModel.stopAndWait(p) }.value }
            guard let self, self.phase == .on else { return } // the user may have turned the proxy off meanwhile
            let outcome = self.proxyLost()
            self.exitIP = nil
            self.status = nil
            self.clearLog()
            self.phase = .error(self.lostMessage(outcome, "The helper stopped responding."))
        }
    }

    /// Asks a process to stop and, if it ignores that for about two seconds, kills it. Returns once it is gone.
    nonisolated static func stopAndWait(_ p: Process) {
        p.terminate()
        for _ in 0..<20 where p.isRunning { usleep(100_000) }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            for _ in 0..<20 where p.isRunning { usleep(100_000) }
        }
    }

    /// Every 15 seconds while on, and at once after a wake or a network change: is the Mac still pointed at the proxy? Something
    /// else (a VPN client, System Settings) can switch it off, and then traffic would go direct while this app still says "On".
    private func verifySystemProxy(force: Bool = false) async {
        tick += 1
        guard phase == .on, force || tick % 5 == 0, let active = activeProxy else { return }
        let known = activeServices
        let check = await Task.detached { () -> (added: [String], lost: [String])? in
            guard let current = listNetworkServicesChecked() else { return nil } // not readable: say nothing
            return (current.filter { !known.contains($0) }, known.filter { current.contains($0) && !active.fullyPoints(at: $0) })
        }.value
        guard let check, phase == .on else { return }
        if !check.lost.isEmpty {
            exitIP = nil
            phase = .error("The proxy settings for \(check.lost.joined(separator: ", ")) were changed by something else, so that traffic may be going direct. Press Try Again to switch them back on.")
            return
        }
        if !check.added.isEmpty { // a hotspot or Ethernet that appeared after turning on would otherwise stay unprotected
            let result = await Task.detached { active.apply(to: check.added) }.value
            // The proxy may have been turned off while this was being applied: undo it, so that nothing is left on behind the turn-off.
            guard phase == .on, activeProxy != nil else {
                _ = await Task.detached { active.disable() }.value
                return
            }
            if result.error == nil { activeServices += result.applied }
        }
    }

    /// After the Mac wakes or the network changes (a different Wi-Fi, a VPN connecting): look again, without waiting for the next
    /// check. Changes come in bursts, so it waits a moment for them to settle.
    private func watchTheNetwork() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.networkChanged() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor [weak self] in self?.networkChanged() } }
        monitor.start(queue: DispatchQueue(label: "app.kagewon.path"))
        pathMonitor = monitor
    }

    private func networkChanged() {
        guard phase == .on else { return }
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .on else { return }
            await self.verifySystemProxy(force: true)
            if let real = self.realIP { await self.checkForLeak(realIP: real) } // through the system path only: no new direct request
        }
    }

    private func clearLog() {
        logGeneration += 1
        logLines = []
        logSince = 0
    }

    func refreshLog() async {
        guard daemonReady, phase == .on || phase == .starting else { return }
        let generation = logGeneration
        guard let r: LogResponse = try? await api("GET", "/api/log?since=\(logSince)") else { return }
        // The log may have been cleared (turn-off, a stopped helper) while this reply was on its way: it is then old news.
        guard generation == logGeneration, phase == .on || phase == .starting else { return }
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
            defer { startDetail = nil }
            await previousStop?.value // a turn-off that is still finishing must be done first
            // With the kill switch on, this app is still holding the proxy port from before. It keeps holding it while the helper
            // loads its providers, and hands it over only when the helper reports that it is about to listen.
            let handover = Task {
                while !Task.isCancelled {
                    if let s: APIStatus = try? await api("GET", "/api/status", timeout: 3) {
                        status = s // so the header follows the helper's steps without waiting for the next poll
                        if s.stage == "listening" { holder.release(); return }
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            defer { handover.cancel() }
            // The real IP is looked up now, while the proxy is still off, and while the helper loads its providers.
            let direct = Task.detached { await AppModel.lookupIP(viaSystemSettings: false) }
            do {
                let _: Empty = try await api("POST", "/api/proxy/start", timeout: 150)
                handover.cancel()
                holder.release() // the helper is listening now, whether or not the watcher saw the moment
                await refreshStatus() // the port the helper is really using
                let sp = systemProxy
                startDetail = "Switching on the Mac's proxy settings..."
                let result = await Task.detached { sp.enable() }.value
                if let err = result.error {
                    let _: Empty? = try? await api("POST", "/api/proxy/stop")
                    var text = "System proxy: \(err)"
                    if lastKillSwitch && activeProxy != nil {
                        // The settings of the earlier run were in place; the failed attempt rolled them back.
                        activeProxy = nil
                        needsHoldRetry = false
                        text += " The kill switch could not stay in place. Traffic is going direct."
                    }
                    phase = .error(text)
                    return
                }
                // The helper may have died, or the app started quitting, while the settings were being applied.
                guard daemonReady, !isQuitting, phase == .starting else {
                    _ = await Task.detached { sp.disable() }.value
                    return
                }
                activeProxy = sp
                activeServices = result.applied
                failedPolls = 0
                phase = .on
                await refreshStatus()
                await refreshIP()
                let real = await direct.value
                realIP = real
                await checkForLeak(realIP: real)
            } catch {
                var text = error.localizedDescription
                // Still pointed at a stopped proxy from before (kill switch): keep holding the port, or switch it off.
                if activeProxy != nil {
                    if lastKillSwitch {
                        if !holder.hold(port: activeProxy?.port ?? systemProxy.port) {
                            needsHoldRetry = true
                            text += " The kill switch is on, but another program is using the proxy port, so traffic may be going to it."
                        }
                    } else {
                        restoreSettingsInBackground()
                    }
                }
                phase = .error(text)
                await refreshStatus()
            }
        }
    }

    func turnOff() {
        let active = activeProxy ?? systemProxy
        let current = systemProxy
        holder.release()
        needsHoldRetry = false
        activeProxy = nil
        exitIP = nil
        leakWarning = nil
        realIP = nil
        clearLog() // the lines name the sites that were visited, so they end with the session
        phase = .off
        stopTask = Task {
            let confirmed = await Task.detached { () -> Bool in
                let first = active.disable()
                return active.port != current.port ? (current.disable() && first) : first
            }.value
            let _: Empty? = try? await api("POST", "/api/proxy/stop")
            clearLog() // lines that were fetched while the helper was still stopping must not outlive the session
            await refreshStatus()
            if !confirmed { settingsRestored(false) }
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

    /// Compares what apps get through the Mac's own proxy settings with the real IP found before turning on. It is also used after
    /// a wake or a network change, with the same remembered real IP: those re-checks never contact the echo service directly.
    /// An unknown answer (offline, blocked check site) shows nothing: only a match proves a leak.
    private func checkForLeak(realIP: String?) async {
        guard let real = realIP else { return }
        for attempt in 0..<2 {
            guard phase == .on, let seen = await AppModel.lookupIP(viaSystemSettings: true) else { return }
            if seen != real { leakWarning = nil; return } // it works now (a VPN that was routing around the proxy has gone)
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

    func setStickySeconds(_ n: Int) {
        status?.stickySeconds = n
        status?.stickyMinutes = (n + 59) / 60 // what an older helper would report
        Task {
            let _: Empty? = try? await api("PUT", "/api/settings", body: ["stickySeconds": n])
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

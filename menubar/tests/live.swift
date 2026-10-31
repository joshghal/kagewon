import Foundation
import AppKit
import Darwin

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok    " : "  FAIL  ", what); fflush(stdout); if !ok { failures += 1 } }

let root = CommandLine.arguments[1]
let proj = root + "/proj"
let fakeState = root + "/ns"
let fm = FileManager.default
try? fm.removeItem(atPath: fakeState)
try! fm.createDirectory(atPath: fakeState, withIntermediateDirectories: true)
try! "Wi-Fi\nEthernet\n".write(toFile: fakeState + "/services", atomically: true, encoding: .utf8)
func put(_ name: String, _ svc: String, _ v: String) { try! (v + "\n").write(toFile: "\(fakeState)/\(name).\(svc)", atomically: true, encoding: .utf8) }
func val(_ name: String, _ svc: String) -> String { ((try? String(contentsOfFile: "\(fakeState)/\(name).\(svc)", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
put("pac.url", "Wi-Fi", "http://pac.example/proxy.pac"); put("pac.en", "Wi-Fi", "Yes"); put("disc", "Wi-Fi", "On")

setenv("FAKE_NS", fakeState, 1)
setenv("KAGEWON_DIR", proj, 1)
setenv("CONTROL_PORT", "18889", 1)
networksetup = root + "/fakens"

let PROXY_PORT = 18888
func connectDropped(_ port: Int) -> Bool? {   // true: accepted then closed by the other side; false: refused; nil: other
    let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
    var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    if !ok { return false }
    var tv = timeval(tv_sec: 2, tv_usec: 0); setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var b: UInt8 = 0
    return recv(s, &b, 1, 0) == 0 ? true : nil
}
func helperPid() -> Int32? { Int32((try? String(contentsOfFile: proj + "/.helper.pid", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") }
func phaseName(_ p: Phase) -> String { if case .error(let m) = p { return "error(\(m.prefix(70)))" }; return "\(p)" }

@MainActor func waitFor(_ what: String, _ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 250_000_000) }
    print("  (timed out waiting for \(what))"); return false
}

@MainActor func scenario() async {
    let m = AppModel()
    m.start()
    check(await waitFor("helper", 30) { m.phase == .off }, "1. the helper starts and the app is ready (phase \(phaseName(m.phase)))")

    // a Tor provider and a private port, added the way the app's form does it
    do {
        let _: Empty = try await m.api("POST", "/api/providers", body: ["type": "tor", "socksPort": 19250, "name": "Tor"], timeout: 60)
        let _: Empty = try await m.api("PUT", "/api/settings", body: ["port": PROXY_PORT])
    } catch { check(false, "setup failed: \(error)"); exit(1) }
    await m.refreshStatus()

    print("2. turning on (Tor has to bootstrap, this can take a minute)")
    m.turnOn()
    let on = await waitFor("on", 150) { if case .error = m.phase { return true }; return m.phase == .on }
    check(on && m.phase == .on, "   phase is on (\(phaseName(m.phase)))")
    check(val("webproxy.en", "Wi-Fi") == "Yes" && val("webproxy.port", "Wi-Fi") == "\(PROXY_PORT)" && val("securewebproxy.en", "Ethernet") == "Yes", "   both networks point at the proxy port")
    check(val("pac.en", "Wi-Fi") == "No" && val("disc", "Wi-Fi") == "Off", "   PAC and discovery are switched off while on")
    check(fm.fileExists(atPath: proj + "/.system-proxy.json"), "   the record for crash recovery exists")
    check(await waitFor("exit ip", 60) { m.exitIP != nil && m.exitIP != "unavailable" }, "   an exit IP is shown: \(m.exitIP ?? "none")")
    check(await waitFor("leak warning", 60) { m.leakWarning != nil }, "   the leak check notices that the (fake) system settings do not carry the traffic")
    print("     warning text: \(m.leakWarning?.prefix(60) ?? "none")...")

    print("3. kill switch")
    do { let _: Empty = try await m.api("PUT", "/api/settings", body: ["killSwitch": true]) } catch { check(false, "settings: \(error)") }
    _ = await waitFor("status", 10) { m.status?.killSwitch == true }
    if let pid = helperPid() { kill(pid, SIGKILL) } else { check(false, "no helper pid") }
    check(await waitFor("error", 20) { if case .error = m.phase { return true }; return false }, "   the app notices the helper died (\(phaseName(m.phase)))")
    check(val("webproxy.en", "Wi-Fi") == "Yes", "   the proxy settings stay on, so the Mac stays offline")
    check(connectDropped(PROXY_PORT) == true, "   the app holds the port and drops connections")
    if case .error(let msg) = m.phase { check(msg.contains("kill switch"), "   the message explains the kill switch") }

    print("4. Try Again")
    m.togglePower()
    check(await waitFor("on again", 150) { m.phase == .on }, "   recovers to on (\(phaseName(m.phase)))")
    check(connectDropped(PROXY_PORT) != true, "   the helper, not the holder, serves the port again")

    print("5. turn off, then on again straight away")
    m.turnOff()
    check(m.phase == .off && m.logLines.isEmpty && m.leakWarning == nil, "   the screen state is cleared at once")
    m.turnOn()
    check(await waitFor("on after quick toggle", 150) { m.phase == .on }, "   it ends up on (\(phaseName(m.phase)))")
    await m.refreshStatus()
    check(m.status?.state == "running", "   and the helper is really running (state \(m.status?.state ?? "?")), not stopped by the earlier turn-off")

    print("6. turn off")
    m.turnOff()
    check(await waitFor("settings restored", 30) { val("webproxy.en", "Wi-Fi") == "No" && !fm.fileExists(atPath: proj + "/.system-proxy.json") }, "   settings are off and the record is removed")
    check(val("pac.url", "Wi-Fi") == "http://pac.example/proxy.pac" && val("pac.en", "Wi-Fi") == "Yes" && val("disc", "Wi-Fi") == "On", "   the PAC file and discovery are back as they were")
    check(val("webproxy.en", "Ethernet") == "No", "   Ethernet is off too")

    print("7. quit while on")
    m.turnOn()
    check(await waitFor("on", 150) { m.phase == .on }, "   on again (\(phaseName(m.phase)))")
    m.shutdown()
    check(val("webproxy.en", "Wi-Fi") == "No" && val("pac.en", "Wi-Fi") == "Yes", "   quitting restores the settings")
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let left = shell("/usr/bin/pgrep", ["-f", proj]).output
    check(left.isEmpty, "   no helper or Tor process is left behind \(left.isEmpty ? "" : "(\(left.replacingOccurrences(of: "\n", with: ",")))")")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
Task { @MainActor in await scenario() }
RunLoop.main.run()

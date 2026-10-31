import Foundation
import Darwin

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   " : "  FAIL ", what); if !ok { failures += 1 } }

let work = NSTemporaryDirectory() + "kg-harness-\(getpid())"
let fm = FileManager.default
func fresh() -> String {
    try? fm.removeItem(atPath: work)
    try! fm.createDirectory(atPath: work, withIntermediateDirectories: true)
    setenv("FAKE_NS", work, 1)
    try! "Wi-Fi\nEthernet\n".write(toFile: work + "/services", atomically: true, encoding: .utf8)
    return work + "/record.json"
}
func put(_ name: String, _ svc: String, _ value: String) { try! (value + "\n").write(toFile: "\(work)/\(name).\(svc)", atomically: true, encoding: .utf8) }
func val(_ name: String, _ svc: String) -> String { ((try? String(contentsOfFile: "\(work)/\(name).\(svc)", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
networksetup = CommandLine.arguments[1]
func bypassList(_ svc: String) -> [String] {
    ((try? String(contentsOfFile: "\(work)/bypass.\(svc)", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}
func setBypass(_ svc: String, _ list: [String]) { try! (list.joined(separator: "\n") + "\n").write(toFile: "\(work)/bypass.\(svc)", atomically: true, encoding: .utf8) }
/// Makes one fake command fail ("fail") or never finish ("hang") for one service; the service is empty for the list command.
func misbehave(_ how: String, _ verb: String, _ svc: String = "") { fm.createFile(atPath: "\(work)/\(how).\(verb).\(svc)", contents: Data()) }
func behaveAgain() { for n in (try? fm.contentsOfDirectory(atPath: work)) ?? [] where n.hasPrefix("fail.") || n.hasPrefix("hang.") { try? fm.removeItem(atPath: "\(work)/\(n)") } }
func pacSetup() { put("pac.url", "Wi-Fi", "http://pac.example/proxy.pac"); put("pac.en", "Wi-Fi", "Yes"); put("disc", "Wi-Fi", "On") }
func pacRestored() -> Bool { val("pac.url", "Wi-Fi") == "http://pac.example/proxy.pac" && val("pac.en", "Wi-Fi") == "Yes" && val("disc", "Wi-Fi") == "On" }
func manualOff() { for svc in ["Wi-Fi", "Ethernet"] { put("webproxy.en", svc, "No"); put("securewebproxy.en", svc, "No") } }

print("Reading answers exactly")
let a30000 = "Enabled: Yes\nServer: 127.0.0.1\nPort: 30000\nAuthenticated Proxy Enabled: 0"
check(!answerPoints(a30000, port: 3000), "port 3000 does not match 30000")
check(answerPoints(a30000, port: 30000), "port 30000 matches itself")
check(!answerPoints("Enabled: Yes\nServer: 127.0.0.10\nPort: 8888", port: 8888), "server 127.0.0.10 is not 127.0.0.1")
check(!answerPoints("Enabled: No\nServer: 127.0.0.1\nPort: 8888\nAuthenticated Proxy Enabled: 1", port: 8888), "a disabled proxy does not count, even with another field saying 1")
check(answerPoints("Enabled: Yes\nServer: 127.0.0.1\nPort: 8888\nAuthenticated Proxy Enabled: 0", port: 8888), "a normal answer matches")
let pac = AutoConfig.parse(pacAnswer: "URL: http://pac.example:8080/proxy.pac\nEnabled: Yes", discoveryAnswer: "Auto Proxy Discovery: On")
check(pac == AutoConfig(pacURL: "http://pac.example:8080/proxy.pac", pacEnabled: true, discovery: true), "a PAC address with a colon stays whole")
check(AutoConfig.parse(pacAnswer: "URL: (null)\nEnabled: No", discoveryAnswer: "Auto Proxy Discovery: Off") == AutoConfig(pacURL: nil, pacEnabled: false, discovery: false), "no PAC and discovery off")

print("Reading the port from config.json")
func configWith(_ json: String) -> Int { try! json.write(toFile: work + "/config.json", atomically: true, encoding: .utf8); return readConfigPort(work) }
_ = fresh()
check(configWith("{\"port\": 9000}") == 9000, "number")
check(configWith("{\"port\": \"9001\"}") == 9001, "numeric text")
check(configWith("{\"port\": true}") == 8888, "a boolean falls back")
check(configWith("{\"port\": 80}") == 8888, "below 1024 falls back")
check(configWith("{\"port\": 3000.5}") == 8888, "a fraction falls back")
check(configWith("{\"port\": \"abc\"}") == 8888, "text falls back")
check(configWith("{}") == 8888, "missing falls back")

print("Switching on and off, with a PAC file and automatic discovery on Wi-Fi")
var rec = fresh()
put("pac.url", "Wi-Fi", "http://pac.example/proxy.pac"); put("pac.en", "Wi-Fi", "Yes"); put("disc", "Wi-Fi", "On")
var sp = SystemProxy(port: 59999, recordPath: rec)
var r = sp.enable()
check(r.error == nil && r.applied.sorted() == ["Ethernet", "Wi-Fi"], "enabled on both networks")
check(sp.fullyPoints(at: "Wi-Fi") && sp.fullyPoints(at: "Ethernet"), "both fully point at us")
check(val("pac.en", "Wi-Fi") == "No" && val("disc", "Wi-Fi") == "Off", "PAC and discovery are switched off while on")
check(fm.fileExists(atPath: rec), "a record was written")
let mode = ((try? fm.attributesOfItem(atPath: rec))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
check(mode == 0o600, "the record is private (mode \(String(mode, radix: 8)))")
put("pac.en", "Wi-Fi", "Yes")
check(!sp.fullyPoints(at: "Wi-Fi"), "switching the PAC file back on is noticed as tampering")
put("pac.en", "Wi-Fi", "No")
check(sp.fullyPoints(at: "Wi-Fi"), "and is fine again once it is off")
sp.disable()
check(!sp.pointsAtUs, "nothing points at us after disable")
check(val("pac.url", "Wi-Fi") == "http://pac.example/proxy.pac" && val("pac.en", "Wi-Fi") == "Yes" && val("disc", "Wi-Fi") == "On", "the PAC file and discovery are back as they were")
check(val("pac.en", "Ethernet") == "No" && val("disc", "Ethernet") == "Off", "Ethernet, which had none, still has none")
check(!fm.fileExists(atPath: rec), "the record is removed")

print("Undoing a crashed run after the port was changed in Settings")
rec = fresh()
put("pac.url", "Wi-Fi", "http://pac.example/proxy.pac"); put("pac.en", "Wi-Fi", "Yes"); put("disc", "Wi-Fi", "On")
_ = SystemProxy(port: 59999, recordPath: rec).enable()   // the app dies here, leaving the record behind
let relaunched = SystemProxy(port: 8888, recordPath: rec) // the next launch reads another port from config.json
check(relaunched.pointsAtUs, "the old port is found through the record")
relaunched.disable()
check(!relaunched.pointsAtUs && val("webproxy.en", "Wi-Fi") == "No" && val("securewebproxy.en", "Ethernet") == "No", "the Mac is back to normal")
check(val("pac.en", "Wi-Fi") == "Yes" && val("disc", "Wi-Fi") == "On", "including the PAC file and discovery")

print("A failure half way through puts everything back")
rec = fresh()
put("pac.url", "Wi-Fi", "http://pac.example/proxy.pac"); put("pac.en", "Wi-Fi", "Yes"); put("disc", "Wi-Fi", "On")
put("bypass", "Ethernet", "keep.me"); try? fm.removeItem(atPath: work + "/bypass.Ethernet"); try! "keep.me\n".write(toFile: work + "/bypass.Ethernet", atomically: true, encoding: .utf8)
fm.createFile(atPath: "\(work)/fail.-setsecurewebproxy.Ethernet", contents: Data())
r = SystemProxy(port: 59999, recordPath: rec).enable()
check(r.error != nil && r.applied.isEmpty, "the error is reported: \(r.error ?? "-")")
check(val("webproxy.en", "Wi-Fi") == "No" && val("securewebproxy.en", "Wi-Fi") == "No" && val("webproxy.en", "Ethernet") == "No", "no network is left pointed at us")
check(val("pac.en", "Wi-Fi") == "Yes" && val("disc", "Wi-Fi") == "On", "the PAC file and discovery of Wi-Fi are back")
check(!fm.fileExists(atPath: rec), "the record is removed")
check(bypassList("Ethernet") == ["keep.me"] && bypassList("Wi-Fi").isEmpty, "the bypass lists are back as they were, with the user's own entry kept")

print("Proxies that are not ours are left alone")
rec = fresh()
put("webproxy.en", "Ethernet", "Yes"); put("webproxy.server", "Ethernet", "10.0.0.1"); put("webproxy.port", "Ethernet", "3128")
put("webproxy.en", "Wi-Fi", "Yes"); put("webproxy.server", "Wi-Fi", "127.0.0.1"); put("webproxy.port", "Wi-Fi", "30000")
SystemProxy(port: 3000, recordPath: rec).disable()
check(val("webproxy.en", "Ethernet") == "Yes" && val("webproxy.en", "Wi-Fi") == "Yes", "a company proxy, and a local proxy on port 30000, stay on when ours is 3000")

print("Changes never overlap")
rec = fresh()
sp = SystemProxy(port: 59999, recordPath: rec)
DispatchQueue.concurrentPerform(iterations: 12) { i in if i % 2 == 0 { _ = sp.enable() } else { sp.disable() } }
sp.disable()
check(!sp.pointsAtUs && !fm.fileExists(atPath: rec), "after 12 racing calls and a final disable, nothing is left on")

print("Putting things back even when the manual proxy is already off")
rec = fresh(); pacSetup(); setBypass("Ethernet", ["keep.me"])
_ = SystemProxy(port: 59999, recordPath: rec).enable()
manualOff() // after a force quit the helper's watchdog switched the manual proxy off, but it never restored the automatic settings
let afterCrash = SystemProxy(port: 8888, recordPath: rec)
check(afterCrash.disable(), "the next launch can confirm that everything is back")
check(pacRestored(), "the PAC file and discovery are restored although nothing pointed at us")
check(bypassList("Ethernet") == ["keep.me"] && bypassList("Wi-Fi").isEmpty, "the bypass entries Kagewon added are gone, the user's own stay")
check(!fm.fileExists(atPath: rec), "the record is removed")

rec = fresh(); pacSetup()
sp = SystemProxy(port: 59999, recordPath: rec)
_ = sp.enable()
manualOff() // something else (a VPN client, System Settings) switched our proxy off before the user turned Kagewon off
check(sp.disable() && pacRestored(), "turning off after something else switched the proxy off still restores the PAC file")

rec = fresh(); pacSetup()
sp = SystemProxy(port: 59999, recordPath: rec)
_ = sp.enable()
put("pac.url", "Wi-Fi", "http://other.example/x.pac"); put("pac.en", "Wi-Fi", "Yes"); put("disc", "Ethernet", "On") // changed by someone else meanwhile
check(sp.disable(), "turning off works")
check(val("pac.url", "Wi-Fi") == "http://other.example/x.pac" && val("pac.en", "Wi-Fi") == "Yes" && val("disc", "Ethernet") == "On", "a change made by someone else is not overwritten with the old settings")

print("The bypass list")
rec = fresh(); setBypass("Wi-Fi", ["localhost", "keep.me"])
sp = SystemProxy(port: 59999, recordPath: rec)
_ = sp.enable()
let withBypass = bypassList("Wi-Fi")
check(SystemProxy.defaultBypass.allSatisfy(withBypass.contains) && withBypass.contains("keep.me"), "every wanted entry is there, and the user's own entry is kept")
check(withBypass.filter { $0 == "localhost" }.count == 1, "an entry that was already there is not added twice")
sp.disable()
check(bypassList("Wi-Fi") == ["localhost", "keep.me"], "turning off leaves exactly what the user had")
check(bypassList("Ethernet").isEmpty, "a list that was empty is empty again")
rec = fresh()
sp = SystemProxy(port: 59999, recordPath: rec, bypass: ["only.this"])
_ = sp.enable()
check(bypassList("Wi-Fi") == ["only.this"], "the list the helper reports is the one that is applied")
sp.disable()

print("The record on disk")
rec = fresh(); pacSetup()
sp = SystemProxy(port: 59999, recordPath: rec)
_ = sp.enable()
if let data = fm.contents(atPath: rec), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let services = obj["services"] as? [String: [String: Any]], let wifi = services["Wi-Fi"], let eth = services["Ethernet"] {
    check(obj["port"] as? Int == 59999 && wifi["pacURL"] as? String == "http://pac.example/proxy.pac" && wifi["pacEnabled"] as? Bool == true
          && wifi["discovery"] as? Bool == true && (wifi["addedBypass"] as? [String])?.count == SystemProxy.defaultBypass.count, "the record has the documented shape")
    check(eth["pacURL"] == nil && eth["addedBypass"] != nil, "a missing PAC address is left out of the record")
} else { check(false, "the record could not be read as JSON") }
sp.disable()
rec = fresh()
try! #"{"port":59999,"services":{"Wi-Fi":{"pacURL":"http://pac.example/proxy.pac","pacEnabled":true,"discovery":true}}}"#.write(toFile: rec, atomically: true, encoding: .utf8)
put("webproxy.en", "Wi-Fi", "Yes"); put("webproxy.server", "Wi-Fi", "127.0.0.1"); put("webproxy.port", "Wi-Fi", "59999")
check(SystemProxy(port: 8888, recordPath: rec).disable() && pacRestored(), "a record from an older version (no addedBypass) is still understood")
rec = fresh()
try! #"{"port":59999,"services":{"Wi-Fi":{"pacURL":"javascript:alert(1)","pacEnabled":true,"discovery":false}}}"#.write(toFile: rec, atomically: true, encoding: .utf8)
check(SystemProxy(port: 8888, recordPath: rec).disable(), "a record with an odd PAC address can be cleared")
check(val("pac.url", "Wi-Fi") == "" && val("pac.en", "Wi-Fi") != "Yes", "and an address that is not http, https, ftp or file is never put back")
check(isSafePACURL("https://pac.example/p.pac") && isSafePACURL("file:///etc/proxy.pac") && !isSafePACURL("javascript:alert(1)") && !isSafePACURL("not a url"), "only ordinary PAC addresses are accepted")

print("A failed read is unknown, never off")
rec = fresh(); setBypass("Wi-Fi", ["keep.me"])
misbehave("fail", "-getproxybypassdomains", "Wi-Fi")
r = SystemProxy(port: 59999, recordPath: rec).enable()
check(r.error != nil && r.applied.isEmpty, "turning on is refused when a bypass list cannot be read: \(r.error ?? "-")")
check(val("webproxy.en", "Wi-Fi") == "" && val("webproxy.en", "Ethernet") == "" && !fm.fileExists(atPath: rec), "nothing was changed and no record was written")
check(bypassList("Wi-Fi") == ["keep.me"], "the user's bypass list was not overwritten with an error text")
behaveAgain()
misbehave("fail", "-getautoproxyurl", "Ethernet")
r = SystemProxy(port: 59999, recordPath: rec).enable()
check(r.error != nil && val("webproxy.en", "Wi-Fi") == "", "turning on is refused when the automatic settings cannot be read")
behaveAgain()
misbehave("fail", "-listallnetworkservices")
r = SystemProxy(port: 59999, recordPath: rec).enable()
check(r.error != nil && val("webproxy.en", "Wi-Fi") == "", "turning on is refused when the list of networks cannot be read")
behaveAgain()
rec = fresh(); pacSetup()
sp = SystemProxy(port: 59999, recordPath: rec)
_ = sp.enable()
misbehave("fail", "-listallnetworkservices")
check(!sp.disable() && fm.fileExists(atPath: rec), "turning off says it failed, and keeps the record, when the networks cannot be listed")
behaveAgain()
misbehave("fail", "-getwebproxy", "Wi-Fi")
check(!sp.disable() && fm.fileExists(atPath: rec), "turning off says it failed, and keeps the record, when one proxy cannot be read")
behaveAgain()
check(sp.disable() && pacRestored() && !fm.fileExists(atPath: rec), "and the next try finishes the job")
rec = fresh()
sp = SystemProxy(port: 59999, recordPath: rec)
_ = sp.enable()
misbehave("fail", "-setwebproxystate", "Wi-Fi")
check(!sp.disable() && fm.fileExists(atPath: rec), "turning off says it failed when a setting cannot be written")
behaveAgain()
sp.disable()

print("No change without a recovery record")
_ = fresh()
r = SystemProxy(port: 59999, recordPath: "/nonexistent-kagewon-folder/record.json").enable()
check(r.error != nil && r.error!.contains("recovery file"), "turning on is refused when the record cannot be written: \(r.error ?? "-")")
check(val("webproxy.en", "Wi-Fi") == "" && val("securewebproxy.en", "Ethernet") == "", "and no setting was touched")
rec = fresh()
_ = SystemProxy(port: 59999, recordPath: rec).enable()
check(!fm.fileExists(atPath: rec + ".tmp"), "no temporary file is left next to the record")
SystemProxy(port: 59999, recordPath: rec).disable()
let privateFile = work + "/private.txt"
check(createPrivateFile(atPath: privateFile, contents: Data("x".utf8)) && ((try? fm.attributesOfItem(atPath: privateFile))?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "a private file is created with mode 600 in one step")
check(!createPrivateFile(atPath: privateFile), "and an existing file is never reused")
let logFile = work + "/app.log"
check(appendPrivate(Data("a".utf8), toPath: logFile) && appendPrivate(Data("b".utf8), toPath: logFile)
      && ((try? fm.attributesOfItem(atPath: logFile))?[.posixPermissions] as? NSNumber)?.intValue == 0o600
      && (try? String(contentsOfFile: logFile, encoding: .utf8)) == "ab", "a log file is created with mode 600 and appended to")
let cappedLog = work + "/capped.log"
let chunk = Data(String(repeating: "x", count: 99) .appending("\n").utf8)
for _ in 0..<60 { appendPrivate(chunk, toPath: cappedLog, maxBytes: 1000) }
let cappedSize = ((try? fm.attributesOfItem(atPath: cappedLog))?[.size] as? NSNumber)?.intValue ?? -1
let cappedText = (try? String(contentsOfFile: cappedLog, encoding: .utf8)) ?? ""
check(cappedSize > 0 && cappedSize <= 1000 + 100, "a log that reaches its limit is emptied instead of growing (size \(cappedSize))")
check(cappedText.contains("was removed because it reached") && cappedText.hasSuffix(String(repeating: "x", count: 99) + "\n"), "it starts again with a note, and the newest lines are kept")
check(((try? fm.attributesOfItem(atPath: cappedLog))?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "and stays private")

print("A stuck command cannot freeze the app")
_ = fresh()
check(shell("/bin/echo", ["hi"]).output == "hi", "a normal command returns its output")
misbehave("hang", "-getwebproxy", "Wi-Fi")
let began = Date()
let stuck = shell(networksetup, ["-getwebproxy", "Wi-Fi"], timeout: 1)
let waited = Date().timeIntervalSince(began)
check(waited < 4 && stuck.status != 0 && stuck.output.contains("timed out"), String(format: "a command that never finishes is stopped and reported (%.1f s): %@", waited, stuck.output))
behaveAgain()
check(answerOK(status: 0, output: "Enabled: Yes") && !answerOK(status: 1, output: "") && !answerOK(status: 0, output: "** Error: The parameters were not valid.")
      && !answerOK(status: 0, output: "Foo is not a recognized network service.") && answerOK(status: 0, output: ""), "an answer is only trusted when it exited normally and printed no error line")

print("Showing the sticky time")
let shown: [(Int, String)] = [(30, "30 s"), (60, "1 min"), (90, "1 min 30 s"), (600, "10 min"), (3600, "60 min"), (3630, "60 min 30 s"), (14400, "240 min")]
for (seconds, text) in shown { check(formatDuration(seconds: seconds) == text, "\(seconds) seconds is shown as \"\(text)\" (got \"\(formatDuration(seconds: seconds))\")") }

print("Recognising the helper after a crash")
let withDays: TimeInterval = 2 * 86400 + 3 * 3600 + 4 * 60 + 5
let understood = parseElapsed("05:07") == 307 && parseElapsed(" 1:02:03 ") == 3723 && parseElapsed("2-03:04:05") == withDays
check(understood, "the running time printed by ps is understood")
let refused = [parseElapsed("garbage"), parseElapsed("12"), parseElapsed("-5:00"), parseElapsed("")].allSatisfy { $0 == nil }
check(refused, "and anything else is refused, so an unclear answer never leads to killing a process")
check(isOurHelper(exe: "/opt/homebrew/bin/node", command: "/opt/homebrew/bin/node /Users/me/kagewon/proxy.mjs", proxyDir: "/Users/me/kagewon"), "node running this folder's proxy.mjs is our helper")
check(!isOurHelper(exe: "/usr/bin/vim", command: "vim /Users/me/kagewon/proxy.mjs", proxyDir: "/Users/me/kagewon"), "an editor that reused the pid is not")
check(!isOurHelper(exe: "/opt/homebrew/bin/node", command: "/opt/homebrew/bin/node /Users/me/other/proxy.mjs", proxyDir: "/Users/me/kagewon"), "node running another folder's file is not")

print("Holding the port")
let holder = PortHolder()
let port = 49000 + Int(getpid() % 500)
check(holder.hold(port: port), "the port is taken")
func connectOnce() -> Bool {
    let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
    var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    guard ok else { return false }
    var byte: UInt8 = 0
    var tv = timeval(tv_sec: 2, tv_usec: 0); setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return recv(s, &byte, 1, 0) == 0 // the other side closed without sending anything
}
check(connectOnce(), "a connection is accepted and dropped at once")
check(!PortHolder().hold(port: port), "a second holder cannot take the same port")
holder.release()
check(!connectOnce(), "after release nothing listens any more")
let again = PortHolder()
check(again.hold(port: port), "and the port can be taken again straight away")
again.release()

print("Quitting")
SystemProxy.closeForQuit()
rec = fresh()
let late = SystemProxy(port: 59999, recordPath: rec).enable()
check(late.error != nil && val("webproxy.en", "Wi-Fi") == "", "nothing is switched on once the app is quitting (\(late.error ?? "-"))")

try? fm.removeItem(atPath: work)
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

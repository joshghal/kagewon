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

#!/usr/bin/env python3
"""Makes the scratch copy of the app and helper that the demonstration runs. The real sources are never changed.

Usage: patch.py <repo root> <demo folder> <node path>
Every replacement asserts that its anchor exists, so a change in the real code that breaks a patch is noticed.
"""
import os, re, shutil, sys

root, demo, node = sys.argv[1:4]
proj, build = f'{demo}/proj', f'{demo}/build'
for d in (proj, build):
    shutil.rmtree(d, ignore_errors=True)
os.makedirs(proj); os.makedirs(build)

# ---- the helper: a copy of the project folder
for name in ('proxy.mjs', 'package.json'):
    shutil.copy(f'{root}/{name}', f'{proj}/{name}')
shutil.copytree(f'{root}/src', f'{proj}/src')
os.symlink(f'{root}/node_modules', f'{proj}/node_modules')
open(f'{proj}/config.json', 'w').write('{"version": 1, "rotation": "sticky", "stickySeconds": 120, "port": 18888, "refreshMinutes": 15, "verbose": false, "rotateOpenConnections": true, "killSwitch": false, "providers": []}\n')
os.chmod(f'{proj}/config.json', 0o600)

def edit(path, pairs):
    s = open(path, encoding='utf-8').read()
    for old, new in pairs:
        assert s.count(old) == 1, (path, old[:70], s.count(old))
        s = s.replace(old, new)
    open(path, 'w', encoding='utf-8').write(s)

edit(f'{proj}/src/providers.mjs', [
    ("const urls = ['https://api.ipify.org', 'https://icanhazip.com'];", "const urls = ['http://ip.example.com/']; // demonstration: a stand-in for the IP echo service"),
    ("    label: `${host}:${port}`,", "    label: `203.0.113.${10 + port - 29101}:${8000 + port - 29101}`, // demonstration: show documentation addresses"),
])
edit(f'{proj}/src/manager.mjs', [
    ("  async checkHealth() {\n", "  async checkHealth() {\n    await new Promise(r => setTimeout(r, 1400)); // demonstration: slow enough to show the step\n"),
])

# ---- the app: patched copies of the Swift sources
for name in ('main.swift', 'System.swift', 'Model.swift', 'Views.swift', 'Glyph.swift'):
    shutil.copy(f'{root}/menubar/{name}', f'{build}/{name}')

wrapper = f'{demo}/networksetup'
edit(f'{build}/System.swift', [
    ('var networksetup = "/usr/sbin/networksetup"', f'var networksetup = "{wrapper}"'),
])

lookup = f'''nonisolated static func lookupIP(viaSystemSettings: Bool) async -> String? {{
        // demonstration: canned answers from documentation address ranges, no network
        let mode = (try? String(contentsOfFile: "{proj}/lookup-mode", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ok"
        if !viaSystemSettings {{ return "198.51.100.23" }}
        return mode == "leak" ? "198.51.100.23" : "203.0.113.44"
    }}'''
model = open(f'{build}/Model.swift', encoding='utf-8').read()
m = re.search(r'    nonisolated static func lookupIP\(viaSystemSettings: Bool\) async -> String\? \{.*?\n    \}\n', model, re.S)
assert m, 'lookupIP not found'
model = model[:m.start()] + '    ' + lookup + '\n' + model[m.end():]
open(f'{build}/Model.swift', 'w', encoding='utf-8').write(model)
edit(f'{build}/Model.swift', [
    ('FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kagewon.log")', f'URL(fileURLWithPath: "{proj}/app.log")'),
    ('?? 8889', '?? 18889'),
    ('        env["CONTROL_PORT"] = String(controlPort)\n', '        env["CONTROL_PORT"] = String(controlPort)\n        env["KAGEWON_DEV"] = "1"\n        env["WEBSHARE_API_BASE"] = "http://127.0.0.1:29100"\n'),
    ('        watchTheNetwork()\n    }', '        watchTheNetwork()\n        startDemoDriver()\n    }'),
])
open(f'{build}/Model.swift', 'a', encoding='utf-8').write('\n' + open(f'{root}/scripts/demo/driver.swift', encoding='utf-8').read())

views = open(f'{build}/Views.swift', encoding='utf-8').read()
assert views.count('        f.dateFormat = "HH:mm:ss"\n') == 2
views = views.replace('        f.dateFormat = "HH:mm:ss"\n', '        f.dateFormat = "HH:mm:ss"\n        f.timeZone = TimeZone(identifier: "UTC") // demonstration: no local time zone in the pictures\n')
open(f'{build}/Views.swift', 'w', encoding='utf-8').write(views)

edit(f'{build}/main.swift', [
    ('        popover.behavior = .transient\n', '        popover.behavior = .applicationDefined // demonstration: stays open while it is recorded\n'),
    ('            self?.popover.behavior = editing ? .applicationDefined : .transient\n', '            self?.popover.behavior = .applicationDefined\n'),
    ('        model.start()\n', '        model.start()\n        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in if self?.popover.isShown == false { self?.togglePopover() } }\n'),
])

# ---- the stand-in for networksetup (it keeps its state in a folder and is a little slow, like the real one)
os.makedirs(f'{demo}/network-state', exist_ok=True)
open(f'{demo}/network-state/services', 'w').write('Wi-Fi\nEthernet\n')
open(wrapper, 'w').write(f'#!/bin/bash\nFAKE_NS="{demo}/network-state" FAKE_NS_DELAY=0.12 exec "{root}/menubar/tests/fake-networksetup" "$@"\n')
os.chmod(wrapper, 0o755)
open(f'{proj}/lookup-mode', 'w').write('ok\n')
print('demo sources ready')

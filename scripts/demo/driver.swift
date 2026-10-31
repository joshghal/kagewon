// MARK: - Demonstration driver (only in the demonstration build, never in the real app)

/// Reads commands from a file in the project folder and runs them on the model, so every flow can be recorded the same way
/// each time. One command per line: "tab providers", "add webshare", "key demo-...", "testdraft", "save", "power"...
extension AppModel {
    func startDemoDriver() {
        let path = proxyDir + "/cmd.txt"
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(atPath: path)
                for line in text.split(separator: "\n") { self.demoRun(String(line)) }
            }
        }
    }

    func demoRun(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "tab": tab = ["home": Tab.home, "providers": .providers, "activity": .activity][arg] ?? .home
        case "settings": showSettings()
        case "add": beginAdd(arg)
        case "key": draft.apiKey = arg
        case "countries": draft.countries = arg
        case "testdraft": testDraft()
        case "testsaved": if let p = status?.providers.first { testSaved(p.id) }
        case "save": saveDraft()
        case "cancel": cancelEdit()
        case "edit": if let p = status?.providers.first { beginEdit(p) }
        case "power": togglePower()
        case "rotation": setRotation(arg)
        case "sticky": setStickySeconds(Int(arg) ?? 60)
        case "verbose": loadSettingsDraft(); settings.verbose = (arg == "on"); saveSettings()
        case "killswitch": loadSettingsDraft(); settings.killSwitch = (arg == "on"); saveSettings()
        case "torguide": torGuideOpen = (arg == "on")
        default: break
        }
    }
}

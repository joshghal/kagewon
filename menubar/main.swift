import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let model = AppModel()
    var cancellables = Set<AnyCancellable>()
    var signalSources: [DispatchSourceSignal] = []
    private var spinTimer: Timer?
    private var spinStep = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy at a time, otherwise the second one would kill the first one's helper.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            model.isDuplicate = true // so quitting does not switch off the proxy that the first copy is running
            NSApp.terminate(nil)
            return
        }

        popover.contentSize = NSSize(width: 360, height: 540)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: RootView(model: model))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.$phase.receive(on: RunLoop.main).sink { [weak self] in self?.updateIcon($0) }.store(in: &cancellables)
        // While a form is open, keep the panel up even if you click another app to copy an API key.
        model.$isEditing.receive(on: RunLoop.main).sink { [weak self] editing in
            self?.popover.behavior = editing ? .applicationDefined : .transient
        }.store(in: &cancellables)
        updateIcon(model.phase)

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }

        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !model.shutdown() {
            // Quitting is the last chance to say it: after this nothing is left that could switch the settings off.
            let alert = NSAlert()
            alert.messageText = "Kagewon could not confirm that the proxy settings are off"
            alert.informativeText = "If your internet does not work, open System Settings, Network, your connection, Details, Proxies and switch the proxies off, or use the recovery command in the README."
            alert.runModal()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverOpen = false
    }

    func updateIcon(_ phase: Phase) {
        guard let button = statusItem.button else { return }
        spinTimer?.invalidate()
        spinTimer = nil
        switch phase {
        case .launching, .starting:
            // The dashes travel around the circle while connecting. Not with Reduce Motion, and not for longer than it takes.
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                spinStep = 0
                let timer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.spinStep += 1
                        self.statusItem.button?.image = menuBarGlyph(for: self.model.phase, spin: self.spinStep)
                    }
                }
                RunLoop.main.add(timer, forMode: .common) // also while a menu is open
                spinTimer = timer
            }
        default:
            break
        }
        button.image = menuBarGlyph(for: phase)
        button.image?.accessibilityDescription = "Kagewon"
        button.title = ""
    }

    @objc func statusClicked(_ sender: Any?) {
        // Accessibility presses (VoiceOver, scripts) arrive without an event: treat them as a left click.
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.popoverShown()
    }

    func showContextMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: model.isOn ? "Turn Off" : "Turn On", action: #selector(quickToggle), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !model.isBusy
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func quickToggle() { model.togglePower() }
    @objc func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run() // blocks until quit, which keeps `delegate` alive
}

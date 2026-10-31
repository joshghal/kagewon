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
        model.shutdown()
    }

    /// The menu bar mark: a ring, plus a disc inside it when on, a dashed ring while connecting, and a "!" on error.
    func glyph(for phase: Phase) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2.25, y: 2.25, width: 13.5, height: 13.5))
            ring.lineWidth = 1.7
            switch phase {
            case .starting, .launching: ring.setLineDash([2.2, 2.2], count: 2, phase: 0)
            default: break
            }
            ring.stroke()
            switch phase {
            case .on:
                NSBezierPath(ovalIn: NSRect(x: 6.3, y: 4.3, width: 7, height: 7)).fill()
            case .error:
                NSBezierPath(rect: NSRect(x: 8.2, y: 6.6, width: 1.6, height: 5.2)).fill()
                NSBezierPath(ovalIn: NSRect(x: 8.0, y: 4.2, width: 2.0, height: 2.0)).fill()
            default: break
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverOpen = false
    }

    func updateIcon(_ phase: Phase) {
        guard let button = statusItem.button else { return }
        button.image = glyph(for: phase)
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

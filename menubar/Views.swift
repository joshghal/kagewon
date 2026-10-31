import SwiftUI
import AppKit

// MARK: - Small building blocks

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

func phaseColor(_ phase: Phase) -> Color {
    switch phase {
    case .launching: return .gray
    case .off: return Color(nsColor: .systemGray)
    case .starting: return .orange
    case .on: return .green
    case .error: return .red
    }
}

func typeIcon(_ type: String) -> String { type == "tor" ? "eye.slash.fill" : "cloud.fill" }

func typeName(_ type: String) -> String { type == "tor" ? "Tor" : "Webshare" }

/// Tor is one local entry point that hands out many exit IPs, not a list of proxies.
func isGatewayType(_ type: String) -> Bool { type == "tor" }

func torDetail(_ p: ProviderInfo, running: Bool) -> String {
    var t = running ? "Tor running on 127.0.0.1:\(p.socksPort ?? 9250)" : "Free, starts with the proxy"
    let c = p.exitCountries ?? []
    if !c.isEmpty { t += ", exit in \(c.joined(separator: ", "))" }
    return t
}

/// One line describing a provider, and the colour to show it in.
func providerLine(_ p: ProviderInfo) -> (text: String, color: Color) {
    if !p.enabled { return ("Disabled", .secondary) }
    if let e = p.runtime.error { return (e, .red) }
    if p.runtime.status == "ok" {
        if p.type == "tor" { return (torDetail(p, running: true), .secondary) }
        return ("\(p.runtime.healthy) of \(p.runtime.count) proxies healthy", p.runtime.healthy == 0 ? .orange : .secondary)
    }
    if p.type == "tor" { return (torDetail(p, running: false), .secondary) }
    let c = p.countries ?? []
    return (c.isEmpty ? "Webshare account, all countries" : "Webshare account, \(c.joined(separator: ", "))", .secondary)
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider().opacity(0.5)
            Group {
                switch model.tab {
                case .home: HomeView(model: model)
                case .providers: ProvidersView(model: model)
                case .activity: ActivityView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            FooterBar(model: model)
        }
        .frame(width: 360, height: 540)
    }
}

// MARK: - Header (status + power switch)

struct HeaderView: View {
    @ObservedObject var model: AppModel

    private var subtitle: String {
        switch model.phase {
        case .launching: return "Starting helper..."
        case .off: return "Off, traffic goes direct"
        case .starting: return "Connecting..."
        case .on:
            let active = (model.status?.providers ?? []).filter { $0.enabled && $0.runtime.status == "ok" }
            if !active.isEmpty && active.allSatisfy({ isGatewayType($0.type) }) {
                return "On, rotating via \(active.map(\.name).joined(separator: ", "))"
            }
            let n = active.reduce(0) { $0 + $1.runtime.healthy }
            return "On, \(n) \(n == 1 ? "proxy" : "proxies") ready"
        case .error(let m): return m
        }
    }

    private var power: Binding<Bool> {
        Binding(get: { model.isOn || model.phase == .starting }, set: { _ in model.togglePower() })
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(phaseColor(model.phase))
                KagewonMark(filled: model.isOn)
                    .frame(width: 24, height: 24)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Kagewon").font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle({ if case .error = model.phase { return Color.red } else { return Color.secondary } }())
                    .lineLimit(2)
            }
            Spacer(minLength: 8)

            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: power)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.isBusy)
        }
        .padding(16)
    }
}

// MARK: - Home

struct Tile: View {
    let title: String
    let value: String
    let caption: String
    var action: (() -> Void)? = nil
    var busy = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionTitle(title)
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else if let action {
                        Button(action: action) { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Check again")
                    }
                }
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: AppModel

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var healthy: Int { model.status?.providers.reduce(0) { $0 + $1.runtime.healthy } ?? 0 }
    private var total: Int { model.status?.providers.reduce(0) { $0 + $1.runtime.count } ?? 0 }
    private var rotation: String { model.status?.rotation ?? "sticky" }
    /// Tor and gateways are one entry point that hands out many IPs, so "1 proxy" would be misleading.
    private var allGateways: Bool {
        let active = (model.status?.providers ?? []).filter { $0.enabled && $0.runtime.status == "ok" }
        return !active.isEmpty && active.allSatisfy { isGatewayType($0.type) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let warning = model.leakWarning {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Your real IP may be exposed", systemImage: "exclamationmark.shield.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text(warning).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if case .error(let msg) = model.phase {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.red)
                            Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Try Again") { model.togglePower() }.controlSize(.small)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Tile(title: "Exit IP",
                         value: model.isOn ? (model.exitIP ?? "checking...") : "Off",
                         caption: model.isOn ? (model.ipCheckedAt.map { "Seen by ipify at \(Self.clock.string(from: $0))" } ?? "Seen by ipify") : "Turn on to see it",
                         action: model.isOn ? { Task { await model.refreshIP() } } : nil,
                         busy: model.ipBusy)
                    Tile(title: allGateways ? "Source" : "Proxies",
                         value: !model.isOn ? "Off" : (allGateways ? "Rotating" : "\(healthy)/\(total)"),
                         caption: !model.isOn ? "Not loaded" : (allGateways ? "gateway picks the IP" : "healthy"))
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("IP rotation")
                        Picker("Rotation", selection: Binding(get: { rotation }, set: { model.setRotation($0) })) {
                            Text("Sticky").tag("sticky")
                            Text("Random").tag("random")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(rotation == "sticky"
                             ? "Each site keeps one IP, so logins keep working."
                             : "A new IP on every connection. Logins may break.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if rotation == "sticky" {
                            let minutes = model.status?.stickyMinutes ?? 10
                            Divider().opacity(0.4)
                            // Each setting is a row: the label on the left, its control on the right.
                            HStack {
                                Text("Keep each IP for").font(.system(size: 12))
                                Spacer()
                                Text("\(minutes) min").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                Stepper("", value: Binding(get: { minutes }, set: { model.setStickyMinutes($0) }), in: 1...240)
                                    .labelsHidden()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("Change the IP by itself when time is up").font(.system(size: 12))
                                    Spacer(minLength: 4)
                                    Toggle("", isOn: Binding(get: { model.status?.rotateOpenConnections ?? true },
                                                             set: { model.setRotateOpenConnections($0) }))
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .labelsHidden()
                                }
                                Text("Closes a site's open connections so apps reconnect with a new IP. Turn off if downloads or streams get interrupted.")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionTitle("Providers")
                            Spacer()
                            Button("Manage") { model.tab = .providers }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        let providers = model.status?.providers ?? []
                        if providers.isEmpty {
                            Text("No provider yet. Add one to get started.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(providers.prefix(4)) { p in
                            let line = providerLine(p)
                            HStack(spacing: 8) {
                                Circle().fill(p.enabled ? (p.runtime.error != nil ? Color.red : Color.green) : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                                Text(p.name).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(line.text).font(.system(size: 10)).foregroundStyle(line.color).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Providers

struct ProvidersView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isEditing {
            ProviderForm(model: model)
        } else {
            VStack(spacing: 0) {
                HStack {
                    SectionTitle("Providers")
                    Spacer()
                    Menu {
                        Button("Webshare (API key)") { model.beginAdd("webshare") }
                        Button("Tor (free, slower)") { model.beginAdd("tor") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                ScrollView {
                    VStack(spacing: 8) {
                        let providers = model.status?.providers ?? []
                        if providers.isEmpty {
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("No providers yet").font(.system(size: 13, weight: .semibold))
                                    Text("Add your Webshare account, or use Tor for free.")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(providers) { p in ProviderRow(model: model, p: p) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

struct ProviderRow: View {
    @ObservedObject var model: AppModel
    let p: ProviderInfo

    var body: some View {
        let line = providerLine(p)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: typeIcon(p.type))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.name).font(.system(size: 13, weight: .semibold))
                            Text(typeName(p.type))
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                                .foregroundStyle(.secondary)
                        }
                        Text(line.text)
                            .font(.system(size: 10))
                            .foregroundStyle(line.color)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Toggle("", isOn: Binding(get: { p.enabled }, set: { model.setEnabled(p, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    Menu {
                        Button("Edit...") { model.beginEdit(p) }
                        Button("Test connection") { model.testSaved(p.id) }
                        Divider()
                        Button("Delete...") { model.pendingDelete = p.id }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if let t = model.tests[p.id] { TestBadge(state: t) }

                if model.pendingDelete == p.id {
                    HStack {
                        Text("Delete \(p.name)?").font(.system(size: 11))
                        Spacer()
                        Button("Cancel") { model.pendingDelete = nil }.controlSize(.small)
                        Button("Delete") { model.deleteProvider(p.id) }.controlSize(.small).tint(.red)
                    }
                }
            }
        }
    }
}

struct TestBadge: View {
    let state: TestState
    var body: some View {
        switch state {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Testing...").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .done(let ok, let text):
            Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Color.green : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Field<Content: View>: View {
    let title: String
    var hint: String? = nil
    let content: Content
    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProviderForm: View {
    @ObservedObject var model: AppModel

    private var d: Binding<ProviderDraft> { $model.draft }
    private var editing: Bool { model.draft.id != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.cancelEdit() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(editing ? "Edit \(typeName(model.draft.type))" : "Add \(typeName(model.draft.type))")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Field("Name") {
                        TextField(typeName(model.draft.type), text: d.name).textFieldStyle(.roundedBorder)
                    }

                    if model.draft.type == "tor" {
                        TorGuide(model: model)
                        Field("Exit countries (optional)", hint: "Two-letter codes, e.g. US, DE. Fewer countries means fewer exits and slower connections. Empty = any.") {
                            TextField("US, DE", text: d.exitCountries).textFieldStyle(.roundedBorder)
                        }
                        Field("Local port", hint: "Tor listens on this local port, and only while the proxy is on. It needs Tor installed (brew install tor). Many sites block Tor, and sticky sessions are best effort.") {
                            TextField("9250", text: d.socksPort).textFieldStyle(.roundedBorder).frame(width: 90)
                        }
                    } else {
                        Field("API key", hint: "In your Webshare dashboard, open Settings, then API.") {
                            SecureField(editing && !model.draft.apiKeyHint.isEmpty ? "\(model.draft.apiKeyHint) (unchanged)" : "Paste your API key", text: d.apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Field("Countries (optional)", hint: "Two-letter codes, e.g. US, GB, DE. Empty = all.") {
                            TextField("US, GB", text: d.countries).textFieldStyle(.roundedBorder)
                        }
                    }

                    Stepper(value: d.weight, in: 1...10) {
                        Text("Traffic share: \(model.draft.weight)").font(.system(size: 12))
                    }
                    Text("When several providers are on, higher numbers get used more often.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)

                    if let t = model.tests["draft"] { TestBadge(state: t) }
                    if let e = model.formError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider().opacity(0.5)
            HStack {
                Button("Test") { model.testDraft() }
                    .disabled(model.tests["draft"] == .running)
                Spacer()
                Button("Cancel") { model.cancelEdit() }
                Button("Save") { model.saveDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSaving)
            }
            .padding(12)
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @ObservedObject var model: AppModel

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func duration(_ s: Int) -> String { s >= 60 ? "\(s / 60) min" : "\(s) s" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle("Active sites")
                    let sites = model.status?.sites ?? []
                    if sites.isEmpty {
                        Text(model.status?.rotation == "random" ? "Random mode does not pin sites." : "No sites yet. Browse something.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(sites.prefix(6)) { s in
                        HStack(spacing: 6) {
                            Text(s.site).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text("\(s.provider), \(s.proxy)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            Text(duration(s.expiresIn)).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }

            SectionTitle("Log")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.logLines.isEmpty {
                            Text("Nothing yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(model.logLines) { l in
                            Text("\(Self.clock.string(from: Date(timeIntervalSince1970: l.t / 1000)))  \(l.msg)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(l.level == "warn" ? Color.orange : Color.primary.opacity(0.8))
                                .textSelection(.enabled)
                                .id(l.id)
                        }
                    }
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .onChange(of: model.logLines.count) { _ in
                    if let last = model.logLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(14)
        .onAppear {
            model.activityVisible = true
            Task { await model.refreshLog() }
        }
        .onDisappear { model.activityVisible = false }
    }
}

// MARK: - Footer

struct FooterBar: View {
    @ObservedObject var model: AppModel

    private func tabButton(_ tab: Tab, _ icon: String, _ title: String) -> some View {
        Button { model.tab = tab } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 9, weight: .medium))
            }
            .frame(width: 64, height: 36)
            .foregroundStyle(model.tab == tab ? Color.accentColor : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.tab == tab ? Color.accentColor.opacity(0.12) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.home, "gauge.with.dots.needle.50percent", "Dashboard")
            tabButton(.providers, "server.rack", "Providers")
            tabButton(.activity, "list.bullet.rectangle", "Activity")
            Spacer()
            Menu {
                Button("Settings...") { model.showSettings() }
                Button("Open Log File") { model.openLogFile() }
                Divider()
                Button("Quit Kagewon") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Provider notes and the Tor setup guide

struct TorGuide: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DisclosureGroup(isExpanded: $model.torGuideOpen) {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Install Homebrew (skip this if you already have it). It is the standard way to install Mac tools.")
                step(2, "Open Terminal and run:  brew install tor")
                step(3, "Come back here, save this provider and switch it on.")
                step(4, "Press Test. The first start can take up to a minute while Tor connects to the network.")
                HStack(spacing: 8) {
                    Button("Copy install command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install tor", forType: .string)
                    }
                    Button("Get Homebrew") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                }
                .controlSize(.small)
                Text("Tor runs only while the proxy is on and stops with it, so there is no background service to manage. It is slower than paid proxies and many websites block it. Sticky sessions are best effort.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            Label("Set up Tor from scratch", systemImage: "questionmark.circle")
                .font(.system(size: 12, weight: .medium))
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 10, weight: .bold)).frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Settings")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Field("Local proxy port", hint: "1024 to 65535. Applies the next time you turn the proxy on.") {
                            TextField("8888", text: $model.settings.port).textFieldStyle(.roundedBorder).frame(width: 90)
                        }
                        Stepper(value: $model.settings.refreshMinutes, in: 1...240) {
                            Text("Refresh provider lists every \(model.settings.refreshMinutes) min").font(.system(size: 12))
                        }
                        Toggle("Log which proxy each site uses", isOn: $model.settings.verbose)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Kill switch: block the internet if the proxy stops", isOn: $model.settings.killSwitch)
                                .font(.system(size: 12))
                            Text("If the helper stops, the Mac stays pointed at the proxy and Kagewon keeps that port closed, so apps that follow the Mac's proxy settings cannot connect. Use it if you prefer losing the connection to exposing your real IP. Press Try Again or quit the app to restore it.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Save") { model.saveSettings() }.keyboardShortcut(.defaultAction)
                    if let m = model.settingsMessage {
                        Label(m, systemImage: model.settingsOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(model.settingsOK ? Color.green : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Where your keys are stored")
                        Text("Your Webshare key is pasted in the Providers tab and saved in config.json, which only your user account can read. It is not encrypted, so any program running as you can read it. There is no .env file.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("The proxy covers every active network, but only apps that follow the Mac's proxy settings. While it is on, automatic proxy settings (PAC file, proxy discovery) are switched off and are restored when you turn it off. The log file never contains the sites you visit.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Show config file") { model.openConfigFolder() }
                            Button("Open log file") { model.openLogFile() }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Brand mark

/// The Kagewon mark: a ring (the circle, 원) with a disc offset inside it (the shadow, 影). The disc appears when the proxy is on.
struct KagewonMark: View {
    var filled: Bool
    var color: Color = .white

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle()
                    .stroke(color, style: StrokeStyle(lineWidth: s * 0.1, lineCap: .round))
                    .frame(width: s * 0.74, height: s * 0.74)
                if filled {
                    Circle()
                        .fill(color)
                        .frame(width: s * 0.38, height: s * 0.38)
                        .offset(x: s * 0.07, y: s * 0.08)
                }
            }
            .frame(width: s, height: s)
        }
    }
}

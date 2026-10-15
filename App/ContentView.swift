import NetworkExtension
import ProxyCore
import SwiftUI

@main
struct ProxyApp: App {
    @StateObject private var tunnel = TunnelController()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tunnel)
                .task { await tunnel.load() }
                .onChange(of: phase) { p in
                    if p == .active { tunnel.startPolling() } else { tunnel.stopPolling() }
                }
        }
    }
}

/// The unlock screen until the sealed subscriptions are open (once per device), then the main screen.
struct RootView: View {
    @EnvironmentObject var tunnel: TunnelController
    var body: some View {
        if tunnel.locked { UnlockView() } else { ContentView() }
    }
}

struct UnlockView: View {
    @EnvironmentObject var tunnel: TunnelController
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Unlock Proxy").font(.title2.weight(.semibold))
            Text("Enter the unlock password once. It opens the subscriptions built into this app and stays in this device's Keychain.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit { tunnel.unlock(password) }
                .accessibilityIdentifier("unlock-password")
            Button("Unlock") { tunnel.unlock(password) }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
                .accessibilityIdentifier("unlock-button")
            if let e = tunnel.unlockError {
                Text(e).font(.callout).foregroundStyle(.red).accessibilityIdentifier("unlock-error")
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelController

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(get: { tunnel.connected || tunnel.status == .connecting },
                                         set: { on in Task { await tunnel.setConnected(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VPN").font(.headline)
                            Text(statusText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(tunnel.working || tunnel.mock != nil)
                    .accessibilityIdentifier("vpn-toggle")
                    #if os(macOS)
                    if tunnel.sysext.needsApproval {
                        Text("Allow Proxy's network extension in System Settings → General → Login Items & Extensions → Network Extensions. Connecting carries on once it is allowed.")
                            .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("sysext-approval")
                    }
                    #endif
                    if let m = tunnel.message {
                        Text(m).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("message")
                    }
                }
                if tunnel.connected, let state = tunnel.state {
                    Section {
                        Button {
                            Task { await tunnel.runTest() }
                        } label: {
                            HStack {
                                Text("Test connectivity and latency").fontWeight(.semibold)
                                Spacer()
                                if tunnel.testing { ProgressView() }
                            }
                        }
                        .disabled(tunnel.testing)
                        .accessibilityIdentifier("test-button")
                        ForEach(tunnel.testLines, id: \.self) { line in
                            Text(line).font(.footnote.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    NetworkSection()
                    ForEach(state.groups) { g in
                        GroupSection(group: g, health: tunnel.health?.entries[g.tag])
                    }
                    Section {
                        Text("Fully automatic. Each group uses its fastest valid candidate: China needs an exit in mainland China, International one outside it, AI one outside mainland China and Hong Kong. Going direct is a candidate whenever this network's own exit is valid for the group; the network is checked again on every network change. Delays are each candidate's last test (one HTTP request through it). The real check loads a real page through the candidate in use every few minutes and after every network change; if it fails, the group switches to the fastest candidate that passes until the fastest one works again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if tunnel.connected {
                    Section {
                        ProgressView("Loading…")
                        if let e = tunnel.apiError { Text(e).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("api-error") }
                    }
                }
            }
            .navigationTitle("Proxy")
            .toolbar {
                if tunnel.connected && tunnel.mock == nil {
                    Button {
                        Task { await tunnel.refreshSubscriptions() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(tunnel.working)
                        .accessibilityLabel("Refresh subscriptions")
                }
            }
        }
    }

    var statusText: String {
        if tunnel.mock != nil { return "Test mode (desktop sing-box)" }
        switch tunnel.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .reasserting: return "Reconnecting…"
        case .disconnected: return tunnel.working ? "Fetching subscriptions…" : "Off"
        default: return tunnel.working ? "Setting up…" : "Off"
        }
    }
}

struct NetworkSection: View {
    @EnvironmentObject var tunnel: TunnelController

    var body: some View {
        Section("This network") {
            if let p = tunnel.probe {
                ForEach(Plan.groups, id: \.tag) { g in
                    let v = p.verdicts[g.tag]
                    HStack {
                        Text("\(g.title) direct").font(.subheadline)
                        Spacer()
                        Text(v?.exit ?? "no answer").font(.subheadline).foregroundStyle(.secondary)
                        Image(systemName: v?.valid == true ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(v?.valid == true ? Color.green : Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("probe-\(g.tag)")
                    .accessibilityValue(v?.valid == true ? "valid" : "invalid")
                }
            } else {
                Text("Checking where this network exits…").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await tunnel.recheckNetwork() }
            } label: {
                HStack {
                    Text("Check this network again")
                    Spacer()
                    if tunnel.probing { ProgressView() }
                }
            }
            .disabled(tunnel.probing)
            .accessibilityIdentifier("recheck-button")
        }
    }
}

struct GroupSection: View {
    let group: ProxyState.Group
    let health: HealthReport.Entry?

    var body: some View {
        Section(group.title) {
            HStack {
                Text("Using").font(.subheadline.weight(.semibold))
                Spacer()
                Text(group.currentCandidate.map { "\($0.name) · \(delayText($0.delay))" } ?? "–")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("using-\(group.tag)")
            .accessibilityValue(group.currentCandidate?.name ?? "")
            HealthLine(group: group, health: health)
            Text(group.directAllowed ? "Direct is valid on this network and races the nodes."
                                     : "Direct is not valid on this network: nodes only.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("direct-\(group.tag)")
                .accessibilityValue(group.directAllowed ? "allowed" : "not allowed")
            ForEach(group.candidates) { n in
                let cur = n.tag == group.current
                HStack {
                    Text(n.name).font(.subheadline.weight(cur ? .semibold : .regular))
                        .foregroundStyle(cur ? Color.green : Color.primary)
                    Spacer()
                    Text(delayText(n.delay)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("node-\(group.tag)-\(n.name)")
            }
        }
    }
}

/// The real check's verdict for a group: passed (with exit and page time), switched away from the fastest
/// candidate, or failed everywhere.
struct HealthLine: View {
    let group: ProxyState.Group
    let health: HealthReport.Entry?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("health-\(group.tag)")
        .accessibilityValue(value)
    }

    var value: String {
        guard let h = health else { return "unchecked" }
        return h.passed ? (h.pinned ? "pinned" : "passed") : "failed"
    }
    var icon: String {
        switch value {
        case "passed": return "checkmark.seal.fill"
        case "pinned": return "arrow.triangle.swap"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "clock"
        }
    }
    var color: Color {
        switch value {
        case "passed": return .green
        case "pinned": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }
    var text: String {
        guard let h = health else { return "Real check: not run yet" }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        let at = fmt.string(from: h.at)
        let name = h.candidate.map(ProxyState.Candidate.displayName) ?? "–"
        let place = [h.exit, h.ms.map { "\($0) ms" }].compactMap { $0 }.joined(separator: ", ")
        if !h.passed { return "Real check \(at): no candidate loaded a real page (\(h.failed.count) tried)" }
        if h.pinned {
            let fastest = h.failed.first.map(ProxyState.Candidate.displayName) ?? "the fastest"
            return "Real check \(at): \(fastest) failed, switched to \(name) (\(place))"
        }
        return "Real check \(at): \(name) loads real pages (\(place))"
    }
}

func delayText(_ d: Int?) -> String {
    switch d {
    case nil: return "–"
    case 0?: return "timeout"
    case let ms?: return "\(ms) ms"
    }
}

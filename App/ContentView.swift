import NetworkExtension
import ProxyCore
import SwiftUI

@main
struct ProxyApp: App {
    @StateObject private var tunnel = TunnelController()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnel)
                .task { await tunnel.load() }
                .onChange(of: phase) { p in
                    if p == .active { tunnel.startPolling() } else { tunnel.stopPolling() }
                }
        }
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
                        GroupSection(group: g)
                    }
                    Section {
                        Text("Fully automatic. Each group uses its fastest valid candidate: China needs an exit in mainland China, International one outside it, AI one outside mainland China and Hong Kong. Going direct is a candidate whenever this network's own exit is valid for the group; the network is checked again on every network change. Delays are each candidate's last test (one HTTP request through it).")
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

func delayText(_ d: Int?) -> String {
    switch d {
    case nil: return "–"
    case 0?: return "timeout"
    case let ms?: return "\(ms) ms"
    }
}

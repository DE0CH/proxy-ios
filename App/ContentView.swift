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
                    ForEach(state.switches) { sw in
                        SwitchSection(sw: sw)
                    }
                    Section {
                        Text("China goes direct. Delays are each node's last test (one HTTP request through the node). Tap a node to pin it; Auto picks the fastest node of that region and keeps it while it stays within 150 ms of the best.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if tunnel.connected {
                    Section { ProgressView("Loading…") }
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

struct SwitchSection: View {
    @EnvironmentObject var tunnel: TunnelController
    let sw: ProxyState.Switch

    var body: some View {
        Section(sw.title) {
            HStack(spacing: 10) {
                ForEach(sw.regions) { r in
                    let on = r.group == sw.selected
                    Button {
                        if !on { Task { await tunnel.select(sw.tag, r.group) } }
                    } label: {
                        VStack(spacing: 2) {
                            Text(r.label).fontWeight(.semibold)
                            Text(on ? "active" : "switch").font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accentColor : Color.secondary.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("switch-\(r.group)")
                    .accessibilityValue(on ? "active" : "inactive")
                }
            }
            .padding(.vertical, 4)
            ForEach(sw.regions) { r in
                RegionNodes(region: r)
            }
        }
    }
}

struct RegionNodes: View {
    @EnvironmentObject var tunnel: TunnelController
    let region: ProxyState.Region

    var body: some View {
        HStack {
            Text("\(region.label) nodes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if region.auto {
                Text("Auto").font(.caption.weight(.semibold)).foregroundStyle(.green).accessibilityIdentifier("mode-\(region.group)")
                if let cur = region.current {
                    Button("pin this node") { Task { await tunnel.select(region.group, cur) } }
                        .font(.caption).accessibilityIdentifier("pin-\(region.group)")
                }
            } else {
                Text("Pinned").font(.caption.weight(.semibold)).foregroundStyle(.orange).accessibilityIdentifier("mode-\(region.group)")
                Button("use Auto") {
                    Task { await tunnel.select(region.group, region.group + Plan.autoSuffix) }
                }
                .font(.caption).accessibilityIdentifier("auto-\(region.group)")
            }
        }
        .buttonStyle(.borderless)
        ForEach(region.nodes) { n in
            let cur = n.tag == region.current
            Button {
                Task { await tunnel.select(region.group, n.tag) }
            } label: {
                HStack {
                    Text(n.name).font(.subheadline.weight(cur ? .semibold : .regular))
                        .foregroundStyle(cur ? Color.green : Color.primary)
                    Spacer()
                    Text(delayText(n.delay)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("node-\(region.group)-\(n.name)")
        }
    }

    func delayText(_ d: Int?) -> String {
        switch d {
        case nil: return "–"
        case 0?: return "timeout"
        case let ms?: return "\(ms) ms"
        }
    }
}

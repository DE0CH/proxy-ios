import Foundation
import Libbox
import Network
import NetworkExtension

/// libbox's platform hooks for an iOS packet tunnel. Adapted from sing-box-for-apple's ExtensionPlatformInterface
/// (GPL-3.0): openTun maps sing-box's tun options onto NEPacketTunnelNetworkSettings, NWPathMonitor reports the
/// default interface; everything this app doesn't use (shell, SSH, bridges, Tailscale, notifications, neighbours)
/// is a stub.
final class PlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private unowned let tunnel: PacketTunnelProvider
    private var monitor: NWPathMonitor?
    private var lastPath: String?

    init(_ tunnel: PacketTunnelProvider) { self.tunnel = tunnel }

    func reset() {
        monitor?.cancel()
        monitor = nil
        lastPath = nil
    }

    private func unsupported(_ what: String) -> NSError { PacketTunnelProvider.error("\(what) is not supported") }

    // MARK: tun

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else { throw PacketTunnelProvider.error("openTun: missing options") }
        let settings = try networkSettings(options)
        let sem = DispatchSemaphore(value: 0)
        var setError: Error?
        tunnel.setTunnelNetworkSettings(settings) { error in setError = error; sem.signal() }
        sem.wait()
        if let setError { throw setError }
        if let fd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        guard fd != -1 else { throw PacketTunnelProvider.error("openTun: missing file descriptor") }
        ret0_.pointee = fd
    }

    private func networkSettings(_ o: LibboxTunOptionsProtocol) throws -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        guard o.getAutoRoute() else { return s }
        s.mtu = NSNumber(value: o.getMTU())

        var dns: NEDNSSettings?
        if o.getDNSMode()?.value != LibboxDNSModeDisabled {
            let it = try o.getDNSServerAddress()
            var servers: [String] = []
            while it.hasNext() { servers.append(it.next()) }
            if !servers.isEmpty { dns = NEDNSSettings(servers: servers) }
        }

        var v4a: [String] = [], v4m: [String] = []
        if let it = o.getInet4Address() { while it.hasNext() { if let p = it.next() { v4a.append(p.address()); v4m.append(p.mask()) } } }
        let v4 = NEIPv4Settings(addresses: v4a, subnetMasks: v4m)
        var v4routes: [NEIPv4Route] = []
        if let it = o.getInet4RouteAddress(), it.hasNext() {
            repeat { if let p = it.next() { v4routes.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask())) } } while it.hasNext()
        } else {
            v4routes.append(NEIPv4Route.default())
        }
        var v4ex: [NEIPv4Route] = []
        if let it = o.getInet4RouteExcludeAddress() {
            while it.hasNext() { if let p = it.next() { v4ex.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask())) } }
        }
        v4.includedRoutes = v4routes
        v4.excludedRoutes = v4ex
        s.ipv4Settings = v4

        var v6a: [String] = [], v6p: [NSNumber] = []
        if let it = o.getInet6Address() { while it.hasNext() { if let p = it.next() { v6a.append(p.address()); v6p.append(NSNumber(value: p.prefix())) } } }
        if !v6a.isEmpty {
            let v6 = NEIPv6Settings(addresses: v6a, networkPrefixLengths: v6p)
            var v6routes: [NEIPv6Route] = []
            if let it = o.getInet6RouteAddress(), it.hasNext() {
                repeat { if let p = it.next() { v6routes.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix()))) } } while it.hasNext()
            } else {
                v6routes.append(NEIPv6Route.default())
            }
            var v6ex: [NEIPv6Route] = []
            if let it = o.getInet6RouteExcludeAddress() {
                while it.hasNext() { if let p = it.next() { v6ex.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix()))) } }
            }
            v6.includedRoutes = v6routes
            v6.excludedRoutes = v6ex
            s.ipv6Settings = v6
        }
        if !v4routes.contains(where: { $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0" }) {
            dns?.matchDomains = [""]
            dns?.matchDomainsNoSearch = true
        }
        s.dnsSettings = dns

        if o.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: o.getHTTPProxyServer(), port: Int(o.getHTTPProxyServerPort()))
            proxy.httpServer = server
            proxy.httpsServer = server
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            s.proxySettings = proxy
        }
        return s
    }

    // MARK: default interface

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let m = NWPathMonitor()
        monitor = m
        let first = DispatchSemaphore(value: 0)
        var signalled = false
        m.pathUpdateHandler = { [weak self] path in
            self?.update(listener, path)
            if !signalled { signalled = true; first.signal() }
        }
        m.start(queue: DispatchQueue.global())
        first.wait()
    }

    private func update(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        let desc = "\(path.status) " + path.availableInterfaces.map { "\($0.name)#\($0.index)" }.joined(separator: ",")
        listener.updateNetworkPath(desc)
        if desc == lastPath { return }
        lastPath = desc
        guard path.status != .unsatisfied, let i = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(i.name, interfaceIndex: Int32(i.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws { reset() }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let monitor else { throw PacketTunnelProvider.error("interface monitor not started") }
        let path = monitor.currentPath
        var list: [LibboxNetworkInterface] = []
        if path.status != .unsatisfied {
            for it in path.availableInterfaces {
                let n = LibboxNetworkInterface()
                n.name = it.name
                n.index = Int32(it.index)
                switch it.type {
                case .wifi: n.type = LibboxInterfaceTypeWIFI
                case .cellular: n.type = LibboxInterfaceTypeCellular
                case .wiredEthernet: n.type = LibboxInterfaceTypeEthernet
                default: n.type = LibboxInterfaceTypeOther
                }
                list.append(n)
            }
        }
        return InterfaceIterator(list)
    }

    final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var it: IndexingIterator<[LibboxNetworkInterface]>
        private var cur: LibboxNetworkInterface?
        init(_ a: [LibboxNetworkInterface]) { it = a.makeIterator() }
        func hasNext() -> Bool { cur = it.next(); return cur != nil }
        func next() -> LibboxNetworkInterface? { cur }
    }

    // MARK: simple answers

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func usePlatformAutoDetectInterfaceControl() -> Bool { false }
    func autoDetectInterfaceControl(_: Int32) throws {}
    func useProcFS() -> Bool { false }
    func usePlatformShell() -> Bool { false }
    func usePlatformBridge() -> Bool { false }
    func clearDNSCache() {}
    func readWIFIState() -> LibboxWIFIState? { nil }
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func registerMyInterface(_: String?) {}
    func tailscaleHostname() -> String { "proxy-ios" }

    // MARK: unsupported features

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw unsupported("process lookup")
    }
    func send(_: LibboxNotification?) throws {}
    func cancelNotification(_: String?, typeID _: Int32) throws {}
    func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
    func checkPlatformShell() throws { throw unsupported("shell") }
    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: LibboxStringIteratorProtocol?, term _: String?, rows _: Int32, cols _: Int32) throws -> LibboxShellSessionProtocol {
        throw unsupported("shell")
    }
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String { error?.pointee = unsupported("SSH"); return "" }
    func lookupSFTPServer(_ error: NSErrorPointer) -> String { error?.pointee = unsupported("SFTP"); return "" }
    func lookupUser(_: String?) throws -> LibboxPlatformUser { throw unsupported("user lookup") }
    func createBridge(_: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol { throw unsupported("bridge") }

    // MARK: command server handler

    func serviceReload() throws {}
    func serviceStop() throws {}
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_: Bool) throws {}
    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws { throw unsupported("SSH agent") }
    func triggerNativeCrash() throws {}
    func writeDebugMessage(_ message: String?) { if let message { tunnel.writeMessage(message) } }
}

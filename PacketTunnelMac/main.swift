import Foundation
import NetworkExtension

// The Mac's packet tunnel runs as a system extension (Developer ID builds can't use an app extension for a VPN):
// the same PacketTunnelProvider, started in system-extension mode.
autoreleasepool { NEProvider.startSystemExtensionMode() }
dispatchMain()

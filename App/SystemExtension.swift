#if os(macOS)
import Foundation
import SystemExtensions

/// On the Mac the packet tunnel is a system extension (a Developer ID build outside the App Store can't use an app
/// extension for a VPN). Connecting first asks macOS to activate it: the first time, macOS asks Deyao to allow it
/// in System Settings → General → Login Items & Extensions → Network Extensions; afterwards (and after an update,
/// which replaces the running copy) the request completes by itself. The app must run from /Applications.
@MainActor
final class SystemExtension: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var needsApproval = false
    private var pending: CheckedContinuation<Void, Error>?

    func activate() async throws {
        let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: TunnelController.tunnelBundleID,
                                                             queue: .main)
        req.delegate = self
        try await withCheckedThrowingContinuation { c in
            pending = c
            OSSystemExtensionManager.shared.submitRequest(req)
        }
        needsApproval = false
    }

    private func finish(_ e: Error?) {
        guard let c = pending else { return }
        pending = nil
        if let e { c.resume(throwing: e) } else { c.resume() }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.needsApproval = true }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.finish(error) }
    }
}
#endif

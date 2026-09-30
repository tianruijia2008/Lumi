import Foundation
import Network
import Observation

/// Whether the machine has a usable network path, known *before* a request is
/// sent rather than after it times out.
///
/// This exists because the obvious implementation of "fall back when offline"
/// — fire every request and see which ones fail — makes going offline the
/// slowest path in the app instead of the fastest. A dead Wi-Fi link does not
/// refuse connections, it swallows them, so the user would watch a spinner for
/// the full timeout before the on-device provider got its turn. With a live
/// path flag the network services are marked unavailable at dispatch time and
/// never leave the process.
@MainActor @Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Starts optimistic: the first path update lands within milliseconds, and
    /// briefly attempting a request on a machine that is online is a far
    /// cheaper mistake than refusing one on a machine that is.
    private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    private init() {
        // The offline ladder is the one path that cannot be exercised by
        // typing into the app, so it gets a way to be tested without asking
        // anyone to pull their Wi-Fi.
        if ProcessInfo.processInfo.environment["LUMI_FORCE_OFFLINE"] == "1" {
            isOnline = false
            return
        }
        monitor.pathUpdateHandler = { path in
            // Only the verdict crosses the actor boundary; NWPath itself stays
            // on the monitor's own queue.
            let online = path.status == .satisfied
            Task { @MainActor in NetworkMonitor.shared.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "com.tianruijia.Lumi.network", qos: .utility))
    }
}

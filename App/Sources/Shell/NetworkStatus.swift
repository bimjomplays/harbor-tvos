import Foundation
import Network

/// The navigator.onLine stand-in for bp-status: an NWPathMonitor on the main queue.
@MainActor
final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()
    @Published private(set) var online = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.online = up }
        }
        monitor.start(queue: DispatchQueue(label: "harbor.network-status"))
    }
}

import Foundation
import Network

class BonjourService: ObservableObject {
    @Published var discoveredPeers: [Peer] = []

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let serviceType = "_localbeam._tcp"
    private let deviceName: String
    // Actual Bonjour-registered name — may differ from deviceName if the system appended a suffix
    private var actualServiceName: String?

    // Strip trailing " (N)" suffix to get the canonical device name
    private func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }

    // Callback when a new incoming connection arrives (for receiving files)
    var onIncomingConnection: ((NWConnection) -> Void)?

    init() {
        self.deviceName = Host.current().localizedName ?? "Unknown Mac"
    }

    // MARK: - Advertise

    func startAdvertising() {
        let params = NWParameters.tcp

        listener = try? NWListener(using: params)

        listener?.service = NWListener.Service(
            name: deviceName,
            type: serviceType
        )

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = self.listener?.port {
                    print("Listening on port \(port)")
                }
                // Capture the actual name the system registered (may have a suffix added)
                self.actualServiceName = self.listener?.service?.name
            case .failed(let error):
                print("Listener failed: \(error)")
                self.listener?.cancel()
                self.startAdvertising()
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.onIncomingConnection?(connection)
        }

        listener?.start(queue: .main)
    }

    // MARK: - Browse

    func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: params
        )

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }

            DispatchQueue.main.async {
                let localBase = self.baseName(self.actualServiceName ?? self.deviceName)

                // Sort so un-suffixed names come first — those are preferred when deduplicating
                let sorted = results.sorted {
                    if case .service(let a, _, _, _) = $0.endpoint,
                       case .service(let b, _, _, _) = $1.endpoint { return a < b }
                    return false
                }

                var seen = Set<String>()
                var peers: [Peer] = []
                for result in sorted {
                    if case .service(let name, _, _, _) = result.endpoint {
                        let base = self.baseName(name)
                        guard !seen.contains(base) else { continue }
                        seen.insert(base)
                        peers.append(Peer(
                            id: base,
                            name: base,
                            endpoint: result.endpoint,
                            isSelf: base == localBase
                        ))
                    }
                }
                self.discoveredPeers = peers.sorted { $0.isSelf && !$1.isSelf }
            }
        }

        browser?.start(queue: .main)
    }

    // MARK: - Lifecycle

    func start() {
        startAdvertising()
        startBrowsing()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
    }
}

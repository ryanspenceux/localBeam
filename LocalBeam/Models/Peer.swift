import Foundation
import Network

struct Peer: Identifiable, Hashable {
    let id: String              // unique identifier (Bonjour service name)
    let name: String            // display name
    let endpoint: NWEndpoint    // network address for connecting
    var isSelf: Bool = false    // true when this is the local machine

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }
}

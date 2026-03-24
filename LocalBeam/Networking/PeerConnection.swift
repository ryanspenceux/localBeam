import Foundation
import Network

class PeerConnection {

    static func connect(
        to endpoint: NWEndpoint,
        completion: @escaping (Result<NWConnection, Error>) -> Void
    ) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        var completed = false

        // Fail if we haven't connected within 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard !completed else { return }
            completed = true
            connection.cancel()
            completion(.failure(NSError(
                domain: "LocalBeam",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Connection timed out"]
            )))
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard !completed else { return }
                completed = true
                completion(.success(connection))
            case .failed(let error):
                guard !completed else { return }
                completed = true
                completion(.failure(error))
            case .waiting(let error):
                // No route to host yet — treat as failure rather than hanging
                guard !completed else { return }
                completed = true
                connection.cancel()
                completion(.failure(error))
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    static func disconnect(_ connection: NWConnection) {
        connection.cancel()
    }
}

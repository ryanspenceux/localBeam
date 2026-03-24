import Foundation
import Network

class FileTransfer: ObservableObject {
    @Published var progress: Double = 0
    @Published var status: String = ""
    @Published var isTransferring: Bool = false
    @Published var saveDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    private let chunkSize = 65_536  // 64 KB chunks
    private var activeConnection: NWConnection?

    func cancel() {
        activeConnection?.cancel()
        activeConnection = nil
        isTransferring = false
        status = "Cancelled"
        progress = 0
    }

    // MARK: - Send

    func send(fileURL: URL, to endpoint: NWEndpoint, completion: @escaping (Bool) -> Void) {
        isTransferring = true
        status = "Connecting..."

        PeerConnection.connect(to: endpoint) { [weak self] result in
            switch result {
            case .success(let connection):
                self?.activeConnection = connection
                self?.streamFile(fileURL: fileURL, over: connection, completion: completion)
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.status = "Connection failed: \(error.localizedDescription)"
                    self?.isTransferring = false
                    completion(false)
                }
            }
        }
    }

    private func streamFile(fileURL: URL, over connection: NWConnection, completion: @escaping (Bool) -> Void) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            status = "Can't read file"
            isTransferring = false
            completion(false)
            return
        }

        let filename = fileURL.lastPathComponent
        let fileSize: UInt64

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            fileSize = attrs[.size] as? UInt64 ?? 0
        } catch {
            status = "Can't read file size"
            isTransferring = false
            completion(false)
            return
        }

        let info = TransferInfo(filename: filename, fileSize: fileSize, fileURL: fileURL)
        status = "Sending \(filename) (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)))"

        connection.send(content: info.headerData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.status = "Header send failed: \(error.localizedDescription)"
                    self?.isTransferring = false
                    completion(false)
                }
                return
            }

            self?.sendNextChunk(
                fileHandle: fileHandle,
                connection: connection,
                totalSize: fileSize,
                bytesSent: 0,
                completion: completion
            )
        })
    }

    private func sendNextChunk(
        fileHandle: FileHandle,
        connection: NWConnection,
        totalSize: UInt64,
        bytesSent: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        let chunk = fileHandle.readData(ofLength: chunkSize)

        if chunk.isEmpty {
            DispatchQueue.main.async {
                self.progress = 1.0
                self.status = "Sent!"
                self.isTransferring = false
                completion(true)
            }
            PeerConnection.disconnect(connection)
            return
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.status = "Send error: \(error.localizedDescription)"
                    self.isTransferring = false
                    completion(false)
                }
                return
            }

            let newBytesSent = bytesSent + UInt64(chunk.count)
            DispatchQueue.main.async {
                self.progress = Double(newBytesSent) / Double(totalSize)
            }

            self.sendNextChunk(
                fileHandle: fileHandle,
                connection: connection,
                totalSize: totalSize,
                bytesSent: newBytesSent,
                completion: completion
            )
        })
    }

    // MARK: - Receive

    func receive(on connection: NWConnection, completion: @escaping (String?) -> Void) {
        isTransferring = true
        status = "Receiving header..."
        activeConnection = connection
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count == 4 else {
                completion(nil)
                return
            }

            let filenameLength = Int(data.withUnsafeBytes {
                $0.load(as: UInt32.self)
            }.bigEndian)

            let remainingHeader = filenameLength + 8
            connection.receive(
                minimumIncompleteLength: remainingHeader,
                maximumLength: remainingHeader
            ) { data, _, _, _ in
                guard let data = data, data.count == remainingHeader else {
                    completion(nil)
                    return
                }

                let filename = String(data: data.prefix(filenameLength), encoding: .utf8) ?? "unknown"
                let fileSize = data.dropFirst(filenameLength).withUnsafeBytes {
                    $0.load(as: UInt64.self).bigEndian
                }

                self.status = "Receiving \(filename)..."

                let dest = self.uniqueDestination(for: filename)

                FileManager.default.createFile(atPath: dest.path, contents: nil)
                guard let writeHandle = try? FileHandle(forWritingTo: dest) else {
                    completion(nil)
                    return
                }

                self.receiveChunks(
                    connection: connection,
                    writeHandle: writeHandle,
                    totalSize: fileSize,
                    bytesReceived: 0,
                    filename: filename,
                    destination: dest,
                    completion: completion
                )
            }
        }
    }

    private func receiveChunks(
        connection: NWConnection,
        writeHandle: FileHandle,
        totalSize: UInt64,
        bytesReceived: UInt64,
        filename: String,
        destination: URL,
        completion: @escaping (String?) -> Void
    ) {
        let remaining = totalSize - bytesReceived
        if remaining == 0 {
            try? writeHandle.close()
            DispatchQueue.main.async {
                self.progress = 1.0
                self.status = "Received \(filename)"
                self.isTransferring = false
                completion(filename)
            }
            PeerConnection.disconnect(connection)
            return
        }

        let toRead = min(remaining, UInt64(chunkSize))

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Int(toRead)
        ) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                writeHandle.write(data)
                let newBytesReceived = bytesReceived + UInt64(data.count)

                DispatchQueue.main.async {
                    self.progress = Double(newBytesReceived) / Double(totalSize)
                }

                self.receiveChunks(
                    connection: connection,
                    writeHandle: writeHandle,
                    totalSize: totalSize,
                    bytesReceived: newBytesReceived,
                    filename: filename,
                    destination: destination,
                    completion: completion
                )
            } else {
                try? writeHandle.close()
                DispatchQueue.main.async {
                    self.status = "Transfer interrupted"
                    self.isTransferring = false
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Helpers

    private func uniqueDestination(for filename: String) -> URL {
        var dest = saveDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: dest.path) {
            let name = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            var counter = 2
            repeat {
                let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
                dest = saveDirectory.appendingPathComponent(newName)
                counter += 1
            } while FileManager.default.fileExists(atPath: dest.path)
        }

        return dest
    }
}

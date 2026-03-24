import Foundation
import Network

// Metadata received before the user approves a transfer
struct IncomingTransfer {
    let senderName: String
    let filename: String
    let fileSize: UInt64
    let connection: NWConnection

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

class FileTransfer: ObservableObject {
    @Published var progress: Double = 0
    @Published var status: String = ""
    @Published var isTransferring: Bool = false
    @Published var saveDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    private let chunkSize = 65_536
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
                self?.sendMetadata(fileURL: fileURL, over: connection, completion: completion)
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.status = "Connection failed: \(error.localizedDescription)"
                    self?.isTransferring = false
                    completion(false)
                }
            }
        }
    }

    private func sendMetadata(fileURL: URL, over connection: NWConnection, completion: @escaping (Bool) -> Void) {
        let filename = fileURL.lastPathComponent
        let senderName = Host.current().localizedName ?? "Unknown Mac"
        let fileSize: UInt64

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            fileSize = attrs[.size] as? UInt64 ?? 0
        } catch {
            DispatchQueue.main.async {
                self.status = "Can't read file size"
                self.isTransferring = false
                completion(false)
            }
            return
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            DispatchQueue.main.async {
                self.status = "Can't read file"
                self.isTransferring = false
                completion(false)
            }
            return
        }

        // Header: [4 sender name len][sender name][4 filename len][filename][8 file size]
        var header = Data()
        let senderData = senderName.data(using: .utf8)!
        var senderLen = UInt32(senderData.count).bigEndian
        header.append(Data(bytes: &senderLen, count: 4))
        header.append(senderData)

        let filenameData = filename.data(using: .utf8)!
        var filenameLen = UInt32(filenameData.count).bigEndian
        header.append(Data(bytes: &filenameLen, count: 4))
        header.append(filenameData)

        var size = fileSize.bigEndian
        header.append(Data(bytes: &size, count: 8))

        DispatchQueue.main.async { self.status = "Waiting for approval..." }

        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.status = "Failed: \(error.localizedDescription)"
                    self.isTransferring = false
                    completion(false)
                }
                return
            }

            // Wait for 1-byte ACK: 0x01 = accepted, 0x00 = declined
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, _ in
                guard let self = self else { return }
                guard let data = data, data.first == 0x01 else {
                    DispatchQueue.main.async {
                        self.status = "Declined"
                        self.isTransferring = false
                        completion(false)
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.status = "Sending \(filename) (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)))"
                }

                self.sendNextChunk(
                    fileHandle: fileHandle,
                    connection: connection,
                    totalSize: fileSize,
                    bytesSent: 0,
                    completion: completion
                )
            }
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

    // MARK: - Receive (Phase 1: read metadata before user approves)

    func receiveMetadata(on connection: NWConnection, completion: @escaping (IncomingTransfer?) -> Void) {
        activeConnection = connection
        connection.start(queue: .main)

        readUInt32(from: connection) { [weak self] senderNameLen in
            guard let self = self, let senderNameLen = senderNameLen else { completion(nil); return }
            self.readBytes(Int(senderNameLen), from: connection) { senderData in
                guard let senderData = senderData else { completion(nil); return }
                let senderName = String(data: senderData, encoding: .utf8) ?? "Unknown"

                self.readUInt32(from: connection) { filenameLen in
                    guard let filenameLen = filenameLen else { completion(nil); return }
                    self.readBytes(Int(filenameLen), from: connection) { filenameData in
                        guard let filenameData = filenameData else { completion(nil); return }
                        let filename = String(data: filenameData, encoding: .utf8) ?? "unknown"

                        self.readBytes(8, from: connection) { sizeData in
                            guard let sizeData = sizeData else { completion(nil); return }
                            let fileSize = sizeData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                            let transfer = IncomingTransfer(
                                senderName: senderName,
                                filename: filename,
                                fileSize: fileSize,
                                connection: connection
                            )
                            DispatchQueue.main.async { completion(transfer) }
                        }
                    }
                }
            }
        }
    }

    // Phase 2a: user accepted — send ACK then stream to disk
    func accept(_ transfer: IncomingTransfer, completion: @escaping (String?) -> Void) {
        isTransferring = true
        status = "Receiving \(transfer.filename)..."

        let ack = Data([0x01])
        transfer.connection.send(content: ack, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            let dest = self.uniqueDestination(for: transfer.filename)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            guard let writeHandle = try? FileHandle(forWritingTo: dest) else {
                completion(nil)
                return
            }
            self.receiveChunks(
                connection: transfer.connection,
                writeHandle: writeHandle,
                totalSize: transfer.fileSize,
                bytesReceived: 0,
                filename: transfer.filename,
                destination: dest,
                completion: completion
            )
        })
    }

    // Phase 2b: user declined — send NAK and close
    func decline(_ transfer: IncomingTransfer) {
        let nak = Data([0x00])
        transfer.connection.send(content: nak, completion: .contentProcessed { _ in
            transfer.connection.cancel()
        })
        activeConnection = nil
    }

    // MARK: - Chunk streaming (receive side)

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
        ) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                try? writeHandle.close()
                DispatchQueue.main.async {
                    self.status = "Receive error: \(error.localizedDescription)"
                    self.isTransferring = false
                    completion(nil)
                }
                return
            }

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

    private func readUInt32(from connection: NWConnection, completion: @escaping (UInt32?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, _ in
            guard let data = data, data.count == 4 else { completion(nil); return }
            completion(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        }
    }

    private func readBytes(_ count: Int, from connection: NWConnection, completion: @escaping (Data?) -> Void) {
        if count == 0 { completion(Data()); return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            guard let data = data, data.count == count else { completion(nil); return }
            completion(data)
        }
    }

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

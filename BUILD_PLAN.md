# LocalBeam — Complete Build Plan

A local AirDrop clone for macOS. No servers, no cloud, no third-party dependencies.
Stack: SwiftUI + Network.framework + Bonjour.

---

## Project Structure

```
LocalBeam/
├── LocalBeam.xcodeproj
├── LocalBeam/
│   ├── LocalBeamApp.swift
│   ├── Models/
│   │   ├── Peer.swift
│   │   └── TransferInfo.swift
│   ├── Networking/
│   │   ├── BonjourService.swift       # Discovery: advertise + browse
│   │   ├── PeerConnection.swift       # TCP connection management
│   │   └── FileTransfer.swift         # Chunked file streaming
│   ├── Views/
│   │   ├── MainView.swift             # Split view: peers + drop zone
│   │   ├── PeerRow.swift              # Single peer in the list
│   │   └── TransferProgressView.swift # Progress bar + status
│   └── Resources/
│       ├── LocalBeam.entitlements
│       └── Info.plist
```

---

## Step 1 — Xcode Project Setup

### Create the project
- Xcode > New Project > macOS > App
- Product Name: `LocalBeam`
- Interface: SwiftUI
- Language: Swift
- Uncheck "Include Tests" (add later if needed)

### Entitlements (LocalBeam.entitlements)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.files.downloads.read-write</key>
    <true/>
</dict>
</plist>
```

### Info.plist additions

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>LocalBeam uses your local network to discover nearby devices and transfer files.</string>
<key>NSBonjourServices</key>
<array>
    <string>_localbeam._tcp</string>
</array>
```

### App entry point (LocalBeamApp.swift)

```swift
import SwiftUI

@main
struct LocalBeamApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 600, height: 450)
    }
}
```

---

## Step 2 — Bonjour Discovery (Advertise + Browse)

This is the "shout" layer. Your app announces itself and listens for others.

### Models/Peer.swift

```swift
import Foundation
import Network

struct Peer: Identifiable, Hashable {
    let id: String              // unique identifier (Bonjour service name)
    let name: String            // display name
    let endpoint: NWEndpoint    // network address for connecting

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }
}
```

### Networking/BonjourService.swift

```swift
import Foundation
import Network

class BonjourService: ObservableObject {
    @Published var discoveredPeers: [Peer] = []

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let serviceType = "_localbeam._tcp"
    private let deviceName: String

    // Callback when a new incoming connection arrives (for receiving files)
    var onIncomingConnection: ((NWConnection) -> Void)?

    init() {
        // Use the Mac's name as the display name
        self.deviceName = Host.current().localizedName ?? "Unknown Mac"
    }

    // MARK: - Advertise

    func startAdvertising() {
        let params = NWParameters.tcp

        // Let the system pick an available port (don't hardcode!)
        listener = try? NWListener(using: params)

        // Register as a Bonjour service so others can find us
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
            case .failed(let error):
                print("Listener failed: \(error)")
                // Retry once
                self.listener?.cancel()
                self.startAdvertising()
            default:
                break
            }
        }

        // When someone connects to us, hand off to the file receive logic
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

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }

            DispatchQueue.main.async {
                self.discoveredPeers = results.compactMap { result in
                    if case .service(let name, _, _, _) = result.endpoint {
                        // Filter out ourselves
                        guard name != self.deviceName else { return nil }
                        return Peer(
                            id: name,
                            name: name,
                            endpoint: result.endpoint
                        )
                    }
                    return nil
                }
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
```

**Key differences from the other agent's code:**
- Auto-assigns port instead of hardcoding 54321
- Filters out the local machine from the peer list
- Peers are removed automatically when they disappear (full replacement on each browse update)
- Doesn't eagerly open connections to every peer

---

## Step 3 — TCP Connection (On-Demand)

Connections are opened only when you actually want to send a file.

### Networking/PeerConnection.swift

```swift
import Foundation
import Network

class PeerConnection {

    // Open a connection to a peer. Returns via callback when ready.
    static func connect(
        to endpoint: NWEndpoint,
        completion: @escaping (Result<NWConnection, Error>) -> Void
    ) {
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                completion(.success(connection))
            case .failed(let error):
                completion(.failure(error))
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    // Clean up a connection
    static func disconnect(_ connection: NWConnection) {
        connection.cancel()
    }
}
```

**Why on-demand?** The other agent's code connects to every peer at browse time. That wastes sockets and causes problems if peers come and go. We only connect when the user picks a peer and hits send.

---

## Step 4 — Prove the Pipe (Simple Message Test)

Before building file transfer, verify the TCP path works with a basic ping/pong. This is a temporary test you can remove later.

```swift
// Sender side — send a test message
func sendTestMessage(to endpoint: NWEndpoint) {
    PeerConnection.connect(to: endpoint) { result in
        switch result {
        case .success(let connection):
            let message = "hello from LocalBeam".data(using: .utf8)!
            connection.send(content: message, completion: .contentProcessed { error in
                if let error = error {
                    print("Send failed: \(error)")
                } else {
                    print("Message sent!")
                }
                PeerConnection.disconnect(connection)
            })
        case .failure(let error):
            print("Connection failed: \(error)")
        }
    }
}

// Receiver side — set as the incoming connection handler
bonjourService.onIncomingConnection = { connection in
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
        if let data = data, let message = String(data: data, encoding: .utf8) {
            print("Received: \(message)")
        }
    }
}
```

Once you see "Received: hello from LocalBeam" in the console on the other Mac, the pipe works. Move on.

---

## Step 5 — File Transfer Protocol (Chunked Streaming)

This is the core of the app. The protocol uses a simple frame-based format:

### Wire Protocol

```
[HEADER]
  4 bytes  — filename length (UInt32, big-endian)
  N bytes  — filename (UTF-8)
  8 bytes  — total file size (UInt64, big-endian)

[DATA]
  Repeating chunks of up to 65,536 bytes until all bytes are sent

[VERIFICATION]
  Receiver compares bytes received vs file size from header
```

### Models/TransferInfo.swift

```swift
import Foundation

struct TransferInfo {
    let filename: String
    let fileSize: UInt64
    let fileURL: URL?          // only set on sender side

    var headerData: Data {
        let filenameData = filename.data(using: .utf8)!
        var headerLength = UInt32(filenameData.count).bigEndian
        var size = fileSize.bigEndian

        var header = Data()
        header.append(Data(bytes: &headerLength, count: 4))
        header.append(filenameData)
        header.append(Data(bytes: &size, count: 8))
        return header
    }

    static func parse(from data: Data) -> (info: TransferInfo, bytesConsumed: Int)? {
        guard data.count >= 4 else { return nil }

        let filenameLength = Int(data.withUnsafeBytes {
            $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian
        })

        let headerSize = 4 + filenameLength + 8
        guard data.count >= headerSize else { return nil }

        let filenameData = data[4 ..< 4 + filenameLength]
        let filename = String(data: filenameData, encoding: .utf8) ?? "unknown"

        let fileSize = data.withUnsafeBytes {
            $0.load(fromByteOffset: 4 + filenameLength, as: UInt64.self).bigEndian
        }

        let info = TransferInfo(filename: filename, fileSize: fileSize, fileURL: nil)
        return (info, headerSize)
    }
}
```

### Networking/FileTransfer.swift

```swift
import Foundation
import Network

class FileTransfer: ObservableObject {
    @Published var progress: Double = 0
    @Published var status: String = ""
    @Published var isTransferring: Bool = false

    private let chunkSize = 65_536  // 64 KB chunks

    // MARK: - Send

    func send(fileURL: URL, to endpoint: NWEndpoint, completion: @escaping (Bool) -> Void) {
        isTransferring = true
        status = "Connecting..."

        PeerConnection.connect(to: endpoint) { [weak self] result in
            switch result {
            case .success(let connection):
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

        // Get file size without loading entire file into memory
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

        // Send header first, then stream chunks
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
            // All done
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

            // Send next chunk
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
        connection.start(queue: .main)

        // Read header: first 4 bytes for filename length
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count == 4 else {
                completion(nil)
                return
            }

            let filenameLength = Int(data.withUnsafeBytes {
                $0.load(as: UInt32.self)
            }.bigEndian)

            // Read filename + file size
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

                // Prepare destination with duplicate handling
                let dest = self.uniqueDestination(for: filename)

                // Stream chunks to disk
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
            // Transfer complete
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
                // Connection closed prematurely
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
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var dest = downloads.appendingPathComponent(filename)

        // If file exists, append a number: "photo (2).jpg"
        if FileManager.default.fileExists(atPath: dest.path) {
            let name = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            var counter = 2
            repeat {
                let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
                dest = downloads.appendingPathComponent(newName)
                counter += 1
            } while FileManager.default.fileExists(atPath: dest.path)
        }

        return dest
    }
}
```

**Key differences from the other agent's code:**
- Streams via FileHandle — never loads the whole file into memory
- Reads/writes in 64KB chunks — handles multi-GB files
- Progress tracking actually works
- Duplicate filename handling (appends a number)
- Receiver reads with `minimumIncompleteLength: 1` so TCP fragmentation is handled correctly

---

## Step 6 — Drag-and-Drop UI + File Picker

### Views/MainView.swift

```swift
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @StateObject private var bonjourService = BonjourService()
    @StateObject private var fileTransfer = FileTransfer()
    @State private var selectedPeer: Peer?
    @State private var showFilePicker = false
    @State private var showIncomingRequest = false
    @State private var incomingPeerName = ""
    @State private var pendingConnection: NWConnection?
    @State private var receivedFiles: [String] = []
    @State private var isDragTargeted = false

    var body: some View {
        HSplitView {
            // Left: peer list
            peerListPanel

            // Right: send area + status
            transferPanel
        }
        .frame(minWidth: 550, minHeight: 400)
        .onAppear {
            bonjourService.onIncomingConnection = { connection in
                // Step 7: prompt user before accepting
                incomingPeerName = "A nearby device"
                pendingConnection = connection
                showIncomingRequest = true
            }
            bonjourService.start()
        }
        .onDisappear {
            bonjourService.stop()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if let url = try? result.get().first, let peer = selectedPeer {
                fileTransfer.send(fileURL: url, to: peer.endpoint) { _ in }
            }
        }
        .alert("Incoming File", isPresented: $showIncomingRequest) {
            Button("Accept") {
                if let connection = pendingConnection {
                    fileTransfer.receive(on: connection) { filename in
                        if let filename = filename {
                            receivedFiles.append(filename)
                        }
                    }
                }
            }
            Button("Decline", role: .cancel) {
                pendingConnection?.cancel()
                pendingConnection = nil
            }
        } message: {
            Text("\(incomingPeerName) wants to send you a file.")
        }
    }

    // MARK: - Subviews

    private var peerListPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby Devices")
                .font(.headline)
                .padding(.top)

            if bonjourService.discoveredPeers.isEmpty {
                VStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Searching...")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(bonjourService.discoveredPeers, selection: $selectedPeer) { peer in
                    PeerRow(peer: peer)
                        .tag(peer)
                }
            }
        }
        .frame(minWidth: 180, maxWidth: 220)
        .padding(.horizontal)
    }

    private var transferPanel: some View {
        VStack(spacing: 20) {
            Spacer()

            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .foregroundColor(isDragTargeted ? .accentColor : .secondary.opacity(0.4))
                    .frame(width: 250, height: 150)

                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 36))
                        .foregroundColor(selectedPeer != nil ? .accentColor : .secondary)

                    if let peer = selectedPeer {
                        Text("Drop file to send to \(peer.name)")
                            .font(.caption)
                    } else {
                        Text("Select a device first")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                handleDrop(providers)
            }

            // Or use file picker
            Button("Choose File...") {
                showFilePicker = true
            }
            .disabled(selectedPeer == nil)

            // Progress
            if fileTransfer.isTransferring {
                TransferProgressView(
                    progress: fileTransfer.progress,
                    status: fileTransfer.status
                )
            } else {
                Text(fileTransfer.status)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            // Received files list
            if !receivedFiles.isEmpty {
                Divider()
                Text("Received Files")
                    .font(.headline)
                ForEach(receivedFiles, id: \.self) { file in
                    Label(file, systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }

            Spacer()
        }
        .frame(minWidth: 300)
        .padding()
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let peer = selectedPeer else { return false }

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        fileTransfer.send(fileURL: url, to: peer.endpoint) { _ in }
                    }
                }
            }
        }
        return true
    }
}
```

### Views/PeerRow.swift

```swift
import SwiftUI

struct PeerRow: View {
    let peer: Peer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .foregroundColor(.accentColor)
            Text(peer.name)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}
```

### Views/TransferProgressView.swift

```swift
import SwiftUI

struct TransferProgressView: View {
    let progress: Double
    let status: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: progress)
                .frame(width: 200)

            Text("\(Int(progress * 100))%")
                .font(.caption)
                .monospacedDigit()

            Text(status)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

---

## Step 7 — Accept/Reject Flow

Already integrated into Step 6 above via the `.alert("Incoming File", ...)` modifier. When a connection arrives:

1. `BonjourService.onIncomingConnection` fires
2. The alert is shown: "[device] wants to send you a file"
3. **Accept** -> starts `fileTransfer.receive(on:)` which reads header + chunks
4. **Decline** -> cancels the connection immediately

### Future enhancement: send metadata before accept

To show the filename and size in the accept prompt, you'd split the protocol into two phases:

```
Phase 1 (before accept):
  Sender connects and sends ONLY the header (filename + size)
  Receiver reads header, shows prompt with details

Phase 2 (after accept):
  Receiver sends a 1-byte "OK" response
  Sender begins streaming chunks
  (If declined, receiver sends "NO" and closes connection)
```

This requires a small protocol change where the sender waits for an ACK byte before streaming:

```swift
// Sender: after sending header, wait for ACK
connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
    if let data = data, data.first == 0x01 {
        // Accepted — start sending chunks
        self.sendNextChunk(...)
    } else {
        // Declined
        PeerConnection.disconnect(connection)
    }
}

// Receiver: after reading header and user accepts
let ack = Data([0x01])
connection.send(content: ack, completion: .contentProcessed { _ in
    self.receiveChunks(...)
})
```

---

## Step 8 — Polish

### 8a. App icon

Design a simple icon (beam/ray graphic) and add to `Assets.xcassets` under `AppIcon`.

### 8b. Menu bar mode (optional)

Add a menu bar presence so the app can run in the background:

```swift
@main
struct LocalBeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            MainView()
        }

        MenuBarExtra("LocalBeam", systemImage: "antenna.radiowaves.left.and.right") {
            Text("LocalBeam is running")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

### 8c. Error handling checklist

- [ ] Network goes down mid-transfer: detect via connection state handler, show error, clean up partial file
- [ ] File is deleted while sending: FileHandle read returns empty, treat as error
- [ ] Port conflict: already handled by auto-assign
- [ ] Peer disappears: NWBrowser removes them from the list automatically
- [ ] Disk full on receiver: catch write errors, notify sender

### 8d. Nice-to-haves (future)

- TLS encryption on the connection (Network.framework makes this easy with `NWProtocolTLS`)
- Transfer history with timestamps
- Notification Center alerts for incoming files
- Multiple file / folder transfer (zip and send)
- Transfer speed display (bytes/sec)

---

## Distribution

### For personal use (simplest)
1. `Product > Archive` in Xcode
2. `Distribute App > Copy App`
3. Drag `LocalBeam.app` to the other Mac
4. Receiver right-clicks > Open (first time only, to bypass Gatekeeper)

### For wider distribution
- Sign with an Apple Developer ID ($99/yr) so Gatekeeper doesn't block it
- Or distribute via the Mac App Store (requires Apple review)

### Requirements on receiving Mac
- macOS 13+
- Same local network (Wi-Fi or wired)
- No additional software or dependencies

---

## Build Order Summary

| Step | What | Test criteria |
|------|------|---------------|
| 1 | Xcode project + entitlements | App launches, shows empty window |
| 2 | Bonjour discovery | Two Macs see each other in the peer list |
| 3 | TCP connection | `PeerConnection.connect` succeeds (logs "ready") |
| 4 | Pipe test | Send/receive a text message between Macs |
| 5 | File transfer | Send a file, appears in Downloads, checksums match |
| 6 | Drag-and-drop UI | Drop a file on the zone, it sends; picker also works |
| 7 | Accept/reject | Receiver gets a prompt before any file is saved |
| 8 | Polish | Error states handled, menu bar, icon |

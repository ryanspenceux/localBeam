import SwiftUI
import UniformTypeIdentifiers
import Network

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

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                fileTransfer.saveDirectory = url
            }
        }
    }

    var body: some View {
        HSplitView {
            peerListPanel
            transferPanel
        }
        .frame(minWidth: 550, minHeight: 400)
        .onAppear {
            bonjourService.onIncomingConnection = { connection in
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
                        .disabled(peer.isSelf)
                }
                .onChange(of: selectedPeer) { _ in
                    if !fileTransfer.isTransferring {
                        fileTransfer.status = ""
                    }
                }
            }
        }
        .frame(minWidth: 180, maxWidth: 220)
        .padding(.horizontal)
    }

    private var transferPanel: some View {
        VStack(spacing: 20) {
            Spacer()

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

            Button("Choose File...") {
                showFilePicker = true
            }
            .disabled(selectedPeer == nil)

            if fileTransfer.isTransferring {
                TransferProgressView(
                    progress: fileTransfer.progress,
                    status: fileTransfer.status
                )
                Button("Cancel Transfer") {
                    fileTransfer.cancel()
                }
                .foregroundColor(.red)
                .font(.caption)
            } else if selectedPeer != nil && fileTransfer.status.isEmpty {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                Text(fileTransfer.status)
                    .foregroundColor(fileTransfer.status == "Cancelled" ? .orange : .secondary)
                    .font(.caption)
            }

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

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.secondary)
                Text(fileTransfer.saveDirectory.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change...") {
                    chooseSaveFolder()
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
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

#Preview {
    MainView()
}

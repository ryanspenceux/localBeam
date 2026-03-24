import SwiftUI

struct PeerRow: View {
    let peer: Peer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .foregroundColor(peer.isSelf ? .secondary : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .lineLimit(1)
                    .foregroundColor(peer.isSelf ? .secondary : .primary)
                if peer.isSelf {
                    Text("This Mac")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(peer.isSelf ? 0.6 : 1.0)
    }
}

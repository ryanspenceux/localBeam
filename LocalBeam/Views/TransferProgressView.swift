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

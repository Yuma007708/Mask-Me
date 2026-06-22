import SwiftUI
import MosaicCore

/// Small overlay capsule showing the live tracking state and rate (追従率).
struct TrackingBadge: View {
    let status: TrackingStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(stateText) \(Int(status.rate.rounded()))%")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.primary)
    }

    private var stateText: String {
        switch status.state {
        case .idle: return "待機"
        case .searching: return "探索中"
        case .tracking: return "追従中"
        case .lost: return "ロスト"
        }
    }

    private var color: Color {
        switch status.state {
        case .idle: return .gray
        case .searching: return .orange
        case .tracking: return .green
        case .lost: return .red
        }
    }
}

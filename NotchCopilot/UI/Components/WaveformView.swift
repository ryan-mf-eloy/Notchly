import SwiftUI

struct WaveformView: View {
    var levels: [CGFloat]
    var color: Color = .white

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.92), Color.gray.opacity(0.52)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3, height: max(4, level * 22))
            }
        }
        .frame(width: 76, height: 28)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: levels)
        .accessibilityLabel("Audio waveform")
    }
}

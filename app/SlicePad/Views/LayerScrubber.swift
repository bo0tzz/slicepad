import SwiftUI

/// The layer control, as a vertical bar beside the plate.
///
/// Vertical because it is a height: dragging up shows more of the print, which is
/// the direction the print grew. Beside the plate rather than in the inspector
/// because it is used while looking at the model, and a control you scrub with one
/// hand should not be on the far side of the screen from what it changes.
struct LayerScrubber: View {
    let count: Int
    @Binding var top: UInt32

    /// Tall enough to place a layer in a print of a few hundred, and no taller
    /// than a plate view on the shortest iPad.
    private let barHeight: CGFloat = 320
    private let barWidth: CGFloat = 6

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: barWidth, height: barHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: barWidth, height: filledHeight)
            }
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(.background)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: 26, height: 26)
                    .offset(y: 13 - filledHeight)
            }
            // The whole strip is the target, not just the knob: a 6pt bar is not
            // something to ask a finger to find.
            .frame(width: 44, height: barHeight, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard count > 1 else { return }
                        // Measured from the bottom, since that is layer one.
                        let fraction = 1 - min(max(value.location.y / barHeight, 0), 1)
                        top = UInt32((fraction * Double(count - 1)).rounded())
                    }
            )

            Text("\(top + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .padding(.leading, 12)
    }

    private var filledHeight: CGFloat {
        guard count > 1 else { return barHeight }
        return barHeight * CGFloat(top) / CGFloat(count - 1)
    }
}

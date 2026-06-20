import SwiftUI

/// The app's single loading primitive: a shimmering rounded-rect placeholder. Per the product direction we
/// use ONLY skeletons — no spinners, no full-screen `LoadingView` takeovers. A skeleton previews the SHAPE
/// of the content that's about to land (a tile, a row, the sticker area), so the screen never goes blank or
/// shows a spinning gear.
///
/// Design: a neutral system fill with a soft diagonal highlight sweeping across it on a gentle loop. Flat,
/// Apple-clean, appearance-agnostic (adapts to Light/Dark/Increase-Contrast/Reduce-Transparency). When the
/// user has Reduce Motion on, the sweep is replaced by a quiet pulse so nothing slides.
struct SkeletonView: View {
    var cornerRadius: CGFloat = Radius.card

    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .overlay {
                    if reduceMotion {
                        // No sliding highlight under Reduce Motion — a quiet opacity pulse instead.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(.systemFill))
                            .opacity(animate ? 0.35 : 0.0)
                    } else {
                        // A soft diagonal highlight that sweeps left→right on a gentle loop.
                        LinearGradient(
                            colors: [.clear, Color(.systemBackground).opacity(0.55), .clear],
                            startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.6)
                        .offset(x: animate ? w * 0.9 : -w * 0.9)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            withAnimation(reduceMotion
                          ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                          : .easeInOut(duration: 1.15).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
        .accessibilityLabel("Loading")
    }
}

/// A skeleton sized to a fixed square — the Style-Wall tile / layer-thumb placeholder.
struct SkeletonTile: View {
    var side: CGFloat
    var cornerRadius: CGFloat = 16
    var body: some View {
        SkeletonView(cornerRadius: cornerRadius)
            .frame(width: side, height: side)
    }
}

/// A horizontal skeleton "row" — an avatar block plus two text lines — for list placeholders.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: Spacing.md) {
            SkeletonView(cornerRadius: Radius.control)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SkeletonView(cornerRadius: 6).frame(height: 12).frame(maxWidth: .infinity)
                SkeletonView(cornerRadius: 6).frame(width: 120, height: 10)
            }
            Spacer(minLength: 0)
        }
    }
}

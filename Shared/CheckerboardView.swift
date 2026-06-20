import SwiftUI

/// THE single shared checkerboard — one component across the app, the keyboard, and the iMessage
/// extension (the transparency motif used to be reimplemented three divergent ways). It lives in `Shared`
/// so all three targets compile the exact same view. Appearance-aware: it uses system fills so the
/// squares read in both Light and Dark Mode (and respects Increase Contrast / Reduce Transparency).
struct CheckerboardView: View {
    var square: CGFloat = 14
    var body: some View {
        Canvas { context, size in
            let cols = Int(size.width / square) + 1
            let rows = Int(size.height / square) + 1
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(c) * square, y: CGFloat(r) * square,
                                      width: square, height: square)
                    context.fill(Path(rect), with: .color(Color(.systemFill)))
                }
            }
        }
        .background(Color(.tertiarySystemFill))
    }
}

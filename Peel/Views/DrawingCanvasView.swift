import SwiftUI
import UIKit

/// A freehand DRAW / DOODLE surface. The user scribbles on a fixed square checkerboard canvas with a
/// chosen color + brush size; on Done the strokes are rasterized to a transparent PNG that becomes a
/// `.drawing` layer on the sticker. All on-device (Core Graphics), no network.
///
/// Strokes are kept as point-paths in NORMALIZED canvas coords (0…1) so the on-screen preview and the
/// exported full-resolution raster are identical regardless of the live canvas size.
struct DrawingCanvasView: View {
    /// An existing doodle to keep editing (re-opening a `.drawing` layer). When nil we start blank.
    var existing: UIImage?
    var onDone: (UIImage?) -> Void
    var onCancel: () -> Void

    private struct Stroke: Identifiable {
        let id = UUID()
        var points: [CGPoint]      // normalized 0…1
        var color: Color
        var width: CGFloat         // fraction of canvas longest side
    }

    @State private var strokes: [Stroke] = []
    @State private var live: Stroke?
    @State private var color: Color = Color(.sRGB, red: 0, green: 0x7A / 255.0, blue: 1, opacity: 1)
    @State private var width: CGFloat = 0.022

    private let palette: [Color] = [
        .black, .white,
        Color(red: 0, green: 0x7A/255, blue: 1),       // Apple blue
        Color(red: 1.0, green: 0.23, blue: 0.30),       // red
        Color(red: 1.0, green: 0.78, blue: 0.16),       // yellow
        Color(red: 0.20, green: 0.78, blue: 0.35),      // green
        Color(red: 1.0, green: 0.45, blue: 0.72),       // pink
        Color(red: 0.62, green: 0.35, blue: 1.0),       // purple
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            canvas
                .padding(16)
            controls
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .font(.body).tint(Color.accentColor)
            Spacer()
            Text("Doodle").font(.headline)
            Spacer()
            Button("Done") { finish() }
                .font(.body.weight(.semibold)).tint(Color.accentColor)
                .disabled(strokes.isEmpty && existing == nil)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let origin = CGPoint(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2)
            ZStack {
                CheckerboardView(square: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                if let existing {
                    Image(uiImage: existing).resizable().scaledToFit()
                }
                Canvas { ctx, _ in
                    for s in strokes { draw(s, in: ctx, side: side, origin: origin) }
                    if let live { draw(live, in: ctx, side: side, origin: origin) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let n = CGPoint(x: clamp01((v.location.x - origin.x) / side),
                                        y: clamp01((v.location.y - origin.y) / side))
                        if live == nil { live = Stroke(points: [n], color: color, width: width) }
                        else { live?.points.append(n) }
                    }
                    .onEnded { _ in
                        if let s = live, s.points.count > 0 { strokes.append(s) }
                        live = nil
                        Haptics.tap()
                    })
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draw(_ s: Stroke, in ctx: GraphicsContext, side: CGFloat, origin: CGPoint) {
        guard let first = s.points.first else { return }
        var path = Path()
        path.move(to: pt(first, side: side, origin: origin))
        for p in s.points.dropFirst() { path.addLine(to: pt(p, side: side, origin: origin)) }
        ctx.stroke(path, with: .color(s.color),
                   style: StrokeStyle(lineWidth: s.width * side, lineCap: .round, lineJoin: .round))
        // A single tap leaves one point — draw a dot so it isn't invisible.
        if s.points.count == 1 {
            let r = s.width * side / 2
            ctx.fill(Path(ellipseIn: CGRect(x: pt(first, side: side, origin: origin).x - r,
                                            y: pt(first, side: side, origin: origin).y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(s.color))
        }
    }
    private func pt(_ n: CGPoint, side: CGFloat, origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + n.x * side, y: origin.y + n.y * side)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, c in
                        Button { Haptics.tap(); color = c } label: {
                            Circle().fill(c).frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                                .overlay(Circle().strokeBorder(Color.accentColor,
                                                               lineWidth: sameColor(c, color) ? 3 : 0).padding(-3))
                        }.buttonStyle(.plain)
                    }
                    ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden().frame(width: 34)
                }
                .padding(.horizontal, 4)
            }
            HStack(spacing: 12) {
                Image(systemName: "pencil.tip").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $width, in: 0.006...0.06)
                Image(systemName: "pencil.tip").font(.system(size: 22)).foregroundStyle(.secondary)
            }
            HStack {
                Button { undoStroke() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(strokes.isEmpty)
                Spacer()
                Button(role: .destructive) { strokes.removeAll(); live = nil } label: {
                    Label("Clear", systemImage: "trash")
                }.disabled(strokes.isEmpty)
            }
            .font(.subheadline).tint(Color.accentColor)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 18)
        .background(Color(.secondarySystemBackground).opacity(0.5))
        .tint(Color.accentColor)
    }

    private func sameColor(_ a: Color, _ b: Color) -> Bool {
        UIColor(a).cgColor == UIColor(b).cgColor
    }

    private func undoStroke() { if !strokes.isEmpty { strokes.removeLast(); Haptics.tap() } }

    // MARK: - Rasterize

    /// Render the strokes (over any existing doodle) into a transparent square PNG at export resolution.
    private func finish() {
        let canvasPx: CGFloat = 1200
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: canvasPx, height: canvasPx), format: fmt).image { rctx in
            let cg = rctx.cgContext
            if let existing {
                // Place the prior doodle aspect-fit, centered, so re-edits compose on top of it.
                let fit = AVMakeFit(existing.size, in: CGSize(width: canvasPx, height: canvasPx))
                let rect = CGRect(x: (canvasPx - fit.width) / 2, y: (canvasPx - fit.height) / 2,
                                  width: fit.width, height: fit.height)
                existing.draw(in: rect)
            }
            cg.setLineCap(.round); cg.setLineJoin(.round)
            for s in strokes {
                guard let first = s.points.first else { continue }
                cg.setStrokeColor(UIColor(s.color).cgColor)
                cg.setFillColor(UIColor(s.color).cgColor)
                cg.setLineWidth(s.width * canvasPx)
                if s.points.count == 1 {
                    let r = s.width * canvasPx / 2
                    cg.fillEllipse(in: CGRect(x: first.x * canvasPx - r, y: first.y * canvasPx - r,
                                              width: r * 2, height: r * 2))
                    continue
                }
                cg.move(to: CGPoint(x: first.x * canvasPx, y: first.y * canvasPx))
                for p in s.points.dropFirst() { cg.addLine(to: CGPoint(x: p.x * canvasPx, y: p.y * canvasPx)) }
                cg.strokePath()
            }
        }
        onDone(img)
    }

    private func clamp01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
}

/// Aspect-fit a size inside a bounding size.
private func AVMakeFit(_ size: CGSize, in bounds: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0 else { return bounds }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    return CGSize(width: size.width * scale, height: size.height * scale)
}

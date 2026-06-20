import SwiftUI

/// A labeled slider with a live NUMERIC readout and DOUBLE-TAP-TO-RESET (the spec's grouped-adjust
/// upgrade that replaces the 13 unlabeled sliders crammed in a 168pt box). Reports its continuous-edit
/// lifecycle so the editor can fold a whole drag into ONE undo step (begin on first change, commit on
/// release) and run the heavy composite only when the gesture ends.
///
/// - `value` drives the bound model.
/// - `defaultValue` is restored on a double-tap of the readout/label.
/// - `format` renders the readout (a signed percentage, an EV stop, etc.).
/// - `onEditingChanged(editing)` brackets a drag: `true` at touch-down, `false` at release.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(format(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(isDefault ? .secondary : Color.accentColor)
            }
            // Double-tapping the readout row resets just this slider (per the spec).
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset() }

            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
    }

    private var isDefault: Bool { abs(value - defaultValue) < 0.0001 }

    private func reset() {
        guard !isDefault else { return }
        Haptics.tap()
        // Bracket the reset as one atomic edit so undo restores the prior value in a single step.
        onEditingChanged(true)
        withAnimation(.easeOut(duration: 0.18)) { value = defaultValue }
        onEditingChanged(false)
    }
}

/// CGFloat convenience overload (transform sliders carry CGFloat values).
extension ValueSlider {
    init(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, defaultValue: CGFloat = 0,
         format: @escaping (Double) -> String = { String(format: "%.2f", $0) },
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        self._value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.defaultValue = Double(defaultValue)
        self.format = format
        self.onEditingChanged = onEditingChanged
    }
}

// MARK: - Readout formatters

enum SliderFormat {
    /// A centered value as a signed percentage of its half-range (e.g. brightness -0.4...0.4 → ±100%).
    static func signedPercent(center: Double, halfSpan: Double) -> (Double) -> String {
        { v in
            let pct = Int(((v - center) / halfSpan * 100).rounded())
            return pct > 0 ? "+\(pct)%" : "\(pct)%"
        }
    }
    /// A 0…max value as a plain percentage of `max`.
    static func percent(of max: Double) -> (Double) -> String {
        { v in "\(Int((v / max * 100).rounded()))%" }
    }
    /// Exposure in EV stops.
    static let ev: (Double) -> String = { v in
        let s = (v * 10).rounded() / 10
        return s > 0 ? "+\(String(format: "%.1f", s)) EV" : "\(String(format: "%.1f", s)) EV"
    }
    /// Degrees from radians (rotation / hue).
    static let degrees: (Double) -> String = { v in "\(Int((v * 180 / .pi).rounded()))°" }
    /// A multiplier around 1.0 shown as a percentage (e.g. contrast 1.2 → 120%).
    static let multiplier: (Double) -> String = { v in "\(Int((v * 100).rounded()))%" }
}

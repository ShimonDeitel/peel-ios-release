import SwiftUI

/// A titled group inside the contextual inspector — the "make the whole app feel like SettingsView"
/// grouped idiom, applied to the editor. Groups the adjust sliders into Light / Color sections (each with
/// a quiet caption header) instead of a flat wall of unlabeled controls in a 168pt box.
struct InspectorSection<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
            VStack(spacing: 10) {
                content
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

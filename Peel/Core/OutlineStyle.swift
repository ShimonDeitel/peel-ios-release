import SwiftUI

/// The sticker outline looks the user can apply to a cutout. All FREE — the editor has no per-tool
/// locks anymore; Pro is only unlimited stickers, dual stickers, and Auto-Edit.
enum OutlineStyle: String, CaseIterable, Identifiable, Codable {
    case none, white, black, candy, mint, glow, pop, sticker, dashed, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .white: return "White"
        case .black: return "Black"
        case .candy: return "Candy"
        case .mint: return "Mint"
        case .glow: return "Neon"
        case .pop: return "Pop"
        case .sticker: return "Sticker"
        case .dashed: return "Cut-line"
        case .custom: return "Custom"
        }
    }

    /// Swatch shown in the style picker.
    var swatch: Color {
        switch self {
        case .none: return .gray.opacity(0.3)
        case .white: return .white
        case .black: return .black
        case .candy: return Color(red: 1.0, green: 0.28, blue: 0.58)
        case .mint: return Color(red: 0.20, green: 0.85, blue: 0.70)
        case .glow: return Color(red: 0.45, green: 0.55, blue: 1.0)
        case .pop: return .white
        case .sticker: return .white
        case .dashed: return .white
        case .custom: return .blue
        }
    }
}

import SwiftUI

/// Peel's design system — a REAL semantic token layer (Stage 4 rebuild). The app chrome is ruthlessly
/// Apple-clean and appearance-agnostic: it adapts to Light Mode, Dark Mode, Increase Contrast, Reduce
/// Transparency and Dynamic Type for free by leaning on system colors, fills and materials instead of
/// hardcoded `Color.black` / `.white.opacity()` literals. There is ONE accent — true system blue
/// (#007AFF) — and the only saturated color on screen is the sticker the user is making.
///
/// What was deleted from the old palette: the dead `gold` / `goldGradient` / `aurora` / `brandGradient`
/// aliases, the forced-dark `AuroraBackground` black wash, and the fragile `tint == accent` ButtonStyle
/// hack (replaced by an explicit role enum).

// MARK: - Accent

enum Brand {
    /// The single accent — Apple system blue (#007AFF). Defined as an explicit sRGB literal so it is
    /// identical to the (now-fixed) AccentColor asset and never drifts with platform tweaks to `.blue`.
    static let accent = Color(.sRGB, red: 0.0, green: 0x7A / 255.0, blue: 1.0, opacity: 1.0)
}

// MARK: - Spacing & radius tokens

/// Spacing ramp — 4 / 8 / 12 / 16 / 24 / 32. Use these instead of ad-hoc literals so rhythm stays
/// consistent across every screen.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner-radius ramp — 10 (controls) / 16 (cards/tiles) / 26 (hero surfaces).
enum Radius {
    static let control: CGFloat = 10
    static let card: CGFloat = 16
    static let hero: CGFloat = 26
}

// MARK: - Typography ramp (Dynamic Type, no sub-legible 8–9pt labels)

/// A small, named Dynamic-Type ramp. Every label scales with the user's text-size setting; nothing is
/// pinned below `.caption2` (~11pt at default), which kills the old sub-legibility 8–9pt labels.
enum AppFont {
    static let largeTitle = Font.largeTitle.weight(.bold)
    static let title = Font.title2.weight(.bold)
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    /// The smallest type the app uses — scales with Dynamic Type, never a fixed 8–9pt point size.
    static let caption = Font.caption2
}

/// Standardized SF Symbol scale/weight so glyphs read consistently. Prefer `Image.appSymbol(...)`.
enum SymbolScale {
    static let weight: Font.Weight = .semibold
}

extension Image {
    /// A system symbol rendered at the standardized weight + an explicit Dynamic-Type text style, so it
    /// scales like the surrounding type and reads consistently everywhere.
    static func appSymbol(_ name: String, _ style: Font.TextStyle = .body) -> some View {
        Image(systemName: name)
            .font(.system(style).weight(SymbolScale.weight))
    }
}

// MARK: - Cards

/// A grouped-content card on the system grouped background — the SettingsView idiom generalized. Uses a
/// system fill so it adapts to Light/Dark/Increase-Contrast without any literal colors.
private struct AppCardModifier: ViewModifier {
    var cornerRadius: CGFloat = Radius.hero
    var padding: CGFloat = Spacing.lg
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    /// A neutral grouped card. (Name `glassCard` kept for call-site stability; the look is now a flat
    /// system fill, not a material glass.)
    func glassCard(cornerRadius: CGFloat = Radius.hero) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius))
    }

    /// Alias with a clearer name for new code.
    func appCard(cornerRadius: CGFloat = Radius.hero, padding: CGFloat = Spacing.lg) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Role-based buttons

/// Explicit button roles — replaces the fragile `tint == accent` hack with a real enum. `primary` is the
/// solid blue call-to-action; `secondary` is a neutral system-fill button; `plainTinted` is a quiet
/// text/symbol button in the accent.
enum AppButtonRole {
    case primary, secondary, plainTinted
}

/// The one capsule action-button style. Flat fills only — no gradients, no glow.
struct AppButtonStyle: ButtonStyle {
    var role: AppButtonRole = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.28), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: return .white
        case .secondary: return .primary
        case .plainTinted: return Brand.accent
        }
    }

    @ViewBuilder private var background: some View {
        switch role {
        case .primary:
            Capsule().fill(Brand.accent)
        case .secondary:
            Capsule().fill(Color(.secondarySystemFill))
        case .plainTinted:
            Capsule().fill(Color.clear)
        }
    }
}

/// Back-compat shim for Stage 1–3 call sites that still construct `GlassActionButtonStyle(tint:)`.
/// It maps the old tint-based API onto the new role enum: the blue accent (or no tint) => primary,
/// anything else => secondary. New code should use `AppButtonStyle(role:)` directly.
struct GlassActionButtonStyle: ButtonStyle {
    var tint: Color = Brand.accent
    private var role: AppButtonRole { tint == Brand.accent ? .primary : .secondary }
    func makeBody(configuration: Configuration) -> some View {
        AppButtonStyle(role: role).makeBody(configuration: configuration)
    }
}

// MARK: - Pro / credits chip

/// The single quiet Pro/credits treatment from the design system: a tinted-material chip with an SF
/// Symbol — NEVER a blue glow or gold ring. Used for the toolbar Pro badge and locked Style-Wall tiles.
struct ProChip: View {
    var text: String = "PRO"
    var systemImage: String = "lock.fill"
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Brand.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.thinMaterial, in: Capsule())
    }
}

/// Toolbar credit-balance chip — a count next to a quiet symbol, same tinted-material treatment.
struct CreditChip: View {
    var count: Int
    var body: some View {
        Label("\(count)", systemImage: "sparkles")
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Brand.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("\(count) sticker credits")
    }
}

// MARK: - Backdrop

/// The app's neutral backdrop — the system grouped background, so it is correct in Light and Dark Mode
/// (and respects Increase Contrast / Reduce Transparency). Name kept to avoid churn at call sites; the
/// old forced-dark aurora black wash is gone.
struct AppBackground: View {
    var body: some View {
        Color(.systemGroupedBackground).ignoresSafeArea()
    }
}

/// Back-compat alias for Stage 1–3 call sites that still reference `AuroraBackground`.
typealias AuroraBackground = AppBackground

import SwiftUI
import Combine

/// "Remix in Peel" deep-link plumbing (P3 — Lens 0's top retention graft).
///
/// Every sent Peel sticker is a template: tapping a received sticker (from the iMessage extension or the
/// keyboard) opens `peel://remix?template=<id>`, which lands the user on a fresh photo pick with that
/// exact look pre-applied — pulling them (and their friends) back into the app.
///
/// The URL carries only a template id (a public, built-in look — never user pixels), so the link is safe
/// to embed in a sticker filename / message and contains nothing private.
@MainActor
final class RemixLink: ObservableObject {
    static let shared = RemixLink()

    /// The template id from the most recent remix link, if one is pending. RootView observes this,
    /// presents the photo picker, and on pick seeds the editor with `StyleCatalog.template(id:)`'s look.
    @Published var pendingTemplateID: String?

    private init() {}

    /// Build the deep link for a given template id (delegates to the Shared builder used by extensions).
    static func url(templateID: String) -> URL? { AppGroup.remixURL(templateID: templateID) }

    /// Parse + record an incoming `peel://remix?template=<id>` URL. Ignores anything else.
    static func handle(_ url: URL) {
        guard url.scheme == AppGroup.urlScheme, url.host == AppGroup.remixHost,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "template" })?.value,
              !id.isEmpty else { return }
        shared.pendingTemplateID = id
    }

    func clear() { pendingTemplateID = nil }
}

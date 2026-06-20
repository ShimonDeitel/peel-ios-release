import SwiftUI
import AuthenticationServices

/// Required Sign in with Apple. The account identifies each user so Pro status can be recorded in
/// CloudKit (owner-visible) and follow them across devices. Stores the stable Apple user id locally
/// and publishes changes so the launch gate reacts immediately.
@MainActor
final class AccountManager: ObservableObject {
    @Published private(set) var userID: String
    @Published private(set) var displayName: String
    @Published var lastError: String?

    private let userIDKey = "appleUserID"
    private let displayNameKey = "appleDisplayName"

    init() {
        let defaults = UserDefaults.standard
        userID = defaults.string(forKey: userIDKey) ?? ""
        displayName = defaults.string(forKey: displayNameKey) ?? ""
    }

    var isSignedIn: Bool { !userID.isEmpty }

    func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            userID = cred.user
            UserDefaults.standard.set(cred.user, forKey: userIDKey)
            if let name = cred.fullName, let given = name.givenName {
                displayName = [given, name.familyName].compactMap { $0 }.joined(separator: " ")
                UserDefaults.standard.set(displayName, forKey: displayNameKey)
            }
            lastError = nil
            Haptics.success()
        case .failure(let error):
            // Ignore explicit user cancellation; surface every other failure so the user can retry.
            if let e = error as? ASAuthorizationError, e.code == .canceled { return }
            lastError = "Sign in didn't complete. Please try again."
            Haptics.warn()
        }
    }

    func signOut() {
        userID = ""
        displayName = ""
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: displayNameKey)
        Haptics.tap()
    }

    /// Re-checks that the stored Apple ID credential is still valid on launch.
    func refreshCredentialState() {
        guard isSignedIn else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { [weak self] state, _ in
            if state == .revoked || state == .notFound {
                Task { @MainActor in self?.signOut() }
            }
        }
    }
}

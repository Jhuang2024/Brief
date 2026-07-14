import Foundation
import GoogleSignIn
import UIKit

/// Wraps Google Sign-In for read-only Calendar and Gmail access.
/// Never requests write scopes; never creates, edits or deletes anything.
/// Calendar is the primary connection (requested at connect time); Gmail is
/// an incremental grant added later from Settings, so connecting Calendar
/// never forces an email consent screen on someone who doesn't want it.
@MainActor
@Observable
final class GoogleAuthenticationService {
    static let calendarReadOnlyScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let gmailReadOnlyScope = "https://www.googleapis.com/auth/gmail.readonly"

    enum ConnectionState: Equatable {
        case notConfigured
        case disconnected
        case connected(email: String)
        case tokenExpired
        case missingScope

        var displayName: String {
            switch self {
            case .notConfigured: return "Not set up"
            case .disconnected: return "Disconnected"
            case .connected(let email): return "Connected: \(email)"
            case .tokenExpired: return "Token expired"
            case .missingScope: return "Permission missing"
            }
        }
    }

    enum AuthError: LocalizedError {
        case notConnected
        case missingScope
        case noPresentingViewController
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Google Calendar is not connected."
            case .missingScope: return "Calendar permission was not granted."
            case .noPresentingViewController: return "Could not present the Google sign-in screen."
            case .notConfigured:
                return "Google Calendar isn't set up yet. Add your OAuth client ID and URL scheme to Info.plist. See SETUP.md."
            }
        }
    }

    /// Placeholder value shipped in Info.plist before setup. iOS OAuth
    /// clients have no runtime "enter your credentials" step: the client
    /// ID and its matching redirect URL scheme must be baked into
    /// Info.plist at build time, per SETUP.md.
    private static let placeholderClientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"

    /// The Info.plist `GIDClientID`, if present and not the placeholder.
    static var configuredClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !value.isEmpty,
              value != placeholderClientID
        else { return nil }
        return value
    }

    static var isConfigured: Bool { configuredClientID != nil }

    /// Explicitly configures GIDSignIn from Info.plist rather than
    /// relying on the SDK's implicit lookup. Safe to call even when not
    /// configured; `connect()` checks `isConfigured` before signing in.
    static func configureIfPossible() {
        guard let clientID = configuredClientID else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    private(set) var state: ConnectionState = .disconnected

    init() {
        if !Self.isConfigured {
            state = .notConfigured
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// True when a Google session exists on this device, even if it has
    /// not been restored yet in this launch.
    var hasPreviousSession: Bool {
        Self.isConfigured && GIDSignIn.sharedInstance.hasPreviousSignIn()
    }

    /// True once a live session actually exists in *this* process. This is
    /// the condition the Calendar fetch really depends on: `hasPreviousSession`
    /// only reports that a sign-in exists on disk, but the token fetch needs
    /// `currentUser`, which stays nil until `restorePreviousSession()` has
    /// run in this launch. The gap between the two is the classic cause of a
    /// brief reporting "Calendar unavailable" while Settings shows Connected.
    var hasLiveSession: Bool {
        Self.isConfigured && GIDSignIn.sharedInstance.currentUser != nil
    }

    /// A human-readable, token-free snapshot of the live Google session,
    /// for the Settings "Test Calendar" diagnostic and generation failure
    /// notes. Never includes an access or refresh token.
    var sessionDiagnostic: String {
        guard Self.isConfigured else {
            return "OAuth client ID is not configured in Info.plist (see SETUP.md)."
        }
        let hasPrevious = GIDSignIn.sharedInstance.hasPreviousSignIn()
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            return "No live session in this process (currentUser is nil); "
                + "previous sign-in on disk: \(hasPrevious); state: \(state.displayName)."
        }
        let scopes = user.grantedScopes ?? []
        let hasCalendarScope = scopes.contains(Self.calendarReadOnlyScope)
        let hasGmail = scopes.contains(Self.gmailReadOnlyScope)
        let email = user.profile?.email ?? "unknown account"
        return "Live session for \(email); calendar.readonly granted: \(hasCalendarScope); "
            + "gmail.readonly granted: \(hasGmail); state: \(state.displayName)."
    }

    /// Whether the live session may read Gmail. False when disconnected,
    /// not yet restored this launch, or the scope was never granted.
    var hasGmailScope: Bool {
        GIDSignIn.sharedInstance.currentUser?.grantedScopes?.contains(Self.gmailReadOnlyScope) == true
    }

    /// Restore the previous session on launch.
    func restorePreviousSession() async {
        guard Self.isConfigured else {
            state = .notConfigured
            return
        }
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            state = .disconnected
            return
        }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            updateState(for: user)
        } catch {
            state = .tokenExpired
        }
    }

    /// One-time connection from Settings, requesting only the read-only scope.
    func connect() async throws {
        guard Self.isConfigured else {
            state = .notConfigured
            throw AuthError.notConfigured
        }
        guard let presenter = Self.presentingViewController() else {
            throw AuthError.noPresentingViewController
        }
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenter,
            hint: nil,
            additionalScopes: [Self.calendarReadOnlyScope]
        )
        updateState(for: result.user)
        if state == .missingScope {
            throw AuthError.missingScope
        }
    }

    func disconnect() {
        GIDSignIn.sharedInstance.signOut()
        state = .disconnected
    }

    /// Incremental Gmail grant from Settings, added to the existing signed-in
    /// account so the user only re-consents to the one new scope. Falls back
    /// to a full sign-in (with both read-only scopes) when there's no live
    /// session to add to.
    func grantGmailAccess() async throws {
        guard Self.isConfigured else {
            state = .notConfigured
            throw AuthError.notConfigured
        }
        guard let presenter = Self.presentingViewController() else {
            throw AuthError.noPresentingViewController
        }
        if let user = GIDSignIn.sharedInstance.currentUser {
            let result = try await user.addScopes([Self.gmailReadOnlyScope], presenting: presenter)
            updateState(for: result.user)
        } else {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: [Self.calendarReadOnlyScope, Self.gmailReadOnlyScope]
            )
            updateState(for: result.user)
        }
    }

    /// A fresh access token, refreshing when required. Grants the caller
    /// nothing beyond the read-only scope it names; callers state which one
    /// they need so a missing Gmail grant can never be papered over by a
    /// calendar-only session (or vice versa). Only a missing CALENDAR scope
    /// moves the connection state to `.missingScope` — that state describes
    /// the primary Calendar connection shown in Settings, and Gmail being
    /// ungranted is an ordinary, deliberate configuration, not a broken one.
    func accessToken(requiring scope: String = calendarReadOnlyScope) async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            state = GIDSignIn.sharedInstance.hasPreviousSignIn() ? .tokenExpired : .disconnected
            throw AuthError.notConnected
        }
        guard user.grantedScopes?.contains(scope) == true else {
            if scope == Self.calendarReadOnlyScope {
                state = .missingScope
            }
            throw AuthError.missingScope
        }
        do {
            let refreshed = try await user.refreshTokensIfNeeded()
            updateState(for: refreshed)
            return refreshed.accessToken.tokenString
        } catch {
            state = .tokenExpired
            throw error
        }
    }

    private func updateState(for user: GIDGoogleUser) {
        let email = user.profile?.email ?? "Google account"
        if user.grantedScopes?.contains(Self.calendarReadOnlyScope) == true {
            state = .connected(email: email)
        } else {
            state = .missingScope
        }
    }

    private static func presentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

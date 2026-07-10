import Foundation
import GoogleSignIn
import UIKit

/// Wraps Google Sign-In for read-only Calendar access.
/// Never requests write scopes; never creates, edits or deletes events.
@MainActor
@Observable
final class GoogleAuthenticationService {
    static let calendarReadOnlyScope = "https://www.googleapis.com/auth/calendar.readonly"

    enum ConnectionState: Equatable {
        case disconnected
        case connected(email: String)
        case tokenExpired
        case missingScope

        var displayName: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connected(let email): return "Connected — \(email)"
            case .tokenExpired: return "Token expired"
            case .missingScope: return "Permission missing"
            }
        }
    }

    enum AuthError: LocalizedError {
        case notConnected
        case missingScope
        case noPresentingViewController

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Google Calendar is not connected."
            case .missingScope: return "Calendar permission was not granted."
            case .noPresentingViewController: return "Could not present the Google sign-in screen."
            }
        }
    }

    private(set) var state: ConnectionState = .disconnected

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// True when a Google session exists on this device, even if it has
    /// not been restored yet in this launch.
    var hasPreviousSession: Bool {
        GIDSignIn.sharedInstance.hasPreviousSignIn()
    }

    /// Restore the previous session on launch.
    func restorePreviousSession() async {
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

    /// A fresh access token, refreshing when required. Grants the caller
    /// nothing beyond calendar.readonly.
    func accessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            state = GIDSignIn.sharedInstance.hasPreviousSignIn() ? .tokenExpired : .disconnected
            throw AuthError.notConnected
        }
        guard user.grantedScopes?.contains(Self.calendarReadOnlyScope) == true else {
            state = .missingScope
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

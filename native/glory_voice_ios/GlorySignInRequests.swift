import Foundation

// Provider-independent lifecycle shared by the UIKit adapter and host tests.
// Cancelling a request destroys its proof while retaining the OS single-flight
// lease until the provider's eventual callback.
final class GlorySignInRequests {
    private var nextID = 0
    private var replies: [Int: [String: Any]] = [:]
    private var started: [Int: Date] = [:]
    private(set) var activeID: Int?

    func create(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-180)
        for id in Array(started.keys) where started[id]! < cutoff && id != activeID { cancel(id) }
        nextID += 1
        started[nextID] = now
        return nextID
    }

    func activate(_ id: Int) -> Bool {
        guard activeID == nil, started[id] != nil else { return false }
        activeID = id
        return true
    }

    func reply(_ id: Int, _ value: [String: Any]) {
        if started[id] != nil { replies[id] = value }
    }

    func finish(_ id: Int, _ value: [String: Any]) {
        guard activeID == id else { return }
        reply(id, value)
        activeID = nil
    }

    func cancel(_ id: Int) {
        started.removeValue(forKey: id)
        replies.removeValue(forKey: id)
    }

    func poll(_ id: Int) -> [String: Any] {
        if let value = replies.removeValue(forKey: id) {
            started.removeValue(forKey: id)
            return value
        }
        return started[id] != nil ? ["state": "pending"]
            : ["state": "error", "error": "signin_unknown_request"]
    }

    func clear() {
        started.removeAll()
        replies.removeAll()
    }

    static func validNonce(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func appleProof(identityToken: Data?, authorizationCode: Data?, state: String?, expectedState: String?) -> [String: Any] {
        guard let expectedState, !expectedState.isEmpty, state == expectedState,
              let identityToken, let token = String(data: identityToken, encoding: .utf8), !token.isEmpty,
              let authorizationCode, let code = String(data: authorizationCode, encoding: .utf8), !code.isEmpty else {
            return ["state": "error", "error": "apple_missing_token"]
        }
        return ["state": "ok", "id_token": token, "authorization_code": code]
    }

    static func acceptsGoogleURL(provider: String?, scheme: String?, expectedScheme: String?) -> Bool {
        guard provider == "google", let expectedScheme, !expectedScheme.isEmpty, let scheme else { return false }
        return scheme.caseInsensitiveCompare(expectedScheme) == .orderedSame
    }
}

import Foundation

@main
struct GlorySignInRequestsTests {
    static var checks = 0

    static func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        precondition(value(), name)
    }

    static func state(_ reply: [String: Any]) -> String { reply["state"] as? String ?? "" }

    static func main() {
        let queue = GlorySignInRequests()
        let first = queue.create()
        expect(state(queue.poll(first)) == "pending", "pending before the OS returns")
        expect(queue.activate(first), "first request acquires OS flight")
        let second = queue.create()
        expect(!queue.activate(second), "a second sheet cannot replace the first")
        queue.reply(second, ["state": "error", "error": "signin_busy"])
        expect(queue.poll(second)["error"] as? String == "signin_busy", "busy error is returned to its own caller")
        expect(state(queue.poll(second)) == "error", "busy response is consumed")
        queue.finish(second, ["state": "ok", "id_token": "untrusted"])
        expect(queue.activeID == first, "unrelated completion cannot release the current flight")
        queue.cancel(first)
        expect(queue.activeID == first, "timeout retains the OS flight lease")
        expect(state(queue.poll(first)) == "error", "cancelled request is no longer pending")
        let retry = queue.create()
        expect(!queue.activate(retry), "retry waits for the abandoned OS sheet to close")
        queue.finish(first, ["state": "ok", "id_token": "late-proof"])
        expect(queue.activeID == nil, "late completion releases OS flight")
        expect(queue.poll(first)["id_token"] == nil, "late proof cannot resurrect cancelled credentials")
        expect(queue.activate(retry), "new OS sheet can begin after callback")
        queue.finish(retry, ["state": "ok", "id_token": "one-use-proof"])
        expect(queue.poll(retry)["id_token"] as? String == "one-use-proof", "terminal proof delivered once")
        expect(queue.poll(retry)["id_token"] == nil, "terminal proof removed after delivery")
        let old = queue.create(now: Date(timeIntervalSince1970: 1))
        queue.reply(old, ["state": "ok", "id_token": "expired-proof"])
        _ = queue.create(now: Date(timeIntervalSince1970: 182))
        expect(queue.poll(old)["id_token"] == nil, "abandoned terminal proof expires")
        let shutdown = queue.create()
        queue.reply(shutdown, ["state": "ok", "id_token": "shutdown-proof"])
        queue.clear()
        expect(queue.poll(shutdown)["id_token"] == nil, "shutdown clears pending credentials")

        let token = Data("test-id-token".utf8), code = Data("test-authorization-code".utf8)
        func apple(_ token: Data?, _ code: Data?, _ state: String? = "expected", _ expected: String? = "expected") -> [String: Any] {
            GlorySignInRequests.appleProof(identityToken: token, authorizationCode: code, state: state, expectedState: expected)
        }
        expect(state(apple(token, code)) == "ok", "Apple proof accepted only with matching request state")
        expect(apple(token, code)["authorization_code"] as? String == "test-authorization-code", "one-use Apple code accompanies ID token")
        expect(state(apple(token, code, "different")) == "error", "wrong Apple request state rejected")
        expect(state(apple(token, code, nil)) == "error", "missing Apple response state rejected")
        expect(state(apple(token, code, nil, nil)) == "error", "missing expected state never matches nil response")
        expect(state(apple(nil, code)) == "error", "missing Apple identity token rejected")
        expect(state(apple(token, nil)) == "error", "missing Apple code rejected")
        expect(state(apple(Data(), code)) == "error", "empty Apple token rejected")
        expect(state(apple(token, Data())) == "error", "empty Apple code rejected")
        expect(state(apple(Data([0xff]), code)) == "error", "malformed Apple token encoding rejected")
        expect(GlorySignInRequests.validNonce(String(repeating: "a1", count: 32)), "SHA-256 nonce accepted")
        expect(!GlorySignInRequests.validNonce(""), "empty nonce rejected")
        expect(!GlorySignInRequests.validNonce(String(repeating: "a", count: 63)), "short nonce rejected")
        expect(!GlorySignInRequests.validNonce(String(repeating: "g", count: 64)), "non-hex nonce rejected")

        let scheme = "com.googleusercontent.apps.example"
        func accepts(_ provider: String?, _ actual: String?, _ expected: String?) -> Bool {
            GlorySignInRequests.acceptsGoogleURL(provider: provider, scheme: actual, expectedScheme: expected)
        }
        expect(accepts("google", scheme, scheme), "Google callback allowed for active Google flow")
        expect(accepts("google", scheme.uppercased(), scheme), "URL scheme matching is case insensitive")
        expect(!accepts("apple", scheme, scheme), "Apple flow does not consume Google callback")
        expect(!accepts(nil, scheme, scheme), "unsolicited Google callback is ignored")
        expect(!accepts("google", "other-app", scheme), "unrelated URL is forwarded to original delegate")
        expect(!accepts("google", nil, scheme), "missing callback scheme ignored")
        expect(!accepts("google", scheme, nil), "unconfigured client does not consume callback")
        print("GlorySignIn native lifecycle: \(checks) checks passed")
    }
}

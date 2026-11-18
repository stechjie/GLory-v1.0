import AuthenticationServices
import Foundation
import GoogleSignIn
import UIKit

// Called only on the main thread by the Godot adapter. Identity proofs remain in
// memory until one terminal poll consumes them; abandoned replies expire.
@MainActor @objc(GlorySignInNative)
final class GlorySignInNative: NSObject, ASAuthorizationControllerDelegate,
                              ASAuthorizationControllerPresentationContextProviding {
    @objc static let shared = GlorySignInNative()
    private let requests = GlorySignInRequests()
    private var activeID: Int? { requests.activeID }
    private var activeProvider: String?
    private var appleController: ASAuthorizationController?
    private var appleState: String?
    private var presentationWindow: UIWindow?

    private func infoString(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validClientID(_ value: String) -> Bool {
        value.hasSuffix(".apps.googleusercontent.com") && !value.contains(" ")
    }

    private func googleScheme() -> String? {
        let client = infoString("GIDClientID")
        guard validClientID(client) else { return nil }
        return client.split(separator: ".").reversed().joined(separator: ".")
    }

    @objc func isGoogleAvailable() -> Bool {
        guard let scheme = googleScheme(), validClientID(infoString("GIDServerClientID")),
              let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        else { return false }
        return types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(scheme) }
    }

    @objc func isAppleAvailable() -> Bool {
        // iOS 15 is the framework's minimum. The packaging gate verifies the
        // Apple capability in both the provisioning profile and signed app.
        true
    }

    private func request() -> Int {
        let id = requests.create()
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in self?.cancelSignIn(id) }
        return id
    }

    private func validNonce(_ value: String) -> Bool {
        GlorySignInRequests.validNonce(value)
    }

    private func currentWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }

    private func presenter() -> UIViewController? {
        guard let window = currentWindow(), var controller = window.rootViewController else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        guard !controller.isBeingDismissed else { return nil }
        presentationWindow = window
        return controller
    }

    private func finish(_ id: Int, _ result: [String: Any]) {
        guard activeID == id else { return }
        // cancelSignIn removes the request; a late OS callback must not bring
        // its discarded credentials back into the reply table.
        requests.finish(id, result)
        activeProvider = nil
        appleController = nil
        appleState = nil
        presentationWindow = nil
    }

    @objc func beginGoogleSignIn(_ webClientID: String, nonce: String) -> Int {
        let id = request()
        guard activeID == nil else { requests.reply(id, ["state": "error", "error": "signin_busy"]); return id }
        guard isGoogleAvailable(), webClientID == infoString("GIDServerClientID"), validNonce(nonce) else {
            requests.reply(id, ["state": "error", "error": "google_not_configured"])
            return id
        }
        guard let controller = presenter() else {
            requests.reply(id, ["state": "error", "error": "signin_no_window"])
            return id
        }
        guard requests.activate(id) else { return id }
        activeProvider = "google"
        let sdk = GIDSignIn.sharedInstance
        sdk.configuration = GIDConfiguration(clientID: infoString("GIDClientID"), serverClientID: webClientID)
        // A fresh interactive request permits account switching. The game keeps
        // its own refresh session; it does not restore an SDK account at launch.
        sdk.signOut()
        sdk.signIn(withPresenting: controller, hint: nil, additionalScopes: nil, nonce: nonce) { [weak self] result, error in
            let token = result?.user.idToken?.tokenString
            let nativeError = error as NSError?
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { GIDSignIn.sharedInstance.signOut() }
                if let nativeError {
                    if nativeError.domain == kGIDSignInErrorDomain && nativeError.code == GIDSignInError.canceled.rawValue {
                        self.finish(id, ["state": "cancelled"])
                    } else {
                        // SDK descriptions can contain redirect URLs, account
                        // details or tokens; only this stable code leaves it.
                        self.finish(id, ["state": "error", "error": "google_signin_failed"])
                    }
                    return
                }
                guard let token, !token.isEmpty else {
                    self.finish(id, ["state": "error", "error": "google_missing_token"])
                    return
                }
                self.finish(id, ["state": "ok", "id_token": token])
            }
        }
        return id
    }

    @objc func beginAppleSignIn(_ nonce: String) -> Int {
        let id = request()
        guard activeID == nil else { requests.reply(id, ["state": "error", "error": "signin_busy"]); return id }
        guard isAppleAvailable(), validNonce(nonce) else {
            requests.reply(id, ["state": "error", "error": "apple_not_configured"])
            return id
        }
        guard presenter() != nil else {
            requests.reply(id, ["state": "error", "error": "signin_no_window"])
            return id
        }
        guard requests.activate(id) else { return id }
        activeProvider = "apple"
        let state = UUID().uuidString
        appleState = state
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = nonce
        request.state = state
        let controller = ASAuthorizationController(authorizationRequests: [request])
        appleController = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
        return id
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // presenter() retains the actual foreground window before performRequests.
        presentationWindow ?? currentWindow() ?? UIWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === appleController, let id = activeID else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(id, ["state": "error", "error": "apple_missing_token"])
            return
        }
        finish(id, GlorySignInRequests.appleProof(identityToken: credential.identityToken,
            authorizationCode: credential.authorizationCode, state: credential.state, expectedState: appleState))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === appleController, let id = activeID else { return }
        let value = error as NSError
        if value.domain == ASAuthorizationError.errorDomain && value.code == ASAuthorizationError.canceled.rawValue {
            finish(id, ["state": "cancelled"])
        } else {
            finish(id, ["state": "error", "error": "apple_signin_failed"])
        }
    }

    @objc func pollSignIn(_ id: Int) -> String {
        let reply = requests.poll(id)
        let data = try? JSONSerialization.data(withJSONObject: reply)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"state\":\"error\"}"
    }

    @objc func cancelSignIn(_ id: Int) {
        requests.cancel(id)
        if activeID == id, activeProvider == "apple", #available(iOS 16.0, *) {
            appleController?.cancel()
        }
        // Google has no public cancel API. Keep the OS request single-flight
        // until its callback, discarding its result if the game timed out.
    }

    @objc func handleURL(_ url: URL) -> Bool {
        guard GlorySignInRequests.acceptsGoogleURL(provider: activeProvider, scheme: url.scheme,
            expectedScheme: googleScheme()) else { return false }
        return GIDSignIn.sharedInstance.handle(url)
    }

    @objc func shutdown() {
        if let id = activeID { cancelSignIn(id) }
        requests.clear()
        GIDSignIn.sharedInstance.signOut()
    }
}

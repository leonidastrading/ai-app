import Foundation
import AppKit
import CryptoKit
import Network
import Security

/// Google sign-in + cloud session for the Mac app.
///
/// Sign-in uses the system browser with a loopback redirect (the standard
/// desktop OAuth flow), exchanges the code for a Google ID token, signs in to
/// Firebase (signInWithIdp over REST), and keeps the Firebase refresh token in
/// the Keychain so you stay signed in. Reads/writes `users/{uid}.data` in
/// Firestore over REST — the single-JSON-blob shape the Windows and web apps
/// also use.
@MainActor
final class AuthStore: ObservableObject {
    struct Account: Equatable {
        var uid: String
        var email: String
        var name: String
        var photo: String
    }

    @Published private(set) var account: Account?
    @Published private(set) var busy = false
    @Published var lastError: String?

    var isSignedIn: Bool { account != nil }

    private var idToken: String?
    private var refreshToken: String?
    private var expiresAt = Date.distantPast
    private let refreshAccount = "firebase.refreshToken"

    // MARK: - Session lifecycle

    /// Restore a saved session (silent). Returns true if signed in.
    @discardableResult
    func restore() async -> Bool {
        guard let saved = Keychain.read(refreshAccount), !saved.isEmpty else { return false }
        refreshToken = saved
        do { _ = try await validToken(); return account != nil }
        catch { return false }
    }

    func signOut() {
        account = nil
        idToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        Keychain.delete(refreshAccount)
    }

    // MARK: - Interactive sign-in

    func signIn() async {
        guard CloudConfig.isConfigured else {
            lastError = "Sign-in isn't configured in this build. Please reinstall the latest UAI."
            return
        }
        busy = true; lastError = nil
        defer { busy = false }
        do {
            let verifier = Self.randomURLSafe(32)
            let challenge = Self.codeChallenge(for: verifier)
            let state = Self.randomURLSafe(16)
            let (code, port) = try await loopbackAuthCode(challenge: challenge, state: state)
            let googleIdToken = try await exchangeGoogleCode(code, port: port, verifier: verifier)
            try await firebaseSignIn(googleIdToken: googleIdToken)
        } catch {
            lastError = (error as NSError).localizedDescription
        }
    }

    // MARK: - Token exchange / refresh

    private func exchangeGoogleCode(_ code: String, port: UInt16, verifier: String) async throws -> String {
        let body = Self.form([
            "code": code,
            "client_id": CloudConfig.googleClientId,
            "client_secret": CloudConfig.googleClientSecret,
            "redirect_uri": "http://127.0.0.1:\(port)",
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        let json = try await postForm(url: "https://oauth2.googleapis.com/token", body: body)
        guard let idTok = json["id_token"] as? String else { throw Self.err("No Google ID token returned") }
        return idTok
    }

    private func firebaseSignIn(googleIdToken: String) async throws {
        let payload: [String: Any] = [
            "postBody": "id_token=\(googleIdToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnSecureToken": true,
        ]
        let json = try await postJSON(
            url: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(CloudConfig.firebaseApiKey)",
            body: payload)
        apply(idToken: json["idToken"] as? String,
              refresh: json["refreshToken"] as? String,
              expiresIn: json["expiresIn"],
              uid: json["localId"] as? String,
              email: json["email"] as? String,
              name: json["displayName"] as? String,
              photo: json["photoUrl"] as? String)
        if let rt = refreshToken { Keychain.write(rt, for: refreshAccount) }
    }

    private func refreshIfNeeded() async throws {
        guard let rt = refreshToken else { throw Self.err("Not signed in") }
        let body = Self.form(["grant_type": "refresh_token", "refresh_token": rt])
        let json = try await postForm(url: "https://securetoken.googleapis.com/v1/token?key=\(CloudConfig.firebaseApiKey)", body: body)
        apply(idToken: json["id_token"] as? String,
              refresh: json["refresh_token"] as? String,
              expiresIn: json["expires_in"],
              uid: json["user_id"] as? String,
              email: account?.email, name: account?.name, photo: account?.photo)
        if let rt = refreshToken { Keychain.write(rt, for: refreshAccount) }
    }

    private func validToken() async throws -> String {
        if let t = idToken, Date() < expiresAt { return t }
        try await refreshIfNeeded()
        guard let t = idToken else { throw Self.err("Could not refresh session") }
        return t
    }

    private func apply(idToken: String?, refresh: String?, expiresIn: Any?, uid: String?,
                       email: String?, name: String?, photo: String?) {
        if let idToken { self.idToken = idToken }
        if let refresh { self.refreshToken = refresh }
        let secs = Double("\(expiresIn ?? "3600")") ?? 3600
        self.expiresAt = Date().addingTimeInterval(secs - 60)
        if let uid {
            self.account = Account(uid: uid, email: email ?? account?.email ?? "",
                                   name: name ?? account?.name ?? "",
                                   photo: photo ?? account?.photo ?? "")
        }
    }

    // MARK: - Firestore REST (single JSON blob in users/{uid}.data)

    private func docURL(_ uid: String) -> String {
        "https://firestore.googleapis.com/v1/projects/\(CloudConfig.projectId)/databases/(default)/documents/users/\(uid)"
    }

    /// Download this account's synced data blob (empty dictionary if none yet).
    func pull() async -> [String: Any] {
        guard let uid = account?.uid else { return [:] }
        do {
            let token = try await validToken()
            var req = URLRequest(url: URL(string: docURL(uid))!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fields = obj["fields"] as? [String: Any],
                  let dataField = fields["data"] as? [String: Any],
                  let s = dataField["stringValue"] as? String,
                  let blob = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
            else { return [:] }
            return blob
        } catch { return [:] }
    }

    /// Upload the full synced data blob.
    @discardableResult
    func push(_ blob: [String: Any]) async -> Bool {
        guard let uid = account?.uid else { return false }
        do {
            let token = try await validToken()
            let blobData = try JSONSerialization.data(withJSONObject: blob)
            let blobString = String(data: blobData, encoding: .utf8) ?? "{}"
            let fields: [String: Any] = [
                "fields": [
                    "data": ["stringValue": blobString],
                    "updatedAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())],
                ]
            ]
            var comps = URLComponents(string: docURL(uid))!
            comps.queryItems = [
                URLQueryItem(name: "updateMask.fieldPaths", value: "data"),
                URLQueryItem(name: "updateMask.fieldPaths", value: "updatedAt"),
            ]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "PATCH"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: fields)
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: - HTTP helpers

    private func postForm(url: String, body: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        return try await send(req)
    }

    private func postJSON(url: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String
            throw Self.err(msg ?? "Request failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return json
    }

    // MARK: - Loopback listener

    private func loopbackAuthCode(challenge: String, state: String) async throws -> (code: String, port: UInt16) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, UInt16), Error>) in
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Bind to loopback only.
            params.requiredInterfaceType = .loopback
            let listener: NWListener
            do { listener = try NWListener(using: params) } catch { cont.resume(throwing: error); return }

            let lock = NSLock()
            var done = false
            @Sendable func finish(_ result: Result<(String, UInt16), Error>) {
                lock.lock(); defer { lock.unlock() }
                if done { return }; done = true
                listener.cancel()
                cont.resume(with: result)
            }

            listener.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    let auth = "https://accounts.google.com/o/oauth2/v2/auth?" + Self.form([
                        "client_id": CloudConfig.googleClientId,
                        "redirect_uri": "http://127.0.0.1:\(port)",
                        "response_type": "code",
                        "scope": "openid email profile",
                        "code_challenge": challenge,
                        "code_challenge_method": "S256",
                        "state": state,
                        "prompt": "select_account",
                    ])
                    if let url = URL(string: auth) {
                        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    }
                case .failed(let e): finish(.failure(e))
                default: break
                }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    let port = listener.port?.rawValue ?? 0
                    var code: String?
                    var oauthError: String?
                    if let data, let request = String(data: data, encoding: .utf8) {
                        (code, oauthError) = Self.parseCode(request, expectedState: state)
                    }
                    let body = "<!doctype html><meta charset=utf-8><title>UAI</title>" +
                        "<body style='font:16px -apple-system,system-ui;background:#0b0b14;color:#e7e9ee;display:flex;height:100vh;align-items:center;justify-content:center'>" +
                        "<div style='text-align:center'><h2>You're signed in to UAI</h2><p>You can close this tab and return to the app.</p></div>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                        "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    if let code { finish(.success((code, port))) }
                    else if let oauthError { finish(.failure(Self.err(oauthError))) }
                }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                finish(.failure(Self.err("Sign-in timed out")))
            }
        }
    }

    /// Parse the authorization code (or error) from the first line of the HTTP request.
    private nonisolated static func parseCode(_ request: String, expectedState: String) -> (code: String?, error: String?) {
        guard let firstLine = request.split(separator: "\r\n").first,
              let path = firstLine.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://127.0.0.1\(path)") else {
            return (nil, nil)
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let e = value("error") { return (nil, e) }
        guard let code = value("code") else { return (nil, nil) }
        guard value("state") == expectedState else { return (nil, "State mismatch") }
        return (code, nil)
    }

    // MARK: - utils

    private nonisolated static func form(_ dict: [String: String]) -> String {
        dict.map { key, val in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? key
            let v = val.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? val
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
    private nonisolated static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return base64URL(Data(bytes))
    }
    private nonisolated static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private nonisolated static func err(_ msg: String) -> NSError {
        NSError(domain: "UAI.Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

private extension CharacterSet {
    /// Characters allowed unescaped in an x-www-form-urlencoded value.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

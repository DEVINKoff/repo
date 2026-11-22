import Foundation

/// The app's identity in listening data (`PlayEventIn.client`: `app/<versionName>`; `/api/dislikes` → `source` `app`).
enum AppInfo {
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    static let client = "app/\(version)-ios"
}

struct ApiError: LocalizedError, Sendable {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

extension Notification.Name {
    /// The app switched between the Hub's home and outside addresses.
    static let hubRouteChanged = Notification.Name("hm.route")
    /// The Hub answered 401: the app goes back to the sign-in screen (client.ts `UNAUTHORIZED_EVENT`).
    static let hubUnauthorized = Notification.Name("hm.unauthorized")
}

/// `api/client.ts`: JSON over the `hm_session` cookie (HTTPCookieStorage.shared, so images and AVPlayer share it).
final class HubClient: @unchecked Sendable {
    static let shared = HubClient()

    private let lock = NSLock()
    private var _base: URL?
    /// The address requests go to now: the home one, or the outside one while home can't be reached.
    var baseURL: URL? {
        get { lock.withLock { _base } }
        set { lock.withLock { _base = newValue } }
    }
    private var _home: URL?
    private var _remote: URL?
    /// The Hub on the home network (what the user typed first).
    var homeURL: URL? {
        get { lock.withLock { _home } }
        set { lock.withLock { _home = newValue; _base = newValue } }
    }
    /// The Hub from outside (a tunnel or the gateway): used when the home address doesn't answer — a VPN on the
    /// phone or the PC, mobile data.
    var remoteURL: URL? {
        get { lock.withLock { _remote } }
        set { lock.withLock { _remote = newValue } }
    }
    var onRemote: Bool { baseURL != nil && baseURL == remoteURL && remoteURL != homeURL }

    /// The other address than the one in use, if there is one.
    private var alternate: URL? {
        lock.withLock {
            guard let b = _base else { return nil }
            if b == _home { return _remote.flatMap { $0 == b ? nil : $0 } }
            return _home.flatMap { $0 == b ? nil : $0 }
        }
    }

    /// Switches to `url`, taking the session cookie along (the account stays signed in on both addresses).
    func use(_ url: URL) {
        if let from = baseURL, from != url { copySession(from: from, to: url) }
        baseURL = url
        NotificationCenter.default.post(name: .hubRouteChanged, object: nil)
    }

    private func copySession(from: URL, to: URL) {
        guard let c = HTTPCookieStorage.shared.cookies(for: from)?.first(where: { $0.name == "hm_session" }), let host = to.host else { return }
        var props: [HTTPCookiePropertyKey: Any] = [.name: c.name, .value: c.value, .domain: host, .path: "/"]
        if let e = c.expiresDate { props[.expires] = e }
        if to.scheme == "https" { props[.secure] = "TRUE" }
        if let copy = HTTPCookie(properties: props) { HTTPCookieStorage.shared.setCookie(copy) }
    }

    /// Back home when home answers again (called when the app comes to the front).
    func preferHome() async {
        guard let home = homeURL, baseURL != home else { return }
        var req = URLRequest(url: home.appendingPathComponent("healthz"))
        req.timeoutInterval = 2.5
        if let res = try? await session.data(for: req), (res.1 as? HTTPURLResponse)?.statusCode == 200 { use(home) }
    }

    let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: URLs

    func url(_ path: String, _ query: [String: String?] = [:]) -> URL? {
        guard let base = baseURL else { return nil }
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = c.percentEncodedPath.hasSuffix("/") ? String(c.percentEncodedPath.dropLast()) : c.percentEncodedPath
        c.percentEncodedPath = basePath + path
        let items = query.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : URLQueryItem(name: k, value: $0) } }
            .sorted { $0.name < $1.name }
        c.queryItems = items.isEmpty ? nil : items
        return c.url
    }

    /// A cover / image URL of the Hub ("/api/nd/cover/…") or an absolute one (Deezer).
    func absolute(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        guard let base = baseURL else { return nil }
        return URL(string: s, relativeTo: base)?.absoluteURL
    }

    /// `listenStreamUrl`: the audio of any ref (`dz:`, `hm:`, `nd:<song>`, `file:…`). `light` asks the Opus
    /// copy for a metered network (`q=mobile`, `app/light.py`).
    func streamURL(ref: String, light: Bool) -> URL? {
        url("/api/listen/stream", ["ref": ref, "q": light ? "mobile" : nil])
    }

    var cookies: [HTTPCookie] {
        guard let base = baseURL else { return [] }
        return HTTPCookieStorage.shared.cookies(for: base) ?? []
    }

    var hasSession: Bool { cookies.contains { $0.name == "hm_session" } }

    func clearCookies() {
        for c in cookies { HTTPCookieStorage.shared.deleteCookie(c) }
    }

    // MARK: Requests

    private static func message(_ detail: JSONValue?, status: Int) -> String {
        if let s = detail?.string, !s.isEmpty { return s }
        if case .array(let rows)? = detail {
            let msgs = rows.compactMap { row -> String? in
                if case .object(let o) = row, let m = o["msg"]?.string { return m }
                return nil
            }
            if !msgs.isEmpty { return "Неверные данные: " + msgs.joined(separator: "; ") }
        }
        switch status {
        case 401: return "Требуется вход"
        case 403: return "Нет доступа"
        case 404: return "Не найдено"
        case 413: return "Файл слишком большой"
        case 429: return "Слишком много запросов, попробуйте позже"
        case 500...: return "Ошибка сервера"
        default: return "Ошибка \(status)"
        }
    }

    private struct ErrorBody: Decodable { var detail: JSONValue? }

    func raw(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil,
             contentType: String? = "application/json", timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await rawOnce(method, path, query: query, body: body, contentType: contentType, timeout: timeout)
        } catch let e as ApiError where e.status == 0 {
            // no connection: the other address (home ↔ outside), once; it stays in use if it answers
            guard let other = alternate else { throw e }
            let from = baseURL
            use(other)
            do {
                return try await rawOnce(method, path, query: query, body: body, contentType: contentType, timeout: timeout.map { min($0, 15) })
            } catch let e2 as ApiError where e2.status == 0 {
                if let from { baseURL = from }
                throw e2
            }
        }
    }

    private func rawOnce(_ method: String, _ path: String, query: [String: String?], body: Data?,
                         contentType: String?, timeout: TimeInterval?) async throws -> (Data, HTTPURLResponse) {
        guard let url = url(path, query) else { throw ApiError(status: 0, message: "Сервер не выбран") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        if let timeout { req.timeoutInterval = timeout }
        // the home address answers within seconds or not at all (a VPN swallows it): don't hang on it for a minute
        else if alternate != nil && baseURL == homeURL { req.timeoutInterval = 8 }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            throw ApiError(status: 0, message: "Нет связи с сервером")
        }
        guard let http = response as? HTTPURLResponse else { throw ApiError(status: 0, message: "Нет связи с сервером") }
        if http.statusCode == 401, !path.hasPrefix("/api/auth/login"), !path.hasPrefix("/api/auth/register"), !path.hasPrefix("/api/auth/email/") {
            NotificationCenter.default.post(name: .hubUnauthorized, object: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(ErrorBody.self, from: data).detail
            throw ApiError(status: http.statusCode, message: Self.message(detail, status: http.statusCode))
        }
        return (data, http)
    }

    func request<T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], timeout: TimeInterval? = nil) async throws -> T {
        let (data, _) = try await raw(method, path, query: query, body: nil, timeout: timeout)
        return try decode(data)
    }

    func request<T: Decodable, B: Encodable>(_ method: String, _ path: String, json: B, query: [String: String?] = [:], timeout: TimeInterval? = nil) async throws -> T {
        let body = try encoder.encode(json)
        let (data, _) = try await raw(method, path, query: query, body: body, timeout: timeout)
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        if T.self == OkOut.self, data.isEmpty { return OkOut(ok: true) as! T }
        do { return try decoder.decode(T.self, from: data) } catch {
            #if DEBUG
            print("decode \(T.self):", error)
            #endif
            throw ApiError(status: 0, message: "Неожиданный ответ сервера")
        }
    }

    func encode<B: Encodable>(_ value: B) throws -> Data { try encoder.encode(value) }
    func decodeValue<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }

    // Short-lived cache for GET pages (client.ts `cachedGet`: back navigation feels instant).
    private var cache: [String: (at: Date, data: Data)] = [:]
    private let cacheTTL: TimeInterval = 180

    func cachedGet<T: Decodable>(_ path: String, query: [String: String?] = [:], fresh: Bool = false) async throws -> T {
        let key = url(path, query)?.absoluteString ?? path
        if !fresh, let hit = lock.withLock({ cache[key] }), Date().timeIntervalSince(hit.at) < cacheTTL {
            return try decode(hit.data)
        }
        let (data, _) = try await raw("GET", path, query: query)
        lock.withLock { cache[key] = (Date(), data) }
        return try decode(data)
    }

    func invalidateCache(_ prefix: String = "") {
        lock.withLock {
            if prefix.isEmpty { cache.removeAll() } else { cache = cache.filter { !$0.key.contains(prefix) } }
        }
    }
}

// MARK: - Typed endpoints (api in client.ts)

/// encodeURIComponent for one path segment.
private func enc(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? s
}

extension HubClient {
    // auth
    func login(_ body: LoginIn) async throws -> MeOut { try await request("POST", "/api/auth/login", json: body) }
    func logout() async throws -> OkOut { try await request("POST", "/api/auth/logout", json: [String: String]()) }
    func me() async throws -> MeOut { try await request("GET", "/api/auth/me") }
    func authOptions() async throws -> AuthOptionsOut { try await request("GET", "/api/auth/options", timeout: 8) }
    func register(_ body: RegisterIn) async throws -> MeOut { try await request("POST", "/api/auth/register", json: body) }
    func health() async throws -> HealthOut { try await request("GET", "/healthz", timeout: 5) }

    // search / catalog
    func search(_ q: String) async throws -> SearchOut { try await cachedGet("/api/search", query: ["q": q]) }
    func searchTracks(_ q: String, offset: Int) async throws -> SearchTracksOut {
        try await cachedGet("/api/search/tracks", query: ["q": q, "offset": String(offset)])
    }
    func searchProviders(_ q: String, group: String?) async throws -> ProviderSearchOut {
        try await cachedGet("/api/search/providers", query: ["q": q, "group": group])
    }
    func searchHistory() async throws -> SearchHistoryOut { try await request("GET", "/api/search/history") }
    func rememberSearch(_ query: String) async throws -> OkOut { try await request("POST", "/api/search/history", json: ["query": query]) }
    func clearSearchHistory() async throws -> OkOut { try await request("DELETE", "/api/search/history") }
    func artist(_ ref: String, fresh: Bool = false) async throws -> ArtistPageOut { try await cachedGet("/api/catalog/artist/\(enc(ref))", fresh: fresh) }
    func album(_ ref: String, fresh: Bool = false) async throws -> AlbumOut { try await cachedGet("/api/catalog/album/\(enc(ref))", fresh: fresh) }
    /// The album's animated cover (an HLS link from Apple Music), when it has one.
    func motionCover(artist: String, album: String, track: String, ref: String?) async throws -> MotionOut {
        try await request("GET", "/api/catalog/motion", query: ["artist": artist, "album": album, "track": track, "ref": ref], timeout: 25)
    }

    // listening before download
    func listen(_ ref: String) async throws -> ListenOut { try await request("GET", "/api/listen", query: ["ref": ref]) }
    struct Queued: Decodable { var queued: Int? }
    @discardableResult
    func listenPrefetch(_ refs: [String]) async throws -> Queued { try await request("POST", "/api/listen/prefetch", json: ["refs": refs]) }

    // downloads
    func download(_ body: DownloadIn) async throws -> DownloadBatchOut { try await request("POST", "/api/downloads", json: body, timeout: 15) }
    func downloads(status: String? = nil, limit: Int = 100) async throws -> [DownloadItemOut] {
        try await request("GET", "/api/downloads", query: ["status": status, "limit": String(limit)])
    }
    func retry(_ id: Int) async throws -> DownloadItemOut { try await request("POST", "/api/downloads/items/\(id)/retry", json: [String: Int]()) }
    func cancel(_ id: Int) async throws -> DownloadItemOut { try await request("POST", "/api/downloads/items/\(id)/cancel", json: [String: Int]()) }
    func clearDownloads() async throws -> ClearOut { try await request("POST", "/api/downloads/clear", json: [String: Int]()) }

    // favorites
    func star(_ body: StarIn, timeout: TimeInterval = 15) async throws -> StarOut { try await request("POST", "/api/star", json: body, timeout: timeout) }
    func starred() async throws -> StarredOut { try await request("GET", "/api/starred", timeout: 10) }

    // listening data
    struct EventsBody: Encodable { var events: [PlayEventIn]; var expectedUserId: Int? }
    func playEvents(_ events: [PlayEventIn], expectedUserId: Int?) async throws -> PlayEventsOut {
        try await request("POST", "/api/plays/events", json: EventsBody(events: events, expectedUserId: expectedUserId))
    }
    func dislikes() async throws -> [DislikeOut] { try await request("GET", "/api/dislikes") }
    func dislike(_ body: DislikeIn) async throws -> DislikeOut { try await request("POST", "/api/dislikes", json: body) }
    func undislike(ref: String?, ndSongId: String?, artistRef: String?) async throws -> RemovedOut {
        try await request("DELETE", "/api/dislikes", query: ["ref": ref, "nd_song_id": ndSongId, "artist_ref": artistRef])
    }

    // «Микс дня»
    func mixToday() async throws -> MixTodayOut { try await request("GET", "/api/mixes/today") }
    func mix(_ id: Int) async throws -> MixOut { try await request("GET", "/api/mixes/\(id)") }
    func mixSettings(_ body: MixSettingsIn) async throws -> MixSettingsOut { try await request("PUT", "/api/mixes/settings", json: body) }
    func tasteOnboarding(q: String?) async throws -> TasteOnboardingOut { try await request("GET", "/api/taste/onboarding", query: ["q": q]) }
    func pickArtists(_ refs: [String]) async throws -> MixSettingsOut { try await request("POST", "/api/taste/artists", json: ["artist_refs": refs]) }

    // «Моя волна», «Умное перемешивание»
    func waveStart(_ body: WaveStartIn) async throws -> WaveOut { try await request("POST", "/api/wave/start", json: body, timeout: 40) }
    func waveNext(_ id: String, _ body: WaveNextIn) async throws -> WaveOut { try await request("POST", "/api/wave/\(enc(id))/next", json: body, timeout: 40) }
    func smartStart(_ body: SmartStartIn) async throws -> SmartOut { try await request("POST", "/api/smart-shuffle/start", json: body, timeout: 40) }
    func smartNext(_ id: String, _ body: SmartNextIn) async throws -> SmartOut { try await request("POST", "/api/smart-shuffle/\(enc(id))/next", json: body, timeout: 40) }
    func smartHide(_ id: String, _ body: SmartTargetIn) async throws -> OkOut { try await request("POST", "/api/smart-shuffle/\(enc(id))/hide", json: body) }
    func smartAdd(_ id: String, _ body: SmartTargetIn) async throws -> SmartAddOut { try await request("POST", "/api/smart-shuffle/\(enc(id))/add", json: body) }

    // playlists
    func playlists() async throws -> [PlaylistOut] { try await request("GET", "/api/playlists") }
    func createPlaylist(_ name: String) async throws -> PlaylistOut { try await request("POST", "/api/playlists", json: PlaylistCreateIn(name: name)) }
    func addToPlaylist(_ id: String, songIds: [String]) async throws -> OkOut { try await request("POST", "/api/playlists/\(enc(id))/add", json: PlaylistAddIn(songIds: songIds)) }
    func playlist(_ id: String) async throws -> PlaylistPageOut { try await request("GET", "/api/playlists/\(enc(id))") }
    func removeFromPlaylist(_ id: String, indexes: [Int]) async throws -> OkOut { try await request("POST", "/api/playlists/\(enc(id))/remove", json: PlaylistRemoveIn(indexes: indexes)) }
    func deletePlaylist(_ id: String) async throws -> OkOut { try await request("DELETE", "/api/playlists/\(enc(id))") }

    // the Navidrome library
    func ndHome() async throws -> NdHomeOut { try await request("GET", "/api/nd/home") }
    func ndLiked() async throws -> NdLikedOut { try await request("GET", "/api/nd/liked") }
    func ndArtists() async throws -> [NdArtistOut] { try await cachedGet("/api/nd/artists") }
    func ndArtist(_ id: String) async throws -> NdArtistPageOut { try await request("GET", "/api/nd/artists/\(enc(id))") }
    func ndAlbum(_ id: String) async throws -> NdAlbumOut { try await request("GET", "/api/nd/albums/\(enc(id))") }
    func ndAlbums(type: String, offset: Int = 0, size: Int = 50) async throws -> [NdAlbumOut] {
        try await request("GET", "/api/nd/albums", query: ["type": type, "offset": String(offset), "size": String(size)])
    }
}

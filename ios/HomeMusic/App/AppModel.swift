import Foundation
import Observation
import UIKit

/// The app's session: the chosen Hub and the signed-in account (android/README «Выбор сервера при первом входе»:
/// the user types the PC's IP or name; `music-pc.local` means `http://music-pc.local:8080` for the Hub).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Stage { case server, checking, login, ready }
    enum Route: Hashable { case downloads }

    private(set) var stage: Stage = .server
    private(set) var me: MeOut?
    private(set) var serverURL: URL?
    var authOptions: AuthOptionsOut?
    /// A screen to switch to (a toast's «Загрузки»).
    var route: Route?
    /// The full player sheet.
    var playerOpen = false

    private let serverKey = "hm-hub-url"

    private init() {
        if let s = Persist.defaults.string(forKey: serverKey), let url = URL(string: s) {
            serverURL = url
            HubClient.shared.baseURL = url
            stage = .checking
        }
        NotificationCenter.default.addObserver(forName: .hubUnauthorized, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let m = AppModel.shared
                if m.stage == .ready { m.signedOut(keepServer: true) }
            }
        }
        HubEvents.shared.on { e in
            switch e {
            case .download(let d):
                Player.shared.downloadChanged(d)
                Stars.shared.downloadChanged(d)
                Downloads.shared.changed(d)
            case .library(let kind):
                if kind == "starred" || kind == "unstarred" { Stars.shared.refresh(force: true) }
                Library.shared.invalidate()
            case .reconnect:
                Stars.shared.refresh(force: true)
                Task { await Downloads.shared.load() }
            case .searchHistory:
                NotificationCenter.default.post(name: .searchHistoryChanged, object: nil)
            }
        }
    }

    /// «192.168.1.10», «music-pc.local», «http://pc:8080», «https://hub.example.com» → the Hub's URL.
    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            let hostPart = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
            let hasPort = hostPart.contains(":") && !hostPart.hasPrefix("[")
            s = "http://" + (hasPort ? s : hostPart + ":8080" + s.dropFirst(hostPart.count))
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    func chooseServer(_ input: String) async -> String? {
        guard let url = Self.normalize(input) else { return "Укажите IP или имя своего ПК" }
        let previous = HubClient.shared.baseURL
        HubClient.shared.baseURL = url
        do {
            _ = try await HubClient.shared.health()
            authOptions = try? await HubClient.shared.authOptions()
            serverURL = url
            Persist.defaults.set(url.absoluteString, forKey: serverKey)
            Capabilities.reset()
            stage = .login
            return nil
        } catch {
            HubClient.shared.baseURL = previous
            return "Хаб не отвечает по адресу \(url.absoluteString). Проверьте, что ПК включён, HomeMusic запущен, а телефон в той же сети."
        }
    }

    func changeServer() {
        if stage == .ready { Task { _ = try? await HubClient.shared.logout() } }
        signedOut(keepServer: false)
    }

    /// The saved session is checked once at launch.
    func checkSession() async {
        guard serverURL != nil else { stage = .server; return }
        do {
            let me = try await HubClient.shared.me()
            signedIn(me)
        } catch let e as ApiError where e.status == 401 {
            authOptions = try? await HubClient.shared.authOptions()
            stage = .login
        } catch {
            // offline: keep the saved account if there was one, the outbox and the queue wait
            if let saved = Persist.load(MeOut.self, key: "hm-me") { signedIn(saved, offline: true) } else { stage = .login }
        }
    }

    func login(username: String, password: String) async -> String? {
        do {
            signedIn(try await HubClient.shared.login(LoginIn(username: username.trimmingCharacters(in: .whitespaces), password: password)))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func register(code: String, username: String, password: String) async -> String? {
        do {
            signedIn(try await HubClient.shared.register(RegisterIn(code: code, username: username, password: password)))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func signedIn(_ me: MeOut, offline: Bool = false) {
        self.me = me
        Persist.save(me, key: "hm-me")
        stage = .ready
        PlayEvents.shared.setAccount(me.id)
        Player.shared.restore(account: me.id)
        Wave.shared.restore(account: me.id)
        Stars.shared.refresh(force: true)
        Task { await Dislikes.shared.refresh(force: true) }
        HubEvents.shared.start()
        Task { await Downloads.shared.load() }
        Task { await Capabilities.typedFavoritesSupported() }
    }

    func logout() async {
        _ = try? await HubClient.shared.logout()
        signedOut(keepServer: true)
    }

    private func signedOut(keepServer: Bool) {
        HubEvents.shared.stop()
        Player.shared.signedOut()
        Wave.shared.signedOut()
        Stars.shared.reset()
        Dislikes.shared.reset()
        PlayEvents.shared.setAccount(nil)
        Library.shared.invalidate()
        HubClient.shared.clearCookies()
        HubClient.shared.invalidateCache()
        Persist.save(Optional<MeOut>.none, key: "hm-me")
        me = nil
        if !keepServer {
            serverURL = nil
            Persist.defaults.removeObject(forKey: serverKey)
            stage = .server
        } else {
            stage = .login
        }
    }

    func foreground() {
        guard stage == .ready else { return }
        HubEvents.shared.start()
        Stars.shared.refresh()
        Task { await Dislikes.shared.refresh() }
    }
}

extension Notification.Name {
    static let searchHistoryChanged = Notification.Name("hm.searchHistory")
}

/// Shared library lists, refreshed on the Hub's `library` events.
@MainActor
@Observable
final class Library {
    static let shared = Library()
    /// Bumped when the library changed: screens reload.
    private(set) var generation = 0
    func invalidate() {
        HubClient.shared.invalidateCache("/api/nd/")
        generation += 1
    }
}

/// «Загрузки»: the user's visible downloads, live from the SSE stream.
@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()
    private(set) var items: [DownloadItemOut] = []
    private(set) var loaded = false

    /// Downloads the Hub queued only for ♥, an import or a mix are its own business: not shown.
    var visible: [DownloadItemOut] { items.filter { $0.star != true } }
    var activeCount: Int { visible.filter(\.isActive).count }

    func load() async {
        if let r = try? await HubClient.shared.downloads(limit: 200) {
            items = r
            loaded = true
        }
    }

    func changed(_ d: DownloadItemOut) {
        if let i = items.firstIndex(where: { $0.id == d.id }) { items[i] = d } else { items.insert(d, at: 0) }
        if d.status == "done" { Library.shared.invalidate() }
    }

    func clearFinished() async {
        do {
            _ = try await HubClient.shared.clearDownloads()
            await load()
        } catch { Toasts.error(error) }
    }
}

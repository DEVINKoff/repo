import Foundation
import Observation
import UIKit

/// `lib/ui.ts` toasts: a short line at the bottom, optionally with one action («Отменить», «Загрузки»).
@MainActor
@Observable
final class Toasts {
    static let shared = Toasts()

    struct Action { var label: String; var run: () -> Void }
    struct Toast: Identifiable {
        enum Kind { case success, info, error }
        let id = UUID()
        var text: String
        var kind: Kind
        var action: Action?
    }

    private(set) var current: Toast?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ text: String, _ kind: Toast.Kind, action: Action? = nil) {
        current = Toast(text: text, kind: kind, action: action)
        UINotificationFeedbackGenerator().notificationOccurred(kind == .error ? .error : .success)
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(action == nil ? 2.6 : 5))
            if !Task.isCancelled { current = nil }
        }
    }

    func dismiss() { current = nil }

    static func success(_ text: String, action: Action? = nil) { shared.show(text, .success, action: action) }
    static func info(_ text: String, action: Action? = nil) { shared.show(text, .info, action: action) }
    static func error(_ text: String) { shared.show(text, .error) }
    static func error(_ error: Error) {
        if error is CancellationError { return }
        shared.show(error.localizedDescription, .error)
    }
}

/// `lib/actions.ts`.
@MainActor
enum Actions {
    /// POST /api/downloads with a Russian summary toast. nil on error (already toasted).
    static func startDownload(_ body: DownloadIn) async -> DownloadBatchOut? {
        do {
            let r = try await HubClient.shared.download(body)
            let toDownloads = Toasts.Action(label: "Загрузки") { AppModel.shared.route = .downloads }
            if r.queued > 0 {
                let owned = r.alreadyOwned > 0 ? ", уже есть: \(r.alreadyOwned)" : ""
                Toasts.success("В очереди: \(Format.tracks(r.queued))\(owned)", action: toDownloads)
            } else if r.expanding == true {
                Toasts.success("Добавлено в загрузки", action: toDownloads)
            } else if r.alreadyOwned > 0 {
                Toasts.info("Уже есть в библиотеке")
            } else {
                Toasts.info("Нечего скачивать")
            }
            return r
        } catch {
            Toasts.error(error)
            return nil
        }
    }

    /// «Добавить в плейлист» (TrackMenu.tsx): a library song goes in at once; a catalog track downloads first.
    static func addToPlaylist(ndSongId: String?, ref: String?, playlist: PlaylistOut?, newName: String?) async -> Bool {
        let name = playlist?.name ?? newName ?? ""
        do {
            if let song = ndSongId {
                let id: String
                if let playlist { id = playlist.id } else { id = try await HubClient.shared.createPlaylist(name).id }
                _ = try await HubClient.shared.addToPlaylist(id, songIds: [song])
                Toasts.success("Добавлено в «\(name)»")
                return true
            }
            guard let ref else { return false }
            _ = try await HubClient.shared.download(DownloadIn(trackRefs: [ref], playlistId: playlist?.id, newPlaylistName: playlist == nil ? newName : nil))
            Toasts.success("Скачиваем — трек появится в «\(name)»")
            return true
        } catch {
            Toasts.error(error)
            return false
        }
    }
}

enum Format {
    /// «1 трек», «2 трека», «5 треков».
    static func tracks(_ n: Int) -> String { "\(n) \(plural(n, "трек", "трека", "треков"))" }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func duration(_ s: Double?) -> String {
        guard let s, s > 0 else { return "" }
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) ч \(m % 60) мин" : "\(m) мин"
    }

    static let statusTitle: [String: String] = [
        "queued": "В очереди", "searching": "Ищем", "downloading": "Качается", "tagging": "Теги",
        "importing": "Импорт", "done": "Готово", "failed": "Ошибка", "needs_review": "Нужен выбор", "cancelled": "Отменено",
    ]
}

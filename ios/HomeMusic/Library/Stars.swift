import Foundation
import Observation

/// What a ♥ is about (`LikeTarget` of lib/stars.ts).
struct LikeTarget: Sendable {
    var targetType = "track"
    var songId: String?
    var ndId: String?
    var ref: String?
    var data: [String: JSONValue]?

    static func track(_ t: QueueTrack) -> LikeTarget {
        LikeTarget(songId: t.ndSongId, ref: t.ref, data: ["title": .string(t.title), "artist": .string(t.artist)])
    }
    static func track(_ t: Track) -> LikeTarget {
        LikeTarget(songId: t.ndSongId, ref: t.ref, data: ["title": .string(t.title), "artist": .string(t.artistLine)])
    }
    static func album(nd id: String, title: String, artist: String) -> LikeTarget {
        LikeTarget(targetType: "album", ndId: id, data: ["name": .string(title), "artist": .string(artist)])
    }
    static func artist(nd id: String, name: String) -> LikeTarget {
        LikeTarget(targetType: "artist", ndId: id, data: ["name": .string(name)])
    }
}

/// ♥ (`web/src/lib/stars.ts`): own decisions (including unlike) override delayed Navidrome/import snapshots; a
/// failed/ambiguous delivery retries the exact same operation, never a new journal decision.
@MainActor
@Observable
final class Stars {
    static let shared = Stars()

    private struct Decision { var liked: Bool; var aliases: [String]; var eventId: String?; var acknowledgedAt: Int? }
    private struct Retry { var eventId: String; var ts: String; var liked: Bool }

    /// Bumped on every change: views reading `isLiked` re-render.
    private(set) var version = 0
    @ObservationIgnored private var snapshot: [String: Bool] = [:]
    @ObservationIgnored private var own: [String: Bool] = [:]
    @ObservationIgnored private var linkedAliases: [String: [String]] = [:]
    @ObservationIgnored private var local: [(key: String, value: Decision)] = []
    @ObservationIgnored private var pendingRefs: Set<String> = []
    @ObservationIgnored private var refSongs: [String: String] = [:]
    @ObservationIgnored private var busy: Set<String> = []
    @ObservationIgnored private var retries: [String: Retry] = [:]
    @ObservationIgnored private var loadedAt = Date.distantPast
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var acknowledged = 0
    @ObservationIgnored private var epoch = 0

    private init() {}

    private func typedKey(_ type: String, _ alias: String) -> String { "\(type):\(alias)" }

    private func aliases(_ t: LikeTarget) -> [String] {
        let id = t.ndId ?? t.songId ?? (t.targetType == "track" ? t.ref.flatMap { refSongs[$0] } : nil)
        let direct = [t.ref.map { "ref:\($0)" }, id.map { "nd:\($0)" }].compactMap { $0 }.map { typedKey(t.targetType, $0) }
        var out: [String] = []
        for key in direct.flatMap({ [$0] + (linkedAliases[$0] ?? []) }) where !out.contains(key) { out.append(key) }
        return out
    }

    private func emit() { version += 1 }

    private func setLocal(_ key: String, _ d: Decision?) {
        local.removeAll { $0.key == key }
        if let d { local.append((key, d)) }
    }

    func refresh(force: Bool = false) {
        if loading != nil { if force { refreshAgain = true }; return }
        if !force && Date().timeIntervalSince(loadedAt) < 30 { return }
        let generation = epoch
        let ackBefore = acknowledged
        loading = Task {
            defer {
                loading = nil
                if refreshAgain { refreshAgain = false; refresh(force: true) }
            }
            guard let r = try? await HubClient.shared.starred(), generation == epoch else { return }
            var next: [String: Bool] = [:]
            for id in r.songIds { next[typedKey("track", "nd:\(id)")] = true }
            for id in r.albumIds { next[typedKey("album", "nd:\(id)")] = true }
            for id in r.artistIds ?? [] { next[typedKey("artist", "nd:\(id)")] = true }
            for ref in r.refs ?? [] { next[typedKey("track", "ref:\(ref)")] = true }
            var decisions: [String: Bool] = [:]
            var links: [String: [String]] = [:]
            for s in r.subjects ?? [] {
                var raw = s.aliases ?? []
                if let ref = s.ref { raw.append("ref:\(ref)") }
                if let nd = s.ndId { raw.append("nd:\(nd)") }
                var keys: [String] = []
                for a in raw.map({ typedKey(s.targetType, $0) }) where !keys.contains(a) { keys.append(a) }
                for k in keys { links[k] = keys }
                for k in keys { if s.provenance == "own" { decisions[k] = s.liked } else { next[k] = s.liked } }
                if s.provenance == "own" {
                    local.removeAll { entry in
                        !busy.contains(entry.key) && entry.value.aliases.contains { keys.contains($0) } &&
                            (entry.value.eventId == s.eventId || (entry.value.acknowledgedAt.map { $0 <= ackBefore } ?? false))
                    }
                }
            }
            snapshot = next
            own = decisions
            linkedAliases = links
            loadedAt = Date()
            emit()
        }
    }

    func isLiked(_ t: LikeTarget) -> Bool {
        _ = version
        let keys = aliases(t)
        for d in local.reversed() where d.value.aliases.contains(where: { keys.contains($0) }) { return d.value.liked }
        for k in keys { if let v = own[k] { return v } }
        return keys.contains { snapshot[$0] == true } || (t.targetType == "track" && t.ref.map { pendingRefs.contains($0) } == true)
    }

    private func apiTarget(_ t: LikeTarget) -> FavoriteTarget {
        let id = t.ndId ?? t.songId ?? (t.targetType == "track" ? t.ref.flatMap { refSongs[$0] } : nil)
        var target = FavoriteTarget(targetType: t.targetType, ref: t.ref, targetData: t.data)
        if let id {
            switch t.targetType {
            case "track": target.ndSongId = id
            case "album": target.ndAlbumId = id
            default: target.ndArtistId = id
            }
        }
        return target
    }

    /// Track ♥ may download one song; album/artist ♥ only records the typed favorite.
    func toggle(_ t: LikeTarget, context: String) async {
        let keys = aliases(t)
        guard let key = keys.first, !keys.contains(where: { busy.contains($0) }) else { return }
        keys.forEach { busy.insert($0) }
        let generation = epoch
        let liked = !isLiked(t)
        let previous = local.first { $0.key == key }?.value
        let op = (retries[key]?.liked == liked) ? retries[key]! : Retry(eventId: Ids.new(), ts: Ids.iso(), liked: liked)
        retries[key] = op
        defer {
            keys.forEach { busy.remove($0) }
            if generation == epoch { emit(); refresh(force: true) }
        }
        do {
            guard let typed = await Capabilities.typedFavoritesSupported() else {
                throw ApiError(status: 0, message: "Не удалось проверить соединение с Хабом. Повторите попытку.")
            }
            if !typed && t.targetType != "track" { throw ApiError(status: 0, message: "Обновите Хаб, чтобы отмечать альбомы и исполнителей") }
            guard generation == epoch else { return }
            setLocal(key, Decision(liked: liked, aliases: keys, eventId: op.eventId))
            emit()
            let target = apiTarget(t)
            if typed {
                let result = try await HubClient.shared.star(StarIn(targets: [target], eventId: op.eventId, ts: op.ts,
                                                                    client: AppInfo.client, context: context, unstar: !liked))
                guard let eventId = result.eventIds?.first else { throw ApiError(status: 0, message: "Хаб не подтвердил изменение отметки") }
                guard generation == epoch else { return }
                acknowledged += 1
                setLocal(key, Decision(liked: liked, aliases: keys, eventId: eventId, acknowledgedAt: acknowledged))
                // Same journal id and target: the wave/batch delivery is a duplicate, not another like.
                if t.targetType == "track" {
                    PlayEvents.shared.event(liked ? "like" : "unlike",
                                            .init(ref: target.ref, ndSongId: target.ndSongId, targetType: target.targetType, targetData: target.targetData),
                                            .init(context: context, eventId: eventId, ts: op.ts))
                }
            } else {
                if let song = target.ndSongId { _ = try await HubClient.shared.star(StarIn(songIds: [song], unstar: !liked)) }
                else if !liked, let ref = t.ref { _ = try await HubClient.shared.star(StarIn(refs: [ref], unstar: true)) }
                else if let ref = t.ref { _ = try await HubClient.shared.download(DownloadIn(trackRefs: [ref], star: true)) }
                guard generation == epoch else { return }
                PlayEvents.shared.event(liked ? "like" : "unlike",
                                        .init(ref: target.ref, ndSongId: target.ndSongId, targetType: target.targetType, targetData: target.targetData),
                                        .init(context: context, eventId: op.eventId, ts: op.ts))
            }
            retries[key] = nil
            if !liked, let ref = t.ref { pendingRefs.remove(ref) }
            Toasts.success(liked ? "Добавлено в понравившиеся" : "Убрано из понравившихся")
        } catch {
            guard generation == epoch else { return }
            setLocal(key, previous)
            emit()
            Toasts.error(error)
        }
    }

    func markPending(_ ref: String) {
        let key = typedKey("track", "ref:\(ref)")
        if own[key] == false || local.contains(where: { $0.value.aliases.contains(key) && !$0.value.liked }) || pendingRefs.contains(ref) { return }
        pendingRefs.insert(ref)
        emit()
    }

    func downloadChanged(_ d: DownloadItemOut) {
        guard let ref = d.trackRef else { return }
        if d.status == "done", let song = d.ndSongId { refSongs[ref] = song }
        if ["done", "failed", "cancelled", "needs_review"].contains(d.status) {
            pendingRefs.remove(ref)
            // Terminal failures are rolled back by the server; never retain a phantom local like.
            if d.status != "done" {
                local.removeAll { $0.value.liked && $0.value.aliases.contains(typedKey("track", "ref:\(ref)")) }
            }
            emit()
            refresh(force: true)
        }
    }

    func reset() {
        epoch += 1
        if loading != nil { refreshAgain = true }
        snapshot = [:]; own = [:]; linkedAliases = [:]
        local = []; pendingRefs = []; refSongs = [:]; busy = []; retries = [:]
        loadedAt = .distantPast
        emit()
    }
}

/// What «Не нравится» is about (`DislikeTarget`).
struct DislikeTarget: Sendable {
    var ref: String?
    var ndSongId: String?
    var artistRef: String?
    var artist: String?
    var title: String?

    static func track(_ t: QueueTrack) -> DislikeTarget { DislikeTarget(ref: t.ref, ndSongId: t.ndSongId, artist: t.artist, title: t.title) }
    static func track(_ t: Track) -> DislikeTarget { DislikeTarget(ref: t.ref, ndSongId: t.ndSongId, artist: t.artistLine, title: t.title) }
    static func artist(ref: String, name: String) -> DislikeTarget { DislikeTarget(artistRef: ref, artist: name) }
}

/// «Не нравится» (MIXES.md 3.2, `web/src/lib/dislikes.ts`): tracks and artists the user doesn't want in mixes and
/// «Моя волна». Marking shows a toast with «Отменить».
@MainActor
@Observable
final class Dislikes {
    static let shared = Dislikes()

    private(set) var rows: [DislikeOut] = []
    @ObservationIgnored private var loadedAt = Date.distantPast
    @ObservationIgnored private var loading = false

    private init() {}

    func refresh(force: Bool = false) async {
        if loading || (!force && Date().timeIntervalSince(loadedAt) < 60) { return }
        loading = true
        defer { loading = false }
        if let r = try? await HubClient.shared.dislikes() {
            rows = r
            loadedAt = Date()
        }
    }

    private func matches(_ d: DislikeOut, _ t: DislikeTarget) -> Bool {
        if let a = t.artistRef { return d.artistRef == a }
        return (t.ref != nil && d.ref == t.ref) || (t.ndSongId != nil && d.ndSongId == t.ndSongId)
    }

    func isDisliked(_ t: DislikeTarget) -> Bool { rows.contains { matches($0, t) } }

    /// Marks or unmarks «Не нравится»; the toast after marking undoes it.
    @discardableResult
    func set(_ t: DislikeTarget, on: Bool, context: String, quiet: Bool = false) async -> Bool {
        let before = rows
        if on {
            rows.insert(DislikeOut(id: 0, ref: t.ref, ndSongId: t.ndSongId, artistRef: t.artistRef, artist: t.artist, title: t.title, source: "app"), at: 0)
        } else {
            rows.removeAll { matches($0, t) }
        }
        do {
            if on {
                let body = t.artistRef != nil
                    ? DislikeIn(artistRef: t.artistRef, artist: t.artist, title: t.title, context: context, client: AppInfo.client)
                    : DislikeIn(ref: t.ref, ndSongId: t.ndSongId, artist: t.artist, title: t.title, context: context, client: AppInfo.client)
                let row = try await HubClient.shared.dislike(body)
                rows = [row] + rows.filter { $0.id != 0 && $0.id != row.id }
                if !quiet {
                    Toasts.success(t.artistRef != nil ? "Исполнитель не будет попадать в миксы" : "Трек не будет попадать в миксы",
                                   action: .init(label: "Отменить") { Task { await Dislikes.shared.set(t, on: false, context: context, quiet: true) } })
                }
            } else {
                if t.artistRef != nil { _ = try await HubClient.shared.undislike(ref: nil, ndSongId: nil, artistRef: t.artistRef) }
                else { _ = try await HubClient.shared.undislike(ref: t.ref, ndSongId: t.ndSongId, artistRef: nil) }
                if !quiet { Toasts.success("Отметка «Не нравится» снята") }
            }
            return true
        } catch {
            rows = before
            Toasts.error(error)
            return false
        }
    }

    func reset() { rows = []; loadedAt = .distantPast }
}

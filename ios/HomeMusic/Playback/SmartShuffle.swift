import Foundation
import Observation

/// The screen a list was started from, when it is a playlist or «Понравившиеся» (`useSmartPage`).
struct SmartPage: Hashable, Sendable {
    /// "liked" or "playlist:<Navidrome id>"
    var context: String
    var title: String?
}

@MainActor
protocol SmartHooks: AnyObject {
    func listStarted(_ context: String, page: SmartPage?)
    func canStart() -> Bool
    func begin(_ list: [QueueTrack], current: QueueTrack)
    func end()
    func restored()
}

/// «Умное перемешивание» (MIXES.md 8, `web/src/lib/smartShuffle.ts`): a playlist or «Понравившиеся» in the shuffle,
/// with recommendations "in the mood of the list" put between its songs. All the logic is the Hub's
/// (`POST /api/smart-shuffle/*`); this keeps the session, hands the Hub the events and the place of the player, and puts
/// what it answers into the player's queue. The playlist itself is never changed.
@MainActor
@Observable
final class SmartShuffle: SmartHooks {
    static let shared = SmartShuffle()

    /// «Умное перемешивание в режимах»: on by default.
    var enabled: Bool {
        didSet { Persist.defaults.set(enabled ? "1" : "0", forKey: "hm-smart-shuffle") }
    }

    private final class Session {
        let id: String
        let context: String
        let title: String?
        let label: String
        var recs: Set<String> = []
        var pending: [PlayEventIn] = []
        var busy = false
        var again = false
        init(id: String, context: String, title: String?, label: String) {
            self.id = id; self.context = context; self.title = title; self.label = label
        }
    }

    @ObservationIgnored private var session: Session?
    /// The list being started: the screen's context at the moment it began.
    @ObservationIgnored private var listPage: SmartPage?
    /// Counts the starts, so that a late answer of an old one is ignored.
    @ObservationIgnored private var generation = 0

    private init() {
        enabled = Persist.defaults.string(forKey: "hm-smart-shuffle") != "0"
        PlayEvents.shared.onEvent { [weak self] e in self?.onEvent(e) }
        Player.shared.smartHooks = self
    }

    static func label(_ context: String, _ title: String?) -> String {
        if context == "liked" { return "Рекомендация на основе любимых песен" }
        if let title, !title.isEmpty { return "Рекомендация на основе «\(title)»" }
        return "Рекомендация на основе плейлиста"
    }

    private func asTrack(_ r: Track, _ s: Session) -> QueueTrack {
        var t = QueueTrack(r, withSong: false, rec: .init(label: s.label, session: s.id))
        t.ndSongId = r.isOwned ? r.ndSongId : nil
        return t
    }

    /// The own song the player is at or passed last (the Hub fills the places ahead of it).
    private func ownAt() -> String? {
        let p = Player.shared
        guard !p.queue.isEmpty else { return nil }
        var i = min(p.index, p.queue.count - 1)
        while i >= 0 {
            if p.queue[i].rec == nil { return p.queue[i].hubId }
            i -= 1
        }
        return nil
    }

    // MARK: SmartHooks

    func listStarted(_ context: String, page: SmartPage?) {
        generation += 1
        session = nil
        if (context == "playlist" || context == "liked"), let page, (page.context == "liked") == (context == "liked") {
            listPage = page
        } else {
            listPage = nil
        }
    }

    func canStart() -> Bool {
        enabled && listPage != nil && !Player.shared.context.hasPrefix("wave:")
    }

    func begin(_ list: [QueueTrack], current: QueueTrack) {
        guard let ctx = listPage else { return Player.shared.endSmart() }
        generation += 1
        let mine = generation
        session = nil
        Task {
            do {
                let r = try await HubClient.shared.smartStart(SmartStartIn(
                    context: ctx.context, songs: list.map(\.hubId), current: current.hubId, title: ctx.title,
                    origin: ctx.context == "liked" ? "liked_page" : "playlist_page", client: AppInfo.client))
                let p = Player.shared
                guard mine == generation, p.smart, p.track != nil else { return }
                let s = Session(id: r.sessionId, context: ctx.context, title: ctx.title, label: Self.label(ctx.context, ctx.title))
                var byId: [String: QueueTrack] = [:]
                for t in list where byId[t.hubId] == nil { byId[t.hubId] = t }
                // what has played or is playing stays; the Hub's order replaces what is after it
                let done = Set(p.queue.prefix(p.index + 1).map(\.hubId))
                let currentId = p.queue.indices.contains(p.index) ? p.queue[p.index].hubId : nil
                var recsAfter: [String: [QueueTrack]] = [:]
                for rec in r.recs {
                    s.recs.insert(rec.ref)
                    recsAfter[rec.after ?? "", default: []].append(asTrack(rec, s))
                }
                var upcoming: [QueueTrack] = []
                for id in r.own {
                    if let own = byId[id], !done.contains(id) { upcoming.append(own) }
                    // a recommendation after a song that already played is not worth a place any more
                    if !done.contains(id) || id == currentId { upcoming.append(contentsOf: recsAfter[id] ?? []) }
                }
                session = s
                p.replaceUpcoming(upcoming)
            } catch {
                guard mine == generation else { return }
                Player.shared.endSmart()
                Toasts.info("Умное перемешивание сейчас недоступно: играет обычное перемешивание")
            }
        }
    }

    func end() {
        generation += 1
        session = nil
    }

    func restored() {
        // a relaunch: the same Hub session goes on from the recommendations in the queue
        let p = Player.shared
        guard p.smart, let rec = p.queue.first(where: { $0.rec != nil })?.rec else { return }
        let s = Session(id: rec.session, context: p.context == "liked" ? "liked" : "playlist", title: nil, label: rec.label)
        s.recs = Set(p.queue.filter { $0.rec != nil }.map(\.ref))
        session = s
        listPage = nil
    }

    // MARK: Keeping it going

    private func ask() async {
        guard let s = session else { return }
        if s.busy { s.again = true; return }
        s.busy = true
        let played = s.pending
        s.pending = []
        do {
            let r = try await HubClient.shared.smartNext(s.id, SmartNextIn(played: played, at: ownAt()))
            if session === s {
                let fresh = r.recs.filter { !s.recs.contains($0.ref) }
                for x in fresh { s.recs.insert(x.ref) }
                Player.shared.insertAfterOwn(fresh.map { (after: $0.after ?? "", track: asTrack($0, s)) })
                if r.pending && fresh.isEmpty {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(4))
                        await self?.ask()
                    }
                }
            }
        } catch let e as ApiError where e.status == 404 {
            session = nil // the session is over: the queue plays out
        } catch {
            s.pending.insert(contentsOf: played, at: 0) // offline: with the next call
        }
        s.busy = false
        if s.again && session === s {
            s.again = false
            await ask()
        }
    }

    private func onEvent(_ e: PlayEventIn) {
        guard let s = session, !["progress", "interrupted", "error"].contains(e.kind) else { return }
        if (e.targetType != nil && e.targetType != "track") || e.revertsEventId != nil { return }
        let rec = e.ref.map { s.recs.contains($0) } ?? false
        if rec { s.pending.append(e) }
        // the player moved on (a track started) or the user reacted to a recommendation: the Hub fills the places ahead
        if e.kind == "start" || (rec && ["finish", "skip", "like", "dislike"].contains(e.kind)) { Task { await ask() } }
    }

    // MARK: «+» and «−» of a playing recommendation

    /// «+»: the recommendation joins the list (a playlist: put in it, downloaded first if the library lacks it;
    /// «Понравившиеся»: ♥). It is the list's own song from now on (no ✨).
    func add(_ t: QueueTrack) async {
        guard let rec = t.rec else { return }
        let s = session
        do {
            if s?.context == "liked" || (s == nil && Player.shared.context == "liked") {
                await Stars.shared.toggle(.track(t), context: Player.shared.context)
                _ = try await HubClient.shared.smartAdd(rec.session, SmartTargetIn(ref: t.ref, ndSongId: t.ndSongId))
                Toasts.success("«\(t.title)» в понравившихся")
            } else {
                let r = try await HubClient.shared.smartAdd(rec.session, SmartTargetIn(ref: t.ref, ndSongId: t.ndSongId))
                Toasts.success(r.status == "downloading" ? "«\(t.title)» скачивается и появится в плейлисте" : "«\(t.title)» добавлен в плейлист")
            }
            Player.shared.markOwn(t.ref)
            s?.recs.remove(t.ref)
        } catch {
            Toasts.error(error)
        }
    }

    /// «−»: skips the recommendation; the Hub does not recommend it in this list again (it stays everywhere else).
    func hide(_ t: QueueTrack) async {
        guard let rec = t.rec else { return }
        let p = Player.shared
        if p.queue.firstIndex(where: { $0.ref == t.ref }) == p.index, !p.next() { Toasts.info("Трек скрыт из рекомендаций") }
        if let gone = p.queue.firstIndex(where: { $0.ref == t.ref }), gone != p.index { p.removeFromQueue(gone) }
        do {
            _ = try await HubClient.shared.smartHide(rec.session, SmartTargetIn(ref: t.ref, ndSongId: t.ndSongId))
            Toasts.info("«\(t.title)» больше не рекомендуется здесь")
        } catch {
            Toasts.error(error)
        }
    }
}

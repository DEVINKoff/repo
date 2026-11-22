import Foundation
import Observation

/// «Моя волна» (MIXES.md 7, `web/src/lib/wave.ts`): an endless stream the Hub picks for the user, 5 tracks at a time
/// (`POST /api/wave/start`, then `POST /api/wave/{id}/next`). Each time a wave track starts, and after a ♥ or
/// «Не нравится» of one, the events since the last call go to the Hub with the refs still ahead, and the answer
/// replaces them — so the stream is picked again after every action. The same events go to /api/plays/events as always
/// (the Hub stores an event_id once). Another list started in the player ends the wave.
@MainActor
@Observable
final class Wave {
    static let shared = Wave()

    private final class Session {
        let id: String
        let title: String
        let context: String
        var refs: Set<String> = []
        var songs: Set<String> = []
        /// events of the wave's tracks not yet handed to the Hub
        var pending: [PlayEventIn] = []
        var inFlight: [PlayEventIn] = []
        var busy = false
        var again = false
        init(id: String, title: String, context: String) { self.id = id; self.title = title; self.context = context }
    }

    private struct Saved: Codable {
        var id: String; var title: String; var refs: [String]; var songs: [String]; var pending: [PlayEventIn]
    }

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var account: Int?
    private let retry: TimeInterval = 4

    /// The playing wave's title (nil — none) and the seed being started ('' — the user's own wave).
    private(set) var title: String?
    private(set) var starting: String?

    private init() {
        PlayEvents.shared.onEvent { [weak self] e in self?.onEvent(e) }
    }

    private func emit() {
        persist()
        title = session?.title
    }

    private func persist() {
        guard let account else { return }
        let key = "hm-wave-session:\(account)"
        guard let s = session else { return Persist.save(Optional<Saved>.none, key: key) }
        Persist.save(Saved(id: s.id, title: s.title, refs: Array(s.refs), songs: Array(s.songs), pending: s.inFlight + s.pending), key: key)
    }

    /// Continue the same server session after a relaunch, including events still awaiting acknowledgement.
    func restore(account a: Int?) {
        if account == a { return }
        session = nil
        account = a
        let p = Player.shared
        if a != nil, p.track != nil, p.context.hasPrefix("wave:") {
            let id = String(p.context.dropFirst("wave:".count))
            var saved = Persist.load(Saved.self, key: "hm-wave-session:\(a!)")
            if saved?.id != id { saved = nil }
            let s = Session(id: id, title: saved?.title ?? "Моя волна", context: p.context)
            s.refs = Set((saved?.refs ?? []) + p.queue.map(\.ref))
            s.songs = Set(saved?.songs ?? [])
            s.pending = saved?.pending ?? []
            session = s
        }
        emit()
    }

    static func seedKey(_ seed: WaveSeedIn?) -> String {
        (seed?.byArtist == true ? "artist:" : "") + (seed?.ref ?? seed?.ndSongId ?? seed?.artistRef ?? seed?.ndArtistId ?? "")
    }

    /// «Волна по треку».
    static func trackSeed(ref: String?, ndSongId: String?) -> WaveSeedIn? {
        let r = ref?.trimmingCharacters(in: .whitespaces)
        if let r, r.range(of: #"^(dz|nd):.+"#, options: .regularExpression) != nil { return WaveSeedIn(ref: r) }
        if let id = ndSongId?.trimmingCharacters(in: .whitespaces), !id.isEmpty { return WaveSeedIn(ndSongId: id) }
        if let r, r.range(of: #"^file:[^:]+:.+"#, options: .regularExpression) != nil { return WaveSeedIn(ref: r) }
        return nil
    }

    /// «Волна по исполнителю».
    static func artistSeed(ref: String?, ndSongId: String?, artistRef: String?) -> WaveSeedIn? {
        if let a = artistRef?.trimmingCharacters(in: .whitespaces), a.hasPrefix("dz:"), a.count > 3 { return WaveSeedIn(artistRef: a) }
        guard var t = trackSeed(ref: ref, ndSongId: ndSongId), t.ref?.hasPrefix("file:") != true else { return nil }
        t.byArtist = true
        return t
    }

    private func remember(_ s: Session, _ w: WaveOut) {
        for t in w.tracks {
            s.refs.insert(t.ref)
            if let id = t.ndSongId { s.songs.insert(id) }
        }
    }

    /// Starts the user's own wave, or one from a track or an artist. `origin` — where it was started
    /// (INSIGHTS.md 6.3: analytics only).
    @discardableResult
    func start(seed: WaveSeedIn?, origin: String) async -> Bool {
        if starting != nil { return false }
        starting = Self.seedKey(seed)
        emit()
        defer { starting = nil; emit() }
        do {
            let w = try await HubClient.shared.waveStart(WaveStartIn(seed: seed, origin: origin, client: AppInfo.client))
            return play(w)
        } catch {
            Toasts.error(error)
            return false
        }
    }

    /// A started wave (the answer of /start, also handed over by the Hub's pages through the bridge `playWave`).
    @discardableResult
    func play(_ w: WaveOut) -> Bool {
        guard !w.tracks.isEmpty else {
            Toasts.error("Волна пока пустая: попробуйте чуть позже")
            return false
        }
        let s = Session(id: w.sessionId, title: w.title, context: "wave:\(w.sessionId)")
        remember(s, w)
        // A wave is a new list even when its seed is already playing.
        session = nil
        Player.shared.startFresh(w.tracks.map { QueueTrack($0, withSong: false) }, context: s.context)
        session = s
        emit()
        return true
    }

    /// The events since the last call and the refs still ahead go to the Hub; its picks replace them.
    private func ask() async {
        guard let s = session else { return }
        if s.busy { s.again = true; return }
        s.busy = true
        let played = s.pending
        s.pending = []
        s.inFlight = played
        persist()
        let p = Player.shared
        let queued = p.upcoming.map(\.ref)
        do {
            let w = try await HubClient.shared.waveNext(s.id, WaveNextIn(played: played, queued: queued))
            if session === s, Player.shared.context == s.context {
                remember(s, w)
                if !w.tracks.isEmpty { Player.shared.replaceUpcoming(w.tracks.map { QueueTrack($0, withSong: false) }) }
                else if w.pending {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(4))
                        await self?.ask()
                    }
                }
            }
        } catch let e as ApiError where e.status == 404 {
            end() // the session is over (a day without it): the queue plays out
        } catch {
            s.pending.insert(contentsOf: played, at: 0) // offline: with the next call
        }
        s.inFlight = []
        persist()
        s.busy = false
        if s.again && session === s {
            s.again = false
            await ask()
        }
    }

    private func end() {
        session = nil
        emit()
    }

    private func onEvent(_ e: PlayEventIn) {
        if ["progress", "interrupted", "error"].contains(e.kind) { return }
        if (e.targetType != nil && e.targetType != "track") || e.revertsEventId != nil { return }
        guard let s = session else { return }
        if Player.shared.context != s.context { return end() } // another list plays now
        let mine = (e.ref.map { s.refs.contains($0) } ?? false) || (e.ndSongId.map { s.songs.contains($0) } ?? false)
        guard mine else { return }
        s.pending.append(e)
        persist()
        if ["start", "like", "dislike"].contains(e.kind) { Task { await ask() } }
    }

    func signedOut() {
        session = nil
        account = nil
        title = nil
    }
}

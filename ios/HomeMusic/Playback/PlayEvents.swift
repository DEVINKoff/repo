import Foundation
import UIKit

/// `lib/plays.ts` — listening events for mixes and «Моя волна» (MIXES.md 3.2). They gather for a few seconds and go
/// to the Hub in one batch (`POST /api/plays/events`); a batch that didn't get through waits on disk and goes with the
/// next one (each event has its own id, so a batch sent twice is stored once).
@MainActor
final class PlayEvents {
    static let shared = PlayEvents()

    struct Queued: Codable {
        var event: PlayEventIn
        var account: Int?
        var rejected: String?
    }

    private let file = "play-events.json"
    private let sendDelay: TimeInterval = 3
    private var queue: [Queued]
    private(set) var account: Int?
    private var batchSize = 500
    private var failures = 0
    private var timer: Timer?
    private var sending = false
    private var listeners: [(PlayEventIn) -> Void] = []

    private init() {
        queue = (Persist.loadFile([Queued].self, name: file) ?? []).sorted { $0.event.ts < $1.event.ts }
        if !queue.isEmpty { schedule() }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PlayEvents.shared.flushInBackground() }
        }
    }

    func setAccount(_ id: Int?) {
        account = id
        if id != nil { schedule() }
    }

    /// Every event as it is made (the wave and the smart shuffle hand the ones of their tracks to the Hub too).
    func onEvent(_ fn: @escaping (PlayEventIn) -> Void) { listeners.append(fn) }

    struct Target {
        var ref: String?
        var ndSongId: String?
        var targetType: String?
        var ndAlbumId: String?
        var ndArtistId: String?
        var targetData: [String: JSONValue]?
    }

    struct Extra {
        var positionS: Double?
        var durationS: Double?
        var context: String?
        var eventId: String?
        var ts: String?
        var revertsEventId: String?
        var playbackId: String?
        var deviceId: String?
        var listenedMs: Int?
        var trackMetadata: TrackMetadata?
        var account: Int?
        var launchId: String?
        var launchOrigin: String?
    }

    @discardableResult
    func event(_ kind: String, _ target: Target, _ extra: Extra = Extra()) -> Bool {
        if target.ref == nil && target.ndSongId == nil && target.ndAlbumId == nil && target.ndArtistId == nil { return false }
        func round(_ x: Double?) -> Double? {
            guard let x, x.isFinite else { return nil }
            return (x * 10).rounded() / 10
        }
        let e = PlayEventIn(
            targetType: target.targetType, ndAlbumId: target.ndAlbumId, ndArtistId: target.ndArtistId,
            targetData: target.targetData, revertsEventId: extra.revertsEventId,
            eventId: extra.eventId ?? Ids.new(), ts: extra.ts ?? Ids.iso(), kind: kind,
            ref: target.ref, ndSongId: target.ndSongId, playbackId: extra.playbackId, deviceId: extra.deviceId,
            listenedMs: extra.listenedMs, trackMetadata: extra.trackMetadata,
            positionS: round(extra.positionS), durationS: round(extra.durationS), context: extra.context,
            client: AppInfo.client,
            launchId: extra.launchId, launchOrigin: extra.launchId != nil ? extra.launchOrigin : nil)
        let owner: Int? = extra.account ?? account
        queue.append(Queued(event: e, account: owner))
        // A newer cumulative checkpoint of the same attempt (same 10-minute bucket) supersedes the older ones.
        if kind == "progress", let pid = e.playbackId, let did = e.deviceId, let ms = e.listenedMs {
            let bucket = e.ts.prefix(15)
            queue.removeAll { old in
                old.event.eventId != e.eventId && old.event.kind == "progress" && old.account == owner &&
                    old.event.playbackId == pid && old.event.deviceId == did && old.event.ts.prefix(15) == bucket &&
                    (old.event.listenedMs ?? .max) <= ms
            }
        }
        let persisted = save()
        schedule()
        for fn in listeners { fn(e) }
        return persisted
    }

    @discardableResult
    private func save() -> Bool { Persist.saveFile(queue, name: file) }

    private func schedule(after delay: TimeInterval? = nil) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay ?? sendDelay, repeats: false) { _ in
            Task { @MainActor in await PlayEvents.shared.flush() }
        }
    }

    func flush() async {
        if sending || queue.isEmpty { return }
        sending = true
        defer { sending = false }
        await Capabilities.typedFavoritesSupported()
        guard let account else { return }
        let batch = Array(queue.filter { $0.account == account && $0.rejected == nil && Capabilities.canSend($0.event) }.prefix(batchSize))
        if batch.isEmpty { return }
        do {
            let response = try await HubClient.shared.playEvents(batch.map(\.event), expectedUserId: account)
            failures = 0
            let rejected = Dictionary(response.rejected.map { ($0.index, $0.detail) }, uniquingKeysWith: { a, _ in a })
            var sent = Set<String>()
            var failed: [String: String] = [:]
            for (i, q) in batch.enumerated() {
                if let why = rejected[i] { failed[q.event.eventId] = why } else { sent.insert(q.event.eventId) }
            }
            queue = queue.filter { !sent.contains($0.event.eventId) }.map { q in
                var q = q
                if let why = failed[q.event.eventId] { q.rejected = why }
                return q
            }
            if !failed.isEmpty { print("Hub rejected listening events; retained in outbox", Array(failed.values)) }
            save()
            if queue.contains(where: { $0.account == account && $0.rejected == nil && Capabilities.canSend($0.event) }) { schedule() }
        } catch let e as ApiError where e.status == 413 {
            if batchSize > 1 {
                batchSize = max(1, batchSize / 2)
                schedule()
            } else if let i = queue.firstIndex(where: { $0.account == account && $0.rejected == nil && Capabilities.canSend($0.event) }) {
                queue[i].rejected = "Server rejected single event as too large (413)"
                save()
                schedule()
            }
        } catch {
            failures += 1
            schedule(after: min(30 * pow(2, Double(min(failures - 1, 6))), 1800))
        }
    }

    /// The app goes to the background: send what is waiting now (the PWA's `pagehide` keepalive flush).
    func flushInBackground() {
        guard !queue.isEmpty else { return }
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "play-events") {
            UIApplication.shared.endBackgroundTask(task)
        }
        timer?.invalidate()
        Task { @MainActor in
            await flush()
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}

/// `routeContext` / `launchOrigin` / `newLaunch` of plays.ts. Native screens say their context themselves.
struct Launch: Codable, Hashable, Sendable {
    var id: String
    var origin: String?

    private static let screenOrigins: Set<String> = ["album", "artist", "playlist", "liked", "search", "queue", "library"]

    static func origin(for context: String) -> String? {
        if context.hasPrefix("mix:") { return "mix_page_track" }
        if context.hasPrefix("wave:") { return "wave" }
        return screenOrigins.contains(context) ? context : nil
    }

    /// A new launch of a list of `context`; a wave's is its session (`wave:<id>`).
    static func new(_ context: String, origin: String? = nil) -> Launch {
        Launch(id: context.hasPrefix("wave:") ? context : Ids.new(), origin: origin ?? Launch.origin(for: context))
    }
}

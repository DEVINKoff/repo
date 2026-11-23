import AVFoundation
import MediaPlayer
import Network
import Observation
import UIKit

/// The app's one player: `web/src/lib/listen.ts` on AVPlayer. Every ref — a library song (`nd:<song>` or its Deezer
/// ref), a catalog track, a provider's file — is streamed by the Hub (`/api/listen/stream`), which picks the file the
/// way a download would (uncensored copies first, source order, ranking: all server-side).
///
/// What plays is reported to the Hub (`PlayEvents`, MIXES.md 3.2): `start` once sound plays and the Hub has said what
/// plays (not a Deezer preview), cumulative `progress` checkpoints every 15 s, then `finish` (played to its end, or
/// left after ≥ 90 %) or `skip` (left earlier), `interrupted` for an attempt cut by the app being killed.
@MainActor
@Observable
final class Player {
    static let shared = Player()

    enum Phase: String, Codable { case resolving, loading, playing, paused, ended, error }
    enum RepeatMode: String, Codable { case off, all, one }

    // MARK: State (ListenState)

    private(set) var track: QueueTrack?
    private(set) var queue: [QueueTrack] = []
    private(set) var index = 0
    /// where the list was started from (`album`, `playlist`, `mix:<id>`, `wave:<id>`…)
    private(set) var context = "other"
    private(set) var phase: Phase = .paused
    private(set) var info: ListenOut?
    private(set) var error: String?
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// Catalog tracks downloaded from the player or a row this session: rows show «качается», then «есть».
    private(set) var downloads: [String: String] = [:]
    private(set) var shuffle: Bool
    /// The playing list has the smart shuffle (recommendations between its songs).
    private(set) var smart = false
    private(set) var repeatMode: RepeatMode
    /// The shuffle button's last choice (off, on, smart) lives on past lists that cannot be smart.
    private(set) var smartChosen: Bool
    /// A seek in progress (the slider is dragged): the shown position stays where the finger is.
    var scrubbing = false

    /// The exact playback time right now (read from AVPlayer, not observed): the lyrics' word animation.
    var liveTime: Double {
        let t = avPlayer.currentTime().seconds
        return t.isFinite && item != nil ? t : position
    }

    var hasNext: Bool { index + 1 < queue.count }
    var hasPrev: Bool { index > 0 }
    var onWave: Bool { context.hasPrefix("wave:") }
    var isBusy: Bool { track != nil && (phase == .playing || phase == .resolving || phase == .loading) }
    var isPlaying: Bool { phase == .playing || phase == .loading || phase == .resolving }
    var upcoming: ArraySlice<QueueTrack> { queue.count > index + 1 ? queue[(index + 1)...] : [] }

    // MARK: Constants

    /// Seconds into a track after which ⏮ restarts it instead of going to the previous one.
    private let restartAfter: Double = 3
    /// Left after this share of a track: it counts as played to the end (`finish`), earlier — `skip`.
    private let finishShare = 0.9

    // MARK: Internals

    @ObservationIgnored private var avPlayer = AVPlayer()
    @ObservationIgnored private var item: AVPlayerItem?
    // the DJ crossfade
    @ObservationIgnored var shapes: [String: TrackShape] = [:]
    @ObservationIgnored var shapeAsked: Set<String> = []
    /// the next track, loaded ahead (muted) to come in at the outro
    @ObservationIgnored private var spare: AVPlayer?
    @ObservationIgnored private var spareRef: String?
    @ObservationIgnored private var spareSeek: NSKeyValueObservation?
    /// the track going out while the next one comes in
    @ObservationIgnored private var tail: AVPlayer?
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private(set) var crossfading = false
    @ObservationIgnored private var itemObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var playerObserver: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSeek: Double = 0
    @ObservationIgnored private var resolving: Task<Void, Never>?
    @ObservationIgnored private var resolvingRef: String?
    @ObservationIgnored private var prefetching: (ref: String, task: Task<Void, Never>)?
    @ObservationIgnored private var refreshed: String?
    @ObservationIgnored private var listContext = "other"
    @ObservationIgnored private var listLaunch = Launch.new("other")
    /// The queue in its own order while shuffle is on (tracks added since go after it when shuffle is turned off).
    @ObservationIgnored private var unshuffled: [QueueTrack]?
    @ObservationIgnored private var sessionAccount: Int?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var checkpointTimer: Timer?
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var expensiveNetwork = false
    @ObservationIgnored var smartHooks: SmartHooks?

    /// The track being played, as reported to the Hub: `started` once its `start` was sent.
    private final class OpenPlay {
        let ref: String
        let context: String
        let launch: Launch
        var started = false
        let playbackId = Ids.new()
        var listenedMs: Double = 0
        var anchor: CFTimeInterval?
        let account: Int?
        var ndSongId: String?
        init(ref: String, context: String, launch: Launch, account: Int?) {
            self.ref = ref; self.context = context; self.launch = launch; self.account = account
        }
    }
    @ObservationIgnored private var played: OpenPlay?

    private struct SavedPlay: Codable {
        var ref: String
        var context: String
        var playbackId: String
        var deviceId: String
        var listenedMs: Int
        var ndSongId: String?
        var account: Int?
        var launchId: String?
        var launchOrigin: String?
    }
    private let openPlayKey = "hm-open-play"
    private let modesKey = "hm-listen-modes"

    private struct Modes: Codable { var shuffle: Bool; var smart: Bool; var repeatMode: RepeatMode }

    private init() {
        let m = Persist.load(Modes.self, key: modesKey)
        shuffle = m?.shuffle == true
        smartChosen = m?.shuffle == true && m?.smart == true
        repeatMode = m?.repeatMode ?? .off

        bind(avPlayer)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, ended === self.item else { return }
                self.ended()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persist(force: true)
                self?.checkpoint()
                self?.reportEnd(interrupted: true)
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist(force: true) }
        }
        path.pathUpdateHandler = { [weak self] p in
            let expensive = p.isExpensive
            Task { @MainActor in self?.expensiveNetwork = expensive }
        }
        path.start(queue: DispatchQueue(label: "hm.path"))
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in Player.shared.checkpoint() }
        }
        recover()
        NowPlaying.setUp(self)
    }

    /// Makes `p` the main player: its play / pause and its time drive everything (the DJ crossfade hands the main
    /// role to the player that already plays the next track).
    private func bind(_ p: AVPlayer) {
        if let o = timeObserver { avPlayer.removeTimeObserver(o) }
        playerObserver?.invalidate()
        avPlayer = p
        p.automaticallyWaitsToMinimizeStalling = true
        playerObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                guard let self, p === self.avPlayer else { return }
                self.timeControlChanged(status)
            }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.timeUpdate(t.seconds) }
        }
    }

    static func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: Listening events

    private func accrue(_ p: OpenPlay) {
        if let a = p.anchor {
            let now = CACurrentMediaTime()
            p.listenedMs += max(0, (now - a) * 1000)
            p.anchor = now
        }
    }

    private func metadata() -> TrackMetadata? {
        guard let t = track else { return nil }
        return TrackMetadata(title: t.title, album: t.album, artistCredit: t.artist,
                             artists: (t.artists?.isEmpty == false) ? t.artists!.map { .init(name: $0.name, ref: $0.ref) } : nil,
                             durationS: t.durationS, isrc: t.isrc, year: t.year)
    }

    private func checkpoint() {
        guard let p = played, p.started else { return }
        accrue(p)
        let snap = SavedPlay(ref: p.ref, context: p.context, playbackId: p.playbackId, deviceId: Ids.device,
                             listenedMs: Int(p.listenedMs.rounded()), ndSongId: p.ndSongId, account: p.account,
                             launchId: p.launch.id, launchOrigin: p.launch.origin)
        Persist.save(snap, key: openPlayKey)
        PlayEvents.shared.event("progress", .init(ref: p.ref, ndSongId: p.ndSongId),
                                .init(context: p.context, playbackId: p.playbackId, deviceId: Ids.device,
                                      listenedMs: snap.listenedMs, trackMetadata: metadata(), account: p.account,
                                      launchId: p.launch.id, launchOrigin: p.launch.origin))
    }

    /// An attempt that the app's end cut off (the last checkpoint on disk) is reported as `interrupted`.
    private func recover() {
        guard let old = Persist.load(SavedPlay.self, key: openPlayKey), old.account != nil else { return }
        if PlayEvents.shared.event("interrupted", .init(ref: old.ref, ndSongId: old.ndSongId),
                                   .init(context: old.context, playbackId: old.playbackId, deviceId: old.deviceId,
                                         listenedMs: old.listenedMs, account: old.account,
                                         launchId: old.launchId, launchOrigin: old.launchOrigin)) {
            Persist.save(Optional<SavedPlay>.none, key: openPlayKey)
        }
    }

    /// Sends `start` once the track sounds and the Hub has said what plays (not a preview).
    private func reportStart() {
        guard let p = played, !p.started, track?.ref == p.ref, let info, info.kind != "preview", phase == .playing else { return }
        p.started = true
        p.ndSongId = info.ndSongId
        p.anchor = CACurrentMediaTime()
        PlayEvents.shared.event("start", .init(ref: p.ref, ndSongId: p.ndSongId),
                                .init(context: p.context, playbackId: p.playbackId, deviceId: Ids.device, listenedMs: 0,
                                      trackMetadata: metadata(), account: p.account, launchId: p.launch.id, launchOrigin: p.launch.origin))
        checkpoint()
    }

    /// The current track is left (`ended`: it played to its end): `finish` or `skip` by where the player was.
    private func reportEnd(ended: Bool = false, failed: Bool = false, interrupted: Bool = false) {
        let p = played
        if let p, p.started { accrue(p) }
        played = nil
        guard let p, p.started, let t = track, t.ref == p.ref else { return }
        let d = duration > 0 ? duration : (t.durationS ?? 0)
        let pos = ended ? d : position
        let kind = interrupted ? "interrupted" : failed ? "error" : (ended || (d > 0 && pos >= d * finishShare)) ? "finish" : "skip"
        let ok = PlayEvents.shared.event(kind, .init(ref: p.ref, ndSongId: p.ndSongId),
                                         .init(positionS: pos, durationS: d > 0 ? d : nil, context: p.context,
                                               playbackId: p.playbackId, deviceId: Ids.device, listenedMs: Int(p.listenedMs.rounded()),
                                               trackMetadata: metadata(), account: p.account, launchId: p.launch.id, launchOrigin: p.launch.origin))
        if ok { Persist.save(Optional<SavedPlay>.none, key: openPlayKey) }
    }

    private func suspendClock() {
        if let p = played, p.started {
            accrue(p)
            p.anchor = nil
            checkpoint()
        }
    }

    // MARK: AVPlayer callbacks

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard track != nil, item != nil else { return }
        switch status {
        case .playing:
            phase = .playing
            error = nil
            refreshInfo()
            reportStart()
            if let p = played, p.started, p.anchor == nil { p.anchor = CACurrentMediaTime() }
        case .waitingToPlayAtSpecifiedRate:
            suspendClock()
            if phase == .playing { phase = .loading }
        case .paused:
            // pauses from outside (an interruption, the lock screen); switching tracks also gives one while resolving
            suspendClock()
            if phase == .playing || phase == .loading { phase = .paused }
        @unknown default: break
        }
        NowPlaying.update(self)
    }

    private func timeUpdate(_ seconds: Double) {
        guard let item, track != nil else { return }
        if !scrubbing { position = pendingSeek > 0 ? pendingSeek : (seconds.isFinite ? seconds : 0) }
        let d = item.duration.seconds
        if d.isFinite && d > 0 && info?.kind != "preview" { duration = d }
        persist()
        crossfadeTick()
    }

    private func ended() {
        reportEnd(ended: true)
        if repeatMode == .one { start(queue, at: index, auto: true) }
        else if hasNext { start(queue, at: index + 1, auto: true) }
        else if repeatMode == .all && !onWave { start(queue, at: 0, auto: true) }
        else { phase = .ended; NowPlaying.update(self) }
    }

    private func failed(_ message: String?) {
        reportEnd(failed: true)
        phase = .error
        error = error ?? message ?? "Не удалось воспроизвести"
        NowPlaying.update(self)
    }

    // MARK: Starting a track

    private func makeItem(_ ref: String) -> AVPlayerItem? {
        guard let url = HubClient.shared.streamURL(ref: ref, light: expensiveNetwork && Settings.lightOnCellular) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: HubClient.shared.cookies])
        return AVPlayerItem(asset: asset)
    }

    /// Tries of the current track after a lost connection (the Hub or the network came back).
    private var retries = 0
    private static let retryDelays: [Double] = [1.5, 4, 9]

    /// A lost connection: the same track again in a moment (from where it was), up to three times. True — retrying.
    private func retryLater(ref: String, auto: Bool) -> Bool {
        guard retries < Self.retryDelays.count, track?.ref == ref else { return false }
        let delay = Self.retryDelays[retries]
        retries += 1
        let at = position
        reportEnd(failed: true)
        phase = .resolving
        error = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.track?.ref == ref, self.phase == .resolving else { return }
            self.start(self.queue, at: self.index, auto: auto, position: at, retry: true)
        }
        return true
    }

    /// `auto`: reached by the previous track ending; a track that can't be played is then skipped.
    /// `retry`: the same track again after a lost connection (the tries are counted, nothing is reported twice).
    private func start(_ list: [QueueTrack], at i: Int, auto: Bool = false, position startAt: Double = 0, autoplay: Bool = true,
                       retry: Bool = false, prepared: AVPlayer? = nil) {
        guard list.indices.contains(i) else { return }
        let t = list[i]
        if !retry { retries = 0 }
        if prepared == nil { endCrossfade() }
        reportEnd()
        // a recommendation of the smart shuffle reports under its session, the list's own songs under their list
        played = OpenPlay(ref: t.ref, context: t.rec.map { "smart:\($0.session)" } ?? listContext, launch: listLaunch,
                          account: PlayEvents.shared.account)
        resolving?.cancel()
        pendingSeek = startAt
        track = t
        queue = list
        index = i
        context = listContext
        phase = autoplay ? .resolving : .paused
        info = nil
        error = nil
        position = startAt
        duration = t.durationS ?? 0
        persist(force: true)

        itemObservers = []
        let newItem = prepared?.currentItem ?? makeItem(t.ref)
        item = newItem
        if prepared != nil { pendingSeek = 0 }
        if let newItem {
            itemObservers.append(newItem.observe(\.status, options: [.new]) { [weak self] it, _ in
                let status = it.status
                let message = it.error?.localizedDescription
                Task { @MainActor in
                    guard let self, it === self.item else { return }
                    if status == .readyToPlay, self.pendingSeek > 0 {
                        let target = self.pendingSeek
                        self.pendingSeek = 0
                        _ = await self.avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                    } else if status == .failed {
                        // the file was found but the stream broke: the connection, most likely — try again
                        if self.info != nil, self.retryLater(ref: t.ref, auto: auto) { return }
                        if auto && self.hasNext && self.info == nil { return self.start(self.queue, at: self.index + 1, auto: true) }
                        self.failed(message)
                    }
                }
            })
        }
        if let prepared {
            // the DJ crossfade: the player already playing this track (from where its sound starts) takes over;
            // the one before it keeps playing — fading out — as the crossfade's `tail`
            bind(prepared)
            if prepared.timeControlStatus != .paused { phase = .playing }
        } else {
            avPlayer.replaceCurrentItem(with: newItem)
            avPlayer.volume = level(for: t.ref)
            if autoplay {
                Player.configureAudioSession()
                avPlayer.play()
            }
        }
        NowPlaying.update(self, newTrack: true)

        // the prefetch of this very track (it was next) is the request to wait for: don't cancel it
        if prefetching?.ref != t.ref { prefetching?.task.cancel() }
        prefetching = nil
        let ref = t.ref
        resolvingRef = ref
        resolving = Task { [weak self] in
            do {
                let out = try await HubClient.shared.listen(ref)
                guard let self, !Task.isCancelled, self.resolvingRef == ref, self.track?.ref == ref else { return }
                self.info = out
                if out.kind == "preview" { self.duration = out.durationS ?? 30 }
                self.fillPlaceholder(out)
                self.reportStart()
                self.prefetchNext()
                self.loadShape(ref)
                NowPlaying.update(self)
            } catch {
                guard let self, !(error is CancellationError), !Task.isCancelled, self.resolvingRef == ref else { return }
                // no connection to the Hub (not «not found»): try again in a moment
                if (error as? ApiError)?.status == 0, self.retryLater(ref: ref, auto: auto) { return }
                if auto && self.hasNext { return self.start(self.queue, at: self.index + 1, auto: true) }
                self.phase = .error
                self.error = error.localizedDescription
                self.avPlayer.pause()
                NowPlaying.update(self)
            }
        }
    }

    /// A library song handed over by its id alone (the PWA's `play(ids)`): the Hub's answer names it.
    private func fillPlaceholder(_ out: ListenOut) {
        guard var t = track, t.title.isEmpty else { return }
        t.title = out.title
        t.artist = out.artist
        if t.durationS == nil { t.durationS = out.durationS }
        track = t
        if queue.indices.contains(index) { queue[index] = t }
    }

    /// The Hub opens the picked file only when the stream asks for it, and moves on to the next file if it doesn't
    /// open: once sound plays, the source shown is asked for again.
    private func refreshInfo() {
        guard let ref = track?.ref, refreshed != ref, info?.kind == "full" else { return }
        refreshed = ref
        Task { [weak self] in
            guard let out = try? await HubClient.shared.listen(ref) else { return }
            if self?.track?.ref == ref { self?.info = out }
        }
    }

    /// Asks the Hub to pick the next track's file now (it remembers the pick), so it starts at once.
    private func prefetchNext() {
        let next = queue.indices.contains(index + 1) ? queue[index + 1] : (repeatMode == .all && !onWave ? queue.first : nil)
        guard let next, prefetching?.ref != next.ref else { return }
        prefetching?.task.cancel()
        let ref = next.ref
        prefetching = (ref, Task { [weak self] in
            _ = try? await HubClient.shared.listen(ref)
            self?.loadShape(ref)
        })
    }

    // MARK: Lists

    /// Tap on a track: starts it (with `list`, the list it belongs to, playing on after it), or pauses/resumes it if it
    /// is the current one. `origin` — where the list was launched (by default by `context`). `smartPage` — the
    /// list is a playlist's or «Понравившиеся» (the smart shuffle may order it).
    func listen(_ t: QueueTrack, in list: [QueueTrack]? = nil, context ctx: String, origin: String? = nil, smartPage: SmartPage? = nil) {
        if track?.ref == t.ref && phase != .error && (list == nil || ctx == context) { return toggle() }
        startList(t, list, ctx, origin, smartPage)
    }

    /// «Слушать» of a whole list: from its first track (with shuffle on, a random one). `shuffle` sets the mode.
    func listenAll(_ list: [QueueTrack], shuffle mode: Bool? = nil, context ctx: String, origin: String? = nil, smartPage: SmartPage? = nil) {
        guard !list.isEmpty else { return }
        if let mode { setModes(shuffle: mode) }
        let first = shuffle ? list.randomElement()! : list[0]
        startList(first, list, ctx, origin, smartPage)
    }

    private func startList(_ t: QueueTrack, _ list: [QueueTrack]?, _ ctx: String, _ origin: String?, _ smartPage: SmartPage?) {
        listContext = ctx
        listLaunch = Launch.new(ctx, origin: origin)
        let l = (list?.contains { $0.uid == t.uid || $0.ref == t.ref } == true) ? list! : [t]
        let at = l.firstIndex { $0.uid == t.uid } ?? l.firstIndex { $0.ref == t.ref } ?? 0
        smartHooks?.listStarted(ctx, page: smartPage) // the previous list's smart session is over
        if shuffle && !ctx.hasPrefix("wave:") && l.count > 1 {
            unshuffled = l
            smart = false
            var rest = l
            rest.remove(at: at)
            start([l[at]] + rest.shuffled(), at: 0)
            // the smart shuffle chosen and this list is a playlist / «Понравившиеся»: the Hub orders it and puts
            // recommendations in, a moment after the tapped track has started (the plain shuffle plays until then)
            if smartChosen, let hooks = smartHooks, hooks.canStart() {
                smart = true
                hooks.begin(l, current: l[at])
            }
        } else {
            unshuffled = nil
            smart = false
            start(l, at: at)
        }
    }

    // MARK: Modes

    private func setModes(shuffle on: Bool? = nil, repeat r: RepeatMode? = nil) {
        if let on { shuffle = on }
        if let r { repeatMode = r }
        if !shuffle { smartChosen = false }
        Persist.save(Modes(shuffle: shuffle, smart: smartChosen, repeatMode: repeatMode), key: modesKey)
        persist(force: true)
    }

    /// On: the tracks after the current one go in random order; off: back to the list's own order (a smart shuffle
    /// ends: its recommendations leave the queue).
    func setShuffle(_ on: Bool) {
        let wasSmart = smart
        if !on { smartChosen = false }
        setModes(shuffle: on)
        if wasSmart && !on {
            smartHooks?.end()
            smart = false
        }
        guard track != nil, !onWave, queue.indices.contains(index) else { return }
        let current = queue[index]
        if on {
            if wasSmart { return }
            unshuffled = queue
            var rest = queue
            rest.remove(at: index)
            queue = [current] + rest.shuffled()
            index = 0
        } else {
            let base = unshuffled ?? queue
            let own = queue.filter { $0.rec == nil }
            var next: [QueueTrack]
            if current.rec != nil {
                // a recommendation plays now: what is left of the list goes on after it, in the list's own order
                let left = queue[(index + 1)...].filter { $0.rec == nil }
                let leftIds = Set(left.map(\.uid))
                let baseIds = Set(base.map(\.uid))
                next = [current] + base.filter { leftIds.contains($0.uid) } + left.filter { !baseIds.contains($0.uid) }
            } else {
                let ownIds = Set(own.map(\.uid))
                let baseIds = Set(base.map(\.uid))
                next = base.filter { ownIds.contains($0.uid) } + own.filter { !baseIds.contains($0.uid) }
            }
            unshuffled = nil
            queue = next
            index = max(0, next.firstIndex { $0.uid == current.uid } ?? 0)
        }
        persist(force: true)
        prefetchNext()
    }

    /// The shuffle button: off → shuffle → smart shuffle (only where the playing list can have one) → off.
    func cycleShuffle() {
        if onWave { return }
        if !shuffle { return setShuffle(true) }
        if smart { return setShuffle(false) }
        if track != nil, let hooks = smartHooks, hooks.canStart() {
            smartChosen = true
            setModes()
            smart = true
            hooks.begin((unshuffled ?? queue).filter { $0.rec == nil }, current: queue[index])
            return
        }
        setShuffle(false)
    }

    /// off → all → one → off.
    func cycleRepeat() {
        setModes(repeat: repeatMode == .off ? .all : repeatMode == .all ? .one : .off)
        prefetchNext()
    }

    /// The Hub did not answer or the session is over: the plain shuffle goes on.
    func endSmart() { if smart { smart = false } }

    // MARK: Queue edits

    /// Recommendations into the queue, each right after the own song it names (not behind the player).
    func insertAfterOwn(_ items: [(after: String, track: QueueTrack)]) {
        guard track != nil, !items.isEmpty else { return }
        var q = queue
        var added = 0
        for (after, t) in items {
            if q.contains(where: { $0.ref == t.ref }) { continue }
            guard let i = q.firstIndex(where: { $0.rec == nil && $0.hubId == after }), i >= index else { continue }
            q.insert(t, at: i + 1)
            added += 1
        }
        guard added > 0 else { return }
        queue = q
        persist(force: true)
        if phase == .ended && hasNext { start(queue, at: index + 1, auto: true) }
        else if phase != .error { prefetchNext() }
    }

    /// «+»: the recommendation became the list's own song (no ✨ any more).
    func markOwn(_ ref: String) {
        guard queue.contains(where: { $0.ref == ref && $0.rec != nil }) else { return }
        queue = queue.map { t in var t = t; if t.ref == ref { t.rec = nil }; return t }
        if queue.indices.contains(index) { track = queue[index] }
        persist(force: true)
    }

    /// «Играть следующим»: right after the current track (when nothing plays, they start now).
    func playNext(_ tracks: [QueueTrack], context ctx: String) {
        guard !tracks.isEmpty else { return }
        guard track != nil else { return listen(tracks[0], in: tracks, context: ctx) }
        queue.insert(contentsOf: tracks.map { $0.copy() }, at: index + 1)
        persist(force: true)
        prefetchNext()
    }

    /// «Добавить в очередь»: after the last track (when nothing plays, they start now).
    func addToQueue(_ tracks: [QueueTrack], context ctx: String) {
        guard !tracks.isEmpty else { return }
        guard track != nil else { return listen(tracks[0], in: tracks, context: ctx) }
        let wasEnded = phase == .ended
        queue.append(contentsOf: tracks.map { $0.copy() })
        persist(force: true)
        if wasEnded { start(queue, at: index + 1, auto: true) } else { prefetchNext() }
    }

    /// Takes a track that is not the current one out of the queue.
    func removeFromQueue(_ i: Int) {
        guard i != index, queue.indices.contains(i) else { return }
        queue.remove(at: i)
        if i < index { index -= 1 }
        persist(force: true)
        prefetchNext()
    }

    /// Moves a track of the queue to another place (the current one too).
    func moveInQueue(from: Int, to: Int) {
        guard from != to, queue.indices.contains(from), queue.indices.contains(to) else { return }
        let current = queue[index]
        let t = queue.remove(at: from)
        queue.insert(t, at: to)
        index = queue.firstIndex { $0.uid == current.uid } ?? index
        persist(force: true)
        prefetchNext()
    }

    /// A tap on a track of the queue: it plays now, the queue stays as it is.
    func playQueue(at i: Int) {
        if i == index { return toggle() }
        if queue.indices.contains(i) { start(queue, at: i) }
    }

    /// More tracks of a list were loaded (search results): if it is the list playing, it plays on through them too.
    func extendQueue(_ list: [QueueTrack]) {
        guard track != nil, list.count > queue.count else { return }
        for (i, t) in queue.enumerated() where t.ref != list[i].ref { return }
        queue += list[queue.count...]
        persist(force: true)
        if phase != .error && phase != .ended { prefetchNext() }
    }

    /// The tracks after the current one are replaced (the Hub picked «Моя волна» anew). A queue that ran out
    /// meanwhile plays on.
    func replaceUpcoming(_ list: [QueueTrack]) {
        guard track != nil else { return }
        let wasEnded = phase == .ended
        queue = Array(queue.prefix(index + 1)) + list
        persist(force: true)
        if wasEnded && hasNext { start(queue, at: index + 1, auto: true) }
        else if phase != .error { prefetchNext() }
    }

    /// The wave / bridge hands a fresh list that starts now (the PWA's `listenAll` without the shuffle).
    func startFresh(_ list: [QueueTrack], at i: Int = 0, context ctx: String, origin: String? = nil, launchId: String? = nil) {
        guard list.indices.contains(i) else { return }
        listContext = ctx
        listLaunch = launchId.map { Launch(id: $0, origin: origin ?? Launch.origin(for: ctx)) } ?? Launch.new(ctx, origin: origin)
        smartHooks?.listStarted(ctx, page: nil)
        unshuffled = nil
        smart = false
        start(list, at: i)
    }

    // MARK: Transport

    /// Plays the next track of the queue; false at its end.
    @discardableResult
    func next() -> Bool {
        if hasNext { start(queue, at: index + 1) }
        else if repeatMode == .all && track != nil && !onWave { start(queue, at: 0) }
        else { return false }
        return true
    }

    /// ⏮: back to the start of the track, or (near its start) the previous track.
    func prev() {
        if hasPrev && (position < restartAfter || phase == .error) { start(queue, at: index - 1) }
        else if track != nil {
            seek(0)
            if phase == .ended || phase == .paused { resume() }
        }
    }

    /// The current track again from the start, with the file the user just picked for it.
    func replayWithNewFile() {
        guard track != nil else { return }
        start(queue, at: index)
    }

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard track != nil else { return }
        if phase == .error || phase == .ended || item == nil { return start(queue, at: index) }
        phase = (info != nil || position > 0) ? .loading : .resolving
        Player.configureAudioSession()
        avPlayer.play()
        NowPlaying.update(self)
    }

    func pause() {
        // a pause in the middle of a blend: the blend is over, the outgoing track stops
        if crossfading { endCrossfade() }
        guard track != nil, phase != .error, phase != .ended else { return }
        avPlayer.pause()
        phase = .paused
        persist(force: true)
        NowPlaying.update(self)
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, item != nil else { return }
        suspendClock()
        if item?.status != .readyToPlay {
            pendingSeek = max(0, seconds)
        } else {
            pendingSeek = 0
            avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.played, p.started, self.avPlayer.timeControlStatus == .playing else { return }
                    p.anchor = CACurrentMediaTime()
                }
            }
        }
        position = seconds
        persist(force: true)
        NowPlaying.update(self)
    }

    /// Stops and hides the player.
    func stop() {
        endCrossfade()
        reportEnd()
        resolving?.cancel()
        resolving = nil
        prefetching?.task.cancel()
        prefetching = nil
        pendingSeek = 0
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        item = nil
        itemObservers = []
        unshuffled = nil
        smartHooks?.end()
        track = nil
        queue = []
        index = 0
        info = nil
        error = nil
        phase = .paused
        position = 0
        duration = 0
        smart = false
        persist(force: true)
        NowPlaying.clear()
    }

    // MARK: Downloads shown on rows

    /// Queues one catalog track (the Hub downloads the file that was listened to, if any).
    func downloadRef(_ ref: String) async -> Bool {
        guard await Actions.startDownload(DownloadIn(trackRefs: [ref])) != nil else { return false }
        markQueued(ref)
        return true
    }

    func markQueued(_ ref: String) { downloads[ref] = "queued" }

    func downloadChanged(_ d: DownloadItemOut) {
        guard let ref = d.trackRef else { return }
        // a download queued only for ♥ is never «качается», but once imported the track is in the library
        if d.star == true && d.status == "done" && downloads[ref] != "done" { downloads[ref] = "done"; return }
        guard downloads[ref] == "queued" else { return }
        if d.status == "done" { downloads[ref] = "done" }
        else if ["failed", "cancelled", "needs_review"].contains(d.status) { downloads[ref] = nil }
    }

    // MARK: The listening session across launches (per account)

    private struct SavedSession: Codable {
        var version = 1
        var queue: [QueueTrack]
        var index: Int
        var context: String
        var launch: Launch?
        var position: Double
        var shuffle: Bool
        var repeatMode: RepeatMode
        /// The list's own order while shuffled, as queue uids (duplicates keep their identity).
        var originalOrder: [UUID]?
        var smart: Bool?
    }

    private func persist(force: Bool = false) {
        guard let account = sessionAccount, force || Date().timeIntervalSince(lastSaved) >= 1 else { return }
        let key = "hm-listen-session:\(account)"
        if track == nil { Persist.save(Optional<SavedSession>.none, key: key) }
        else {
            Persist.save(SavedSession(queue: queue, index: index, context: context, launch: listLaunch, position: position,
                                      shuffle: shuffle, repeatMode: repeatMode, originalOrder: unshuffled?.map(\.uid), smart: smart), key: key)
        }
        lastSaved = Date()
    }

    /// Restore only after /me confirms the account; the queue comes back paused where it was.
    func restore(account: Int?) {
        if sessionAccount == account { return }
        if sessionAccount != nil { stop() }
        sessionAccount = account
        guard let account, let saved = Persist.load(SavedSession.self, key: "hm-listen-session:\(account)"),
              saved.version == 1, !saved.queue.isEmpty, saved.queue.indices.contains(saved.index),
              saved.position.isFinite, saved.position >= 0 else { return }
        if let order = saved.originalOrder {
            let byId = Dictionary(saved.queue.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
            let restored = order.compactMap { byId[$0] }
            unshuffled = restored.count == order.count ? restored : nil
        } else { unshuffled = nil }
        listContext = saved.context
        listLaunch = saved.launch ?? Launch.new(saved.context)
        shuffle = saved.shuffle
        smart = saved.smart == true
        repeatMode = saved.repeatMode
        start(saved.queue, at: saved.index, position: saved.position, autoplay: false)
        smartHooks?.restored()
    }

    /// Signing out: the next account starts clean.
    func signedOut() {
        stop()
        sessionAccount = nil
    }
}

/// Settings of the app (More): stored choices.
enum Settings {
    /// «Кроссфейд»: tracks blend into each other like a DJ's (where the outro starts, past the silences, at one
    /// loudness).
    static var crossfade: Bool {
        get { Persist.defaults.object(forKey: "hm-crossfade") as? Bool ?? true }
        set { Persist.defaults.set(newValue, forKey: "hm-crossfade") }
    }

    /// «Экономия трафика»: on a metered network (cellular, a hotspot) the Hub's light Opus copy (`q=mobile`).
    static var lightOnCellular: Bool {
        get { Persist.defaults.object(forKey: "hm-light-cellular") as? Bool ?? true }
        set { Persist.defaults.set(newValue, forKey: "hm-light-cellular") }
    }
}


// MARK: - DJ crossfade

/// A track's shape from the Hub (`/api/listen/shape`): where its sound starts and ends, where its outro begins, how
/// loud it is.
struct TrackShape: Codable, Sendable {
    var duration: Double?
    var leadIn: Double?
    var outro: Double?
    var end: Double?
    var gainDb: Double?
    var fadesOut: Bool?
}

extension HubClient {
    func shape(_ ref: String) async throws -> TrackShape {
        try await request("GET", "/api/listen/shape", query: ["ref": ref], timeout: 70)
    }
}

extension Player {
    /// The Hub's shape of a track, asked once (it reads the file when its copy is on the Hub's disk).
    func loadShape(_ ref: String) {
        guard Settings.crossfade, shapes[ref] == nil, !shapeAsked.contains(ref) else { return }
        shapeAsked.insert(ref)
        Task { [weak self] in
            guard let s = try? await HubClient.shared.shape(ref), s.end != nil else {
                self?.shapeAsked.remove(ref)
                return
            }
            self?.shapes[ref] = s
            // the playing track: its loudness evened out now
            if let self, self.track?.ref == ref, !self.crossfading {
                self.rampVolume(self.avPlayer, to: self.level(for: ref), over: 1.5)
            }
        }
    }

    /// The track's volume, evening out loudness: a loud master is brought down to the others' level (never up —
    /// AVPlayer can't go past 1).
    func level(for ref: String) -> Float {
        guard Settings.crossfade, let g = shapes[ref]?.gainDb else { return 1 }
        return Float(min(1, max(0.35, pow(10, min(0, g) / 20))))
    }

    /// The next track in line for a blend, if this transition should blend: not in «repeat one», not inside an
    /// album played in order (its tracks run into each other as they are), not for previews or short tracks.
    private var blendNext: QueueTrack? {
        guard Settings.crossfade, repeatMode != .one, let cur = track, info?.kind != "preview", duration > 45 else { return nil }
        let next = queue.indices.contains(index + 1) ? queue[index + 1] : (repeatMode == .all && !onWave ? queue.first : nil)
        guard let next, next.ref != cur.ref else { return nil }
        if let a = cur.albumRef, a == next.albumRef, !shuffle { return nil }
        if context.hasPrefix("album") && !shuffle { return nil }
        return next
    }

    /// Where the blend into the next track starts, and how long it lasts.
    private var blendWindow: (start: Double, length: Double)? {
        guard duration > 45 else { return nil }
        if let s = shapes[track?.ref ?? ""], let outro = s.outro, let end = s.end, end > outro {
            return (outro, min(12, max(3, end - outro)))
        }
        return (duration - 6, 6)
    }

    /// Every tick of the playing track: loads the next one ahead in the spare player, and starts the blend at the
    /// outro.
    func crossfadeTick() {
        guard !crossfading, phase == .playing, !scrubbing, let next = blendNext, let w = blendWindow else { return }
        if position >= w.start - 10, spare == nil || spareRef != next.ref { prepareSpare(next) }
        if position >= w.start, let spare, spareRef == next.ref, spare.currentItem?.status == .readyToPlay {
            beginCrossfade(next, spare, length: w.length)
        }
    }

    private func prepareSpare(_ next: QueueTrack) {
        guard let item = makeItem(next.ref) else { return }
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        p.volume = 0
        spare = p
        spareRef = next.ref
        let start = shapes[next.ref]?.leadIn ?? 0
        if start > 0.2 {
            spareSeek = item.observe(\.status, options: [.new]) { it, _ in
                guard it.status == .readyToPlay else { return }
                Task { @MainActor in _ = await p.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
            }
        }
    }

    private func beginCrossfade(_ next: QueueTrack, _ incoming: AVPlayer, length: Double) {
        let outgoing = avPlayer
        let fadesOut = shapes[track?.ref ?? ""]?.fadesOut == true
        let target = level(for: next.ref)
        let from = outgoing.volume
        crossfading = true
        tail = outgoing
        spare = nil
        spareRef = nil
        spareSeek = nil
        incoming.volume = 0
        incoming.play()
        // the track that reached its outro counts as played to the end, as when it ends by itself
        reportEnd(ended: true)
        let ni = queue.indices.contains(index + 1) ? index + 1 : 0
        start(queue, at: ni, auto: true, position: shapes[next.ref]?.leadIn ?? 0, prepared: incoming)
        Haptics.soft(0.25)
        let began = CACurrentMediaTime()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let x = min(1, (CACurrentMediaTime() - began) / length)
                // equal power; a track that fades out by itself is let go linearly, a hard ending a bit sooner
                let outCurve = fadesOut ? 1 - x : cos(min(1, x * 1.1) * .pi / 2)
                let inCurve = sin(min(1, x * (fadesOut ? 1.0 : 1.25)) * .pi / 2)
                outgoing.volume = from * Float(max(0, outCurve))
                if self.avPlayer === incoming { incoming.volume = target * Float(inCurve) }
                if x >= 1 { self.endCrossfade() }
            }
        }
    }

    /// The blend is over (or cut short by a skip, a new list, a pause-and-skip): the outgoing track stops.
    func endCrossfade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        tail?.pause()
        tail?.replaceCurrentItem(with: nil)
        tail = nil
        if crossfading, let ref = track?.ref { avPlayer.volume = level(for: ref) }
        crossfading = false
        spare?.replaceCurrentItem(with: nil)
        spare = nil
        spareRef = nil
        spareSeek = nil
    }

    private func rampVolume(_ p: AVPlayer, to v: Float, over secs: Double) {
        let from = p.volume
        let began = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { timer in
            MainActor.assumeIsolated {
                let x = Float(min(1, (CACurrentMediaTime() - began) / secs))
                p.volume = from + (v - from) * x
                if x >= 1 { timer.invalidate() }
            }
        }
    }
}

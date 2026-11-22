import Foundation
import UIKit

/// Keeps the StandBy widget's copy of the playing track up to date (App Group container): title, cover, where the
/// track is and its synced lyrics. The widget is reloaded only when its plan changes — another track, a pause, a seek
/// or the lyrics arriving — never every second.
@MainActor
enum StandByFeed {
    private static var lastKey = ""
    private static var lastPosition: Double = 0
    private static var lastAt = Date.distantPast
    private static var coverRef: String?

    /// The widget's buttons act on the app's player.
    static func registerCommands() {
        IntentRelay.handler = { command in
            await MainActor.run {
                let p = Player.shared
                switch command {
                case .playPause: p.toggle()
                case .next: _ = p.next()
                case .previous: p.prev()
                }
            }
        }
    }

    static func update(_ p: Player) {
        guard StandBy.container != nil else { return } // the App Group is not available (signed without it)
        guard let t = p.track else {
            if lastKey != "none" { lastKey = "none"; StandBy.write(nil); StandBy.reload() }
            return
        }
        if Lyrics.shared.ref != t.ref { Lyrics.shared.load(for: t) }

        var lines: [StandBy.LyricLine]?
        if Lyrics.shared.ref == t.ref {
            switch Lyrics.shared.state {
            case .synced(let l): lines = l.map { StandBy.LyricLine(time: $0.time, text: $0.text) }
            case .plain, .instrumental, .missing: lines = []
            default: lines = nil
            }
        }
        let playing = p.phase == .playing || p.phase == .loading
        let now = Date()
        // a seek (or a stall) moved the track away from where the widget thinks it is
        let expected = lastPosition + (playing ? now.timeIntervalSince(lastAt) : 0)
        let jumped = abs(p.position - expected) > 2.5
        let key = "\(t.ref)|\(playing)|\(lines?.count ?? -1)|\(Int(p.duration))"
        lastPosition = p.position
        lastAt = now
        guard key != lastKey || jumped else { return }
        lastKey = key

        StandBy.write(StandBy.State(ref: t.ref, title: t.title, artist: t.artist, playing: playing,
                                    position: p.position, duration: p.duration > 0 ? p.duration : (t.durationS ?? 0),
                                    at: now, lyrics: lines))
        StandBy.reload()
        saveCover(t)
    }

    private static func saveCover(_ t: QueueTrack) {
        guard coverRef != t.ref else { return }
        coverRef = t.ref
        let ref = t.ref
        Task {
            guard let url = HubClient.shared.absolute(t.coverSmallUrl ?? t.coverUrl),
                  let image = await ImageCache.shared.image(url), coverRef == ref,
                  let file = StandBy.coverURL else { return }
            let size = CGSize(width: 240, height: 240)
            let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            try? small.jpegData(compressionQuality: 0.85)?.write(to: file, options: .atomic)
            StandBy.reload()
        }
    }
}

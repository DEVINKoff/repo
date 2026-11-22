import MediaPlayer
import UIKit

/// Lock screen, Control Center, headphones and CarPlay-style remote controls (the PWA's `mediaSession`).
@MainActor
enum NowPlaying {
    private static var artworkRef: String?
    private static var artwork: MPMediaItemArtwork?

    static func setUp(_ player: Player) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.resume() }; return .success }
        c.pauseCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.toggle() }; return .success }
        c.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { Player.shared.next() } ? .success : .noActionableNowPlayingItem
        }
        c.previousTrackCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.prev() }; return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            MainActor.assumeIsolated { Player.shared.seek(t) }
            return .success
        }
        c.likeCommand.localizedTitle = "Нравится"
        c.likeCommand.addTarget { _ in
            MainActor.assumeIsolated {
                guard let t = Player.shared.track else { return .noActionableNowPlayingItem }
                let ctx = Player.shared.context
                Task { @MainActor in await Stars.shared.toggle(.track(t), context: ctx) }
                return .success
            }
        }
        c.dislikeCommand.localizedTitle = "Не нравится"
        c.dislikeCommand.addTarget { _ in
            MainActor.assumeIsolated {
                guard let t = Player.shared.track else { return .noActionableNowPlayingItem }
                let ctx = Player.shared.context
                Task { @MainActor in _ = await Dislikes.shared.set(.track(t), on: true, context: ctx) }
                return .success
            }
        }
    }

    static func update(_ p: Player, newTrack: Bool = false) {
        guard let t = p.track else { return clear() }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.position,
            MPNowPlayingInfoPropertyPlaybackRate: p.phase == .playing ? 1.0 : 0.0,
        ]
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if p.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = p.duration }
        if artworkRef == t.ref, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = p.isPlaying ? .playing : .paused
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = p.hasNext || p.repeatMode == .all

        if artworkRef != t.ref {
            artworkRef = t.ref
            artwork = nil
            let ref = t.ref
            Task {
                guard let url = HubClient.shared.absolute(t.coverUrl ?? t.coverSmallUrl),
                      let image = await ImageCache.shared.image(url) else { return }
                guard artworkRef == ref else { return }
                artwork = makeArtwork(image)
                update(Player.shared)
            }
        }
    }

    /// Outside the main actor: MediaPlayer asks for the image on its own thread.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    static func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        artworkRef = nil
        artwork = nil
    }
}

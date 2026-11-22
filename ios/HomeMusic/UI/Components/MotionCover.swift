import AVFoundation
import SwiftUI
import UIKit

/// Animated album covers (Apple Music's motion artwork): the Hub finds the video, this plays it muted and looped
/// over the still cover, fading in once the first frame is ready. Nothing shows for albums without one.
@MainActor
enum MotionCovers {
    private static var known: [String: URL?] = [:]
    private static var pending: [String: Task<URL?, Never>] = [:]

    static func key(_ t: QueueTrack) -> String? {
        guard let album = t.album, !album.isEmpty else { return nil }
        return Norm.key(t.artist) + "|" + Norm.key(album)
    }

    static func url(for t: QueueTrack) async -> URL? {
        guard let key = key(t), let album = t.album else { return nil }
        if let hit = known[key] { return hit }
        if let task = pending[key] { return await task.value }
        let ref = t.albumRef?.hasPrefix("am:") == true ? t.albumRef : nil
        let task = Task<URL?, Never> {
            let out = try? await HubClient.shared.motionCover(artist: t.artist, album: album, ref: ref)
            return out?.url.flatMap(URL.init(string:))
        }
        pending[key] = task
        let url = await task.value
        pending[key] = nil
        known[key] = url
        return url
    }
}

struct MotionCover: View {
    let track: QueueTrack
    let size: CGFloat
    let corner: CGFloat
    let playing: Bool
    @Environment(AppTheme.self) private var theme
    @State private var url: URL?
    @State private var ready = false

    var body: some View {
        ZStack {
            if let url, theme.motionCovers {
                LoopingVideo(url: url, playing: playing, ready: $ready)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .opacity(ready ? 1 : 0)
                    .animation(.easeInOut(duration: 0.6), value: ready)
            }
        }
        .allowsHitTesting(false)
        .task(id: MotionCovers.key(track)) {
            ready = false
            url = nil
            guard theme.motionCovers else { return }
            url = await MotionCovers.url(for: track)
        }
    }
}

/// A muted, looping AVPlayerLayer that never touches the audio session or Now Playing.
private struct LoopingVideo: UIViewRepresentable {
    let url: URL
    let playing: Bool
    @Binding var ready: Bool

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
        var observation: NSKeyValueObservation?
        var url: URL?
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .clear
        load(v)
        return v
    }

    func updateUIView(_ v: PlayerView, context: Context) {
        if v.url != url { load(v) }
        guard let p = v.playerLayer.player else { return }
        if playing { p.play() } else { p.pause() }
    }

    static func dismantleUIView(_ v: PlayerView, coordinator: ()) {
        v.playerLayer.player?.pause()
        v.observation?.invalidate()
        v.looper = nil
        v.playerLayer.player = nil
    }

    private func load(_ v: PlayerView) {
        v.observation?.invalidate()
        v.url = url
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = 6_000_000
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        v.looper = AVPlayerLooper(player: player, templateItem: item)
        v.playerLayer.player = player
        let binding = $ready
        v.observation = v.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { layer, _ in
            let ok = layer.isReadyForDisplay
            Task { @MainActor in binding.wrappedValue = ok }
        }
        if playing { player.play() }
    }
}

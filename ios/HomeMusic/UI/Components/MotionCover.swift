import AVFoundation
import SwiftUI
import UIKit

/// Animated album covers (Apple Music's motion artwork): the Hub finds the video, this plays it muted and looped
/// over the still cover, fading in once the first frame is ready. Nothing shows for albums without one.
@MainActor
enum MotionCovers {
    /// What the Hub answered, kept on the phone: a found cover for a month, «none» for three days.
    private struct Saved: Codable { var url: String?; var at: Date }
    private static var known: [String: URL?] = load()
    private static var saveTask: Task<Void, Never>?

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("motion-covers.json")
    }

    private static func load() -> [String: URL?] {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Saved].self, from: data) else { return [:] }
        var out: [String: URL?] = [:]
        for (k, v) in saved {
            let age = Date().timeIntervalSince(v.at)
            if let u = v.url, age < 30 * 86400 { out[k] = URL(string: u) } else if v.url == nil, age < 3 * 86400 { out[k] = .some(nil) }
        }
        return out
    }

    private static var stamps: [String: Date] = [:]

    private static func remember(_ key: String, _ url: URL?) {
        known[key] = .some(url)
        stamps[key] = Date()
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            var saved: [String: Saved] = (try? JSONDecoder().decode([String: Saved].self, from: Data(contentsOf: file))) ?? [:]
            for (k, v) in known { saved[k] = Saved(url: v?.absoluteString, at: stamps[k] ?? saved[k]?.at ?? Date()) }
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// The cover found before for this album, without asking (nil — unknown or none).
    static func cached(_ t: QueueTrack) -> URL? { known[key(t)] ?? nil }
    private static var pending: [String: Task<(url: URL?, status: String), Never>] = [:]

    static func key(_ t: QueueTrack) -> String {
        Norm.key(t.artist) + "|" + (t.album.map { Norm.key($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "t:" + Norm.key(t.title))
    }

    static func url(for t: QueueTrack) async -> URL? { await lookup(t).url }

    /// The animated cover of the track's album and why there is none: found / none / no_album / apple_unreachable.
    /// «Apple unreachable» is not remembered (asked again next time).
    static func lookup(_ t: QueueTrack) async -> (url: URL?, status: String) {
        let key = key(t)
        if let hit = known[key] { return (hit, hit == nil ? "none" : "found") }
        if let task = pending[key] { return await task.value }
        let ref = t.albumRef?.hasPrefix("am:") == true ? t.albumRef : nil
        let album = t.album ?? ""
        let task = Task<(url: URL?, status: String), Never> {
            guard let out = try? await HubClient.shared.motionCover(artist: t.artist, album: album, track: t.title, ref: ref) else {
                return (nil, "apple_unreachable")
            }
            return (out.url.flatMap(URL.init(string:)), out.status ?? (out.url == nil ? "none" : "found"))
        }
        pending[key] = task
        let res = await task.value
        pending[key] = nil
        // a found cover is never forgotten because Apple was busy later; «unreachable» is not remembered at all
        if res.status != "apple_unreachable" { remember(key, res.url) }
        return res
    }
}

struct LiveCover: View {
    let track: QueueTrack
    let size: CGFloat
    let corner: CGFloat
    let playing: Bool
    @Environment(AppTheme.self) private var theme
    @State private var url: URL?
    @State private var ready = false

    private var live: Bool { theme.motionCovers }

    var body: some View {
        ZStack {
            Cover(url: HiRes.cover(track.coverUrl ?? track.coverSmallUrl, size: 900), size: size, corner: 0,
                  fallback: track.coverUrl ?? track.coverSmallUrl)
            if let url, live {
                LoopingVideo(url: url, playing: playing, ready: $ready)
                    .opacity(ready ? 1 : 0)
                    .animation(.easeInOut(duration: 0.6), value: ready)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if url != nil {
                Image(systemName: live ? "livephoto" : "livephoto.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.22), in: Circle())
                    .opacity(0.55)
                    .padding(6)
                    .contentShape(Rectangle())
                    // ahead of every gesture around the cover (the player's scroll, the sheet)
                    .highPriorityGesture(TapGesture().onEnded {
                        withAnimation(.smooth) { theme.motionCovers.toggle() }
                        Toasts.info(theme.motionCovers ? "Живые обложки включены" : "Живые обложки выключены")
                    })
                    .sensoryFeedback(.selection, trigger: live)
                    .padding(4)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(live ? "Выключить живые обложки" : "Включить живые обложки")
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: url != nil)
        .onChange(of: live) { ready = false }
        .task(id: MotionCovers.key(track)) {
            ready = false
            url = MotionCovers.cached(track)
            let found = await MotionCovers.url(for: track)
            guard !Task.isCancelled else { return }
            url = found
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

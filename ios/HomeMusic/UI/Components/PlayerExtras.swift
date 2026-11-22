import SwiftUI
import UIKit

extension QueueTrack {
    /// Every artist of the track: its credits, else the names in its artist line («A, B feat. C»).
    var allArtists: [QueueTrack.Artist] {
        if let list = artists?.filter({ !$0.name.isEmpty }), list.count > 1 { return list }
        let names = artist
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring|x|×|&|и)\s+"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = names.filter { seen.insert(Norm.key($0)).inserted }
        if unique.count > 1 {
            let known = artists ?? []
            return unique.map { n in QueueTrack.Artist(name: n, ref: known.first { Norm.key($0.name) == Norm.key(n) }?.ref) }
        }
        return [QueueTrack.Artist(name: artists?.first?.name ?? artist, ref: artistRef ?? artists?.first?.ref)]
    }
}

// MARK: - Artist avatar

/// A round artist picture (found by name in the catalog), initials on the accent until it arrives.
struct ArtistAvatar: View {
    let name: String
    var size: CGFloat = 44
    @State private var picture: String?

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.gradient)
            Text(initials).font(.system(size: size * 0.38, weight: .bold).width(.expanded)).foregroundStyle(Theme.onAccent)
            if picture != nil {
                Cover(url: picture, size: size, round: true, symbol: "music.microphone").transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .task(id: name) {
            guard let res = try? await HubClient.shared.search(name) else { return }
            let who = Norm.key(name)
            if let a = res.artists.first(where: { Norm.key($0.name) == who }), let p = a.pictureSmallUrl ?? a.pictureUrl {
                withAnimation(.smooth) { picture = p }
            }
        }
    }

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

// MARK: - «Several artists» picker

/// Slides up from the bottom of the player as one glass card; each artist with a picture; a tap outside closes it.
struct ArtistPicker: View {
    let artists: [QueueTrack.Artist]
    let pick: (QueueTrack.Artist) -> Void
    let cancel: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.black.opacity(shown ? 0.35 : 0))
                .background(.ultraThinMaterial.opacity(shown ? 0.6 : 0))
                .ignoresSafeArea()
                .onTapGesture { close(cancel) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("ИСПОЛНИТЕЛИ")
                        .font(.system(size: 12, weight: .semibold).width(.expanded)).tracking(0.8).opacity(0.55)
                    Spacer()
                    Button { close(cancel) } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 30, height: 30)
                    }
                    .glassCircle()
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 4)
                ForEach(Array(artists.enumerated()), id: \.offset) { i, a in
                    Button { close { pick(a) } } label: {
                        HStack(spacing: 14) {
                            ArtistAvatar(name: a.name)
                            Text(a.name).font(.headline).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).opacity(0.35)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 24)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.06 * Double(i) + 0.05), value: shown)
                }
            }
            .padding(12)
            .foregroundStyle(.primary)
            .glassRect(30)
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
            .offset(y: shown ? 0 : 420)
        }
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) { shown = true } }
        .sensoryFeedback(.impact(weight: .light), trigger: shown)
    }

    private func close(_ then: @escaping () -> Void) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { then() }
    }
}

// MARK: - Below the player: about the track

/// Scrolled to under the player: the album, the artists, the file, the album's other tracks, the artist's popular ones.
struct TrackInfoSection: View {
    let track: QueueTrack
    let openArtist: () -> Void
    let open: (QueueTrack.Artist) -> Void
    @Environment(Player.self) private var player
    @State private var album: AlbumOut?
    @State private var top: [Track] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            card {
                VStack(alignment: .leading, spacing: 0) {
                    Text("О ТРЕКЕ").font(.system(size: 12, weight: .semibold).width(.expanded)).tracking(0.8).opacity(0.55)
                        .padding(.bottom, 10)
                    if let name = album?.title ?? track.album {
                        infoRow("Альбом", name, tap: track.albumRef.map { r in { Router.shared.go(.catalogAlbum(r)) } })
                    }
                    if let y = track.year ?? album?.displayYear { infoRow("Год", String(y)) }
                    if let d = track.durationS, d > 0 { infoRow("Длительность", Format.time(d)) }
                    if let g = album?.genre { infoRow("Жанр", g) }
                    if let info = player.info, player.track?.uid == track.uid {
                        infoRow("Источник", [info.provider ?? info.kind, info.bitrateKbps.map { "\(Int($0)) кбит/с" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let isrc = track.isrc { infoRow("ISRC", isrc) }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: track.allArtists.count > 1 ? "Исполнители" : "Исполнитель")
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(Array(track.allArtists.enumerated()), id: \.offset) { _, a in
                            Button { open(a) } label: {
                                VStack(spacing: 8) {
                                    ArtistAvatar(name: a.name, size: 84)
                                    Text(a.name).font(.footnote.weight(.semibold)).lineLimit(1).frame(width: 96)
                                }
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if let tracks = album?.tracks, tracks.count > 1 {
                list("Из этого альбома", tracks, context: "album")
            }
            if !top.isEmpty {
                list("Популярное у исполнителя", Array(top.prefix(5)), context: "artist")
            }
        }
        .padding(.top, 8)
        .task(id: track.ref) { await load() }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(18).frame(maxWidth: .infinity, alignment: .leading).glassRect(24)
    }

    private func infoRow(_ label: String, _ value: String, tap: (() -> Void)? = nil) -> some View {
        Button { tap?() } label: {
            HStack {
                Text(label).opacity(0.55)
                Spacer(minLength: 16)
                Text(value).fontWeight(.medium).lineLimit(1)
                if tap != nil { Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.4) }
            }
            .font(.subheadline)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tap == nil)
    }

    private func list(_ title: String, _ tracks: [Track], context: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            ForEach(Array(tracks.enumerated()), id: \.element.ref) { i, t in
                TrackRow(track: t, list: tracks, context: context, origin: "player", order: i)
                    .padding(.vertical, 4)
            }
        }
    }

    private func load() async {
        album = nil
        top = []
        if let r = track.albumRef, !r.hasPrefix("nd:"), !r.hasPrefix("file:"),
           let a = try? await HubClient.shared.album(r) {
            withAnimation(.smooth) { album = a }
        }
        if let ref = track.allArtists.first?.ref, let p = try? await HubClient.shared.artist(ref) {
            withAnimation(.smooth) { top = p.topTracks.filter { $0.ref != track.ref } }
        }
    }
}

// MARK: - Cinematic mode (the phone sideways)

/// Full-bleed: the cover's colours fill the whole screen; the cover (animated when Apple has it) on the left; the
/// title and the same lyrics as the portrait player on the right; a full-width control bar at the bottom (a big ⏯,
/// the progress line with times). The bar fades after a few seconds (a tap brings it back); the screen stays on.
struct CinematicPlayer: View {
    let track: QueueTrack
    let size: CGSize
    let rotateBack: () -> Void
    @Environment(Player.self) private var player
    @Environment(Lyrics.self) private var lyrics
    @Environment(Stars.self) private var stars
    @State private var controls = true
    @State private var hide: Task<Void, Never>?

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let w = g.size.width
            let barH: CGFloat = 96
            // the bar gone, the cover and the lyrics zoom into its room
            let upper = controls ? h - barH : h - 8
            let art = min(upper * 0.9, w * (controls ? 0.34 : 0.4))
            ZStack(alignment: .bottom) {
                HStack(alignment: .center, spacing: w * 0.045) {
                    LiveCover(track: track, size: art, corner: art * 0.07, playing: player.isPlaying)
                        .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
                        .scaleEffect(player.isPlaying ? 1 : 0.95)
                        .animation(.spring(response: 0.6, dampingFraction: 0.75), value: player.isPlaying)
                        .id(track.uid)
                        .transition(.blurFade)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title)
                                    .font(.system(size: 22, weight: .bold).width(.expanded))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                Text(track.artist).font(.system(size: 15, weight: .medium)).opacity(0.6).lineLimit(1)
                            }
                            .id(track.uid)
                            .transition(.blurFade)
                            Spacer(minLength: 0)
                            Button(action: rotateBack) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 38, height: 38)
                            }
                            .glassCircle()
                            .buttonStyle(.plain)
                            .opacity(controls ? 1 : 0)
                        }
                        .padding(.bottom, 4)
                        // the same lyrics as the portrait player: every line, scrolled to the sung one
                        LyricsView()
                            .padding(.leading, 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: upper)
                }
                .frame(height: upper)
                .frame(maxHeight: .infinity, alignment: .top)
                CinematicBar(liked: stars.isLiked(.track(track)), like: {
                    Task { await stars.toggle(.track(track), context: player.context) }
                }, poke: poke)
                .frame(height: barH)
                .opacity(controls ? 1 : 0)
                .offset(y: controls ? 0 : 30)
                .blur(radius: controls ? 0 : 6)
                .allowsHitTesting(controls)
            }
            .frame(width: w, height: h)
            .animation(.spring(response: 0.7, dampingFraction: 0.88), value: controls)
            .animation(.smooth(duration: 0.5), value: track.uid)
        }
        // clear of the screen's rounded corners and the camera
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 10)
        .background { CinematicBackdrop(url: track.coverUrl ?? track.coverSmallUrl, tintKey: MotionCovers.key(track)) }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // a tap on an empty spot shows or hides the controls (a tap on a lyric line or a button is theirs)
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        // controls hidden: the whole screen is one catch-all — nothing under it (the lyrics) reacts
        .overlay {
            if !controls {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .topTrailing) {
            VolumeDial().padding(.top, 14).padding(.trailing, 22)
        }
        .background { SystemVolumeHider().frame(width: 1, height: 1) }
        .animation(.smooth(duration: 0.45), value: controls)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            VolumeWatch.shared.start()
            lyrics.load(for: player.track)
            poke()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            VolumeWatch.shared.stop()
            hide?.cancel()
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
    }

    private func toggleControls() {
        if controls {
            hide?.cancel()
            Haptics.soft(0.4)
            withAnimation(.smooth) { controls = false }
        } else {
            Haptics.soft(0.6)
            poke()
        }
    }

    /// Shows the bar and hides it again after a few seconds.
    private func poke() {
        withAnimation(.smooth) { controls = true }
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.6)) { controls = false }
        }
    }
}

/// The cinematic control bar: ♥ · ⏮ (big ⏯) ⏭ · repeat, over a full-width progress line with its times.
private struct CinematicBar: View {
    let liked: Bool
    let like: () -> Void
    let poke: () -> Void
    @Environment(Player.self) private var player

    var body: some View {
        VStack(spacing: 6) {
            Hairline(poke: poke)
            HStack {
                Button { Haptics.tap(); like(); poke() } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? Theme.accent : .white)
                        .symbolEffect(.bounce, value: liked)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                Spacer()
                HStack(spacing: 30) {
                    Button { Haptics.tap(); player.prev(); poke() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 24)).frame(width: 48, height: 48)
                    }
                    Button { Haptics.press(); player.toggle(); poke() } label: {
                        ZStack {
                            Circle().fill(Theme.accent)
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .contentTransition(.symbolEffect(.replace))
                                .offset(x: player.isPlaying ? 0 : 2)
                        }
                        .frame(width: 58, height: 58)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 14, y: 6)
                    }
                    Button { Haptics.tap(); player.next(); poke() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 24)).frame(width: 48, height: 48)
                    }
                }
                Spacer()
                Button { Haptics.select(); player.cycleRepeat(); poke() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode != .off ? Theme.accent : .white.opacity(0.6))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
            }
            .font(.system(size: 19, weight: .semibold))
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

private struct Hairline: View {
    let poke: () -> Void
    @Environment(Player.self) private var player
    @State private var drag: Double?

    var body: some View {
        let total = max(player.duration, 1)
        let shown = min(drag ?? player.position, total)
        HStack(spacing: 12) {
            Text(Format.time(shown)).frame(minWidth: 38, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(drag == nil ? Color.white : Theme.accent).frame(width: g.size.width * shown / total)
                }
                .frame(height: drag == nil ? 4 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        poke()
                        player.scrubbing = true
                        drag = max(0, min(total, Double(v.location.x / g.size.width) * total))
                    }
                    .onEnded { _ in
                        player.scrubbing = false
                        if let d = drag { player.seek(d) }
                        drag = nil
                    })
                .animation(.smooth(duration: 0.2), value: drag == nil)
            }
            .frame(height: 22)
            Text("-" + Format.time(max(0, player.duration - shown))).frame(minWidth: 42, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit().weight(.medium))
        .foregroundStyle(.white.opacity(0.65))
    }
}

/// The cover blown up and blurred behind everything, darkened, filling the whole screen edge to edge.
private struct CinematicBackdrop: View {
    let url: String?
    var tintKey: String? = nil
    @State private var image: UIImage?
    @Environment(MotionTint.self) private var tint

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05)
                // the animated cover's own colours while it plays, else the still cover's
                if let frame = tintKey.flatMap({ tint.frame(for: $0) }) ?? image {
                    Image(uiImage: frame).resizable().scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .blur(radius: 60, opaque: true)
                        .saturation(1.5)
                        .opacity(0.75)
                        .id(ObjectIdentifier(frame))
                        .transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.9), value: tint.version)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: url) {
            guard let u = HubClient.shared.absolute(url) else { return }
            if let img = await ImageCache.shared.image(u, px: 256) { withAnimation(.easeInOut(duration: 0.8)) { image = img } }
        }
    }
}

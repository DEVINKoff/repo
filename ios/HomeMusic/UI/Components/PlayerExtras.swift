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

/// Full-bleed: the cover's colours fill the screen, the cover (animated where it can be) on the left, the title and
/// the sung line on the right. Every size follows the screen's height. The controls float over the bottom, fade
/// away after a few seconds and come back with a tap. The screen stays on.
struct CinematicPlayer: View {
    let track: QueueTrack
    let size: CGSize
    let rotateBack: () -> Void
    @Environment(Player.self) private var player
    @Environment(Lyrics.self) private var lyrics
    @State private var controls = true
    @State private var hide: Task<Void, Never>?

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let w = g.size.width
            let art = min(h * 0.66, w * 0.36)
            ZStack {
                CinematicBackdrop(url: track.coverUrl ?? track.coverSmallUrl)
                HStack(alignment: .center, spacing: w * 0.05) {
                    LiveCover(track: track, size: art, corner: art * 0.08, playing: player.isPlaying)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                        .scaleEffect(player.isPlaying ? 1 : 0.94)
                        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: player.isPlaying)
                        .id(track.uid)
                        .transition(.scale(scale: 0.9).combined(with: .blurFade))
                    VStack(alignment: .leading, spacing: h * 0.03) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: min(26, h * 0.07), weight: .heavy).width(.expanded))
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text(track.artist)
                                .font(.system(size: min(17, h * 0.045), weight: .medium))
                                .opacity(0.7).lineLimit(1)
                        }
                        .id(track.uid)
                        .transition(.blurFade)
                        CinematicLyric(size: min(26, h * 0.068))
                            .frame(maxWidth: .infinity, maxHeight: h * 0.42, alignment: .topLeading)
                            .clipped()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, controls ? h * 0.2 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.85), value: track.uid)

                VStack {
                    HStack {
                        Spacer()
                        Button(action: rotateBack) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.headline).frame(width: 38, height: 38)
                        }
                        .glassCircle()
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    HStack(spacing: 22) {
                        Button { player.prev(); poke() } label: { Image(systemName: "backward.fill").font(.title3) }
                        Button { player.toggle(); poke() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 46, height: 46)
                        }
                        .glassCircle()
                        Button { player.next(); poke() } label: { Image(systemName: "forward.fill").font(.title3) }
                        Scrubber()
                            .frame(maxWidth: .infinity)
                            .simultaneousGesture(TapGesture().onEnded { poke() })
                    }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .glassCapsule()
                }
                .opacity(controls ? 1 : 0)
                .offset(y: controls ? 0 : 16)
                .allowsHitTesting(controls)
            }
            .frame(width: w, height: h)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture {
            if controls { withAnimation(.smooth) { controls = false } } else { poke() }
        }
        .animation(.smooth(duration: 0.4), value: controls)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            lyrics.load(for: player.track)
            poke()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hide?.cancel()
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
    }

    /// Shows the controls and hides them again after a few seconds.
    private func poke() {
        withAnimation(.smooth) { controls = true }
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.6)) { controls = false }
        }
    }
}

/// The cover blown up and blurred behind everything, darkened, filling the whole screen.
private struct CinematicBackdrop: View {
    let url: String?
    @State private var image: UIImage?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .blur(radius: 50, opaque: true)
                        .saturation(1.4)
                        .scaleEffect(1.25)
                        .transition(.opacity)
                }
            }
            .overlay(Color.black.opacity(0.45))
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .task(id: url) {
                guard let u = HubClient.shared.absolute(url) else { return }
                if let img = await ImageCache.shared.image(u, px: 256) { withAnimation(.easeInOut(duration: 0.8)) { image = img } }
            }
    }
}

/// The sung line, with the next one dimmed below it; lines rise in and out.
struct CinematicLyric: View {
    var size: CGFloat = 26
    @Environment(Player.self) private var player
    @Environment(Lyrics.self) private var lyrics

    var body: some View {
        if case .synced(let lines) = lyrics.state,
           let id = Lyrics.current(lines, at: player.position),
           let i = lines.firstIndex(where: { $0.id == id }) {
            let line = lines[i]
            VStack(alignment: .leading, spacing: size * 0.4) {
                Group {
                    if line.words.isEmpty {
                        Text(line.text.isEmpty ? "♪" : line.text).font(.system(size: size, weight: .heavy))
                    } else {
                        SungLine(line: line, size: size)
                    }
                }
                .id(line.id)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .blurFade),
                                        removal: .move(edge: .top).combined(with: .blurFade)))
                if i + 1 < lines.count {
                    Text(lines[i + 1].text).font(.system(size: size * 0.62, weight: .bold)).opacity(0.35).lineLimit(1)
                        .id("next-\(line.id)")
                        .transition(.blurFade)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.spring(response: 0.6, dampingFraction: 0.86), value: line.id)
        } else if case .plain = lyrics.state {
            Text("Текст без синхронизации").font(.footnote).opacity(0.4)
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

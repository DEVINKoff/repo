import SwiftUI

/// The full player. Its own look rather than Apple Music's: a dark surface lit by the cover's colours from above,
/// a large rounded cover that slides between tracks, a thin accent progress line, an accent play button and one
/// glass bar of modes. The middle switches between the cover, live lyrics and the queue.
struct PlayerView: View {
    enum Mode { case cover, lyrics, queue }

    @Environment(Player.self) private var player
    @Environment(Stars.self) private var stars
    @Environment(Wave.self) private var wave
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .cover
    @State private var isLandscape = false
    @Namespace private var hero
    @State private var picking: QueueTrack?
    /// the artists of a track with several, to pick which one to open
    @State private var artistChoice: [QueueTrack.Artist] = []

    var body: some View {
        GeometryReader { geo in
            let art = max(140, min(geo.size.width - 48, geo.size.height * 0.44))
            ZStack {
                PlayerBackground(url: player.track?.coverUrl ?? player.track?.coverSmallUrl,
                                 tintKey: player.track.map { MotionCovers.key($0) })
                if let t = player.track {
                    if geo.size.width > geo.size.height * 1.15 {
                        // the phone turned sideways: the cinematic mode
                        CinematicPlayer(track: t, size: geo.size, rotateBack: { rotate(landscape: false) })
                            .transition(.blurFade)
                    } else {
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                page(t, art: art).frame(height: geo.size.height)
                                // scroll down: more about the track (only under the cover: the lyrics and the queue
                                // scroll themselves, and with nothing below the page doesn't move)
                                if mode == .cover {
                                    TrackInfoSection(track: t, openArtist: { openArtist(t) }, open: open)
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 40)
                                        .transition(.opacity)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .transition(.blurFade)
                    }
                } else {
                    ContentUnavailableView("Ничего не играет", systemImage: "music.note")
                }
                if !artistChoice.isEmpty {
                    ArtistPicker(artists: artistChoice, pick: { a in
                        artistChoice = []
                        open(a)
                    }, cancel: { artistChoice = [] })
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: artistChoice.isEmpty)
            .animation(.smooth(duration: 0.4), value: geo.size.width > geo.size.height * 1.15)
        }
        .presentationBackground(Color(.systemBackground))
        .presentationDragIndicator(.visible)
        .sheet(item: $picking) { PickFileSheet(track: $0) }
        .interactiveDismissDisabled(isLandscape)
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height * 1.15 } action: { isLandscape = $0 }
    }

    /// The first screen of the player (the rest is below it).
    private func page(_ t: QueueTrack, art: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch mode {
                case .cover:
                    LiveCover(track: t, size: art, corner: 26, playing: player.isPlaying)
                        .shadow(color: .black.opacity(0.5), radius: player.isPlaying ? 34 : 18, y: player.isPlaying ? 20 : 10)
                        .scaleEffect(player.isPlaying ? 1 : 0.88)
                        .animation(.spring(response: 0.55, dampingFraction: 0.68), value: player.isPlaying)
                        .id(t.uid)
                        .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .blurFade),
                                                removal: .scale(scale: 1.08).combined(with: .blurFade)))
                case .lyrics:
                    LyricsView().padding(.horizontal, 4)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .blurFade), removal: .blurFade))
                case .queue:
                    QueueView().transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .blurFade), removal: .blurFade))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: t.uid)
            if mode == .lyrics || mode == .queue { compactTitle(t).padding(.bottom, 10) }
            VStack(spacing: 0) {
                if mode == .cover { titleRow(t).padding(.bottom, 6) }
                infoRow(t).frame(height: 30)
                Scrubber()
                    .padding(.top, 4)
                transport.padding(.top, 14)
                modesBar.padding(.top, 22)
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 22, weight: .medium))
                    .opacity(mode == .cover ? 0.25 : 0)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 24)
        .foregroundStyle(.primary)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: mode)
    }

    /// Turns the phone's UI sideways (the cinematic mode) or back.
    private func rotate(landscape: Bool) {
        Haptics.soft()
        if landscape { AppDelegate.toLandscape() } else { AppDelegate.backToPortrait() }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40) }
                .glassCircle()
            Color.clear.frame(width: 48, height: 40)
            Spacer()
            VStack(spacing: 2) {
                Text(contextTitle.uppercased())
                    .font(.system(size: 11, weight: .semibold).width(.expanded)).tracking(0.8).opacity(0.75).lineLimit(1)
                Text(sourceLine).font(.caption2).opacity(0.5).lineLimit(1)
            }
            Spacer()
            if let t = player.track {
                HStack(spacing: 8) {
                    Button { rotate(landscape: true) } label: {
                        Image(systemName: "rectangle.landscape.rotate").font(.subheadline.weight(.semibold)).frame(width: 40, height: 40)
                    }
                    .glassCircle()
                    .accessibilityLabel("Кинорежим")
                    Menu {
                        TrackMenuItems(track: Track(t), context: player.context, inPlayer: true)
                        if !t.ref.hasPrefix("nd:") && !t.ref.hasPrefix("file:") && player.info?.kind != "library" {
                            Section {
                                Button { picking = t } label: {
                                    Label("Выбрать другой файл", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                        }
                        Section {
                            Toggle(isOn: Binding(get: { AppTheme.shared.motionCovers }, set: { AppTheme.shared.motionCovers = $0 })) {
                                Label("Живые обложки", systemImage: "livephoto")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.headline).frame(width: 40, height: 40)
                    }
                    .glassCircle()
                }
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
        .buttonStyle(.plain)
    }

    private var sourceLine: String {
        guard let info = player.info else { return player.phase == .resolving ? "Ищем файл…" : " " }
        switch info.kind {
        case "preview": return "превью 30 сек"
        case "library": return "из библиотеки"
        default:
            return [info.provider, info.bitrateKbps.map { "\(Int($0)) кбит/с" }].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var contextTitle: String {
        let c = player.context
        if c.hasPrefix("wave:") { return wave.title ?? "Моя волна" }
        if c.hasPrefix("mix:") { return "Микс дня" }
        switch c {
        case "liked": return "Понравившиеся"
        case "playlist": return "Плейлист"
        case "album": return "Альбом"
        case "artist": return "Исполнитель"
        case "search": return "Поиск"
        default: return "Сейчас играет"
        }
    }

    private func titleRow(_ t: QueueTrack) -> some View {
        let liked = stars.isLiked(.track(t))
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.title).font(.display(22, .bold)).lineLimit(1)
                artistButton(t, font: .body.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(t.uid)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .blurFade),
                                    removal: .move(edge: .leading).combined(with: .blurFade)))
            likeButton(t, liked)
        }
    }

    /// Title line above the controls while the lyrics or the queue take the middle.
    private func compactTitle(_ t: QueueTrack) -> some View {
        HStack(spacing: 12) {
            // a tap on the small cover (or the title) brings the big cover back
            Button { mode = .cover } label: {
                Cover(url: t.coverSmallUrl ?? t.coverUrl, size: 48, corner: 10)
            }
            .buttonStyle(.pressable)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.headline).lineLimit(1)
                    .onTapGesture { mode = .cover }
                artistButton(t, font: .subheadline)
            }
            .id(t.uid)
            .transition(.blurFade)
            Spacer()
            likeButton(t, stars.isLiked(.track(t)))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func likeButton(_ t: QueueTrack, _ liked: Bool) -> some View {
        Button { Task { await stars.toggle(.track(t), context: player.context) } } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundStyle(liked ? Theme.accent : .primary)
                .symbolEffect(.bounce, value: liked)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background { LikeBurst(on: liked) }
        }
        .buttonStyle(.plain)
        .glassCircle()
        // one heart: it flies between the title row and the compact row (never two on screen)
        .matchedGeometryEffect(id: "like", in: hero)
        .sensoryFeedback(.impact(weight: .light), trigger: liked)
    }

    /// The artist's name: a tap opens the artist (the player closes).
    private func artistButton(_ t: QueueTrack, font: Font) -> some View {
        Button { openArtist(t) } label: {
            HStack(spacing: 3) {
                Text(t.artist).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).opacity(0.6)
            }
            .font(font)
            .opacity(0.65)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func openArtist(_ t: QueueTrack) {
        Haptics.tap()
        let all = t.allArtists
        if all.count > 1 { artistChoice = all } else if let a = all.first { open(a) }
    }

    private func open(_ a: QueueTrack.Artist) {
        if let ref = a.ref {
            Router.shared.go(.catalogArtist(ref))
            return
        }
        // a library or file track carries no catalog ref: find the artist by name
        let name = a.name
        Task {
            guard let res = try? await HubClient.shared.search(name), !res.artists.isEmpty else {
                Toasts.info("Исполнитель «\(name)» не найден в каталоге")
                return
            }
            let who = Norm.key(name)
            let a = res.artists.first { Norm.key($0.name) == who } ?? res.artists[0]
            Router.shared.go(.catalogArtist(a.ref))
        }
    }

    /// ✨ the smart shuffle's line with «+» / «−», or the error; empty otherwise (a still layout).
    @ViewBuilder private func infoRow(_ t: QueueTrack) -> some View {
        if let rec = t.rec {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text(rec.label).font(.footnote).lineLimit(1).opacity(0.8)
                Spacer()
                Button { Task { await SmartShuffle.shared.hide(t) } } label: { Image(systemName: "minus").frame(width: 28, height: 28) }
                    .glassCircle()
                Button { Task { await SmartShuffle.shared.add(t) } } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        } else if player.phase == .error, let e = player.error {
            Text(e).font(.footnote).foregroundStyle(.yellow).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
        }
    }

    private var transport: some View {
        let canNext = player.hasNext || player.repeatMode == .all
        return HStack {
            Button { Haptics.tap(); player.prev() } label: {
                Image(systemName: "backward.fill").font(.system(size: 26)).frame(width: 64, height: 64)
            }
            .buttonStyle(.pressable)
            Spacer()
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(Theme.accent)
                    if player.phase == .resolving || player.phase == .loading {
                        ProgressView().tint(Theme.onAccent).controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .contentTransition(.symbolEffect(.replace))
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
                .frame(width: 82, height: 82)
                .shadow(color: Theme.accent.opacity(0.45), radius: 18, y: 8)
            }
            .buttonStyle(.pressable)
            .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
            Spacer()
            Button { Haptics.tap(); player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 26)).frame(width: 64, height: 64)
            }
            .buttonStyle(.pressable)
            .disabled(!canNext)
            .opacity(canNext ? 1 : 0.35)
        }
        .padding(.horizontal, 12)
    }

    private var modesBar: some View {
        HStack {
            modeButton(player.smart ? "sparkles" : "shuffle", on: player.shuffle) { player.cycleShuffle() }
                .disabled(player.onWave)
                .opacity(player.onWave ? 0.3 : 1)
            Spacer()
            modeButton("quote.bubble", on: mode == .lyrics) { mode = mode == .lyrics ? .cover : .lyrics }
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
            Spacer()
            modeButton("list.bullet", on: mode == .queue) { mode = mode == .queue ? .cover : .queue }
            Spacer()
            modeButton(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) { player.cycleRepeat() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .glassCapsule()
    }

    private func modeButton(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.select(); action() } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.55))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: on)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressable)
        .animation(.smooth(duration: 0.2), value: on)
    }
}

/// A thin progress line that thickens under the finger (drag to seek; the time labels follow the finger).
struct Scrubber: View {
    @Environment(Player.self) private var player
    @State private var drag: Double?
    @State private var landing: Double?

    var body: some View {
        let total = max(player.duration, 1)
        let shown = min(drag ?? landing ?? player.position, total)
        VStack(spacing: 8) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(drag == nil ? Color.primary : Theme.accent)
                        .frame(width: max(0, min(w, w * shown / total)))
                }
                .frame(height: drag == nil ? 5 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            player.scrubbing = true
                            drag = max(0, min(total, Double(v.location.x / w) * total))
                        }
                        .onEnded { _ in
                            player.scrubbing = false
                            if let d = drag {
                                landing = d
                                player.seek(d)
                                Task { try? await Task.sleep(for: .seconds(1.5)); landing = nil }
                            }
                            drag = nil
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: drag == nil)
            }
            .frame(height: 20)
            HStack {
                Text(Format.time(shown))
                Spacer()
                Text("-" + Format.time(max(0, player.duration - shown)))
            }
            .font(.caption.monospacedDigit())
            .opacity(drag == nil ? 0.5 : 0.9)
        }
        .sensoryFeedback(.selection, trigger: drag == nil)
    }
}

/// A plain surface (dark or light, as the app's theme), with the cover's colours glowing from the top.
struct PlayerBackground: View {
    var url: String?
    var tintKey: String? = nil
    @Environment(MotionTint.self) private var tint

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.035, green: 0.035, blue: 0.05, alpha: 1)
                                                               : UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1) })
                ZStack {
                    Cover(url: url, size: g.size.width, corner: 0, pixels: 160)
                    // the animated cover's own colours while it plays, flowing over the still ones
                    if let colors = tintKey.flatMap({ tint.colors(for: $0) }) {
                        TintMesh(colors: colors).transition(.opacity)
                    }
                }
                    .frame(width: g.size.width, height: g.size.width)
                    .animation(.easeInOut(duration: 1.2), value: tintKey.flatMap { tint.colors(for: $0) } != nil)
                    .blur(radius: 80, opaque: true)
                    .saturation(1.6)
                    .opacity(0.55)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                    .clipped()
                    .animation(.easeInOut(duration: 0.8), value: url)
                RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .bottom, startRadius: 10, endRadius: g.size.height * 0.6)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}


/// A ring and a few sparks fly out of the heart when a track is liked.
struct LikeBurst: View {
    let on: Bool
    @State private var shot = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(Theme.accent, lineWidth: shot ? 0.5 : 6)
                .scaleEffect(shot ? 1.9 : 0.4)
                .opacity(shot ? 0 : 0.9)
            ForEach(0..<6, id: \.self) { i in
                Circle().fill(Theme.accent)
                    .frame(width: 5, height: 5)
                    .offset(y: shot ? -34 : -8)
                    .rotationEffect(.degrees(Double(i) * 60))
                    .opacity(shot ? 0 : 1)
            }
        }
        .opacity(on ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: on) { _, now in
            guard now else { return }
            shot = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { withAnimation(.easeOut(duration: 0.6)) { shot = true } }
        }
        .onAppear { shot = true }
    }
}

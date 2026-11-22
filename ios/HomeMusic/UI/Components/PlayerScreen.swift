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

    var body: some View {
        GeometryReader { geo in
            let art = max(140, min(geo.size.width - 48, geo.size.height * 0.44))
            ZStack {
                PlayerBackground(url: player.track?.coverUrl ?? player.track?.coverSmallUrl)
                if let t = player.track {
                    VStack(spacing: 0) {
                        header
                        ZStack {
                            switch mode {
                            case .cover:
                                Cover(url: HiRes.cover(t.coverUrl ?? t.coverSmallUrl, size: 900), size: art, corner: 26,
                                      fallback: t.coverUrl ?? t.coverSmallUrl)
                                    .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
                                    .scaleEffect(player.isPlaying ? 1 : 0.9)
                                    .animation(.spring(response: 0.55, dampingFraction: 0.72), value: player.isPlaying)
                                    .id(t.uid)
                                    .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                                            removal: .scale(scale: 1.05).combined(with: .opacity)))
                            case .lyrics:
                                LyricsView().padding(.horizontal, 4).transition(.opacity)
                            case .queue:
                                QueueView().transition(.opacity)
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
                            modesBar.padding(.top, 22).padding(.bottom, 10)
                        }
                    }
                    .padding(.horizontal, 24)
                    .foregroundStyle(.white)
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: mode)
                } else {
                    ContentUnavailableView("Ничего не играет", systemImage: "music.note").foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40) }
                .glassCircle()
            Spacer()
            VStack(spacing: 2) {
                Text(contextTitle.uppercased())
                    .font(.system(size: 11, weight: .semibold).width(.expanded)).tracking(0.8).opacity(0.75).lineLimit(1)
                Text(sourceLine).font(.caption2).opacity(0.5).lineLimit(1)
            }
            Spacer()
            if let t = player.track {
                Menu { TrackMenuItems(track: Track(t), context: player.context, inPlayer: true) } label: {
                    Image(systemName: "ellipsis").font(.headline).frame(width: 40, height: 40)
                }
                .glassCircle()
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
                Text(t.artist).font(.body.weight(.medium)).opacity(0.6).lineLimit(1)
                    .onTapGesture { openArtist(t) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(t.uid)
            .transition(.opacity.combined(with: .move(edge: .leading)))
            likeButton(t, liked)
        }
    }

    /// Title line above the controls while the lyrics or the queue take the middle.
    private func compactTitle(_ t: QueueTrack) -> some View {
        HStack(spacing: 12) {
            Cover(url: t.coverSmallUrl ?? t.coverUrl, size: 48, corner: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.headline).lineLimit(1)
                Text(t.artist).font(.subheadline).opacity(0.6).lineLimit(1)
            }
            Spacer()
            likeButton(t, stars.isLiked(.track(t)))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func likeButton(_ t: QueueTrack, _ liked: Bool) -> some View {
        Button { Task { await stars.toggle(.track(t), context: player.context) } } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundStyle(liked ? Theme.accent : .white)
                .symbolEffect(.bounce, value: liked)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassCircle()
        .sensoryFeedback(.impact(weight: .light), trigger: liked)
    }

    private func openArtist(_ t: QueueTrack) {
        if let a = t.artistRef ?? t.artists?.first(where: { $0.ref != nil })?.ref { Router.shared.go(.catalogArtist(a)) }
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
            Button { player.prev() } label: {
                Image(systemName: "backward.fill").font(.system(size: 26)).frame(width: 64, height: 64)
            }
            .buttonStyle(.pressable)
            Spacer()
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(Theme.accent)
                    if player.phase == .resolving || player.phase == .loading {
                        ProgressView().tint(.white).controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34, weight: .semibold))
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
            Button { player.next() } label: {
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
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : .white.opacity(0.55))
                .contentTransition(.symbolEffect(.replace))
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
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(drag == nil ? Color.white : Theme.accent)
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

/// Dark, with the cover's colours glowing from the top (not a full-screen blur).
struct PlayerBackground: View {
    var url: String?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Color(red: 0.035, green: 0.035, blue: 0.05)
                Cover(url: url, size: g.size.width, corner: 0)
                    .frame(width: g.size.width, height: g.size.width)
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

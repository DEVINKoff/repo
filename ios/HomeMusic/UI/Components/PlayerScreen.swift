import SwiftUI

/// The full player (Apple Music's Now Playing): artwork, title, scrubber, transport, modes, the queue.
/// The artwork has a fixed size from the screen, so nothing below it moves when a line appears or a cover loads.
struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(Stars.self) private var stars
    @Environment(Wave.self) private var wave
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var dragPosition: Double?
    @State private var seekTarget: Double?

    var body: some View {
        GeometryReader { geo in
            let art = max(120, min(geo.size.width - 56, geo.size.height * 0.42))
            ZStack {
                ArtworkBackground(url: player.track?.coverUrl ?? player.track?.coverSmallUrl)
                if let t = player.track {
                    VStack(spacing: 0) {
                        header
                        ZStack {
                            if showQueue {
                                QueueView().transition(.opacity)
                            } else {
                                Cover(url: t.coverUrl ?? t.coverSmallUrl, size: art, corner: 14)
                                    .shadow(color: .black.opacity(0.4), radius: 26, y: 14)
                                    .scaleEffect(player.isPlaying ? 1 : 0.86)
                                    .animation(.spring(response: 0.5, dampingFraction: 0.75), value: player.isPlaying)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(spacing: 0) {
                            titleRow(t)
                            recRow(t).frame(height: 38)
                            scrubber
                            transport.padding(.top, 6)
                            bottomBar.padding(.top, 20).padding(.bottom, 12)
                        }
                    }
                    .padding(.horizontal, 24)
                    .foregroundStyle(.white)
                } else {
                    ContentUnavailableView("Ничего не играет", systemImage: "music.note").foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
        .presentationDragIndicator(.visible)
        .animation(.easeInOut(duration: 0.25), value: showQueue)
        .onChange(of: player.position) { _, p in
            // the scrubber follows the player again once the seek has landed
            if let target = seekTarget, abs(p - target) < 1.5 { seekTarget = nil }
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40) }
                .glassCircle()
            Spacer()
            VStack(spacing: 1) {
                Text(contextTitle).font(.caption.weight(.semibold)).opacity(0.8).lineLimit(1)
                Text(sourceLine).font(.caption2).opacity(0.6).lineLimit(1)
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
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.title3.weight(.bold)).lineLimit(1)
                Text(t.artist).font(.title3).opacity(0.7).lineLimit(1)
                    .onTapGesture {
                        if let a = t.artistRef ?? t.artists?.first(where: { $0.ref != nil })?.ref { Router.shared.go(.catalogArtist(a)) }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await stars.toggle(.track(t), context: player.context) } } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .sensoryFeedback(.impact, trigger: liked)
        }
    }

    /// ✨ «Рекомендация на основе …» with «+» and «−» (smart shuffle), or the error; empty otherwise (a still layout).
    @ViewBuilder private func recRow(_ t: QueueTrack) -> some View {
        if let rec = t.rec {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                Text(rec.label).font(.footnote).lineLimit(1)
                Spacer()
                Button { Task { await SmartShuffle.shared.hide(t) } } label: { Image(systemName: "minus").frame(width: 30, height: 30) }
                    .glassCircle()
                Button { Task { await SmartShuffle.shared.add(t) } } label: { Image(systemName: "plus").frame(width: 30, height: 30) }
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .opacity(0.9)
        } else if player.phase == .error, let e = player.error {
            Text(e).font(.footnote).foregroundStyle(.yellow).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
        }
    }

    private var scrubber: some View {
        let total = max(player.duration, 1)
        let shown = min(dragPosition ?? seekTarget ?? player.position, total)
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { shown }, set: { dragPosition = $0 }), in: 0...total) { editing in
                player.scrubbing = editing
                if !editing, let d = dragPosition {
                    seekTarget = d
                    player.seek(d)
                    dragPosition = nil
                    Task { try? await Task.sleep(for: .seconds(2)); seekTarget = nil }
                }
            }
            .tint(.white)
            HStack {
                Text(Format.time(shown))
                Spacer()
                Text("-" + Format.time(max(0, player.duration - shown)))
            }
            .font(.caption2.monospacedDigit())
            .opacity(0.65)
        }
    }

    private var transport: some View {
        let canNext = player.hasNext || player.repeatMode == .all
        return HStack {
            Spacer()
            Button { player.prev() } label: { Image(systemName: "backward.fill").font(.system(size: 30)).frame(width: 60, height: 60) }
            Spacer()
            Button { player.toggle() } label: {
                ZStack {
                    if player.phase == .resolving || player.phase == .loading {
                        ProgressView().tint(.white).controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 42))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 80, height: 80)
            }
            .glassCircle()
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)).frame(width: 60, height: 60) }
                .disabled(!canNext)
                .opacity(canNext ? 1 : 0.4)
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack {
            Button { player.cycleShuffle() } label: {
                Image(systemName: player.smart ? "sparkles" : "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.shuffle ? .white : .white.opacity(0.45))
                    .frame(width: 44, height: 44)
            }
            .disabled(player.onWave)
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
            Spacer()
            Button { showQueue.toggle() } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(showQueue ? .white : .white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.45) : .white)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassCapsule()
    }
}

/// The artwork's colours, blurred, behind the player: sized to the screen and clipped (it never pushes the layout).
struct ArtworkBackground: View {
    var url: String?
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                Cover(url: url, size: max(g.size.width, g.size.height), corner: 0)
                    .frame(width: g.size.width, height: g.size.height)
                    .blur(radius: 60, opaque: true)
                    .saturation(1.5)
                    .opacity(0.75)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

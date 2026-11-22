import AVKit
import SwiftUI

/// The mini player: above the tab bar (on iOS 26 in the tab bar's accessory, like Apple Music).
struct MiniPlayer: View {
    @Environment(Player.self) private var player
    @Environment(AppModel.self) private var app

    var body: some View {
        if let t = player.track {
            HStack(spacing: 12) {
                Cover(url: t.coverSmallUrl ?? t.coverUrl, size: 38, corner: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36)
                }
                .disabled(!player.hasNext && player.repeatMode != .all)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { app.playerOpen = true }
        }
    }

    private func subtitle(_ t: QueueTrack) -> String {
        switch player.phase {
        case .resolving: return "Ищем файл…"
        case .error: return player.error ?? "Не удалось воспроизвести"
        default: return t.artist
        }
    }
}

/// The full player (Apple Music's Now Playing): artwork, title, scrubber, transport, modes, the queue.
struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(Stars.self) private var stars
    @Environment(Wave.self) private var wave
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var dragPosition: Double?

    var body: some View {
        ZStack {
            ArtworkBackground(url: player.track?.coverUrl ?? player.track?.coverSmallUrl)
            if let t = player.track {
                VStack(spacing: 0) {
                    Capsule().fill(.white.opacity(0.4)).frame(width: 38, height: 5).padding(.top, 10)
                    header
                    if showQueue {
                        QueueView().transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        Spacer(minLength: 16)
                        Cover(url: t.coverUrl ?? t.coverSmallUrl, corner: 14)
                            .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
                            .scaleEffect(player.phase == .playing ? 1 : 0.86)
                            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.phase == .playing)
                            .padding(.horizontal, 28)
                        Spacer(minLength: 20)
                    }
                    titleRow(t)
                    if let rec = t.rec { recRow(t, rec) }
                    scrubber.padding(.top, 14)
                    transport.padding(.top, 10)
                    bottomBar.padding(.top, 18).padding(.bottom, 8)
                }
                .padding(.horizontal, 24)
                .foregroundStyle(.white)
            } else {
                ContentUnavailableView("Ничего не играет", systemImage: "music.note")
                    .foregroundStyle(.white)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.smooth, value: showQueue)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40) }
                .glassCircle()
            Spacer()
            VStack(spacing: 1) {
                Text(contextTitle).font(.caption.weight(.semibold)).opacity(0.75).lineLimit(1)
                if player.info?.kind == "preview" { Text("превью 30 сек").font(.caption2).opacity(0.7) }
                else if let p = player.info?.provider, player.info?.kind == "full" {
                    Text([p, player.info?.bitrateKbps.map { "\(Int($0)) кбит/с" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).opacity(0.6)
                }
            }
            Spacer()
            if let t = player.track {
                Menu { TrackMenuItems(track: Track(t), context: player.context, inPlayer: true) } label: {
                    Image(systemName: "ellipsis").font(.headline).frame(width: 40, height: 40)
                }
                .glassCircle()
            }
        }
        .padding(.top, 6)
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.title3.weight(.bold)).lineLimit(1)
                Button {
                    if let a = t.artistRef ?? t.artists?.first(where: { $0.ref != nil })?.ref { Router.shared.go(.catalogArtist(a)) }
                } label: {
                    Text(t.artist).font(.title3).opacity(0.7).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            let liked = stars.isLiked(.track(t))
            Button { Task { await stars.toggle(.track(t), context: player.context) } } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
            .glassCircle()
            .sensoryFeedback(.impact, trigger: liked)
        }
    }

    /// ✨ «Рекомендация на основе …» with «+» and «−» (smart shuffle).
    private func recRow(_ t: QueueTrack, _ rec: QueueTrack.Rec) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
            Text(rec.label).font(.footnote).lineLimit(1)
            Spacer()
            Button { Task { await SmartShuffle.shared.hide(t) } } label: { Image(systemName: "minus").frame(width: 30, height: 30) }
                .glassCircle()
            Button { Task { await SmartShuffle.shared.add(t) } } label: { Image(systemName: "plus").frame(width: 30, height: 30) }
                .glassCircle()
        }
        .padding(.top, 8)
        .opacity(0.9)
    }

    private var scrubber: some View {
        let total = max(player.duration, 1)
        let shown = dragPosition ?? player.position
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { min(shown, total) }, set: { dragPosition = $0 }), in: 0...total) { editing in
                player.scrubbing = editing
                if !editing, let d = dragPosition { player.seek(d); dragPosition = nil }
            }
            .tint(.white)
            HStack {
                Text(Format.time(shown))
                Spacer()
                if player.phase == .resolving || player.phase == .loading { ProgressView().controlSize(.mini).tint(.white) }
                Spacer()
                Text("-" + Format.time(max(0, player.duration - shown)))
            }
            .font(.caption2.monospacedDigit())
            .opacity(0.65)
            if player.phase == .error, let e = player.error {
                Text(e).font(.footnote).foregroundStyle(.yellow).multilineTextAlignment(.center)
            }
        }
    }

    private var transport: some View {
        HStack {
            Spacer()
            Button { player.prev() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 84, height: 84)
            }
            .glassCircle()
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                .disabled(!player.hasNext && player.repeatMode != .all)
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
        .padding(.horizontal, 6)
        .glassCapsule()
    }
}

/// «Далее»: the queue after the current track; drag to reorder, swipe to remove, tap to play.
struct QueueView: View {
    @Environment(Player.self) private var player

    var body: some View {
        List {
            Section {
                let start = player.index + 1
                ForEach(Array(player.upcoming.enumerated()), id: \.element.uid) { offset, t in
                    let i = start + offset
                    HStack(spacing: 12) {
                        Cover(url: t.coverSmallUrl ?? t.coverUrl, size: 42, corner: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if t.rec != nil { Image(systemName: "sparkles").font(.caption) }
                                Text(t.title).lineLimit(1)
                            }
                            Text(t.artist).font(.caption).opacity(0.6).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.playQueue(at: i) }
                    .listRowBackground(Color.clear)
                    .swipeActions { Button(role: .destructive) { player.removeFromQueue(i) } label: { Label("Убрать", systemImage: "trash") } }
                }
                .onMove { from, to in
                    guard let f = from.first else { return }
                    player.moveInQueue(from: start + f, to: start + (to > f ? to - 1 : to))
                }
            } header: {
                HStack {
                    Text(player.onWave ? "Дальше в волне" : "Далее").font(.headline)
                    Spacer()
                    if player.smart { Label("Умное перемешивание", systemImage: "sparkles").font(.caption) }
                }
                .foregroundStyle(.white)
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .foregroundStyle(.white)
    }
}

/// The artwork's colours, blurred, behind the player.
struct ArtworkBackground: View {
    var url: String?
    var body: some View {
        ZStack {
            Color.black
            Cover(url: url, corner: 0)
                .scaledToFill()
                .blur(radius: 70)
                .saturation(1.4)
                .opacity(0.85)
                .scaleEffect(1.6)
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.6)
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

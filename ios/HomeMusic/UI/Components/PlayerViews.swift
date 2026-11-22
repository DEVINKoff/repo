import AVKit
import SwiftUI

/// The mini player: above the tab bar (on iOS 26 in the tab bar's accessory, like Apple Music).
struct MiniPlayer: View {
    @Environment(Player.self) private var player
    @Environment(AppModel.self) private var app

    var body: some View {
        if let t = player.track {
            HStack(spacing: 12) {
                Cover(url: t.coverSmallUrl ?? t.coverUrl, size: 38, corner: 9)
                    .id(t.uid)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .id("title-\(t.uid)")
                .transition(.push(from: .bottom).combined(with: .opacity))
                Spacer(minLength: 0)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.pressable)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36)
                }
                .disabled(!player.hasNext && player.repeatMode != .all)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: t.uid)
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

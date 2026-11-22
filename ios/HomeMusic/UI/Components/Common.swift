import Observation
import SwiftUI

/// An album / playlist tile (Apple Music's square card with two lines under it).
struct AlbumCard: View {
    var title: String
    var subtitle: String?
    var cover: String?
    var width: CGFloat = 160
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Cover(url: cover, size: width, corner: 10, symbol: "square.stack")
                if let badge {
                    Text(badge).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .glassCapsule()
                        .padding(6)
                }
            }
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: width, alignment: .leading)
    }
}

struct ArtistBubble: View {
    var name: String
    var picture: String?
    var size: CGFloat = 110
    var body: some View {
        VStack(spacing: 6) {
            Cover(url: picture, size: size, round: true, symbol: "music.microphone")
            Text(name).font(.footnote.weight(.medium)).lineLimit(1)
        }
        .frame(width: size)
    }
}

/// A row of cards scrolling sideways, under a header (Apple Music's shelves).
struct Shelf<Content: View>: View {
    var title: String
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { action?() } label: {
                HStack(spacing: 4) {
                    Text(title).font(.title2.weight(.bold)).foregroundStyle(.primary)
                    if action != nil { Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary) }
                }
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal)
                    .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// «Слушать» / «Перемешать» under a list's header.
struct PlayShuffleButtons: View {
    var play: () -> Void
    var shuffle: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                Label("Слушать", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
            }
            .glassButton()
            Button(action: shuffle) {
                Label("Перемешать", systemImage: "shuffle").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
            }
            .glassButton()
        }
        .tint(.accentColor)
    }
}

/// The big header of an album / playlist / mix page.
struct ListHeader: View {
    var title: String
    var subtitle: String?
    var detail: String?
    var cover: String?
    var round = false
    var onSubtitle: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Cover(url: cover, size: 250, corner: 12, round: round, symbol: round ? "music.microphone" : "square.stack")
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            if let subtitle {
                Button { onSubtitle?() } label: {
                    Text(subtitle).font(.title3).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(onSubtitle == nil)
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

/// A screen's data: loading, the error with «Повторить», or the content.
struct Loading<T, Content: View>: View {
    var value: T?
    var error: String?
    var retry: () -> Void
    @ViewBuilder var content: (T) -> Content

    var body: some View {
        if let value { content(value) }
        else if let error {
            ContentUnavailableView {
                Label("Не загрузилось", systemImage: "wifi.exclamationmark")
            } description: { Text(error) } actions: {
                Button("Повторить", action: retry).glassButton()
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 80)
        }
    }
}

// MARK: - Toasts

struct ToastOverlay: View {
    @Environment(Toasts.self) private var toasts
    var body: some View {
        VStack {
            if let t = toasts.current {
                HStack(spacing: 10) {
                    Image(systemName: t.kind == .error ? "exclamationmark.triangle.fill" : t.kind == .success ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(t.kind == .error ? .orange : Color.accentColor)
                    Text(t.text).font(.subheadline).lineLimit(3)
                    if let a = t.action {
                        Spacer(minLength: 4)
                        Button(a.label) { a.run(); toasts.dismiss() }.font(.subheadline.weight(.semibold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassRect(20)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { toasts.dismiss() }
                .id(t.id)
            }
            Spacer()
        }
        .padding(.top, 4)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toasts.current?.id)
    }
}

// MARK: - Playlist picker

@MainActor
@Observable
final class PlaylistPicker {
    static let shared = PlaylistPicker()
    struct Request: Identifiable { let id = UUID(); var ndSongId: String?; var ref: String? }
    var request: Request?

    static func present(ndSongId: String?, ref: String?) { shared.request = Request(ndSongId: ndSongId, ref: ref) }
}

struct PlaylistPickerSheet: View {
    let request: PlaylistPicker.Request
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [PlaylistOut]?
    @State private var error: String?
    @State private var newName = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Новый плейлист", text: $newName)
                        Button("Создать") { Task { await pick(nil) } }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                } footer: {
                    if request.ndSongId == nil { Text("Трек скачается в библиотеку и появится в плейлисте") }
                }
                Section("Плейлисты") {
                    if let playlists {
                        ForEach(playlists) { p in
                            Button { Task { await pick(p) } } label: {
                                HStack {
                                    Cover(url: p.coverArt.map { "/api/nd/cover/\($0)?size=120" }, size: 44, corner: 6, symbol: "music.note.list")
                                    VStack(alignment: .leading) {
                                        Text(p.name).foregroundStyle(.primary)
                                        Text(Format.tracks(p.songCount ?? 0)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(busy)
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Добавить в плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .task {
                do { playlists = try await HubClient.shared.playlists() } catch { self.error = error.localizedDescription }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ p: PlaylistOut?) async {
        busy = true
        let name = newName.trimmingCharacters(in: .whitespaces)
        let ok = await Actions.addToPlaylist(ndSongId: request.ndSongId, ref: request.ref, playlist: p, newName: p == nil ? name : nil)
        busy = false
        if ok { dismiss() }
    }
}

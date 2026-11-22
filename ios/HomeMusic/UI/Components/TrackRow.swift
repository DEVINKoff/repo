import SwiftUI

/// A track in a list, the way Apple Music draws it: artwork (or the track number on an album), title, artist,
/// badges for «E», «качается» and the library, the playing bars, a ⋯ menu with the PWA's TrackMenu actions.
struct TrackRow: View {
    let track: Track
    /// the list it belongs to: a tap plays it from this track on
    let list: [Track]
    let context: String
    var origin: String? = nil
    var smartPage: SmartPage? = nil
    var number: Int? = nil
    var order: Int = 0
    var showCover = true
    var withSong = true

    @Environment(Player.self) private var player

    private var isCurrent: Bool { player.track?.ref == track.ref }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    leading
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(track.title).font(.body).lineLimit(1)
                                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            if track.explicit == true { ExplicitBadge() }
                        }
                        HStack(spacing: 4) {
                            status
                            Text(track.artistLine).lineLimit(1)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .animation(.smooth(duration: 0.3), value: isCurrent)
            }
            .buttonStyle(.pressable)
            TrackMenuButton(track: track, context: context)
                .buttonStyle(.borderless)
        }
        .contextMenu { TrackMenuItems(track: track, context: context) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { player.playNext([QueueTrack(track, withSong: withSong)], context: context) } label: {
                Label("Играть следующим", systemImage: "text.line.first.and.arrowtriangle.forward")
            }.tint(.purple)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { player.addToQueue([QueueTrack(track, withSong: withSong)], context: context) } label: {
                Label("В очередь", systemImage: "text.line.last.and.arrowtriangle.forward")
            }.tint(.orange)
        }
        .rowTransition()
        .onAppear { if !track.isOwned { OnScreen.shared.appear(track.ref, order: order) } }
        .onDisappear { OnScreen.shared.disappear(track.ref) }
    }

    @ViewBuilder private var leading: some View {
        if let number {
            ZStack {
                if isCurrent { PlayingBars(active: player.phase == .playing) }
                else { Text("\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .frame(width: 26)
        } else if showCover {
            ZStack {
                Cover(url: track.coverSmallUrl ?? track.coverUrl, size: 48, corner: 10)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.4)).frame(width: 48, height: 48)
                        .transition(.opacity)
                    PlayingBars(active: player.phase == .playing).foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        let dl = player.downloads[track.ref]
        if track.isOwned || dl == "done" {
            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary)
        } else if track.downloading == true || dl == "queued" {
            Image(systemName: "arrow.down.circle.dotted").font(.caption2).foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)
        }
    }

    private func play() {
        OnScreen.shared.touch(track.ref)
        let q = list.map { QueueTrack($0, withSong: withSong) }
        let t = q.first { $0.ref == track.ref } ?? QueueTrack(track, withSong: withSong)
        player.listen(t, in: q, context: context, origin: origin, smartPage: smartPage)
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E").font(.system(size: 9, weight: .bold))
            .foregroundStyle(.background)
            .frame(width: 13, height: 13)
            .background(.secondary, in: RoundedRectangle(cornerRadius: 2.5))
    }
}

/// The playing indicator (Apple Music's equalizer bars).
struct PlayingBars: View {
    var active: Bool
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: active)
    }
}

/// ⋯ of a row.
struct TrackMenuButton: View {
    let track: Track
    let context: String
    var body: some View {
        Menu {
            TrackMenuItems(track: track, context: context)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 40)
                .contentShape(Rectangle())
        }
    }
}

/// What a track's menu offers — the same actions as the PWA's TrackMenu.tsx.
struct TrackMenuItems: View {
    let track: Track
    let context: String
    var inPlayer = false

    @Environment(Player.self) private var player
    @Environment(Stars.self) private var stars
    @Environment(Dislikes.self) private var dislikes
    @State private var picking = false

    var body: some View {
        let liked = stars.isLiked(.track(track))
        let disliked = dislikes.isDisliked(.track(track))
        let artistTarget = track.artistRef.map { DislikeTarget.artist(ref: $0, name: track.artist) }
        let artistDisliked = artistTarget.map { dislikes.isDisliked($0) } ?? false

        Section {
            Button { Task { await stars.toggle(.track(track), context: context) } } label: {
                Label(liked ? "Убрать из понравившихся" : "Нравится", systemImage: liked ? "heart.slash" : "heart")
            }
            if !inPlayer {
                Button { player.playNext([QueueTrack(track)], context: context) } label: {
                    Label("Играть следующим", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { player.addToQueue([QueueTrack(track)], context: context) } label: {
                    Label(player.track == nil ? "Слушать" : "Добавить в очередь", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
        Section {
            if let seed = Wave.trackSeed(ref: track.ref, ndSongId: track.ndSongId) {
                Button {
                    Task { await Wave.shared.start(seed: seed, origin: inPlayer ? "player" : track.ref.hasPrefix("file:") ? "search_file" : "track_menu") }
                } label: { Label("Волна по треку", systemImage: "dot.radiowaves.left.and.right") }
            }
            if let seed = Wave.artistSeed(ref: track.ref, ndSongId: track.ndSongId, artistRef: track.artistRef) {
                Button { Task { await Wave.shared.start(seed: seed, origin: inPlayer ? "player" : "artist_menu") } } label: {
                    Label("Волна по исполнителю", systemImage: "person.wave.2")
                }
            }
        }
        Section {
            if !track.isOwned && player.downloads[track.ref] == nil && track.downloading != true && !track.ref.hasPrefix("nd:") {
                Button { Task { _ = await player.downloadRef(track.ref) } } label: {
                    Label("Скачать в библиотеку", systemImage: "arrow.down.circle")
                }
            }
            if track.ndSongId != nil || !track.ref.isEmpty {
                Button { PlaylistPicker.present(ndSongId: track.isOwned ? track.ndSongId : nil, ref: track.ref) } label: {
                    Label("Добавить в плейлист", systemImage: "text.badge.plus")
                }
            }
            if let album = track.albumRef {
                Button { Router.shared.go(.catalogAlbum(album)) } label: { Label("Перейти к альбому", systemImage: "square.stack") }
            } else if let album = track.ndAlbumId {
                Button { Router.shared.go(.ndAlbum(album)) } label: { Label("Перейти к альбому", systemImage: "square.stack") }
            }
            if let artist = track.artistRef {
                Button { Router.shared.go(.catalogArtist(artist)) } label: { Label("Перейти к исполнителю", systemImage: "music.microphone") }
            } else if let artist = track.ndArtistId {
                Button { Router.shared.go(.ndArtist(artist)) } label: { Label("Перейти к исполнителю", systemImage: "music.microphone") }
            }
        }
        Section {
            Button(role: disliked ? nil : .destructive) { setDisliked(.track(track), !disliked) } label: {
                Label(disliked ? "Убрать «Не нравится»" : "Не нравится", systemImage: "hand.thumbsdown")
            }
            if let artistTarget {
                Button(role: artistDisliked ? nil : .destructive) { setDisliked(artistTarget, !artistDisliked) } label: {
                    Label(artistDisliked ? "Убрать «Не нравится» с исполнителя" : "Не нравится исполнитель", systemImage: "person.slash")
                }
            }
        }
    }

    /// TrackMenu.tsx: a «Не нравится» of the playing track moves on (or stops at the end of the queue).
    private func setDisliked(_ t: DislikeTarget, _ on: Bool) {
        let playing = player.track?.ref == track.ref
        Task {
            if await dislikes.set(t, on: on, context: context), on, playing, !player.next() { player.stop() }
        }
    }
}

/// A queue entry as a `Track` (the player's menu works on the playing track).
extension Track {
    init(_ q: QueueTrack) {
        self.init(ref: q.ref, title: q.title, artist: q.artist)
        artists = q.artists?.map(\.name)
        artistRef = q.artistRef ?? q.artists?.first(where: { $0.ref != nil })?.ref
        albumRef = q.albumRef
        albumTitle = q.album
        durationS = q.durationS
        isrc = q.isrc
        coverUrl = q.coverUrl
        coverSmallUrl = q.coverSmallUrl
        ndSongId = q.ndSongId
        owned = q.ndSongId != nil || q.ref.hasPrefix("nd:")
    }

    /// A Hub library track found by the search (`LibTrackOut`): played by its Navidrome song.
    init(lib t: LibTrackOut) {
        self.init(ref: t.ndSongId.map { "nd:\($0)" } ?? "lib:\(t.id)", title: t.title, artist: t.artist)
        ndSongId = t.ndSongId
        owned = true
        albumTitle = t.album
        durationS = t.durationS
        explicit = t.explicit
        coverSmallUrl = t.ndSongId.map { "/api/nd/cover/mf-\($0)?size=300" }
    }
}

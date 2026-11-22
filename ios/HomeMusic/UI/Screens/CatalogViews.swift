import SwiftUI

struct CatalogAlbumView: View {
    let ref: String
    @Environment(Player.self) private var player
    @State private var album: AlbumOut?
    @State private var error: String?
    @State private var downloading = false

    var body: some View {
        Loading(value: album, error: error, retry: { Task { await load(fresh: true) } }) { a in
            let tracks = a.tracks ?? []
            List {
                Section {
                    VStack(spacing: 16) {
                        ListHeader(title: a.title, subtitle: a.artist,
                                   detail: detail(a), cover: a.coverUrl ?? a.coverSmallUrl,
                                   onSubtitle: a.artistRef.map { r in { Router.shared.go(.catalogArtist(r)) } })
                        PlayShuffleButtons(
                            play: { player.listenAll(tracks.map { QueueTrack($0) }, shuffle: false, context: "album", origin: "album") },
                            shuffle: { player.listenAll(tracks.map { QueueTrack($0) }, shuffle: true, context: "album", origin: "album") })
                        if a.ownedStatus != "full" {
                            Button {
                                downloading = true
                                Task {
                                    if await Actions.startDownload(DownloadIn(albumRef: a.ref)) != nil {
                                        for t in tracks where !t.isOwned { player.markQueued(t.ref) }
                                    }
                                    downloading = false
                                }
                            } label: {
                                Label(a.ownedStatus == "partial" ? "Докачать альбом" : "Скачать альбом", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .glassButton()
                            .disabled(downloading)
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.ref) { i, t in
                        TrackRow(track: t, list: tracks, context: "album", origin: "album", number: t.trackNo ?? (i + 1), order: i, showCover: false)
                    }
                } footer: {
                    if let y = a.releaseDate { Text(y).font(.footnote) }
                }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func detail(_ a: AlbumOut) -> String {
        var parts: [String] = []
        switch a.recordType {
        case "single": parts.append("Сингл")
        case "ep": parts.append("EP")
        case "compile": parts.append("Сборник")
        default: parts.append("Альбом")
        }
        if let y = a.displayYear { parts.append(String(y)) }
        if let g = a.genre { parts.append(g) }
        switch a.ownedStatus {
        case "full": parts.append("в библиотеке")
        case "partial": parts.append("частично в библиотеке")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private func load(fresh: Bool = false) async {
        do { album = try await HubClient.shared.album(ref, fresh: fresh); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct CatalogArtistView: View {
    let ref: String
    @Environment(Player.self) private var player
    @Environment(Dislikes.self) private var dislikes
    @State private var page: ArtistPageOut?
    @State private var error: String?
    @State private var allTop = false
    @State private var kind = 0
    @State private var libraryAlbums: [NdAlbumOut] = []

    var body: some View {
        Loading(value: page, error: error, retry: { Task { await load(fresh: true) } }) { p in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(spacing: 14) {
                        Cover(url: p.artist.pictureUrl ?? p.artist.pictureSmallUrl, size: 200, round: true, symbol: "music.microphone")
                            .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
                        Text(p.artist.name).font(.display(30, .heavy)).multilineTextAlignment(.center)
                        if let fans = p.artist.nbFans, fans > 0 {
                            Text("\(fans.formatted()) слушателей на Deezer").font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button {
                                Task { await Wave.shared.start(seed: WaveSeedIn(artistRef: p.artist.ref), origin: "artist_page") }
                            } label: {
                                Label("Волна", systemImage: "dot.radiowaves.left.and.right").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .prominentButton()
                            Button {
                                player.listenAll(p.topTracks.map { QueueTrack($0) }, shuffle: false, context: "artist", origin: "artist")
                            } label: {
                                Label("Популярное", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .glassButton()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)

                    if !p.topTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionTitle(text: "Популярные треки").padding(.horizontal, 20)
                            let shown = allTop ? p.topTracks : Array(p.topTracks.prefix(5))
                            ForEach(Array(shown.enumerated()), id: \.element.ref) { i, t in
                                TrackRow(track: t, list: p.topTracks, context: "artist", origin: "artist", order: i)
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                Divider().padding(.leading, 76)
                            }
                            if p.topTracks.count > 5 && !allTop {
                                Button("Показать все") { allTop = true }.padding(.horizontal).padding(.top, 4)
                            }
                        }
                    }
                    discography(p)
                }
                .padding(.vertical)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let p = page {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { _ = await Actions.startDownload(DownloadIn(artistRef: p.artist.ref, recordTypes: ["album", "single", "ep"])) } } label: {
                            Label("Скачать всю дискографию", systemImage: "arrow.down.circle")
                        }
                        let target = DislikeTarget.artist(ref: p.artist.ref, name: p.artist.name)
                        let on = dislikes.isDisliked(target)
                        Button(role: on ? nil : .destructive) { Task { await dislikes.set(target, on: !on, context: "artist") } } label: {
                            Label(on ? "Убрать «Не нравится»" : "Не нравится исполнитель", systemImage: "hand.thumbsdown")
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .task { await load() }
    }

    /// A tile of the discography: a catalog release, or an album of the user's own library the catalog lacks.
    private struct Release: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let cover: String?
        let dest: Dest
        let badge: String?
    }

    private func release(_ a: AlbumOut) -> Release {
        Release(id: a.ref, title: a.title,
                subtitle: [a.displayYear.map(String.init), kindTitle(a.recordType)].compactMap { $0 }.joined(separator: " · "),
                cover: a.coverSmallUrl ?? a.coverUrl, dest: .catalogAlbum(a.ref),
                badge: a.ownedStatus == "full" ? "в библиотеке" : a.ownedStatus == "partial" ? "частично" : nil)
    }

    private func release(_ a: NdAlbumOut) -> Release {
        Release(id: "nd:" + a.id, title: a.title, subtitle: [a.year.map(String.init), "из библиотеки"].compactMap { $0 }.joined(separator: " · "),
                cover: a.coverUrl, dest: .ndAlbum(a.id), badge: "в библиотеке")
    }

    private func byDate(_ list: [AlbumOut]) -> [AlbumOut] { list.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") } }

    /// Every release the catalog has for the artist (albums first, then singles and EPs, then compilations), plus the
    /// albums of the user's library that the catalog lacks, with a filter by kind.
    @ViewBuilder private func discography(_ p: ArtistPageOut) -> some View {
        let albums = byDate(p.albums).map { release($0) } + libraryAlbums.map { release($0) }
        let singles = byDate(p.singles).map { release($0) }
        let comps = byDate(p.compilations).map { release($0) }
        let shown: [Release] = kind == 1 ? albums : kind == 2 ? singles : kind == 3 ? comps : albums + singles + comps
        let total = albums.count + singles.count + comps.count
        if total > 0 {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Дискография · \(total)")
                Picker("", selection: $kind.animation(Theme.spring)) {
                    Text("Все").tag(0)
                    if !albums.isEmpty { Text("Альбомы · \(albums.count)").tag(1) }
                    if !singles.isEmpty { Text("Синглы · \(singles.count)").tag(2) }
                    if !comps.isEmpty { Text("Сборники").tag(3) }
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(shown) { r in
                        NavigationLink(value: r.dest) {
                            AlbumCard(title: r.title, subtitle: r.subtitle, cover: r.cover, width: 160, badge: r.badge)
                        }
                        .buttonStyle(.pressable)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// The user's library albums of this artist (any spelling) that the catalog doesn't list.
    private func loadLibraryAlbums(_ p: ArtistPageOut) async {
        let who = Norm.key(p.artist.name)
        guard !who.isEmpty, let artists = try? await HubClient.shared.ndArtists() else { return }
        let known = Set((p.albums + p.singles + p.compilations).map { Norm.key($0.title) })
        var found: [NdAlbumOut] = []
        for a in artists where Norm.key(a.name) == who {
            guard let page = try? await HubClient.shared.ndArtist(a.id) else { continue }
            for al in page.albums where !known.contains(Norm.key(al.title)) && !found.contains(where: { Norm.key($0.title) == Norm.key(al.title) }) {
                found.append(al)
            }
        }
        withAnimation(Theme.spring) { libraryAlbums = found }
    }

    private func kindTitle(_ t: String?) -> String? {
        switch t {
        case "single": return "сингл"
        case "ep": return "EP"
        case "compile": return "сборник"
        default: return nil
        }
    }

    private func load(fresh: Bool = false) async {
        do {
            let p = try await HubClient.shared.artist(ref, fresh: fresh)
            page = p
            error = nil
            await loadLibraryAlbums(p)
        } catch { self.error = error.localizedDescription }
    }
}

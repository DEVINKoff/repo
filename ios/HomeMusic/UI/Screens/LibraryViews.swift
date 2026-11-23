import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @State private var recent: [Track] = []
    @State private var appeared = false

    var body: some View {
        List {
            HStack {
                Text("Библиотека").font(.display(28, .heavy))
                Spacer()
                AccountButton()
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            Section {
                row("Понравившиеся", "heart", .liked)
                row("Плейлисты", "music.note.list", .playlists)
                row("Альбомы", "square.stack", .ndAlbums)
                row("Исполнители", "music.microphone", .ndArtists)
                row("Загрузки", "arrow.down.circle", .downloads, badge: downloads.activeCount)
            }
            if !recent.isEmpty {
                Section {
                    // what you added yourself, newest first (not the mixes' own downloads, not files already there)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(Array(recent.enumerated()), id: \.element.ref) { i, t in
                                NewSongCard(track: t, list: recent, order: i)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 18)
                                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(min(0.4, Double(i) * 0.04)), value: appeared)
                                    .scrollTransition(.animated(.smooth(duration: 0.35)), axis: .horizontal) { c, phase in
                                        c.scaleEffect(phase.isIdentity ? 1 : 0.88).opacity(phase.isIdentity ? 1 : 0.5)
                                            .rotation3DEffect(.degrees(phase.value * -12), axis: (x: 0, y: 1, z: 0))
                                    }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 20)
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                    .listRowSeparator(.hidden)
                } header: {
                    SectionTitle(text: "Новое").textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: library.generation) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let r = try? await HubClient.shared.ndNew(limit: 40) {
            withAnimation(Theme.spring) { recent = r }
            if !appeared { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { appeared = true } }
        }
    }

    private func row(_ title: String, _ icon: String, _ d: Dest, badge: Int = 0) -> some View {
        NavigationLink(value: d) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                Text(title).font(.body.weight(.medium))
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accentFill, in: Capsule())
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 8)
            .animation(Theme.spring, value: badge)
        }
    }
}

struct LikedView: View {
    enum Part: String, CaseIterable { case songs = "Песни", albums = "Альбомы", artists = "Исполнители" }
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(Stars.self) private var stars
    @State private var liked: NdLikedOut?
    @State private var error: String?
    @State private var part: Part = .songs
    @AppStorage("liked.sort") private var sort: LikedSort = .added
    /// only the songs whose album has an animated cover on Apple Music
    @State private var onlyLive = false
    @State private var live: Set<String> = []
    @State private var checked = 0
    @State private var toCheck = 0
    @State private var unreachable = 0

    private let page = SmartPage(context: "liked", title: nil)

    private func shown(_ songs: [Track]) -> [Track] {
        var list: [Track]
        switch sort {
        case .added: list = songs
        case .oldest: list = songs.reversed()
        case .title: list = songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            list = songs.sorted {
                let c = $0.artistLine.localizedStandardCompare($1.artistLine)
                return c == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : c == .orderedAscending
            }
        case .album: list = songs.sorted { ($0.albumTitle ?? "").localizedStandardCompare($1.albumTitle ?? "") == .orderedAscending }
        case .year: list = songs.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .length: list = songs.sorted { ($0.durationS ?? 0) < ($1.durationS ?? 0) }
        }
        if onlyLive { list = list.filter { live.contains(MotionCovers.key(QueueTrack($0))) } }
        return list
    }

    /// Asks the Hub which albums of the liked songs have an animated cover (once per album, a few at a time).
    private func checkLive(_ songs: [Track]) async {
        var byKey: [String: QueueTrack] = [:]
        for t in songs { let q = QueueTrack(t); byKey[MotionCovers.key(q)] = byKey[MotionCovers.key(q)] ?? q }
        // what the phone already knows shows at once
        for (k, q) in byKey where MotionCovers.cached(q) != nil { live.insert(k) }
        let todo = Array(byKey.values)
        toCheck = todo.count
        checked = 0
        unreachable = 0
        await withTaskGroup(of: (String, String).self) { group in
            var next = 0
            func add() {
                guard next < todo.count else { return }
                let q = todo[next]
                next += 1
                group.addTask { (await MotionCovers.key(q), await MotionCovers.lookup(q).status) }
            }
            for _ in 0..<3 { add() }
            for await (key, status) in group {
                checked += 1
                if status == "found" { withAnimation(.smooth) { _ = live.insert(key) } }
                if status == "apple_unreachable" { unreachable += 1 }
                if Task.isCancelled { group.cancelAll(); return }
                add()
            }
        }
    }

    var body: some View {
        Loading(value: liked, error: error, retry: { Task { await load() } }) { l in
            List {
                switch part {
                case .songs:
                    let songs = shown(l.songs)
                    header(songs, total: l.songs.count)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    if l.songs.isEmpty {
                        ContentUnavailableView("Пока пусто", systemImage: "heart", description: Text("Отмечайте песни ♥ — они появятся здесь"))
                    } else if onlyLive && songs.isEmpty && checked >= toCheck {
                        if unreachable >= checked && checked > 0 {
                            ContentUnavailableView("Apple Music недоступен", systemImage: "wifi.exclamationmark",
                                                   description: Text("Хаб не смог связаться с music.apple.com — живые обложки берутся оттуда. Проверьте интернет или VPN на компьютере с Хабом."))
                        } else {
                            ContentUnavailableView("Нет живых обложек", systemImage: "livephoto.slash",
                                                   description: Text("Ни у одного альбома понравившихся песен нет анимированной обложки в Apple Music"))
                        }
                    }
                    ForEach(Array(songs.enumerated()), id: \.element.ref) { i, t in
                        TrackRow(track: t, list: songs, context: "liked", origin: "liked", smartPage: page, order: i)
                    }
                case .albums:
                    ForEach(l.albums) { a in
                        NavigationLink(value: Dest.ndAlbum(a.id)) { albumLine(a) }
                    }
                case .artists:
                    ForEach(l.artists) { a in
                        NavigationLink(value: Dest.ndArtist(a.id)) {
                            HStack(spacing: 12) {
                                Cover(url: a.coverUrl, size: 50, round: true, symbol: "music.microphone")
                                Text(a.name)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(part == .songs ? "Понравившиеся" : part.rawValue)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        .animation(.smooth(duration: 0.35), value: sort)
        .animation(.smooth(duration: 0.35), value: onlyLive)
        .animation(.smooth(duration: 0.35), value: part)
        .task(id: onlyLive) { if onlyLive, let l = liked { await checkLive(l.songs) } }
        .task(id: library.generation) { await load() }
        .onChange(of: stars.version) { Task { try? await Task.sleep(for: .seconds(1.5)); await load() } }
        .refreshable { await load() }
    }

    /// One row over the songs: ▶ «Слушать», shuffle, and what is shown (count, sort, the live-covers filter).
    private func header(_ songs: [Track], total: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                Haptics.press()
                player.listenAll(songs.map { QueueTrack($0) }, shuffle: false, context: "liked", origin: "liked", smartPage: page)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Слушать")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Theme.accentFill, in: Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(songs.isEmpty)
            Button {
                Haptics.press()
                player.listenAll(songs.map { QueueTrack($0) }, shuffle: true, context: "liked", origin: "liked", smartPage: page)
            } label: {
                Image(systemName: "shuffle").font(.subheadline.weight(.semibold)).frame(width: 38, height: 38)
            }
            .buttonStyle(.pressable)
            .glassCircle()
            .disabled(songs.isEmpty)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(onlyLive ? "\(songs.count) с живыми обложками" : Format.tracks(total))
                    .font(.footnote.weight(.semibold))
                    .contentTransition(.numericText())
                Text(onlyLive && checked < toCheck ? "проверено \(checked) из \(toCheck)" : sort.title.lowercased())
                    .font(.caption2).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
        }
    }

    /// The screen's options in one menu: the part, the sort, the live-covers filter.
    private var optionsMenu: some View {
        Menu {
            Picker("Раздел", selection: $part) {
                ForEach(Part.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if part == .songs {
                Section("Сортировка") {
                    Picker("Сортировка", selection: $sort) {
                        ForEach(LikedSort.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                }
                Section {
                    Toggle(isOn: $onlyLive) { Label("Только живые обложки", systemImage: "livephoto") }
                }
            }
        } label: {
            Image(systemName: onlyLive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .symbolEffect(.bounce, value: onlyLive)
        }
    }

    private func load() async {
        do { liked = try await HubClient.shared.ndLiked(); error = nil } catch { self.error = error.localizedDescription }
    }

}

enum LikedSort: String, CaseIterable, Identifiable {
    case added, oldest, title, artist, album, year, length
    var id: String { rawValue }
    var title: String {
        switch self {
        case .added: "Недавно добавленные"
        case .oldest: "Сначала старые"
        case .title: "По названию"
        case .artist: "По исполнителю"
        case .album: "По альбому"
        case .year: "По году"
        case .length: "По длительности"
        }
    }
    var icon: String {
        switch self {
        case .added: "clock"
        case .oldest: "clock.arrow.circlepath"
        case .title: "textformat"
        case .artist: "music.microphone"
        case .album: "square.stack"
        case .year: "calendar"
        case .length: "timer"
        }
    }
}

func albumLine(_ a: NdAlbumOut) -> some View {
    HStack(spacing: 12) {
        Cover(url: a.coverUrl, size: 56, corner: 6, symbol: "square.stack")
        VStack(alignment: .leading, spacing: 2) {
            Text(a.title).lineLimit(1)
            Text([a.artist, a.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct PlaylistsView: View {
    @State private var playlists: [PlaylistOut]?
    @State private var error: String?
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        Loading(value: playlists, error: error, retry: { Task { await load() } }) { list in
            List {
                ForEach(list) { p in
                    NavigationLink(value: Dest.playlist(id: p.id, name: p.name)) {
                        HStack(spacing: 12) {
                            Cover(url: p.coverArt.map { "/api/nd/cover/\($0)?size=200" }, size: 56, corner: 6, symbol: "music.note.list")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).lineLimit(1)
                                Text(Format.tracks(p.songCount ?? 0)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                do { _ = try await HubClient.shared.deletePlaylist(p.id); await load() } catch { Toasts.error(error) }
                            }
                        } label: { Label("Удалить", systemImage: "trash") }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if list.isEmpty { ContentUnavailableView("Нет плейлистов", systemImage: "music.note.list") } }
        }
        .navigationTitle("Плейлисты")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") } } }
        .alert("Новый плейлист", isPresented: $creating) {
            TextField("Название", text: $newName)
            Button("Создать") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                guard !name.isEmpty else { return }
                Task { do { _ = try await HubClient.shared.createPlaylist(name); await load() } catch { Toasts.error(error) } }
            }
            Button("Отмена", role: .cancel) { newName = "" }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { playlists = try await HubClient.shared.playlists(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct PlaylistView: View {
    let id: String
    var name: String?
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var page: PlaylistPageOut?
    @State private var error: String?

    var body: some View {
        Loading(value: page, error: error, retry: { Task { await load() } }) { p in
            let smart = SmartPage(context: "playlist:\(p.id)", title: p.name)
            List {
                Section {
                    VStack(spacing: 16) {
                        ListHeader(title: p.name, subtitle: nil,
                                   detail: [Format.tracks(p.tracks.count), Format.duration(p.durationS)].filter { !$0.isEmpty }.joined(separator: " · "),
                                   cover: p.coverArt.map { "/api/nd/cover/\($0)?size=600" })
                        PlayShuffleButtons(
                            play: { player.listenAll(p.tracks.map { QueueTrack($0) }, shuffle: false, context: "playlist", origin: "playlist", smartPage: smart) },
                            shuffle: { player.listenAll(p.tracks.map { QueueTrack($0) }, shuffle: true, context: "playlist", origin: "playlist", smartPage: smart) })
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(Array(p.tracks.enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t, list: p.tracks, context: "playlist", origin: "playlist", smartPage: smart, order: i)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task {
                                        do { _ = try await HubClient.shared.removeFromPlaylist(p.id, indexes: [i]); await load() } catch { Toasts.error(error) }
                                    }
                                } label: { Label("Убрать", systemImage: "minus.circle") }
                            }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(page?.name ?? name ?? "Плейлист")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library.generation) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { page = try await HubClient.shared.playlist(id); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct NdAlbumsView: View {
    @State private var sort = "alphabeticalByName"
    @State private var albums: [NdAlbumOut] = []
    @State private var done = false
    @State private var loading = false

    private let sorts: [(String, String)] = [("alphabeticalByName", "По названию"), ("alphabeticalByArtist", "По исполнителю"),
                                             ("newest", "Недавно добавленные"), ("recent", "Недавно игравшие"),
                                             ("frequent", "Часто слушаете"), ("starred", "Понравившиеся"), ("random", "Случайно")]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(albums) { a in
                    NavigationLink(value: Dest.ndAlbum(a.id)) {
                        AlbumCard(title: a.title, subtitle: a.artist, cover: a.coverUrl, width: 165)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if a.id == albums.last?.id { Task { await more() } } }
                }
            }
            .padding()
            if loading { ProgressView().padding() }
        }
        .navigationTitle("Альбомы")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Сортировка", selection: $sort) { ForEach(sorts, id: \.0) { Text($0.1).tag($0.0) } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .task(id: sort) {
            albums = []
            done = false
            await more()
        }
    }

    private func more() async {
        guard !loading, !done else { return }
        loading = true
        defer { loading = false }
        guard let page = try? await HubClient.shared.ndAlbums(type: sort, offset: albums.count, size: 60) else { return }
        if page.isEmpty || sort == "random" { done = true }
        let known = Set(albums.map(\.id))
        albums += page.filter { !known.contains($0.id) }
    }
}

struct NdAlbumView: View {
    let id: String
    @Environment(Player.self) private var player
    @Environment(Stars.self) private var stars
    @State private var album: NdAlbumOut?
    @State private var error: String?

    var body: some View {
        Loading(value: album, error: error, retry: { Task { await load() } }) { a in
            let tracks = a.tracks ?? []
            List {
                Section {
                    VStack(spacing: 16) {
                        ListHeader(title: a.title, subtitle: a.artist,
                                   detail: [a.year.map(String.init), Format.tracks(tracks.count), Format.duration(a.durationS)]
                                       .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                   cover: a.coverUrl?.replacingOccurrences(of: "size=300", with: "size=800"),
                                   onSubtitle: a.artistId.map { aid in { Router.shared.go(.ndArtist(aid)) } })
                        PlayShuffleButtons(
                            play: { player.listenAll(tracks.map { QueueTrack($0) }, shuffle: false, context: "album", origin: "album") },
                            shuffle: { player.listenAll(tracks.map { QueueTrack($0) }, shuffle: true, context: "album", origin: "album") })
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.ref) { i, t in
                        TrackRow(track: t, list: tracks, context: "album", origin: "album", number: t.trackNo ?? (i + 1), order: i, showCover: false)
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let a = album {
                ToolbarItem(placement: .topBarTrailing) {
                    let target = LikeTarget.album(nd: a.id, title: a.title, artist: a.artist)
                    let liked = stars.isLiked(target)
                    Button { Task { await stars.toggle(target, context: "album") } } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { album = try await HubClient.shared.ndAlbum(id); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct NdArtistsView: View {
    @State private var artists: [NdArtistOut]?
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        Loading(value: artists, error: error, retry: { Task { await load() } }) { list in
            let shown = query.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(query) }
            List(shown) { a in
                NavigationLink(value: Dest.ndArtist(a.id)) {
                    HStack(spacing: 12) {
                        Cover(url: a.coverUrl, size: 48, round: true, symbol: "music.microphone")
                        VStack(alignment: .leading) {
                            Text(a.name)
                            if let n = a.albumCount { Text("\(n) \(Format.plural(n, "альбом", "альбома", "альбомов"))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Исполнители")
        .searchable(text: $query, prompt: "Найти в библиотеке")
        .task { await load() }
    }

    private func load() async {
        do { artists = try await HubClient.shared.ndArtists(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct NdArtistView: View {
    let id: String
    @Environment(Stars.self) private var stars
    @State private var page: NdArtistPageOut?
    @State private var error: String?

    var body: some View {
        Loading(value: page, error: error, retry: { Task { await load() } }) { p in
            ScrollView {
                VStack(spacing: 18) {
                    Cover(url: p.artist.coverUrl, size: 190, round: true, symbol: "music.microphone")
                    Text(p.artist.name).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                    Button {
                        Task { await Wave.shared.start(seed: WaveSeedIn(ndArtistId: p.artist.id), origin: "radio") }
                    } label: {
                        Label("Радиостанция", systemImage: "dot.radiowaves.left.and.right").font(.headline).frame(maxWidth: 260, minHeight: 34)
                    }
                    .prominentButton()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(p.albums) { a in
                            NavigationLink(value: Dest.ndAlbum(a.id)) {
                                AlbumCard(title: a.title, subtitle: a.year.map(String.init), cover: a.coverUrl, width: 165)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let p = page {
                ToolbarItem(placement: .topBarTrailing) {
                    let target = LikeTarget.artist(nd: p.artist.id, name: p.artist.name)
                    Button { Task { await stars.toggle(target, context: "artist") } } label: {
                        Image(systemName: stars.isLiked(target) ? "heart.fill" : "heart")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { page = try await HubClient.shared.ndArtist(id); error = nil } catch { self.error = error.localizedDescription }
    }
}

/// «Микс дня»: 50 songs, the familiar ones and the new, with where each came from.
struct MixView: View {
    let id: Int
    @Environment(Player.self) private var player
    @State private var mix: MixOut?
    @State private var error: String?

    var body: some View {
        Loading(value: mix, error: error, retry: { Task { await load() } }) { m in
            List {
                Section {
                    VStack(spacing: 14) {
                        MixCollage(tracks: m.tracks).frame(width: 230, height: 230).shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                        Text(m.title).font(.title2.weight(.bold))
                        if let d = m.description, !d.isEmpty { Text(d).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                        if let mode = m.modeTitle { Text(mode).font(.caption).foregroundStyle(.secondary) }
                        PlayShuffleButtons(
                            play: { player.listenAll(m.tracks.map { QueueTrack($0) }, shuffle: false, context: "mix:\(m.id)", origin: "mix_page") },
                            shuffle: { player.listenAll(m.tracks.map { QueueTrack($0) }, shuffle: true, context: "mix:\(m.id)", origin: "mix_page") })
                    }
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(Array(m.tracks.enumerated()), id: \.element.ref) { i, t in
                        VStack(alignment: .leading, spacing: 2) {
                            TrackRow(track: t, list: m.tracks, context: "mix:\(m.id)", order: i)
                            if let g = t.generatorTitle {
                                Text((t.familiar == true ? "знакомое · " : "новое · ") + g)
                                    .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { mix = try await HubClient.shared.mix(id); error = nil } catch { self.error = error.localizedDescription }
    }
}


/// A song in «Новое»: its cover, a tap plays it (and the rest of «Новое» after it); the menu is the track's.
struct NewSongCard: View {
    let track: Track
    let list: [Track]
    var order = 0
    @Environment(Player.self) private var player

    var body: some View {
        let playing = player.track?.ref == track.ref
        Button {
            Haptics.tap()
            let q = list.map { QueueTrack($0) }
            player.listen(QueueTrack(track), in: q, context: "library_new", origin: "library")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Cover(url: track.coverUrl ?? track.coverSmallUrl, size: 140, corner: 14)
                        .shadow(color: .black.opacity(playing ? 0.3 : 0.12), radius: playing ? 14 : 6, y: playing ? 8 : 3)
                    if playing {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .font(.footnote.weight(.bold))
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 30, height: 30)
                            .background(Theme.accent, in: Circle())
                            .padding(8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(playing ? Theme.accent : .primary)
                Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: playing)
        }
        .buttonStyle(.pressable)
        .contextMenu { TrackMenuItems(track: track, context: "library_new") }
    }
}

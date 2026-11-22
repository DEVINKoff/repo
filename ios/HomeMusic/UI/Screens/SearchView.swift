import Combine
import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable { case catalog = "Каталог", files = "Файлы" }

    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var scope: Scope = .catalog
    @State private var history: [String] = []
    @State private var showAllHistory = false
    @State private var result: SearchOut?
    @State private var tracks: [Track] = []
    @State private var next: Int?
    @State private var loadingMore = false
    @State private var moreFailed = false
    @State private var error: String?
    @State private var searching = false
    @State private var sources: [Candidate]?
    @State private var reuploads: [Candidate]?

    private var q: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            if q.count < 2 {
                historySection
            } else {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                if scope == .catalog { catalog } else { files }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Поиск")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Артисты, альбомы, треки")
        .autocorrectionDisabled()
        .task(id: q) { await search() }
        .task(id: "\(q)|\(scope.rawValue)") { if scope == .files { await searchFiles() } }
        .task { await loadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: .searchHistoryChanged)) { _ in Task { await loadHistory() } }
    }

    // MARK: History

    @ViewBuilder private var historySection: some View {
        if !history.isEmpty {
            Section {
                ForEach(showAllHistory ? history : Array(history.prefix(8)), id: \.self) { h in
                    Button { query = h } label: {
                        Label(h, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                    }
                }
                if history.count > 8 && !showAllHistory {
                    Button("Показать ещё") { showAllHistory = true }
                }
            } header: {
                HStack {
                    Text("Недавние запросы")
                    Spacer()
                    Button("Очистить") {
                        Task {
                            _ = try? await HubClient.shared.clearSearchHistory()
                            history = []
                        }
                    }
                    .font(.subheadline)
                }
            }
        } else {
            ContentUnavailableView("Ищите что угодно", systemImage: "magnifyingglass",
                                   description: Text("Песни из вашей библиотеки и всего каталога: послушать сразу или скачать к себе."))
                .listRowSeparator(.hidden)
        }
    }

    private func loadHistory() async {
        if let h = try? await HubClient.shared.searchHistory() { history = h.queries }
    }

    // MARK: Catalog

    @ViewBuilder private var catalog: some View {
        if let r = result {
            if !r.library.isEmpty {
                Section("В библиотеке") {
                    let lib = r.library.map { Track(lib: $0) }
                    ForEach(Array(lib.enumerated()), id: \.element.ref) { i, t in
                        TrackRow(track: t, list: lib, context: "search", origin: "search", order: i)
                    }
                }
            }
            if !r.artists.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(r.artists.enumerated()), id: \.offset) { _, a in
                                NavigationLink(value: Dest.catalogArtist(a.ref)) {
                                    ArtistBubble(name: a.name, picture: a.pictureSmallUrl ?? a.pictureUrl, size: 96)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                } header: { Text("Исполнители") }
            }
            if !r.albums.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(r.albums.enumerated()), id: \.offset) { _, a in
                                NavigationLink(value: Dest.catalogAlbum(a.ref)) {
                                    AlbumCard(title: a.title, subtitle: [a.artist, a.displayYear.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                              cover: a.coverSmallUrl ?? a.coverUrl, width: 140, badge: ownedBadge(a.ownedStatus))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                } header: { Text("Альбомы") }
            }
            if !tracks.isEmpty {
                Section("Треки") {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t, list: tracks, context: "search", origin: "search", order: 1000 + i)
                            // the next page is asked for a few rows before the end (search.tsx MORE_AT)
                            .onAppear { if i >= tracks.count - 6 { Task { await more() } } }
                    }
                    if loadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if next != nil {
                        Button(moreFailed ? "Не загрузилось — повторить" : "Показать ещё") { Task { await more() } }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if r.library.isEmpty && r.artists.isEmpty && r.albums.isEmpty && tracks.isEmpty {
                ContentUnavailableView.search(text: q)
            }
            if let errors = r.errors, !errors.isEmpty {
                Text(errors.joined(separator: "\n")).font(.footnote).foregroundStyle(.secondary)
            }
        } else if let error {
            Text(error).foregroundStyle(.secondary)
        } else if searching {
            ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
        }
    }

    private func ownedBadge(_ s: String?) -> String? {
        switch s {
        case "full": return "в библиотеке"
        case "partial": return "частично"
        default: return nil
        }
    }

    private func search() async {
        let query = q
        guard query.count >= 2 else { result = nil; tracks = []; return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let r = try await HubClient.shared.search(query)
            guard !Task.isCancelled else { return }
            result = r
            var seen = Set<String>()
            tracks = r.tracks.filter { seen.insert($0.ref).inserted }
            next = r.tracksNext
            moreFailed = false
            error = nil
            // the account's recent queries (debounced, independent of the result)
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled, query == q { _ = try? await HubClient.shared.rememberSearch(query) }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription; result = nil }
        }
    }

    private func more() async {
        guard let offset = next, !loadingMore else { return }
        let query = q
        loadingMore = true
        defer { loadingMore = false }
        guard let r = try? await HubClient.shared.searchTracks(query, offset: offset) else { moreFailed = true; return }
        guard query == q else { return }
        moreFailed = false
        let known = Set(tracks.map(\.ref))
        tracks += r.tracks.filter { !known.contains($0.ref) } // a page may repeat a track of an earlier page
        next = r.nextOffset
        player.extendQueue(tracks.map { QueueTrack($0) })
    }

    // MARK: Files (provider search)

    @ViewBuilder private var files: some View {
        Section {
            if let sources {
                if sources.isEmpty { Text("Ничего не нашлось").foregroundStyle(.secondary) }
                ForEach(Array(sources.enumerated()), id: \.element.id) { i, c in FileRow(file: c, list: sources, order: i) }
            } else { ProgressView().frame(maxWidth: .infinity) }
        } header: { Text("Источники") }
        Section {
            if let reuploads {
                if reuploads.isEmpty { Text("Перезаливов не нашлось").foregroundStyle(.secondary) }
                ForEach(Array(reuploads.enumerated()), id: \.element.id) { i, c in FileRow(file: c, list: reuploads, order: 500 + i) }
            } else {
                HStack { ProgressView(); Text("SoundCloud и YouTube отвечают дольше…").font(.footnote).foregroundStyle(.secondary) }
            }
        } header: { Text("Перезаливы") } footer: {
            Text("Файлы небольших каналов: часто это версии без цензуры.")
        }
    }

    private func searchFiles() async {
        let query = q
        guard query.count >= 2 else { return }
        sources = nil
        reuploads = nil
        async let s = try? HubClient.shared.searchProviders(query, group: "sources")
        async let r = try? HubClient.shared.searchProviders(query, group: "reuploads")
        let a = await s
        if query == q { sources = a?.candidates ?? [] }
        let b = await r
        if query == q { reuploads = b?.candidates ?? [] }
    }
}

/// A provider's file: listen to it as is, start a wave from it, or download exactly this file.
struct FileRow: View {
    let file: Candidate
    let list: [Candidate]
    var order = 0
    @Environment(Player.self) private var player

    private func queueTrack(_ c: Candidate) -> QueueTrack? {
        guard let ref = c.fileRef else { return nil }
        return QueueTrack(ref: ref, title: c.title ?? "Без названия", artist: c.artist ?? "", coverUrl: c.coverUrl, album: c.album, durationS: c.durationS)
    }

    var body: some View {
        Button {
            guard let t = queueTrack(file) else { return }
            OnScreen.shared.touch(t.ref)
            player.listen(t, in: list.compactMap(queueTrack), context: "search", origin: "search")
        } label: {
            HStack(spacing: 12) {
                Cover(url: file.coverUrl, size: 44, corner: 6, symbol: "waveform")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(file.title ?? "Без названия").lineLimit(1)
                            .foregroundStyle(player.track?.ref == file.fileRef ? Color.accentColor : .primary)
                        if file.explicit == true { ExplicitBadge() }
                    }
                    Text(file.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Tag(text: providerName(file.provider))
                        if let b = file.bitrateKbps { Tag(text: "\(Int(b)) кбит/с") }
                        if let d = file.durationS { Tag(text: Format.time(d)) }
                        if file.uncensored == true { Tag(text: "без цензуры", tint: .green) }
                        if file.uncensored == false { Tag(text: "без мата", tint: .orange) }
                        if let ch = file.channel { Text(ch).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .onAppear { if let r = file.fileRef { OnScreen.shared.appear(r, order: order) } }
        .onDisappear { if let r = file.fileRef { OnScreen.shared.disappear(r) } }
        .contextMenu { menu }
        .swipeActions { Button { download() } label: { Label("Скачать", systemImage: "arrow.down.circle") }.tint(.accentColor) }
    }

    @ViewBuilder private var menu: some View {
        Button { download() } label: { Label("Скачать этот файл", systemImage: "arrow.down.circle") }
        if let t = queueTrack(file) {
            Button { player.playNext([t], context: "search") } label: { Label("Играть следующим", systemImage: "text.line.first.and.arrowtriangle.forward") }
            if let seed = Wave.trackSeed(ref: t.ref, ndSongId: nil) {
                Button { Task { await Wave.shared.start(seed: seed, origin: "search_file") } } label: { Label("Волна по треку", systemImage: "dot.radiowaves.left.and.right") }
            }
        }
        if let page = file.pageUrl, let url = URL(string: page) {
            Link(destination: url) { Label("Открыть страницу источника", systemImage: "safari") }
        }
    }

    private func download() {
        guard let ref = file.fileRef else { return }
        Task { if await Actions.startDownload(DownloadIn(trackRefs: [ref])) != nil { player.markQueued(ref) } }
    }

}

struct Tag: View {
    var text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A source's name as the app shows it.
func providerName(_ p: String) -> String {
    switch p {
    case "hitmoz": "hitmoz"
    case "hitmos_fm": "hitmos.fm"
    case "ytdlp": "YouTube Music"
    case "yt_reupload": "YouTube"
    case "soundcloud": "SoundCloud"
    case "soulseek": "Soulseek"
    default: p
    }
}

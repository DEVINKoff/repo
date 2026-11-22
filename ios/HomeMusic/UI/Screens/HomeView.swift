import SwiftUI

struct HomeView: View {
    @Environment(Wave.self) private var wave
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var mix: MixTodayOut?
    @State private var home: NdHomeOut?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                WaveHero()
                    .padding(.horizontal)
                mixCard.padding(.horizontal)
                if let home {
                    shelf("Недавно играли", home.recent)
                    shelf("Новое в библиотеке", home.newest)
                    shelf("Часто слушаете", home.frequent)
                    shelf("Любимые альбомы", home.starred)
                    if !home.radio.isEmpty {
                        Shelf(title: "Радиостанции") {
                            ForEach(home.radio) { a in
                                Button {
                                    Task { await wave.start(seed: WaveSeedIn(ndArtistId: a.id), origin: "radio") }
                                } label: {
                                    ZStack(alignment: .bottomTrailing) {
                                        ArtistBubble(name: a.name, picture: a.coverUrl, size: 120)
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .font(.caption.weight(.bold))
                                            .frame(width: 30, height: 30)
                                            .glassCircle(interactive: false)
                                            .offset(x: -4, y: -28)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { Router.shared.go(.ndArtist(a.id)) } label: { Label("Открыть исполнителя", systemImage: "music.microphone") }
                                }
                            }
                        }
                    }
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Главная")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
        .refreshable { await load() }
        .task(id: library.generation) { await load() }
    }

    private func load() async {
        async let m = try? HubClient.shared.mixToday()
        do { home = try await HubClient.shared.ndHome(); error = nil } catch { self.error = error.localizedDescription }
        mix = await m
    }

    @ViewBuilder private func shelf(_ title: String, _ albums: [NdAlbumOut]) -> some View {
        if !albums.isEmpty {
            Shelf(title: title) {
                ForEach(albums) { a in
                    NavigationLink(value: Dest.ndAlbum(a.id)) {
                        AlbumCard(title: a.title, subtitle: a.artist, cover: a.coverUrl)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var mixCard: some View {
        if let m = mix?.mix {
            NavigationLink(value: Dest.mix(m.id)) {
                HStack(spacing: 14) {
                    MixCollage(tracks: m.tracks).frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("МИКС ДНЯ").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text(m.title).font(.headline).lineLimit(1)
                        if let d = m.description, !d.isEmpty { Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        if let ready = m.ready, let total = m.total, ready < total {
                            Text("Готово \(ready) из \(total)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        let q = m.tracks.map { QueueTrack($0) }
                        player.listenAll(q, shuffle: false, context: "mix:\(m.id)", origin: "mix_card")
                    } label: {
                        Image(systemName: "play.fill").font(.title3).frame(width: 48, height: 48)
                    }
                    .glassCircle()
                    .buttonStyle(.plain)
                }
                .padding(14)
                .glassRect(24)
            }
            .buttonStyle(.plain)
        } else if mix?.onboarding == true {
            NavigationLink(value: Dest.taste) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.title).frame(width: 56, height: 56).glassCircle(interactive: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Что вы слушаете?").font(.headline)
                        Text("Выберите исполнителей — и Хаб соберёт «Микс дня» и «Мою волну»").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding(16)
                .glassRect(24)
            }
            .buttonStyle(.plain)
        } else if mix?.building == true {
            HStack(spacing: 12) {
                ProgressView()
                Text("Собираем «Микс дня»…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRect(24)
        }
    }
}

/// «Моя волна»: the big card that starts the user's own wave (origin `home_card`).
struct WaveHero: View {
    @Environment(Wave.self) private var wave
    @Environment(Player.self) private var player
    @State private var phase = false

    private var playing: Bool { player.onWave && wave.title != nil }

    var body: some View {
        Button {
            if playing { player.toggle() } else { Task { await wave.start(seed: nil, origin: "home_card") } }
        } label: {
            ZStack(alignment: .bottomLeading) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying || !playing)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    WaveGradient(t: t)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(playing ? (wave.title ?? "Моя волна") : "Моя волна").font(.largeTitle.weight(.heavy))
                    Text(playing ? "Играет сейчас · подбирается после каждого действия" : "Бесконечный поток под ваш вкус")
                        .font(.subheadline.weight(.medium)).opacity(0.85)
                    HStack(spacing: 8) {
                        if wave.starting == "" { ProgressView().tint(.white) }
                        Image(systemName: playing && player.isPlaying ? "pause.fill" : "play.fill")
                        Text(playing ? (player.isPlaying ? "Пауза" : "Продолжить") : "Слушать")
                    }
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassCapsule(interactive: true)
                    .padding(.top, 8)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .purple.opacity(0.25), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
        .disabled(wave.starting != nil)
    }
}

/// Soft moving colours of the wave card.
struct WaveGradient: View {
    var t: Double
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.36, green: 0.13, blue: 0.85), Color(red: 0.95, green: 0.2, blue: 0.45)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            let blobs: [(Color, Double, Double)] = [(.orange, 0.7, 0.0), (.cyan, 0.5, 2.0), (.pink, 0.9, 4.0)]
            for (color, speed, offset) in blobs {
                let x = size.width * (0.5 + 0.38 * sin(t * speed + offset))
                let y = size.height * (0.5 + 0.35 * cos(t * speed * 0.8 + offset))
                let r = size.width * 0.42
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.55), color.opacity(0)]),
                                               center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
            }
        }
    }
}

/// Four covers of a mix in a square.
struct MixCollage: View {
    var tracks: [Track]
    var body: some View {
        let covers = Array(tracks.compactMap { $0.coverSmallUrl ?? $0.coverUrl }.prefix(4))
        GeometryReader { g in
            let s = g.size.width / 2
            ZStack {
                if covers.count < 4 {
                    Cover(url: covers.first, size: g.size.width, corner: 14)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) { Cover(url: covers[0], size: s, corner: 0); Cover(url: covers[1], size: s, corner: 0) }
                        HStack(spacing: 0) { Cover(url: covers[2], size: s, corner: 0); Cover(url: covers[3], size: s, corner: 0) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

struct AccountButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Menu {
            if let me = app.me { Text(me.username) }
            Button { Router.shared.tab = .more } label: { Label("Настройки", systemImage: "gearshape") }
            Button(role: .destructive) { Task { await app.logout() } } label: { Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right") }
        } label: {
            Text(String(app.me?.username.prefix(1) ?? "?").uppercased())
                .font(.headline)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.gradient, in: Circle())
                .foregroundStyle(.white)
        }
    }
}

/// «Что вы слушаете?»: artists to start the taste with (`/api/taste/onboarding`, `/api/taste/artists`).
struct TasteOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var data: TasteOnboardingOut?
    @State private var query = ""
    @State private var picked: [String: String] = [:]
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Выберите несколько исполнителей, которых слушаете: Хаб соберёт по ним первый «Микс дня» и «Мою волну».")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 18) {
                    ForEach(data?.suggestions ?? []) { a in
                        Button {
                            if picked[a.ref] != nil { picked[a.ref] = nil } else if picked.count < 20 { picked[a.ref] = a.name }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                ArtistBubble(name: a.name, picture: a.pictureSmallUrl ?? a.pictureUrl, size: 100)
                                if picked[a.ref] != nil {
                                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .padding()
        }
        .navigationTitle("Что вы слушаете?")
        .searchable(text: $query, prompt: "Найти исполнителя")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 400))
            if let r = try? await HubClient.shared.tasteOnboarding(q: query.isEmpty ? nil : query) {
                data = r
                if picked.isEmpty { for s in r.selected { picked[s.ref] = s.name } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                busy = true
                Task {
                    do {
                        _ = try await HubClient.shared.pickArtists(Array(picked.keys))
                        Toasts.success("Готово: собираем «Микс дня»")
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                    busy = false
                }
            } label: {
                Text(picked.isEmpty ? "Выберите исполнителей" : "Готово · \(picked.count)").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .prominentButton()
            .disabled(picked.isEmpty || busy)
            .padding()
        }
    }
}

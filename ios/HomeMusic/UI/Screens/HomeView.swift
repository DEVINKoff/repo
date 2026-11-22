import SwiftUI

struct HomeView: View {
    @Environment(Wave.self) private var wave
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app
    @State private var mix: MixTodayOut?
    @State private var home: NdHomeOut?
    @State private var error: String?
    @State private var appeared = false

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Доброе утро"
        case 12..<18: return "Добрый день"
        case 18..<23: return "Добрый вечер"
        default: return "Доброй ночи"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(greeting).font(.subheadline).foregroundStyle(.secondary)
                        Text(app.me?.username ?? "HomeMusic").font(.display(28, .heavy)).lineLimit(1)
                    }
                    Spacer()
                    AccountButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                WaveHero().padding(.horizontal, 20)
                mixCard.padding(.horizontal, 20)

                if let home {
                    Group {
                        shelf("Недавно играли", home.recent)
                        if !home.radio.isEmpty {
                            Shelf(title: "Радиостанции") {
                                ForEach(home.radio) { a in
                                    Button {
                                        Task { await wave.start(seed: WaveSeedIn(ndArtistId: a.id), origin: "radio") }
                                    } label: {
                                        RadioTile(name: a.name, picture: a.coverUrl, starting: wave.starting == a.id)
                                    }
                                    .buttonStyle(.pressable)
                                    .shelfTransition()
                                    .contextMenu {
                                        Button { Router.shared.go(.ndArtist(a.id)) } label: { Label("Открыть исполнителя", systemImage: "music.microphone") }
                                    }
                                }
                            }
                        }
                        shelf("Новое в библиотеке", home.newest)
                        shelf("Часто слушаете", home.frequent)
                        shelf("Любимые альбомы", home.starred)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .onAppear { withAnimation(Theme.spring.delay(0.05)) { appeared = true } }
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding(.bottom, 24)
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task(id: library.generation) { await load() }
    }

    private func load() async {
        async let m = try? HubClient.shared.mixToday()
        do {
            let h = try await HubClient.shared.ndHome()
            withAnimation(Theme.spring) { home = h }
            error = nil
        } catch { self.error = error.localizedDescription }
        let loaded = await m
        withAnimation(Theme.spring) { mix = loaded }
    }

    @ViewBuilder private func shelf(_ title: String, _ albums: [NdAlbumOut]) -> some View {
        if !albums.isEmpty {
            Shelf(title: title) {
                ForEach(albums) { a in
                    NavigationLink(value: Dest.ndAlbum(a.id)) {
                        AlbumCard(title: a.title, subtitle: a.artist, cover: a.coverUrl, width: 150)
                    }
                    .buttonStyle(.pressable)
                    .shelfTransition()
                }
            }
        }
    }

    @ViewBuilder private var mixCard: some View {
        if let m = mix?.mix {
            NavigationLink(value: Dest.mix(m.id)) {
                HStack(spacing: 14) {
                    MixCollage(tracks: m.tracks).frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("МИКС ДНЯ").font(.system(size: 11, weight: .semibold).width(.expanded)).tracking(0.6).foregroundStyle(Theme.accent)
                        Text(m.title).font(.headline).lineLimit(1)
                        if let d = m.description, !d.isEmpty { Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        if let ready = m.ready, let total = m.total, ready < total {
                            ProgressView(value: Double(ready), total: Double(max(total, 1))).tint(Theme.accent).frame(maxWidth: 140)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        player.listenAll(m.tracks.map { QueueTrack($0) }, shuffle: false, context: "mix:\(m.id)", origin: "mix_card")
                    } label: {
                        Image(systemName: "play.fill").font(.title3).frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .glassCircle()
                }
                .padding(14)
                .glassRect(Theme.corner + 6)
            }
            .buttonStyle(.pressable)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if mix?.onboarding == true {
            NavigationLink(value: Dest.taste) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(Theme.accent).frame(width: 52, height: 52).glassCircle(interactive: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Что вы слушаете?").font(.headline)
                        Text("Выберите исполнителей — Хаб соберёт «Микс дня» и «Мою волну»").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(16)
                .glassRect(Theme.corner + 6)
            }
            .buttonStyle(.pressable)
        } else if mix?.building == true {
            HStack(spacing: 12) {
                ProgressView()
                Text("Собираем «Микс дня»…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRect(Theme.corner + 6)
        }
    }
}

/// A station of «Радиостанции»: the artist in a circle with a small wave badge.
struct RadioTile: View {
    var name: String
    var picture: String?
    var starting: Bool
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Cover(url: picture, size: 112, round: true, symbol: "music.microphone")
                Group {
                    if starting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "dot.radiowaves.left.and.right").font(.caption.weight(.bold)) }
                }
                .frame(width: 32, height: 32)
                .glassCircle(interactive: false)
            }
            Text(name).font(.footnote.weight(.medium)).lineLimit(1)
        }
        .frame(width: 112)
    }
}

/// «Моя волна»: a quiet glass card with a living orb; one tap starts the user's own wave (origin `home_card`).
struct WaveHero: View {
    @Environment(Wave.self) private var wave
    @Environment(Player.self) private var player

    private var playing: Bool { player.onWave && wave.title != nil }

    var body: some View {
        Button {
            if playing { player.toggle() } else { Task { await wave.start(seed: nil, origin: "home_card") } }
        } label: {
            HStack(spacing: 18) {
                WaveOrb(active: playing && player.isPlaying, loading: wave.starting == "")
                    .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text(playing ? (wave.title ?? "Моя волна") : "Моя волна").font(.display(22, .heavy)).lineLimit(1)
                    Text(playing ? "Подстраивается после каждого трека" : "Бесконечный поток под ваш вкус")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Image(systemName: playing && player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                        Text(playing ? (player.isPlaying ? "Пауза" : "Продолжить") : "Слушать")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRect(Theme.corner + 10)
        }
        .buttonStyle(.pressable)
        .disabled(wave.starting != nil)
    }
}

/// Concentric accent rings that breathe while idle and pulse with the music.
struct WaveOrb: View {
    var active: Bool
    var loading: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active && !loading)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) / 2
                let speed = active ? 2.4 : (loading ? 4.0 : 0.8)
                for i in 0..<3 {
                    let phase = t * speed + Double(i) * 1.1
                    let r = base * (0.55 + 0.12 * Double(i) + (active || loading ? 0.06 * sin(phase) : 0))
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(Theme.accent.opacity(0.55 - Double(i) * 0.15)), lineWidth: 2)
                }
                let core = base * (0.42 + (active ? 0.04 * sin(t * 5) : 0))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
                         with: .radialGradient(Gradient(colors: [Theme.accent, Theme.accent.opacity(0.35)]),
                                               center: c, startRadius: 0, endRadius: core))
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
                .frame(width: 36, height: 36)
                .glassCircle()
                .foregroundStyle(.primary)
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

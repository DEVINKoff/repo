import SwiftUI

struct DownloadsView: View {
    @Environment(Downloads.self) private var downloads

    var body: some View {
        let items = downloads.visible
        let review = items.filter { $0.status == "needs_review" }
        let active = items.filter(\.isActive)
        let failed = items.filter { $0.status == "failed" }
        let finished = items.filter { $0.status == "done" || $0.status == "cancelled" }
        List {
            if items.isEmpty && downloads.loaded {
                ContentUnavailableView("Загрузок нет", systemImage: "arrow.down.circle",
                                       description: Text("Скачивайте треки и альбомы из поиска — они появятся здесь"))
                    .listRowSeparator(.hidden)
            }
            if !review.isEmpty {
                Section {
                    ForEach(review) { d in
                        NavigationLink(value: Dest.web(path: "/downloads/\(d.id)", title: "Выбор файла")) { DownloadRow(item: d) }
                    }
                } header: { Text("Нужен выбор") } footer: { Text("Хаб не уверен в файле: выберите вариант или вставьте ссылку") }
            }
            if !active.isEmpty { Section("Сейчас") { ForEach(active) { DownloadRow(item: $0) } } }
            if !failed.isEmpty { Section("Ошибки") { ForEach(failed) { DownloadRow(item: $0) } } }
            if !finished.isEmpty { Section("Готово") { ForEach(finished.prefix(100)) { DownloadRow(item: $0) } } }
        }
        .navigationTitle("Загрузки")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Очистить") { Task { await downloads.clearFinished() } }.disabled(finished.isEmpty)
            }
        }
        .refreshable { await downloads.load() }
        .task { await downloads.load() }
    }
}

struct DownloadRow: View {
    let item: DownloadItemOut
    @Environment(Downloads.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Format.statusTitle[item.status] ?? item.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            if item.isActive {
                ProgressView(value: max(0, min(1, item.progress ?? 0))).tint(.accentColor)
            }
            if let e = item.error, !e.isEmpty, item.status != "done" {
                Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            if item.isActive {
                Button(role: .destructive) { Task { await act { try await HubClient.shared.cancel(item.id) } } } label: { Label("Отменить", systemImage: "xmark") }
            }
            if item.status == "failed" || item.status == "cancelled" {
                Button { Task { await act { try await HubClient.shared.retry(item.id) } } } label: { Label("Повторить", systemImage: "arrow.clockwise") }
                    .tint(.accentColor)
            }
        }
    }

    private var color: Color {
        switch item.status {
        case "done": return .green
        case "failed": return .red
        case "needs_review": return .orange
        case "cancelled": return .secondary
        default: return .accentColor
        }
    }

    private func act(_ f: () async throws -> DownloadItemOut) async {
        do { downloads.changed(try await f()) } catch { Toasts.error(error) }
    }
}

/// «Хаб»: the Hub's own tools (its pages inside the app, as in the Android app) and the settings.
struct MoreView: View {
    @Environment(AppModel.self) private var app
    @Environment(SmartShuffle.self) private var smart
    @State private var light = Settings.lightOnCellular
    @State private var settings: MixSettingsOut?

    var body: some View {
        List {
            Section {
                web("Ассистент", "sparkles", .purple, "/assistant", "ИИ: найдёт и скачает по скриншоту, ссылке или тексту")
                web("Перенести музыку", "arrow.triangle.2.circlepath", .orange, "/import", "Яндекс Музыка, Spotify")
                web("Загрузить свои файлы", "square.and.arrow.up", .blue, "/upload", nil)
                web("Медиатека: редактор", "slider.horizontal.3", .teal, "/library", "Альбомы, теги, обложки")
            } header: { Text("Хаб") }

            Section {
                Picker("Режим микса", selection: Binding(get: { settings?.mode ?? "normal" }, set: { setMode($0) })) {
                    Text("Обычный").tag("normal")
                    Text("Любимое").tag("favorites")
                    Text("Незнакомое").tag("discover")
                }
                .disabled(settings == nil)
                NavigationLink(value: Dest.taste) { Label("Мои исполнители", systemImage: "person.2") }
            } header: { Text("«Микс дня» и «Моя волна»") } footer: {
                Text(modeHint + (settings.map { ". Новый микс — каждый день в \($0.mixHour):00" } ?? ""))
            }

            Section {
                Toggle(isOn: Binding(get: { smart.enabled }, set: { smart.enabled = $0 })) {
                    Label("Умное перемешивание", systemImage: "sparkles")
                }
                .tint(Theme.toggle)
                Toggle(isOn: $light) { Label("Экономия трафика", systemImage: "antenna.radiowaves.left.and.right") }
                    .tint(Theme.toggle)
                    .onChange(of: light) { Settings.lightOnCellular = light }
            } header: { Text("Воспроизведение") } footer: {
                Text("Умное перемешивание добавляет рекомендации между песнями плейлистов и «Понравившихся». Экономия трафика: в сотовой сети Хаб отдаёт лёгкую копию (Opus 160 кбит/с).")
            }

            AppearanceSection()

            if app.me?.isAdmin == true {
                Section("Администратор") {
                    web("Пользователи и приглашения", "person.3", .indigo, "/admin", nil)
                    web("Аналитика", "chart.bar.xaxis", .pink, "/admin/insights", nil)
                    web("Матрица вкуса", "square.grid.3x3", .mint, "/admin/taste", nil)
                }
            }

            Section {
                LabeledContent("Пользователь", value: app.me?.username ?? "—")
                LabeledContent("Сервер", value: app.serverURL?.absoluteString ?? "—")
                RemoteAddressRow()
                Button("Сменить сервер") { app.changeServer() }
                Button("Выйти", role: .destructive) { Task { await app.logout() } }
            } header: { Text("Аккаунт") } footer: {
                Text("Адрес вне дома — как открыть Хаб не из домашней сети (туннель или свой сервер, https://…). Если домашний адрес не отвечает — включён VPN на телефоне или на ПК, мобильный интернет, — приложение само переключается на него и возвращается домой, когда дом снова доступен.")
            }

            Section {
                LabeledContent("Версия", value: AppInfo.version)
            } footer: {
                Text("HomeMusic для iOS — клиент вашего сервера HomeMusic (Хаб + Navidrome).")
            }
        }
        .navigationTitle("Ещё")
        .task { settings = (try? await HubClient.shared.mixToday())?.settings }
    }

    private var modeHint: String {
        switch settings?.mode {
        case "favorites": return "В основном то, что вы любите: 80 % знакомого"
        case "discover": return "Почти всё новое: 90 % песен, которых вы не слышали"
        default: return "40 % знакомого и 60 % нового"
        }
    }

    private func setMode(_ mode: String) {
        Task {
            do {
                settings = try await HubClient.shared.mixSettings(MixSettingsIn(mode: mode))
                Toasts.success("Режим сменится в следующем миксе")
            } catch { Toasts.error(error) }
        }
    }

    private func web(_ title: String, _ icon: String, _ color: Color, _ path: String, _ hint: String?) -> some View {
        NavigationLink(value: Dest.web(path: path, title: title)) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(Theme.accent)
            }
        }
    }
}


/// «Оформление»: the accent colour (a row of swatches), light / dark, animated covers.
struct AppearanceSection: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        @Bindable var theme = theme
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(AccentChoice.allCases) { c in
                        let on = theme.accent == c
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { theme.accent = c }
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(c.color.gradient)
                                    Circle().strokeBorder(.primary.opacity(on ? 0.9 : 0), lineWidth: 2.5).padding(-5)
                                    if on {
                                        Image(systemName: "checkmark").font(.footnote.weight(.bold))
                                            .foregroundStyle(c == .mono ? Color(.systemBackground) : .white)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .frame(width: 38, height: 38)
                                .scaleEffect(on ? 1.08 : 1)
                                Text(c.title).font(.caption2).foregroundStyle(on ? .primary : .secondary)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.pressable)
                        .sensoryFeedback(.selection, trigger: on)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            Picker(selection: $theme.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            } label: { Label("Тема", systemImage: "circle.lefthalf.filled") }
            Toggle(isOn: $theme.motionCovers) { Label("Живые обложки", systemImage: "play.rectangle.on.rectangle") }
                .tint(Theme.toggle)
        } header: { Text("Оформление") } footer: {
            Text("Живые обложки — анимированные обложки альбомов из Apple Music в плеере, когда они есть у альбома.")
        }
    }
}


/// «Адрес вне дома»: shows the outside address (and whether it's in use now), edits it.
struct RemoteAddressRow: View {
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Button {
            text = app.remoteURL?.absoluteString ?? ""
            error = nil
            editing = true
        } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    if HubClient.shared.onRemote { Image(systemName: "globe").foregroundStyle(Theme.accent) }
                    Text(app.remoteURL?.host ?? "не задан").lineLimit(1)
                }
            } label: {
                Text("Адрес вне дома").foregroundStyle(.primary)
            }
        }
        .alert("Адрес вне дома", isPresented: $editing) {
            TextField("https://…", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Сохранить") {
                busy = true
                Task {
                    if let e = await app.setRemote(text) { Toasts.error(e) } else { Toasts.success(text.isEmpty ? "Адрес вне дома убран" : "Адрес вне дома сохранён") }
                    busy = false
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Например, адрес туннеля Cloudflare или вашего сервера. Пусто — убрать.")
        }
    }
}

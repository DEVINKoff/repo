import AVFoundation
import SwiftUI

@main
struct HomeMusicApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Player.configureAudioSession()
        _ = SmartShuffle.shared // registers its hooks in the player
        _ = Wave.shared
        StandByFeed.registerCommands() // the StandBy widget's ⏮ ⏯ ⏭
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
                .environment(Player.shared)
                .environment(Wave.shared)
                .environment(Stars.shared)
                .environment(Dislikes.shared)
                .environment(Toasts.shared)
                .environment(Library.shared)
                .environment(Downloads.shared)
                .environment(SmartShuffle.shared)
                .environment(Router.shared)
                .environment(PlaylistPicker.shared)
                .environment(Lyrics.shared)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                NowPlaying.setInApp(true)
                AppModel.shared.foreground()
            case .inactive:
                NowPlaying.setInApp(false) // Control Center / the app switcher: show the track there
            case .background:
                NowPlaying.setInApp(false)
                PlayEvents.shared.flushInBackground()
            @unknown default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            switch app.stage {
            case .server: ServerView().transition(.opacity)
            case .checking: ProgressView().controlSize(.large).task { await app.checkSession() }
            case .login: LoginView().transition(.opacity)
            case .ready: MainTabs().transition(.opacity)
            }
            ToastOverlay()
        }
        .animation(.smooth, value: app.stage)
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads
    @Environment(PlaylistPicker.self) private var picker

    var body: some View {
        @Bindable var router = router
        @Bindable var app = app
        @Bindable var picker = picker
        content
            .sheet(isPresented: $app.playerOpen) {
                PlayerView()
            }
            .sheet(item: $picker.request) { PlaylistPickerSheet(request: $0) }
            .onChange(of: app.route) { _, r in
                if r == .downloads { router.openDownloads(); app.route = nil }
            }
    }

    @ViewBuilder private var content: some View {
        if #available(iOS 26.0, *) {
            tabs
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory {
                    if player.track != nil { MiniPlayer() } else { NothingPlaying() }
                }
        } else {
            tabs
                .safeAreaInset(edge: .bottom) {
                    if player.track != nil {
                        MiniPlayer()
                            .glassRect(18)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 54)
                    }
                }
        }
    }

    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.tab) {
            Tab("Главная", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $router.home) { HomeView().destinations() }
            }
            Tab("Поиск", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack(path: $router.search) { SearchView().destinations() }
            }
            Tab("Библиотека", systemImage: "square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $router.library) { LibraryView().destinations() }
            }
            .badge(downloads.activeCount)
            Tab("Ещё", systemImage: "ellipsis.circle.fill", value: AppTab.more) {
                NavigationStack(path: $router.more) { MoreView().destinations() }
            }
        }
    }
}

/// The accessory when nothing plays: one tap starts «Моя волна».
struct NothingPlaying: View {
    var body: some View {
        Button {
            Task { await Wave.shared.start(seed: nil, origin: "player") }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("Включить «Мою волну»").font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "play.fill")
            }
            .padding(.horizontal, 16)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

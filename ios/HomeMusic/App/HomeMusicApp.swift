import AVFoundation
import SwiftUI
import UIKit

@main
struct HomeMusicApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // covers and pages survive relaunches (the image memory cache doesn't)
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
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
                .environment(AppTheme.shared)
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

/// The app stays upright; only the full player may turn sideways (its cinematic mode).
final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var orientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }

    @MainActor static func allowLandscape(_ on: Bool) {
        orientations = on ? .allButUpsideDown : .portrait
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        if !on { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppTheme.self) private var theme
    @State private var splash = true

    var body: some View {
        ZStack {
            switch app.stage {
            case .server: ServerView().transition(.opacity)
            case .checking: ProgressView().controlSize(.large).task { await app.checkSession() }
            case .login: LoginView().transition(.opacity)
            case .ready: MainTabs().transition(.opacity)
            }
            ToastOverlay()
            if splash {
                LaunchSplash { withAnimation(.smooth(duration: 0.5)) { splash = false } }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.smooth, value: app.stage)
        .tint(theme.accent.color)
        .preferredColorScheme(theme.appearance.scheme)
        .animation(.smooth(duration: 0.35), value: theme.accent)
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
            .onChange(of: app.playerOpen) { _, open in AppDelegate.allowLandscape(open) }
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

/// The opening: the app's mark draws in on the accent's glow, the two waves ripple out, then everything lifts away
/// into the app.
struct LaunchSplash: View {
    let done: () -> Void
    @State private var step = 0

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(step >= 1 ? 0.35 : 0), .clear], center: .center, startRadius: 0,
                           endRadius: step >= 1 ? 420 : 60)
                .ignoresSafeArea()
            ForEach(0..<2, id: \.self) { i in
                Circle().strokeBorder(Theme.accent.opacity(step >= 2 ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 110, height: 110)
                    .scaleEffect(step >= 2 ? 3.2 + Double(i) : 1)
                    .animation(.easeOut(duration: 1.0).delay(Double(i) * 0.12), value: step)
            }
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Theme.accent.gradient)
                        .frame(width: 110, height: 110)
                        .shadow(color: Theme.accent.opacity(0.5), radius: step >= 1 ? 30 : 0, y: 10)
                    Image(systemName: "waveform")
                        .font(.system(size: 50, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .symbolEffect(.variableColor.iterative, options: .speed(1.6), isActive: step == 1)
                }
                .scaleEffect(step == 0 ? 0.6 : step >= 3 ? 1.5 : 1)
                .rotationEffect(.degrees(step == 0 ? -12 : 0))
                Text("HomeMusic")
                    .font(.display(26, .heavy))
                    .opacity(step >= 1 && step < 3 ? 1 : 0)
                    .offset(y: step >= 1 ? 0 : 14)
                    .blur(radius: step >= 1 && step < 3 ? 0 : 8)
            }
            .opacity(step >= 3 ? 0 : 1)
            .blur(radius: step >= 3 ? 12 : 0)
        }
        .task {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.62)) { step = 1 }
            try? await Task.sleep(for: .milliseconds(550))
            step = 2
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeIn(duration: 0.35)) { step = 3 }
            try? await Task.sleep(for: .milliseconds(300))
            done()
        }
    }
}

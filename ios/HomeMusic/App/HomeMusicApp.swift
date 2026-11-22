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

/// The opening, about 1.8 s: a living mesh gradient in the accent's colours, drops of liquid glass orbiting over it
/// and melting into each other, then drawn together into one lens; a flash of light runs across it and the lens
/// opens out over the whole screen into the app.
struct LaunchSplash: View {
    let done: () -> Void
    @State private var start = Date()
    @State private var phase = 0 // 0 — orbit; 1 — gather into one; 2 — flash; 3 — open out

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            ZStack {
                LaunchMesh(t: t)
                    .scaleEffect(phase == 3 ? 1.25 : 1)
                    .opacity(phase == 3 ? 0 : 1)
                    .ignoresSafeArea()
                drops(t)
                    .scaleEffect(phase == 3 ? 14 : 1)
                    .opacity(phase == 3 ? 0 : 1)
                    .blur(radius: phase == 3 ? 10 : 0)
                // the flash across the lens
                LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 70, height: 260)
                    .rotationEffect(.degrees(24))
                    .offset(x: phase >= 2 ? 200 : -200)
                    .opacity(phase == 2 ? 1 : 0)
                    .blendMode(.plusLighter)
                    .mask(Circle().frame(width: 150, height: 150))
            }
        }
        .allowsHitTesting(phase < 3)
        .task {
            start = Date()
            try? await Task.sleep(for: .milliseconds(850))
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { phase = 1 }
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.easeInOut(duration: 0.45)) { phase = 2 }
            try? await Task.sleep(for: .milliseconds(330))
            withAnimation(.easeIn(duration: 0.5)) { phase = 3 }
            try? await Task.sleep(for: .milliseconds(420))
            done()
        }
    }

    /// Five drops on their own orbits (radius, speed, size), gathered into one lens from phase 1.
    private func drops(_ t: Double) -> some View {
        let orbits: [(r: CGFloat, speed: Double, size: CGFloat, phase: Double)] = [
            (92, 1.6, 84, 0), (74, -2.1, 58, 1.3), (110, 1.15, 46, 2.6), (54, 2.6, 40, 3.8), (128, -1.4, 34, 5.0),
        ]
        let gathered = phase >= 1
        return glassGroup {
            ZStack {
                ForEach(0..<orbits.count, id: \.self) { i in
                    let o = orbits[i]
                    let a = o.phase + t * o.speed
                    // the orbits breathe in and out a little
                    let r = o.r * (0.8 + 0.2 * sin(t * 2.4 + o.phase))
                    Color.clear
                        .frame(width: gathered ? 150 : o.size, height: gathered ? 150 : o.size)
                        .modifier(GlassDrop())
                        .offset(x: gathered ? 0 : r * cos(a), y: gathered ? 0 : r * sin(a))
                }
            }
        }
    }

    @ViewBuilder private func glassGroup<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 36) { c() }
        } else {
            c()
        }
    }
}

/// A round drop of liquid glass (frosted material before iOS 26).
private struct GlassDrop: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.06)), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// A 3×3 mesh of the accent and its neighbours, its inner points drifting.
private struct LaunchMesh: View {
    let t: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let a = Theme.accent
        let base: Color = scheme == .dark ? .black : .white
        let c1 = a.mix(with: .pink, by: 0.45)
        let c2 = a.mix(with: .cyan, by: 0.45)
        let c3 = a.mix(with: base, by: 0.55)
        let x = Float(0.5 + 0.18 * sin(t * 1.9))
        let y = Float(0.5 + 0.16 * cos(t * 1.5))
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [Float(0.5 + 0.2 * sin(t * 1.3)), 0], [1, 0],
            [0, Float(0.5 + 0.2 * cos(t * 1.7))], [x, y], [1, Float(0.5 + 0.2 * sin(t * 1.1))],
            [0, 1], [Float(0.5 + 0.2 * cos(t * 1.4)), 1], [1, 1],
        ], colors: [
            c3, c1, base,
            c2, a, c1,
            base, c2, c3,
        ])
    }
}

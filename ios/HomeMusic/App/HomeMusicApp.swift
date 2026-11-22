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
    @State private var revealed = false

    var body: some View {
        ZStack {
            Group {
            switch app.stage {
            case .server: ServerView().transition(.opacity)
            case .checking: ProgressView().controlSize(.large).task { await app.checkSession() }
            case .login: LoginView().transition(.opacity)
            case .ready: MainTabs().transition(.opacity)
            }
            }
            // during the opening the app waits a little deeper and soft, and comes up as the iris opens
            .scaleEffect(revealed ? 1 : 1.08)
            .blur(radius: revealed ? 0 : 10)
            ToastOverlay()
            if splash {
                LaunchSplash(reveal: { withAnimation(.easeOut(duration: 0.7)) { revealed = true } }, done: { splash = false })
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

/// The opening, about 2 s, always dark, all of it a function of time:
/// 1. a dark mesh gradient in the accent's colours; drops of liquid glass orbit over it, their edges splitting the
///    light a little (dispersion);
/// 2. the drops gather into one lens, which breathes once;
/// 3. the lens opens like an iris: the hole grows from its middle over the whole screen, and the app comes up
///    through it from a little depth (`reveal`).
struct LaunchSplash: View {
    let reveal: () -> Void
    let done: () -> Void
    @State private var start = Date()
    @State private var finished = false

    private static let total = 2.0

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation) { tl in
                frame(tl.date.timeIntervalSince(start), g.size)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(!finished)
        .task {
            start = Date()
            try? await Task.sleep(for: .seconds(1.36))
            reveal()
            try? await Task.sleep(for: .seconds(Self.total - 1.36))
            finished = true
            done()
        }
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func ease(_ x: Double) -> Double { let c = clamp(x); return c * c * (3 - 2 * c) }
    private static func easeInOut(_ x: Double) -> Double {
        let c = clamp(x)
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }

    private static let orbits: [(r: CGFloat, speed: Double, size: CGFloat, phase: Double)] = [
        (96, 1.5, 86, 0), (72, -2.0, 60, 1.3), (118, 1.1, 46, 2.6), (54, 2.5, 40, 3.8), (136, -1.3, 34, 5.0),
    ]

    @ViewBuilder private func frame(_ t: Double, _ size: CGSize) -> some View {
        let gather = Self.ease((t - 0.75) / 0.45)
        let breathe = 1 + 0.05 * sin(Self.clamp((t - 1.15) / 0.25) * .pi)
        let iris = Self.easeInOut((t - 1.36) / 0.6)
        let reach = sqrt(size.width * size.width + size.height * size.height) / 2 + 40
        let hole = Self.lerp(0, reach * 2, iris)

        ZStack {
            LaunchMesh(t: t)
                .scaleEffect(1 + 0.08 * iris)
            drops(t, gather: gather)
                .scaleEffect(breathe * (1 + 0.6 * iris))
                .opacity(1 - Self.clamp(iris * 1.6))
        }
        .frame(width: size.width, height: size.height)
        // the iris: a soft-edged hole from the lens' middle out to the corners
        .mask {
            Rectangle()
                .overlay {
                    Circle()
                        .frame(width: hole, height: hole)
                        .blur(radius: 18 + 30 * iris)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
        // the lens' rim as it opens: a hair of light, its red and blue a little apart
        .overlay {
            if iris > 0 && iris < 1 {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                    Circle().stroke(Color.red.opacity(0.35), lineWidth: 1).offset(x: -1.5)
                    Circle().stroke(Color.blue.opacity(0.35), lineWidth: 1).offset(x: 1.5)
                }
                .frame(width: hole * 0.86, height: hole * 0.86)
                .blur(radius: 1 + 3 * iris)
                .opacity(1 - iris)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        }
    }

    /// The orbiting drops, their edges splitting the light a little; one lens once gathered.
    private func drops(_ t: Double, gather: Double) -> some View {
        glassGroup {
            ZStack {
                ForEach(0..<Self.orbits.count, id: \.self) { i in
                    let o = Self.orbits[i]
                    let a = o.phase + t * o.speed
                    let r = o.r * (0.8 + 0.2 * sin(t * 2.4 + o.phase)) * CGFloat(1 - gather)
                    let d = Self.lerp(o.size, 150, gather)
                    Color.clear
                        .frame(width: d, height: d)
                        .modifier(GlassDrop())
                        .overlay {
                            ZStack {
                                Circle().stroke(Color.red.opacity(0.4), lineWidth: 1).offset(x: -1.2, y: -0.4)
                                Circle().stroke(Color.cyan.opacity(0.4), lineWidth: 1).offset(x: 1.2, y: 0.4)
                            }
                            .blur(radius: 0.6)
                            .blendMode(.plusLighter)
                            .opacity(0.8 - 0.4 * gather)
                        }
                        .offset(x: r * cos(a), y: r * sin(a))
                }
            }
        }
    }

    @ViewBuilder private func glassGroup<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 38) { c() }
        } else {
            c()
        }
    }
}

/// A drop of liquid glass (frosted material before iOS 26).
private struct GlassDrop: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.04)), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// A 3×3 mesh of the accent and its neighbours, its inner points drifting.
private struct LaunchMesh: View {
    let t: Double

    var body: some View {
        let a = Theme.accent.mix(with: .black, by: 0.35)
        let base = Color(red: 0.02, green: 0.02, blue: 0.035)
        let c1 = a.mix(with: .pink, by: 0.35).mix(with: .black, by: 0.45)
        let c2 = a.mix(with: .cyan, by: 0.35).mix(with: .black, by: 0.5)
        let c3 = a.mix(with: base, by: 0.75)
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

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
        VolumeWatch.shared.start() // volume at zero pauses the music; the cinematic mode's dial
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
                .environment(VolumeWatch.shared)
                .environment(MotionTint.shared)
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
        refresh()
        if !on { request(.portrait) }
    }

    /// Out of the cinematic mode with the phone still sideways: upright now, and kept upright until the phone itself
    /// is held upright (else iOS would turn it straight back); then sideways is allowed again (while the player is open).
    @MainActor static func backToPortrait() {
        orientations = .portrait
        refresh()
        request(.portrait)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        uprightWatch.map(NotificationCenter.default.removeObserver)
        uprightWatch = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard UIDevice.current.orientation == .portrait else { return }
                uprightWatch.map(NotificationCenter.default.removeObserver)
                uprightWatch = nil
                if AppModel.shared.playerOpen { orientations = .allButUpsideDown; refresh() }
            }
        }
    }

    /// Into the cinematic mode from the button (the phone upright).
    @MainActor static func toLandscape() {
        uprightWatch.map(NotificationCenter.default.removeObserver)
        uprightWatch = nil
        orientations = .allButUpsideDown
        refresh()
        request(.landscapeRight)
    }

    nonisolated(unsafe) private static var uprightWatch: NSObjectProtocol?

    @MainActor private static func scene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    @MainActor private static func refresh() {
        for w in scene()?.windows ?? [] { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
    }

    @MainActor private static func request(_ o: UIInterfaceOrientationMask) {
        scene()?.requestGeometryUpdate(.iOS(interfaceOrientations: o)) { _ in }
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
            // during the opening the app waits a little deeper and soft, and comes up as the black lifts
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
        // «Адаптивный»: the accent follows the playing track's cover
        .task(id: [Player.shared.track?.coverSmallUrl ?? Player.shared.track?.coverUrl ?? "", theme.accent.rawValue]) {
            await theme.adapt(to: HubClient.shared.absolute(Player.shared.track?.coverSmallUrl ?? Player.shared.track?.coverUrl))
        }
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
            .onChange(of: app.playerOpen) { _, open in AppDelegate.allowLandscape(open); Haptics.soft(open ? 0.7 : 0.4) }
            .onChange(of: router.tab) { Haptics.select() }
            .onChange(of: app.route) { _, r in
                if r == .downloads { router.openDownloads(); app.route = nil }
            }
    }

    @ViewBuilder private var content: some View {
        if #available(iOS 26.0, *) {
            tabs
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory {
                    if player.track != nil {
                        MiniPlayer()
                    } else {
                        NothingPlaying()
                    }
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

/// The opening, about 2.4 s, on pure black (pure white in the light theme), all of it a function of time:
/// 1. drops of liquid glass orbit, seen by their rims (lit on black, shaded on white) and edges splitting the light;
/// 2. they gather into one lens, which breathes once;
/// 3. the lens flows down into the dock and stretches into its shape; the background lifts and the app is there,
///    its dock where the glass landed.
struct LaunchSplash: View {
    let reveal: () -> Void
    let done: () -> Void
    @State private var start = Date()
    @State private var finished = false
    @State private var insets = UIEdgeInsets.zero
    @Environment(\.colorScheme) private var scheme

    private static let total = 2.4
    private static let revealAt = 1.72

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation) { tl in
                frame(tl.date.timeIntervalSince(start), g.size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!finished)
        .task {
            insets = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets ?? .zero
            start = Date()
            try? await Task.sleep(for: .seconds(Self.revealAt))
            reveal()
            try? await Task.sleep(for: .seconds(Self.total - Self.revealAt))
            finished = true
            done()
        }
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func ease(_ x: Double) -> Double { let c = clamp(x); return c * c * (3 - 2 * c) }
    /// eases out past the end a little and settles (a liquid's overshoot)
    private static func easeOutBack(_ x: Double) -> Double {
        let c = clamp(x), k = 1.25
        return 1 + (k + 1) * pow(c - 1, 3) + k * pow(c - 1, 2)
    }
    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }

    private static let orbits: [(r: CGFloat, speed: Double, size: CGFloat, phase: Double)] = [
        (96, 1.5, 86, 0), (72, -2.0, 60, 1.3), (118, 1.1, 46, 2.6), (54, 2.5, 40, 3.8), (136, -1.3, 34, 5.0),
    ]

    @ViewBuilder private func frame(_ t: Double, _ size: CGSize) -> some View {
        let gather = Self.ease((t - 0.7) / 0.45)
        let breathe = 1 + 0.05 * sin(Self.clamp((t - 1.1) / 0.22) * .pi)
        let split = (t - 1.3) / 0.62
        let black = 1 - Self.ease((t - Self.revealAt) / 0.42)
        let fade = 1 - Self.ease((t - 2.0) / 0.38)
        ZStack {
            (scheme == .dark ? Color.black : Color.white).opacity(black)
            if split <= 0 {
                drops(t, gather: gather).scaleEffect(breathe)
            } else {
                halves(Self.easeOutBack(split), size)
                    .opacity(fade)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// The lens' two parts on their way to the island and the dock (`k` 0 → 1, a little past and back).
    private func halves(_ k: Double, _ size: CGSize) -> some View {
        let lens: CGFloat = 150
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        // the floating dock (the tab bar) at the bottom
        let dockW = size.width - 40, dockH: CGFloat = 62
        let dockY = size.height - (insets.bottom > 0 ? 52 : 40)
        let dock = CGRect(x: c.x - dockW / 2, y: dockY - dockH / 2, width: dockW, height: dockH)

        func shape(_ to: CGRect) -> some View {
            let w = Self.lerp(lens, to.width, k), h = Self.lerp(lens, to.height, k)
            let x = Self.lerp(c.x, to.midX, k), y = Self.lerp(c.y, to.midY, k)
            return Color.clear
                .frame(width: max(1, w), height: max(1, h))
                .modifier(GlassPill())
                .overlay { GlassLight(shape: Capsule(), dark: scheme == .dark) }
                .position(x: x, y: y)
        }

        return glassGroup {
            ZStack {
                shape(dock)
            }
        }
    }

    /// The orbiting drops, seen by their own light; one lens once gathered.
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
                        .overlay { GlassLight(shape: Circle(), dark: scheme == .dark).opacity(1 - 0.35 * gather) }
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

/// How glass shows on a plain background: on black a rim lit from the top left and a faint inner glow, on white a
/// rim shaded toward the bottom right and a soft drop shadow; on both the edges split the light a little.
private struct GlassLight<S: InsettableShape>: View {
    let shape: S
    var dark = true

    var body: some View {
        if dark {
            ZStack {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08), .white.opacity(0.35)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                shape.fill(RadialGradient(colors: [.white.opacity(0.09), .clear], center: UnitPoint(x: 0.35, y: 0.3),
                                          startRadius: 0, endRadius: 90))
                shape.stroke(Color.red.opacity(0.45), lineWidth: 1).offset(x: -1.3, y: -0.4).blur(radius: 0.6)
                shape.stroke(Color.cyan.opacity(0.45), lineWidth: 1).offset(x: 1.3, y: 0.4).blur(radius: 0.6)
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        } else {
            ZStack {
                shape.strokeBorder(LinearGradient(colors: [.white, .black.opacity(0.08), .black.opacity(0.28)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                shape.fill(RadialGradient(colors: [.white.opacity(0.7), .clear], center: UnitPoint(x: 0.32, y: 0.28),
                                          startRadius: 0, endRadius: 70))
                shape.stroke(Color.red.opacity(0.3), lineWidth: 1).offset(x: -1.3, y: -0.4).blur(radius: 0.6).blendMode(.multiply)
                shape.stroke(Color.cyan.opacity(0.35), lineWidth: 1).offset(x: 1.3, y: 0.4).blur(radius: 0.6).blendMode(.multiply)
            }
            .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
            .allowsHitTesting(false)
        }
    }
}

/// A pill of liquid glass (frosted material before iOS 26).
private struct GlassPill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.04)), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
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


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
                LaunchSplash { splash = false }
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

/// The opening, about 2.3 s, all of it a function of time (no steps):
/// 1. a living mesh gradient in the accent's colours; drops of liquid glass orbit over it, each with a prismatic rim
///    and its light split into red, green and blue;
/// 2. the drops gather into one lens; prismatic sparks scatter from it and a rainbow ring of dispersion runs out;
/// 3. a flash of light crosses the lens;
/// 4. the lens morphs into the shape of the screen while the gradient fades: the app shows through the glass, and
///    the glass dissolves into it.
struct LaunchSplash: View {
    let done: () -> Void
    @State private var start = Date()
    @State private var finished = false

    private static let total = 2.35

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSince(start)
                frame(t, g.size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!finished)
        .task {
            start = Date()
            try? await Task.sleep(for: .seconds(Self.total))
            finished = true
            done()
        }
    }

    // MARK: timing

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func ease(_ x: Double) -> Double { let c = clamp(x); return c * c * (3 - 2 * c) }
    private static func easeOut(_ x: Double) -> Double { let c = clamp(x); return 1 - pow(1 - c, 3) }
    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }

    private static let orbits: [(r: CGFloat, speed: Double, size: CGFloat, phase: Double)] = [
        (96, 1.5, 86, 0), (72, -2.0, 60, 1.3), (118, 1.1, 46, 2.6), (52, 2.5, 40, 3.8), (136, -1.3, 34, 5.0), (84, 1.9, 28, 0.7),
    ]

    @ViewBuilder private func frame(_ t: Double, _ size: CGSize) -> some View {
        let gather = Self.ease((t - 0.85) / 0.42)          // the drops come together
        let burst = (t - 1.15) / 0.85                       // sparks fly out
        let ring = (t - 1.22) / 0.7                         // the dispersion ring
        let flash = (t - 1.32) / 0.32                       // the light across the lens
        let morph = Self.ease((t - 1.6) / 0.42)             // lens → screen
        let dissolve = Self.ease((t - 1.98) / 0.35)         // the glass melts into the app
        let lens: CGFloat = 150
        let w = Self.lerp(lens, size.width, morph)
        let h = Self.lerp(lens, size.height, morph)
        let corner = Self.lerp(lens / 2, 54, morph)

        ZStack {
            LaunchMesh(t: t)
                .scaleEffect(1 + 0.15 * morph)
                .opacity(1 - morph)

            // soft caustic light the glass bends
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 160))
                .frame(width: 320, height: 320)
                .offset(x: 60 * sin(t * 1.7), y: 50 * cos(t * 1.3))
                .blendMode(.plusLighter)
                .opacity(0.7 * (1 - morph))

            if morph <= 0 {
                drops(t, gather: gather)
            } else {
                GlassPane(cornerRadius: corner)
                    .frame(width: w, height: h)
                    .opacity(1 - dissolve)
            }

            // the prismatic rim of the lens (and then of the screen-shaped glass)
            PrismRim(cornerRadius: corner, spin: t, width: 2.5 + 2 * (1 - morph))
                .frame(width: w, height: h)
                .opacity(gather * (1 - dissolve) * 0.9)

            if burst > 0 && burst < 1 { Sparks(k: burst) }

            if ring > 0 && ring < 1 {
                Circle()
                    .strokeBorder(AngularGradient(colors: Prism.colors, center: .center), lineWidth: 10 * (1 - ring) + 1)
                    .frame(width: lens, height: lens)
                    .scaleEffect(1 + 3.2 * Self.easeOut(ring))
                    .blur(radius: 3 + 6 * ring)
                    .opacity(0.8 * (1 - ring))
                    .blendMode(.plusLighter)
            }

            if flash > 0 && flash < 1 {
                LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 60, height: 240)
                    .rotationEffect(.degrees(24))
                    .offset(x: -160 + 320 * Self.ease(flash))
                    .blendMode(.plusLighter)
                    .mask(Circle().frame(width: lens, height: lens))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// The orbiting drops, each with a prismatic rim and a highlight split into red, green and blue.
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
                        .overlay { SplitHighlight(angle: a, size: d).opacity(1 - gather) }
                        .overlay {
                            Circle()
                                .strokeBorder(AngularGradient(colors: Prism.colors, center: .center), lineWidth: 1.5)
                                .rotationEffect(.radians(-a * 1.5))
                                .blur(radius: 0.8)
                                .opacity(0.55 * (1 - gather))
                                .blendMode(.plusLighter)
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

enum Prism {
    static let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red]
}

/// A drop of liquid glass (frosted material before iOS 26).
private struct GlassDrop: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.05)), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// The screen-shaped glass the lens becomes.
private struct GlassPane: View {
    let cornerRadius: CGFloat
    var body: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial)
        }
    }
}

/// A rainbow edge (the glass splitting light), slowly turning; red, green and blue copies a hair apart.
private struct PrismRim: View {
    let cornerRadius: CGFloat
    let spin: Double
    let width: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(AngularGradient(colors: Prism.colors, center: .center, angle: .degrees(spin * 70)), lineWidth: width)
                .blur(radius: 1.5)
            shape.strokeBorder(Color.red.opacity(0.6), lineWidth: 1).offset(x: -1.6, y: -0.6)
            shape.strokeBorder(Color.blue.opacity(0.6), lineWidth: 1).offset(x: 1.6, y: 0.6)
        }
        .blendMode(.plusLighter)
    }
}

/// A drop's highlight split into red, green and blue (chromatic dispersion), turning with the drop.
private struct SplitHighlight: View {
    let angle: Double
    let size: CGFloat

    var body: some View {
        let arc = Circle().trim(from: 0.06, to: 0.2)
        let off = size * 0.025
        ZStack {
            arc.stroke(Color.red, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round)).offset(x: -off)
            arc.stroke(Color.green, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
            arc.stroke(Color.blue, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round)).offset(x: off)
        }
        .padding(size * 0.14)
        .rotationEffect(.radians(angle * 0.6 + .pi))
        .blur(radius: size * 0.02)
        .blendMode(.plusLighter)
        .opacity(0.75)
    }
}

/// Prismatic sparks flying out of the lens and fading (`k` 0 → 1).
private struct Sparks: View {
    let k: Double

    var body: some View {
        let e = 1 - pow(1 - k, 3)
        ZStack {
            ForEach(0..<36, id: \.self) { i in
                let a = Double(i) * 2.399963 // the golden angle: spread evenly, never in rows
                let dist = (90 + Double((i * 37) % 120)) * e
                let hue = Double(i) / 36
                Circle()
                    .fill(Color(hue: hue, saturation: 0.75, brightness: 1))
                    .frame(width: 3 + CGFloat(i % 4), height: 3 + CGFloat(i % 4))
                    .blur(radius: 0.6)
                    .shadow(color: Color(hue: hue, saturation: 0.9, brightness: 1), radius: 4)
                    .offset(x: CGFloat(cos(a) * dist), y: CGFloat(sin(a) * dist))
                    .opacity((1 - k) * (i % 3 == 0 ? 1 : 0.7))
            }
        }
        .blendMode(.plusLighter)
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

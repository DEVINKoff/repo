import Observation
import UIKit
import SwiftUI

/// The accent colours on offer (light / dark variants) and the appearance.
enum AccentChoice: String, CaseIterable, Identifiable {
    case adaptive, indigo, ocean, mint, lime, sun, coral, rose, violet, mono
    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive: "Адаптивный"
        case .indigo: "Индиго"
        case .ocean: "Океан"
        case .mint: "Мята"
        case .lime: "Лайм"
        case .sun: "Солнце"
        case .coral: "Коралл"
        case .rose: "Роза"
        case .violet: "Фиалка"
        case .mono: "Моно"
        }
    }

    private var hex: (light: UInt32, dark: UInt32) {
        switch self {
        // calmer, richer tones: each a little deeper in the light theme and a little brighter in the dark one
        case .adaptive, .indigo: (0x5856D6, 0x8A87FF)
        case .ocean: (0x1677E8, 0x5AA9FF)
        case .mint: (0x0E9F8E, 0x5FE3CB)
        case .lime: (0x4C9A2A, 0x9BE15D)
        case .sun: (0xD9860B, 0xFFC857)
        case .coral: (0xE8505B, 0xFF8A80)
        case .rose: (0xD63A7A, 0xFF7EB3)
        case .violet: (0x9446D6, 0xC79BFF)
        case .mono: (0x1C1C1E, 0xE8E8ED)
        }
    }

    /// Text and icons on the accent: black on a light one (Моно in the dark theme, a pale adaptive colour), else white.
    @MainActor var onColor: Color {
        if self == .adaptive, let seed = AppTheme.shared.adaptiveSeed {
            return Color(UIColor { AccentChoice.adaptive(seed, $0.userInterfaceStyle == .dark).luminance > 0.62 ? .black : .white })
        }
        guard self == .mono else { return .white }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    }

    @MainActor var color: Color {
        if self == .adaptive, let seed = AppTheme.shared.adaptiveSeed {
            return Color(UIColor { AccentChoice.adaptive(seed, $0.userInterfaceStyle == .dark) })
        }
        let (l, d) = hex
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: d) : UIColor(hex: l) })
    }

    /// The cover's colour made fit for an accent: vivid enough, light enough on dark and dark enough on light.
    nonisolated static func adaptive(_ seed: (h: CGFloat, s: CGFloat, b: CGFloat), _ dark: Bool) -> UIColor {
        let s = min(0.85, max(0.42, seed.s))
        let b = dark ? max(0.78, seed.b) : min(0.72, max(0.48, seed.b))
        return UIColor(hue: seed.h, saturation: s, brightness: b, alpha: 1)
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Как в системе" : self == .light ? "Светлое" : "Тёмное" }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}

@MainActor
@Observable
final class AppTheme {
    static let shared = AppTheme()
    var accent: AccentChoice { didSet { UserDefaults.standard.set(accent.rawValue, forKey: "theme.accent") } }
    var appearance: AppearanceChoice { didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "theme.appearance") } }
    /// Animated covers in the player (Apple Music motion artwork, when the album has one).
    var motionCovers: Bool { didSet { UserDefaults.standard.set(motionCovers, forKey: "theme.motion") } }
    /// «Адаптивный»: the hue, saturation and brightness of the playing track's cover (nil — not known yet: indigo).
    private(set) var adaptiveSeed: (h: CGFloat, s: CGFloat, b: CGFloat)?
    @ObservationIgnored private var adaptedURL: URL?

    /// The playing track's cover changed: its most vivid colour becomes the accent (a grey cover keeps the last one).
    func adapt(to url: URL?) async {
        guard accent == .adaptive, let url, url != adaptedURL else { return }
        adaptedURL = url
        guard let image = await ImageCache.shared.image(url, px: 128),
              let seed = await Task.detached(priority: .utility, operation: { Self.vivid(image) }).value else { return }
        withAnimation(.smooth(duration: 0.9)) { adaptiveSeed = seed }
    }

    /// The most vivid colour of an image: the average of its most saturated, not too dark pixels.
    nonisolated private static func vivid(_ image: UIImage) -> (h: CGFloat, s: CGFloat, b: CGFloat)? {
        guard let cg = image.cgImage else { return nil }
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var cands: [(score: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat, s: CGFloat, v: CGFloat)] = []
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = CGFloat(px[i]) / 255, g = CGFloat(px[i + 1]) / 255, b = CGFloat(px[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let v = mx, sat = mx > 0 ? (mx - mn) / mx : 0
            guard v > 0.18 else { continue }
            cands.append((sat * (0.4 + v), r, g, b, sat, v))
        }
        let top = cands.sorted { $0.score > $1.score }.prefix(max(8, cands.count / 7))
        guard !top.isEmpty, top.map(\.s).reduce(0, +) / CGFloat(top.count) > 0.18 else { return nil }
        let k = CGFloat(top.count)
        let c = UIColor(red: top.map(\.r).reduce(0, +) / k, green: top.map(\.g).reduce(0, +) / k, blue: top.map(\.b).reduce(0, +) / k, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    init() {
        let d = UserDefaults.standard
        accent = AccentChoice(rawValue: d.string(forKey: "theme.accent") ?? "") ?? .indigo
        appearance = AppearanceChoice(rawValue: d.string(forKey: "theme.appearance") ?? "") ?? .system
        motionCovers = d.object(forKey: "theme.motion") as? Bool ?? true
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The app's look: neutral surfaces, one accent, Liquid Glass for floating controls, wide type for headings.
enum Theme {
    /// The accent the user picked in «Ещё → Оформление» (views that read it redraw when it changes).
    @MainActor static var accent: Color { AppTheme.shared.accent.color }
    /// The accent as a soft diagonal gradient (a lighter top left): for the big buttons.
    @MainActor static var accentFill: LinearGradient {
        LinearGradient(colors: [accent.mix(with: .white, by: 0.18), accent, accent.mix(with: .black, by: 0.12)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Text and icons drawn on the accent (black on «Моно» in the dark theme, white otherwise).
    @MainActor static var onAccent: Color { AppTheme.shared.accent.onColor }
    /// Switches: «Моно» would draw a white knob on a white track, so they stay green there.
    @MainActor static var toggle: Color { AppTheme.shared.accent == .mono ? .green : accent }
    static let corner: CGFloat = 16
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
}

extension Font {
    /// Wide, heavy headings (the app's signature instead of Apple Music's large titles).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
}

/// A small, wide, secondary section title.
struct SectionTitle: View {
    var text: String
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 13, weight: .semibold).width(.expanded))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let action {
                Button("Все", action: action).font(.subheadline.weight(.medium)).tint(Theme.accent)
            }
        }
    }
}

/// Cards and tiles shrink a little under the finger and spring back.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

extension View {
    /// Cards in a sideways row ease in and out at the edges as they scroll.
    func shelfTransition() -> some View {
        scrollTransition(.interactive, axis: .horizontal) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.92)
                .opacity(phase.isIdentity ? 1 : 0.6)
        }
    }

    /// Rows fade and rise in as they come on screen.
    func rowTransition() -> some View {
        scrollTransition(.animated(.smooth(duration: 0.35))) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.55)
                .scaleEffect(phase.isIdentity ? 1 : 0.97, anchor: .leading)
                .offset(y: phase.value * 6)
        }
    }
}

/// Covers at a size that stays crisp on the lock screen and in the player.
enum HiRes {
    static func cover(_ s: String?, size: Int = 1200) -> String? {
        guard var s, !s.isEmpty else { return s }
        if s.contains("/api/nd/cover/") {
            if let r = s.range(of: #"size=\d+"#, options: .regularExpression) { s.replaceSubrange(r, with: "size=\(size)") }
            else { s += (s.contains("?") ? "&" : "?") + "size=\(size)" }
            return s
        }
        // Deezer: …/images/cover/<md5>/250x250-000000-80-0-0.jpg
        if s.contains("dzcdn.net"), let r = s.range(of: #"/\d+x\d+-"#, options: .regularExpression) {
            s.replaceSubrange(r, with: "/\(size)x\(size)-")
            return s
        }
        // Yandex avatars: …/200x200
        if s.contains("avatars.yandex.net"), let r = s.range(of: #"/\d+x\d+$"#, options: .regularExpression) {
            s.replaceSubrange(r, with: "/1000x1000")
            return s
        }
        return s
    }
}

/// Fades out while blurring (and back in sharpening): the app's transition for content that swaps in place.
struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.blur(radius: active ? 14 : 0).opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition { .modifier(active: BlurFade(active: true), identity: BlurFade(active: false)) }
}

extension UIColor {
    /// Relative luminance (0 black … 1 white).
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

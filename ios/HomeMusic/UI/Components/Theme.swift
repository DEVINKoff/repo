import Observation
import UIKit
import SwiftUI

/// The accent colours on offer (light / dark variants) and the appearance.
enum AccentChoice: String, CaseIterable, Identifiable {
    case indigo, ocean, mint, lime, sun, coral, rose, violet, mono
    var id: String { rawValue }

    var title: String {
        switch self {
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
        case .indigo: (0x5B4BFF, 0x8C82FF)
        case .ocean: (0x0A84FF, 0x4FA8FF)
        case .mint: (0x00A88F, 0x3EE0C0)
        case .lime: (0x5E9E00, 0xA6E22E)
        case .sun: (0xE08A00, 0xFFC233)
        case .coral: (0xF0533A, 0xFF7A63)
        case .rose: (0xE0336E, 0xFF6B9A)
        case .violet: (0x9B3FE0, 0xC384FF)
        case .mono: (0x1C1C1E, 0xF2F2F7)
        }
    }

    var color: Color {
        let (l, d) = hex
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: d) : UIColor(hex: l) })
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

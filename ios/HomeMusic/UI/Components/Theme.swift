import SwiftUI

/// The app's look: neutral surfaces, one accent, Liquid Glass for floating controls, wide type for headings.
enum Theme {
    static let accent = Color("AccentColor")
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
                .opacity(phase.isIdentity ? 1 : 0.4)
                .offset(y: phase.value * 8)
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

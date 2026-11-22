import SwiftUI

// Liquid Glass helpers. On iOS 26+ these use the real glass APIs;
// on older iOS (or with the in-app toggle off) they fall back to blur material.

extension View {
    @ViewBuilder
    func glassCard(_ enabled: Bool, cornerRadius: CGFloat = 26, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if enabled {
                self.glassEffect(Glass.regular.tint(tint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    func glassButton(_ enabled: Bool, prominent: Bool = false, tint: Color = .blue) -> some View {
        modifier(GlassButtonModifier(enabled: enabled, prominent: prominent, tint: tint))
    }
}

struct GlassButtonModifier: ViewModifier {
    let enabled: Bool
    let prominent: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if enabled { glassBody(content) } else { fallback(content) }
        } else {
            fallback(content)
        }
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private func glassBody(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent).tint(tint)
        } else {
            content.buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).tint(tint)
        } else {
            content.buttonStyle(.bordered).tint(.white)
        }
    }
}

/// iOS 26-only playground: morphing glass blobs plus regular / clear / tinted samples.
@available(iOS 26.0, *)
struct GlassShowcase: View {
    @Namespace private var ns
    @State private var expanded = false
    private let extras = ["sparkles", "bolt.fill", "star.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tap the drop — glass blobs morph in and out")
                .font(.caption)
                .opacity(0.85)

            GlassEffectContainer(spacing: 24) {
                HStack(spacing: 14) {
                    Button {
                        withAnimation(.bouncy(duration: 0.5)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "xmark" : "drop.fill")
                            .font(.title2.weight(.semibold))
                            .frame(width: 60, height: 60)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(Glass.regular.interactive(), in: Circle())
                    .glassEffectID("drop", in: ns)

                    if expanded {
                        ForEach(extras, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.title2)
                                .frame(width: 60, height: 60)
                                .glassEffect(Glass.regular.tint(.cyan.opacity(0.45)).interactive(), in: Circle())
                                .glassEffectID(symbol, in: ns)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                sample("Regular", Glass.regular)
                sample("Clear", Glass.clear)
                sample("Tinted", Glass.regular.tint(.pink.opacity(0.6)))
            }
        }
    }

    private func sample(_ title: String, _ glass: Glass) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .glassEffect(glass.interactive(), in: Capsule())
    }
}

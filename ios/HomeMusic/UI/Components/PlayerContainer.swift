import SwiftUI

/// How far the full player is being pulled down (0 — open, 1 — at the bottom): the player shrinks its cover toward
/// the mini player and dims its controls as it goes.
struct PlayerPullKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var playerPull: CGFloat {
        get { self[PlayerPullKey.self] }
        set { self[PlayerPullKey.self] = newValue }
    }
}

/// The full player as the app's own layer (not a system sheet), so the way it goes is ours: it rises from the bottom;
/// pulled down by its header or its cover it follows the finger — the card rounds its corners and draws back, the
/// cover shrinks toward the mini player, the rest dims — and, let go far or fast enough, slides away into the mini
/// player (else it springs back).
struct PlayerContainer: View {
    @Environment(AppModel.self) private var app
    @State private var pull: CGFloat = 0
    @State private var closing = false

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            let full = CGSize(width: outer.size.width + insets.leading + insets.trailing,
                              height: outer.size.height + insets.top + insets.bottom)
            let p = min(1, max(0, pull / max(full.height, 1)))
            ZStack(alignment: .top) {
                // what is behind darkens while the player is up, and clears as it goes
                Color.black.opacity(0.4 * (1 - min(1, p * 1.6)))
                    .allowsHitTesting(false)
                PlayerView(close: close)
                    .environment(\.playerPull, p)
                    // the card fills the screen; its content keeps clear of the notch and the home indicator
                    .safeAreaPadding(EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing))
                    .frame(width: full.width, height: full.height)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 44 * min(1, p * 5), style: .continuous))
                    .scaleEffect(1 - 0.07 * min(1, p * 2.5), anchor: .top)
                    .offset(y: pull)
                    .shadow(color: .black.opacity(0.3 * min(1, p * 5)), radius: 30)
                    .simultaneousGesture(dragToClose(full.height), including: .all)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
        }
        .transition(.move(edge: .bottom))
    }

    /// The pull: only a mostly vertical, downward drag that starts on a handle (the header or the cover) — the views
    /// mark those with `PlayerHandle`.
    private func dragToClose(_ h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { v in
                guard !closing, PlayerHandle.active, v.translation.height > 0,
                      abs(v.translation.height) > abs(v.translation.width) else { return }
                // a little resistance at the start, then 1:1
                pull = v.translation.height
            }
            .onEnded { v in
                guard PlayerHandle.active else { return }
                PlayerHandle.active = false
                guard pull > 0 else { return }
                let fast = v.predictedEndTranslation.height - v.translation.height > 220
                if pull > h * 0.22 || (fast && pull > 30) {
                    close()
                } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { pull = 0 }
                }
            }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        Haptics.soft(0.5)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.92)) {
            pull = UIScreen.main.bounds.height
        } completion: {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { app.playerOpen = false }
            pull = 0
            closing = false
        }
    }
}

/// Where a pull-down may start: the header, the cover, the compact title row. Set on touch-down there; a drag
/// elsewhere (the lyrics, the queue, the progress line) scrolls or scrubs as usual.
@MainActor
enum PlayerHandle {
    static var active = false
}

extension View {
    /// Makes this part of the player a handle for pulling it down.
    func playerHandle() -> some View {
        simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in PlayerHandle.active = true }
            // after the player's own gesture has seen the end of this touch
            .onEnded { _ in DispatchQueue.main.async { PlayerHandle.active = false } })
    }
}

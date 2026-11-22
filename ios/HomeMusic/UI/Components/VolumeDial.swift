import AVFoundation
import MediaPlayer
import SwiftUI

/// The device volume, watched (the hardware buttons) and set (turning the dial) through a hidden system volume
/// view — which also keeps the system's own volume popup away while it is on screen.
@MainActor
@Observable
final class VolumeWatch {
    static let shared = VolumeWatch()
    private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    /// bumped on every change from outside (the buttons): the dial shows itself
    private(set) var changes = 0
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored weak var slider: UISlider?
    @ObservationIgnored private var settingUntil = Date.distantPast

    func start() {
        guard observation == nil else { return }
        level = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, _ in
            let v = session.outputVolume
            Task { @MainActor in
                let w = VolumeWatch.shared
                w.level = v
                if Date() > w.settingUntil { w.changes += 1 }
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    func set(_ v: Float) {
        let v = min(1, max(0, v))
        settingUntil = Date().addingTimeInterval(0.3)
        level = v
        slider?.setValue(v, animated: false)
        slider?.sendActions(for: .valueChanged)
    }
}

/// An invisible system volume view: while it is in the window, iOS shows no volume popup of its own.
struct SystemVolumeHider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        v.alpha = 0.0001
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            VolumeWatch.shared.slider = v.subviews.compactMap { $0 as? UISlider }.first
        }
        return v
    }

    func updateUIView(_ v: MPVolumeView, context: Context) {
        if VolumeWatch.shared.slider == nil {
            VolumeWatch.shared.slider = v.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}

/// The cinematic mode's volume: a glass dial in the corner with a ring of ticks, the level as an arc and a knob.
/// It appears when the volume changes and fades a moment later; turning it with a finger sets the volume.
struct VolumeDial: View {
    @Environment(VolumeWatch.self) private var watch
    @State private var shown = false
    @State private var dragging = false
    @State private var hide: Task<Void, Never>?
    @State private var lastStep = -1

    private let size: CGFloat = 84
    private let ticks = 27
    private static let start = 135.0 // degrees, clockwise from 3 o'clock: the bottom-left
    private static let sweep = 270.0

    var body: some View {
        let v = Double(watch.level)
        ZStack {
            Color.clear.modifier(DialGlass())
            ForEach(0..<ticks, id: \.self) { i in
                let f = Double(i) / Double(ticks - 1)
                let a = (Self.start + Self.sweep * f) * .pi / 180
                Capsule()
                    .fill(.white.opacity(f <= v + 0.001 ? 0.95 : 0.22))
                    .frame(width: 2, height: i % 13 == 0 ? 8 : 5)
                    .rotationEffect(.radians(a + .pi / 2))
                    .offset(x: cos(a) * size * 0.41, y: sin(a) * size * 0.41)
            }
            Circle()
                .trim(from: 0, to: 0.75 * v)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(Self.start))
                .frame(width: size * 0.62, height: size * 0.62)
                .shadow(color: Theme.accent.opacity(0.6), radius: 5)
            let ka = (Self.start + Self.sweep * v) * .pi / 180
            Circle().fill(.white)
                .frame(width: 9, height: 9)
                .shadow(color: .black.opacity(0.3), radius: 2)
                .offset(x: cos(ka) * size * 0.31, y: sin(ka) * size * 0.31)
            VStack(spacing: 1) {
                Image(systemName: v <= 0.001 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text("\(Int((v * 100).rounded()))")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .opacity(0.8)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.white)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            dragging = true
            show()
            let dx = g.location.x - size / 2, dy = g.location.y - size / 2
            var deg = atan2(dy, dx) * 180 / .pi - Self.start
            while deg < 0 { deg += 360 }
            if deg > Self.sweep { deg = deg > Self.sweep + (360 - Self.sweep) / 2 ? 0 : Self.sweep }
            let f = Float(deg / Self.sweep)
            watch.set(f)
            let step = Int(f * 16)
            if step != lastStep { lastStep = step; Haptics.select() }
        }.onEnded { _ in
            dragging = false
            scheduleHide()
        })
        .animation(.smooth(duration: 0.15), value: watch.level)
        .scaleEffect(shown ? 1 : 0.6, anchor: .topTrailing)
        .opacity(shown ? 1 : 0)
        .blur(radius: shown ? 0 : 8)
        .allowsHitTesting(shown)
        .onChange(of: watch.changes) { show(); scheduleHide() }
    }

    private func show() {
        guard !shown else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { shown = true }
    }

    private func scheduleHide() {
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, !dragging else { return }
            withAnimation(.smooth(duration: 0.45)) { shown = false }
        }
    }
}

private struct DialGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.25)), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

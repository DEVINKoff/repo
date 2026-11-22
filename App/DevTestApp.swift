import SwiftUI
import WidgetKit
import UIKit

@main
struct DevTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

enum Themes {
    static let all: [[Color]] = [
        [Color(red: 0.38, green: 0.20, blue: 0.95), Color(red: 0.05, green: 0.65, blue: 0.95), Color(red: 1.00, green: 0.45, blue: 0.70)],
        [Color(red: 0.98, green: 0.36, blue: 0.42), Color(red: 0.99, green: 0.70, blue: 0.25), Color(red: 0.55, green: 0.20, blue: 0.90)],
        [Color(red: 0.05, green: 0.75, blue: 0.55), Color(red: 0.10, green: 0.35, blue: 0.70), Color(red: 0.95, green: 0.90, blue: 0.30)],
        [Color(red: 0.12, green: 0.12, blue: 0.16), Color(red: 0.35, green: 0.10, blue: 0.45), Color(red: 0.10, green: 0.80, blue: 0.95)],
    ]
}

struct ContentView: View {
    @StateObject private var live = LiveActivityManager()
    @AppStorage("glassOn") private var glassOn = true
    @State private var count = 0
    @State private var theme = 0
    @State private var showAlert = false
    @State private var now = Date()
    @Environment(\.scenePhase) private var scenePhase

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            AnimatedBackground(colors: Themes.all[theme % Themes.all.count])
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    counterCard
                    glassSection
                    liveActivityCard
                    widgetCard
                    infoCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onReceive(clock) { now = $0 }
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { live.reattach() }
        }
        .alert("Hello from DevTest", isPresented: $showAlert) {
            Button("Reset", role: .destructive) { withAnimation { count = 0 } }
            Button("Nice", role: .cancel) {}
        } message: {
            Text("You've tapped \(count) times.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: count)
        .sensoryFeedback(.selection, trigger: theme)
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 6) {
            Text("It works! 🎉")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
            Text("Liquid Glass · Widgets · Dynamic Island")
                .font(.subheadline.weight(.medium))
                .opacity(0.85)
        }
        .padding(.top, 8)
    }

    private var counterCard: some View {
        VStack(spacing: 14) {
            Text("\(count)")
                .font(.system(size: 88, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(spacing: 10) {
                Button {
                    withAnimation(.bouncy) { count += 1 }
                } label: {
                    Label("Tap me", systemImage: "hand.tap.fill").frame(maxWidth: .infinity)
                }
                .glassButton(glassOn, prominent: true, tint: .blue)

                Button {
                    withAnimation(.easeInOut(duration: 0.6)) { theme += 1 }
                } label: {
                    Label("Colors", systemImage: "paintpalette.fill").frame(maxWidth: .infinity)
                }
                .glassButton(glassOn)

                Button {
                    showAlert = true
                } label: {
                    Image(systemName: "bell.fill")
                }
                .glassButton(glassOn)
            }
            .controlSize(.large)
            .font(.headline)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard(glassOn)
    }

    private var glassSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $glassOn.animation(.easeInOut)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Liquid Glass", systemImage: "drop.halffull").font(.headline)
                    Text(glassStatus).font(.caption).opacity(0.8)
                }
            }
            .tint(.cyan)

            if #available(iOS 26.0, *) {
                if glassOn { GlassShowcase() }
            }
        }
        .padding(20)
        .glassCard(glassOn)
    }

    private var glassStatus: String {
        if #available(iOS 26.0, *) {
            return glassOn ? "On: real iOS 26 glass" : "Off: classic blur material"
        }
        return "Needs iOS 26, showing blur fallback"
    }

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Dynamic Island", systemImage: "capsule.fill").font(.headline)
            Text(live.isRunning
                 ? "Live Activity running, count \(live.count). Go home to see the island; long-press it for +1 / End."
                 : "Start a Live Activity, then swipe home or lock your phone.")
                .font(.subheadline)
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button { live.start() } label: { Text("Start").frame(maxWidth: .infinity) }
                    .glassButton(glassOn, prominent: true, tint: .green)
                    .disabled(live.isRunning)
                Button { live.bump() } label: { Text("+1").frame(maxWidth: .infinity) }
                    .glassButton(glassOn)
                    .disabled(!live.isRunning)
                Button { live.end() } label: { Text("End").frame(maxWidth: .infinity) }
                    .glassButton(glassOn, prominent: true, tint: .red)
                    .disabled(!live.isRunning)
            }
            .controlSize(.large)
            .font(.headline)

            if !live.message.isEmpty {
                Text(live.message).font(.caption).opacity(0.8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glassOn)
    }

    private var widgetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Widgets", systemImage: "square.grid.2x2.fill").font(.headline)
            Text("Long-press the Home Screen, tap Edit, then Add Widget, and search \"DevTest\". There are small, medium and Lock Screen sizes, and the +1 button works right on the widget.")
                .font(.subheadline)
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                WidgetCenter.shared.reloadAllTimelines()
            } label: {
                Label("Refresh widgets", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .glassButton(glassOn)
            .controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glassOn)
    }

    private var infoCard: some View {
        let device = UIDevice.current
        let level = device.batteryLevel
        let battery = level < 0 ? "n/a" : "\(Int(level * 100))%"
        let px = UIScreen.main.nativeBounds.size

        return VStack(spacing: 4) {
            Text("\(DeviceInfo.model) · \(device.systemName) \(device.systemVersion)")
            Text("\(Int(px.width))×\(Int(px.height)) px · battery \(battery)")
            Text(now.formatted(date: .omitted, time: .standard))
        }
        .font(.system(.footnote, design: .monospaced))
        .opacity(0.9)
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassCard(glassOn, cornerRadius: 20)
    }
}

/// Moving blurred blobs so the glass has something to refract.
struct AnimatedBackground: View {
    let colors: [Color]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: [colors[0], colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(colors[2])
                    .frame(width: 280, height: 280)
                    .blur(radius: 50)
                    .offset(x: CGFloat(sin(t * 0.5)) * 120, y: CGFloat(cos(t * 0.4)) * 240)
                Circle()
                    .fill(colors[0])
                    .frame(width: 220, height: 220)
                    .blur(radius: 40)
                    .offset(x: CGFloat(cos(t * 0.6)) * 140, y: CGFloat(sin(t * 0.3)) * 260 + 120)
            }
        }
    }
}

enum DeviceInfo {
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DevTestWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TapWidget()
        DevTestLiveActivity()
    }
}

// MARK: - Home / Lock Screen widget

/// Stored in the widget extension's own defaults; interactive buttons run in the extension.
enum WidgetStore {
    static let key = "widgetTaps"
    static var taps: Int {
        get { UserDefaults.standard.integer(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

struct TapWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Tap DevTest widget"
    func perform() async throws -> some IntentResult {
        WidgetStore.taps += 1
        return .result()
    }
}

struct ResetWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset DevTest widget"
    func perform() async throws -> some IntentResult {
        WidgetStore.taps = 0
        return .result()
    }
}

struct TapEntry: TimelineEntry {
    let date: Date
    let taps: Int
    let theme: Int
}

struct TapProvider: TimelineProvider {
    func placeholder(in context: Context) -> TapEntry {
        TapEntry(date: Date(), taps: 0, theme: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (TapEntry) -> Void) {
        completion(TapEntry(date: Date(), taps: WidgetStore.taps, theme: 0))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TapEntry>) -> Void) {
        // New colour every 15 minutes so you can see the timeline advancing.
        let now = Date()
        let taps = WidgetStore.taps
        let entries = (0..<4).map { i in
            TapEntry(date: now.addingTimeInterval(Double(i) * 900), taps: taps, theme: i)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

private let widgetThemes: [[Color]] = [
    [Color(red: 0.38, green: 0.20, blue: 0.95), Color(red: 0.05, green: 0.65, blue: 0.95)],
    [Color(red: 0.98, green: 0.36, blue: 0.42), Color(red: 0.99, green: 0.70, blue: 0.25)],
    [Color(red: 0.05, green: 0.75, blue: 0.55), Color(red: 0.10, green: 0.35, blue: 0.70)],
    [Color(red: 0.20, green: 0.15, blue: 0.30), Color(red: 0.45, green: 0.15, blue: 0.55)],
]

struct TapWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TapEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "hand.tap.fill").font(.caption2)
                    Text("\(entry.taps)").font(.title3.bold()).monospacedDigit()
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("DevTest", systemImage: "sparkles").font(.headline)
                Text("\(entry.taps) widget taps").monospacedDigit()
                Text(entry.date, style: .time).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text("DevTest · \(entry.taps) taps")
        case .systemMedium:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("DevTest", systemImage: "sparkles").font(.headline)
                    Text("\(entry.taps)")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Updated \(entry.date, style: .time)").font(.caption).opacity(0.8)
                }
                Spacer()
                VStack(spacing: 10) {
                    Button(intent: TapWidgetIntent()) {
                        Label("+1", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    Button(intent: ResetWidgetIntent()) {
                        Label("Reset", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                }
                .frame(width: 110)
                .tint(.white)
            }
            .foregroundStyle(.white)
        default:
            VStack(spacing: 6) {
                Text("\(entry.taps)")
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Button(intent: TapWidgetIntent()) {
                    Label("+1", systemImage: "hand.tap.fill")
                }
                .tint(.white)
            }
            .foregroundStyle(.white)
        }
    }
}

struct TapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DevTestTapWidget", provider: TapProvider()) { entry in
            TapWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    let c = widgetThemes[entry.theme % widgetThemes.count]
                    LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("DevTest Tapper")
        .description("Interactive test widget: tap +1 right on the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Live Activity / Dynamic Island

struct CountdownText: View {
    let end: Date
    var body: some View {
        if end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
        } else {
            Text("0:00")
        }
    }
}

struct LockScreenLiveView: View {
    let state: DevTestActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("DevTest · \(state.status)").font(.headline)
                HStack(spacing: 6) {
                    Text("Count \(state.count)").monospacedDigit()
                    Text("·")
                    CountdownText(end: state.endDate).monospacedDigit()
                }
                .font(.subheadline)
                .opacity(0.85)
            }
            Spacer()
            Button(intent: BumpActivityIntent()) {
                Image(systemName: "plus")
            }
            .tint(.cyan)
            Button(intent: EndActivityIntent()) {
                Image(systemName: "xmark")
            }
            .tint(.red)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

struct DevTestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DevTestActivityAttributes.self) { context in
            LockScreenLiveView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.count)", systemImage: "hand.tap.fill")
                        .font(.title2.bold())
                        .monospacedDigit()
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(end: context.state.endDate)
                        .font(.title2.monospacedDigit())
                        .frame(width: 72)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Button(intent: BumpActivityIntent()) {
                            Label("+1", systemImage: "plus").frame(maxWidth: .infinity)
                        }
                        .tint(.cyan)
                        Button(intent: EndActivityIntent()) {
                            Label("End", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(.cyan)
            } compactTrailing: {
                Text("\(context.state.count)")
                    .monospacedDigit()
                    .foregroundStyle(.cyan)
            } minimal: {
                Text("\(context.state.count)")
                    .monospacedDigit()
                    .foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }
}

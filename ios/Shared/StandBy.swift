// Shared by the app and the StandBy widget: the playing track as the widget shows it (in the App Group container)
// and the widget's buttons.
import AppIntents
import Foundation
import WidgetKit

enum StandBy {
    static let group = "group.app.homemusic.ios"
    static let kind = "HomeMusicStandBy"

    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }
    static var stateURL: URL? { container?.appendingPathComponent("standby.json") }
    static var coverURL: URL? { container?.appendingPathComponent("standby-cover.jpg") }

    struct LyricLine: Codable, Hashable { var time: Double; var text: String }

    struct State: Codable {
        var ref: String
        var title: String
        var artist: String
        var playing: Bool
        /// where the track was at `at`
        var position: Double
        var duration: Double
        var at: Date
        /// time-synced lines (nil: none found yet)
        var lyrics: [LyricLine]?

        /// The moment the track's 0:00 was (or would be) — the timeline counts from it.
        var startDate: Date { at.addingTimeInterval(-position) }
    }

    static func read() -> State? {
        guard let url = stateURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func write(_ s: State?) {
        guard let url = stateURL else { return }
        if let s, let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
    }

    /// The widget shows the lyrics (the 💬 button) instead of the progress.
    static var showLyrics: Bool {
        get { defaults?.object(forKey: "standby-lyrics") as? Bool ?? true }
        set { defaults?.set(newValue, forKey: "standby-lyrics") }
    }

    static func reload() { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
}

enum StandByCommand: Sendable { case playPause, next, previous }

/// The app registers what the buttons do; audio-playback intents run in the app's own process.
enum IntentRelay {
    nonisolated(unsafe) static var handler: (@Sendable (StandByCommand) async -> Void)?
}

struct PlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Пауза / играть"
    func perform() async throws -> some IntentResult {
        await IntentRelay.handler?(.playPause)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Следующий трек"
    func perform() async throws -> some IntentResult {
        await IntentRelay.handler?(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Предыдущий трек"
    func perform() async throws -> some IntentResult {
        await IntentRelay.handler?(.previous)
        return .result()
    }
}

/// 💬: lyrics or the progress in the widget (the widget's own setting).
struct ToggleLyricsIntent: AppIntent {
    static let title: LocalizedStringResource = "Текст песни"
    func perform() async throws -> some IntentResult {
        StandBy.showLyrics.toggle()
        StandBy.reload()
        return .result()
    }
}

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

@main
struct HomeMusicWidgets: WidgetBundle {
    var body: some Widget { StandByWidget() }
}

struct StandByEntry: TimelineEntry {
    let date: Date
    let state: StandBy.State?
    /// the lyric line playing at `date`
    let line: Int?
    let showLyrics: Bool
}

/// One entry now, then one at every lyric line of the next ten minutes: the widget steps through the lyrics on time
/// without the app waking it; the app reloads it when the track, a pause or a seek changes the plan.
struct StandByProvider: TimelineProvider {
    func placeholder(in context: Context) -> StandByEntry {
        StandByEntry(date: Date(), state: StandBy.State(ref: "", title: "HomeMusic", artist: "Моя волна", playing: false,
                                                        position: 0, duration: 180, at: Date(), lyrics: nil),
                     line: nil, showLyrics: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (StandByEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StandByEntry>) -> Void) {
        let now = Date()
        let state = StandBy.read()
        let show = StandBy.showLyrics
        var entries = [entry(at: now, state: state, show: show)]
        if let s = state, s.playing, show, let lyrics = s.lyrics, !lyrics.isEmpty {
            let start = s.startDate
            for (i, l) in lyrics.enumerated() {
                let d = start.addingTimeInterval(l.time)
                if d > now && d < now.addingTimeInterval(600) {
                    entries.append(StandByEntry(date: d, state: s, line: i, showLyrics: show))
                }
                if entries.count >= 120 { break }
            }
        }
        var policy: TimelineReloadPolicy = .never
        if let s = state, s.playing, s.duration > 0 {
            policy = .after(max(now.addingTimeInterval(5), s.startDate.addingTimeInterval(s.duration + 1)))
        }
        completion(Timeline(entries: entries, policy: policy))
    }

    private func entry(at date: Date, state: StandBy.State? = StandBy.read(), show: Bool = StandBy.showLyrics) -> StandByEntry {
        var line: Int?
        if let s = state, let lyrics = s.lyrics {
            let t = s.playing ? date.timeIntervalSince(s.startDate) : s.position
            line = lyrics.lastIndex { $0.time <= t + 0.2 }
        }
        return StandByEntry(date: date, state: state, line: line, showLyrics: show)
    }
}

struct StandByView: View {
    let entry: StandByEntry
    @Environment(\.widgetFamily) private var family

    private let accent = Color(red: 0.55, green: 0.51, blue: 1.0)

    var body: some View {
        if let s = entry.state {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    cover.frame(width: family == .systemSmall ? 34 : 44, height: family == .systemSmall ? 34 : 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Text(s.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                middle(s)
                Spacer(minLength: 4)
                controls(s)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "music.note.house.fill").font(.title2).foregroundStyle(accent)
                Text("HomeMusic").font(.headline)
                Text("Включите музыку в приложении").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(intent: PlayPauseIntent()) { Label("Играть", systemImage: "play.fill").font(.caption.weight(.semibold)) }
                    .tint(accent)
            }
        }
    }

    @ViewBuilder private var cover: some View {
        if let url = StandBy.coverURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.3))
                .overlay(Image(systemName: "music.note").foregroundStyle(.white))
        }
    }

    @ViewBuilder private func middle(_ s: StandBy.State) -> some View {
        if entry.showLyrics, let lyrics = s.lyrics, !lyrics.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.line.map { lyrics[$0].text.isEmpty ? "♪" : lyrics[$0].text } ?? "♪")
                    .font(.system(size: family == .systemSmall ? 17 : 21, weight: .heavy))
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                if let i = entry.line, i + 1 < lyrics.count {
                    Text(lyrics[i + 1].text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if s.duration > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if s.playing {
                    ProgressView(timerInterval: s.startDate...s.startDate.addingTimeInterval(s.duration), countsDown: false,
                                 label: { EmptyView() }, currentValueLabel: { EmptyView() })
                        .tint(accent)
                    Text(timerInterval: s.startDate...s.startDate.addingTimeInterval(s.duration), countsDown: false)
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: min(s.position, s.duration), total: s.duration).tint(accent)
                    Text("На паузе").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        } else if s.lyrics == nil && entry.showLyrics {
            Text("Ищем текст…").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(s.playing ? "Играет" : "На паузе").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func controls(_ s: StandBy.State) -> some View {
        HStack {
            Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
            Spacer(minLength: 0)
            Button(intent: PlayPauseIntent()) {
                Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .bold))
            }
            Spacer(minLength: 0)
            Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
            Spacer(minLength: 0)
            Button(intent: ToggleLyricsIntent()) {
                Image(systemName: "quote.bubble.fill").foregroundStyle(entry.showLyrics ? accent : .secondary)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .semibold))
    }
}

/// A player for StandBy: the track, its lyrics line by line (or the progress), ⏮ ⏯ ⏭ and 💬. It is kept out of the
/// Home Screen gallery: the Lock Screen and the Dynamic Island keep the system player.
struct StandByWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StandBy.kind, provider: StandByProvider()) { entry in
            StandByView(entry: entry)
                // a tap outside the buttons opens the app on its player
                .widgetURL(URL(string: "homemusic://player"))
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.07, green: 0.06, blue: 0.12), .black], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("HomeMusic — режим ожидания")
        .description("Трек, текст песни по строкам и кнопки управления для StandBy.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .disfavoredLocations([.homeScreen], for: [.systemSmall, .systemMedium])
    }
}

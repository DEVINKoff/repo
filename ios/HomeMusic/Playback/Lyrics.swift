import Foundation
import Observation
import SwiftUI

/// Lyrics of the playing track from LRCLIB (lrclib.net — a free, open lyrics database): time-synced LRC when it has
/// them, plain text otherwise. Asked from the phone directly; the Hub is not involved.
@MainActor
@Observable
final class Lyrics {
    static let shared = Lyrics()

    struct Word: Hashable { let text: String; let start: Double; let end: Double }
    struct Line: Identifiable, Hashable {
        let id: Int
        let time: Double
        let text: String
        /// per word: from the enhanced LRC «<mm:ss.xx>» stamps, else spread over the line by length
        var words: [Word] = []
        var end: Double = 0
    }

    enum State: Equatable {
        case idle, loading
        case synced([Line])
        case plain(String)
        case instrumental
        case missing
    }

    private(set) var state: State = .idle
    private(set) var ref: String?
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Loads the lyrics of `t` (once per track; kept for the session).
    func load(for t: QueueTrack?) {
        guard let t else { state = .idle; ref = nil; return }
        guard t.ref != ref else { return }
        ref = t.ref
        if let hit = cache[t.ref] { state = hit; StandByFeed.update(Player.shared); return }
        state = .loading
        task?.cancel()
        let key = t.ref
        task = Task {
            let result = await Self.fetch(artist: t.artist, title: t.title, album: t.album, duration: t.durationS)
            guard !Task.isCancelled else { return }
            cache[key] = result
            if ref == key {
                withAnimation(.smooth) { state = result }
                StandByFeed.update(Player.shared)
            }
        }
    }

    /// The line playing at `position` (a hair early, as the eye reads ahead).
    static func current(_ lines: [Line], at position: Double) -> Int? {
        var found: Int?
        for l in lines {
            if l.time <= position + 0.25 { found = l.id } else { break }
        }
        return found
    }

    // MARK: LRCLIB

    private struct Record: Decodable {
        var syncedLyrics: String?
        var plainLyrics: String?
        var instrumental: Bool?
        var duration: Double?
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.httpAdditionalHeaders = ["User-Agent": "HomeMusic iOS \(AppInfo.version) (https://github.com/justman-1/HomeMusic-public)"]
        return URLSession(configuration: c)
    }()

    private static func get<T: Decodable>(_ path: String, _ query: [String: String?]) async -> T? {
        var c = URLComponents(string: "https://lrclib.net/api/" + path)!
        c.queryItems = query.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : URLQueryItem(name: k, value: $0) } }
        guard let url = c.url, let result = try? await session.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: result.0)
    }

    /// «Title (feat. X) [Remix]» → «Title»; «A, B» → «A» (LRCLIB names the main artist).
    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|при уч\.?)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func fetch(artist: String, title: String, album: String?, duration: Double?) async -> State {
        let mainArtist = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?.trimmingCharacters(in: .whitespaces) ?? artist
        var record: Record? = await get("get", [
            "artist_name": mainArtist, "track_name": title, "album_name": album,
            "duration": duration.map { String(Int($0.rounded())) },
        ])
        if record == nil || (record?.syncedLyrics == nil && record?.plainLyrics == nil && record?.instrumental != true) {
            let found: [Record]? = await get("search", ["track_name": clean(title), "artist_name": mainArtist])
            // the closest length first; synced ones win
            let ranked = (found ?? []).sorted { a, b in
                let da = abs((a.duration ?? 0) - (duration ?? 0)), db = abs((b.duration ?? 0) - (duration ?? 0))
                if (a.syncedLyrics != nil) != (b.syncedLyrics != nil) { return a.syncedLyrics != nil }
                return da < db
            }
            if let best = ranked.first(where: { duration == nil || abs(($0.duration ?? 0) - duration!) < 8 }) ?? ranked.first {
                record = best
            }
        }
        guard let r = record else { return .missing }
        if r.instrumental == true { return .instrumental }
        if let s = r.syncedLyrics {
            let lines = parse(s)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let p = r.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return .plain(p) }
        return .missing
    }

    /// LRC: «[mm:ss.xx] text» (several stamps on one line are several lines); enhanced LRC «<mm:ss.xx>word» keeps
    /// the time of every word.
    static func parse(_ lrc: String) -> [Line] {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        var rows: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches { rows.append((seconds(ns, m), text)) }
        }
        rows.sort { $0.0 < $1.0 }
        var lines: [Line] = []
        for (i, row) in rows.enumerated() {
            let next = i + 1 < rows.count ? rows[i + 1].0 : row.0 + 5
            lines.append(timed(id: i, start: row.0, nextStart: next, raw: row.1))
        }
        return lines
    }

    private static func seconds(_ ns: NSString, _ m: NSTextCheckingResult) -> Double {
        let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
        var frac = 0.0
        if m.range(at: 3).location != NSNotFound {
            let f = ns.substring(with: m.range(at: 3))
            frac = (Double(f) ?? 0) / pow(10, Double(f.count))
        }
        return min * 60 + sec + frac
    }

    private static let vowelSet = Set("аеёиоуыэюяaeiouyæøåäöü")
    static func vowels(_ w: String) -> Int { w.lowercased().filter { vowelSet.contains($0) }.count }

    /// The words of a line with their times. A long instrumental gap after a line is not sung: the line ends after
    /// about the time its words take.
    private static func timed(id: Int, start: Double, nextStart: Double, raw: String) -> Line {
        let wordStamp = try! NSRegularExpression(pattern: #"<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>"#)
        let ns = raw as NSString
        let marks = wordStamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        let plain = wordStamp.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let tokens = plain.split(separator: " ").map(String.init)
        let gap = max(0.3, nextStart - start)
        // syllables (vowels) decide how long a word is sung, not its letters
        let syllables = tokens.map { max(1, Self.vowels($0)) }
        let natural = Double(syllables.reduce(0, +)) * 0.21 + 0.15
        let end = start + min(gap * 0.95, max(0.8, natural))

        var words: [Word] = []
        if !marks.isEmpty {
            // enhanced LRC: each stamp opens the text up to the next stamp
            for (i, m) in marks.enumerated() {
                let from = m.range.location + m.range.length
                let to = i + 1 < marks.count ? marks[i + 1].range.location : ns.length
                let piece = ns.substring(with: NSRange(location: from, length: max(0, to - from))).trimmingCharacters(in: .whitespaces)
                let t0 = seconds(ns, m)
                let t1 = i + 1 < marks.count ? seconds(ns, marks[i + 1]) : end
                for w in piece.split(separator: " ") { words.append(Word(text: String(w), start: t0, end: max(t0 + 0.05, t1))) }
            }
        } else if !tokens.isEmpty {
            // spread over the line by syllables; vocals start a hair after the line's stamp
            let weights = syllables.map { Double($0) + 0.35 }
            let total = weights.reduce(0, +)
            let lead = min(0.12, (end - start) * 0.05)
            var t = start + lead
            for (w, weight) in zip(tokens, weights) {
                let d = (end - start - lead) * weight / total
                words.append(Word(text: w, start: t, end: t + d))
                t += d
            }
        }
        return Line(id: id, time: start, text: plain, words: words, end: end)
    }
}

/// The lyrics in the player: the playing line large and bright, the rest dimmed; it scrolls by itself (a finger on it
/// pauses that for a moment); a tap on a line seeks there.
struct LyricsView: View {
    @Environment(Player.self) private var player
    @Environment(Lyrics.self) private var lyrics
    @State private var userScrolledAt = Date.distantPast
    @State private var current: Int?

    var body: some View {
        Group {
            switch lyrics.state {
            case .synced(let lines): synced(lines)
            case .plain(let text):
                ScrollView {
                    Text(text).font(.title3.weight(.semibold)).lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)
            case .instrumental: placeholder("Инструментал", "music.note")
            case .missing: placeholder("Текст не найден", "text.badge.xmark")
            case .loading, .idle: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .onAppear { lyrics.load(for: player.track) }
        .onChange(of: player.track?.ref) { lyrics.load(for: player.track) }
    }

    private func placeholder(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle)
            Text(title).font(.headline)
        }
        .opacity(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func synced(_ lines: [Lyrics.Line]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // a plain VStack: every line keeps one measured height, so nothing shifts while the lyrics scroll
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 40)
                    ForEach(lines) { line in
                        LyricLine(line: line, isNow: line.id == current, passed: (current ?? -1) > line.id,
                                  far: abs(line.id - (current ?? line.id)) > 2)
                            .equatable()
                            .onTapGesture { player.seek(max(0, line.time - 0.05)) }
                            .id(line.id)
                    }
                    Color.clear.frame(height: 220)
                }
            }
            .scrollIndicators(.hidden)
            .background { LyricsClock(lines: lines, current: $current) }
            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in userScrolledAt = Date() })
            .onChange(of: current) { old, now in
                guard let now, Date().timeIntervalSince(userScrolledAt) > 3 else { return }
                if old == nil {
                    proxy.scrollTo(now, anchor: UnitPoint(x: 0, y: 0.3))
                } else {
                    withAnimation(.spring(response: 0.65, dampingFraction: 0.9)) { proxy.scrollTo(now, anchor: UnitPoint(x: 0, y: 0.3)) }
                }
            }
            .onChange(of: lyrics.state) { current = nil }
        }
    }
}

/// Reads the playback position (the only view of the lyrics that redraws on every tick) and moves `current`.
private struct LyricsClock: View {
    let lines: [Lyrics.Line]
    @Binding var current: Int?
    @Environment(Player.self) private var player

    var body: some View {
        let now = Lyrics.current(lines, at: player.position)
        Color.clear.onChange(of: now, initial: true) { _, v in
            if current != v { current = v }
        }
    }
}

/// One line of synced lyrics. Its words are laid out the same way whether it plays or not (only the colour and the
/// light change), so a line never reflows — or makes the lines below jump — when it starts.
struct LyricLine: View, Equatable {
    let line: Lyrics.Line
    let isNow: Bool
    let passed: Bool
    let far: Bool

    static func == (a: LyricLine, b: LyricLine) -> Bool {
        a.line.id == b.line.id && a.isNow == b.isNow && a.passed == b.passed && a.far == b.far
    }

    var body: some View {
        Group {
            if line.words.isEmpty {
                Text(line.text.isEmpty ? "♪" : line.text)
                    .font(LyricsStyle.font)
                    .foregroundStyle(Color.primary.opacity(isNow ? 1 : passed ? 0.28 : 0.38))
            } else if isNow {
                SungLine(line: line)
            } else {
                FlowLayout(spacing: LyricsStyle.wordSpacing, lineSpacing: LyricsStyle.lineSpacing) {
                    ForEach(Array(line.words.enumerated()), id: \.offset) { _, w in
                        Text(w.text).font(LyricsStyle.font)
                    }
                }
                .foregroundStyle(Color.primary.opacity(passed ? 0.28 : 0.38))
            }
        }
        .blur(radius: isNow ? 0 : far ? 1.4 : 0.5)
        .scaleEffect(isNow ? 1 : 0.95, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: isNow)
    }
}

enum LyricsStyle {
    static let font = Font.system(size: 30, weight: .heavy)
    static let wordSpacing: CGFloat = 9
    static let lineSpacing: CGFloat = 4
}

/// The playing line: each word fills with light as it is sung, lifts a little and glows; sung words stay lit.
struct SungLine: View {
    let line: Lyrics.Line
    @Environment(Player.self) private var player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !player.isPlaying)) { _ in
            let t = player.liveTime
            FlowLayout(spacing: LyricsStyle.wordSpacing, lineSpacing: LyricsStyle.lineSpacing) {
                ForEach(Array(line.words.enumerated()), id: \.offset) { _, w in
                    SungWord(word: w.text, progress: w.end > w.start ? min(1, max(0, (t - w.start) / (w.end - w.start))) : (t >= w.start ? 1 : 0))
                }
            }
        }
    }
}

struct SungWord: View {
    let word: String
    /// 0 — not reached, 1 — sung
    let progress: Double

    var body: some View {
        let active = progress > 0 && progress < 1
        Text(word)
            .font(LyricsStyle.font)
            .foregroundStyle(Color.primary.opacity(0.32))
            .overlay(alignment: .leading) {
                // the light sweeps through the word with a soft edge
                Text(word)
                    .font(LyricsStyle.font)
                    .foregroundStyle(.primary)
                    .mask(alignment: .leading) {
                        GeometryReader { g in
                            if progress >= 1 {
                                Rectangle()
                            } else if progress > 0 {
                                // a soft edge that never runs ahead of the sung part
                                LinearGradient(stops: [.init(color: .black, location: 0),
                                                       .init(color: .black, location: max(0, progress - 0.12)),
                                                       .init(color: .clear, location: progress)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: g.size.width)
                            }
                        }
                    }
            }
            .shadow(color: Color.primary.opacity(active ? 0.4 : 0), radius: active ? 10 : 0)
            .offset(y: active ? -2.5 * sin(progress * .pi) : 0)
            .scaleEffect(active ? 1 + 0.04 * sin(progress * .pi) : 1, anchor: .bottom)
    }
}

/// Words wrapped onto lines like text, but each one its own view (so each can animate).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += rowH + lineSpacing; x = 0; rowH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + lineSpacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

import Foundation
import Observation
import SwiftUI

/// Lyrics of the playing track from LRCLIB (lrclib.net — a free, open lyrics database): time-synced LRC when it has
/// them, plain text otherwise. Asked from the phone directly; the Hub is not involved.
@MainActor
@Observable
final class Lyrics {
    static let shared = Lyrics()

    struct Line: Identifiable, Hashable { let id: Int; let time: Double; let text: String }

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
        if let hit = cache[t.ref] { state = hit; return }
        state = .loading
        task?.cancel()
        let key = t.ref
        task = Task {
            let result = await Self.fetch(artist: t.artist, title: t.title, album: t.album, duration: t.durationS)
            guard !Task.isCancelled else { return }
            cache[key] = result
            if ref == key { withAnimation(.smooth) { state = result } }
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

    /// LRC: «[mm:ss.xx] text» (several stamps on one line are several lines).
    static func parse(_ lrc: String) -> [Line] {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        var rows: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                rows.append((min * 60 + sec + frac, text))
            }
        }
        return rows.sorted { $0.0 < $1.0 }.enumerated().map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

/// The lyrics in the player: the playing line large and bright, the rest dimmed; it scrolls by itself (a finger on it
/// pauses that for a moment); a tap on a line seeks there.
struct LyricsView: View {
    @Environment(Player.self) private var player
    @Environment(Lyrics.self) private var lyrics
    @State private var userScrolledAt = Date.distantPast

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
            case .loading, .idle: ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let current = Lyrics.current(lines, at: player.position)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 40)
                    ForEach(lines) { line in
                        let isNow = line.id == current
                        let passed = (current ?? -1) > line.id
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white.opacity(isNow ? 1 : passed ? 0.35 : 0.45))
                            .blur(radius: isNow ? 0 : 0.6)
                            .scaleEffect(isNow ? 1 : 0.96, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(max(0, line.time - 0.05)) }
                            .id(line.id)
                            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isNow)
                    }
                    Color.clear.frame(height: 200)
                }
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in userScrolledAt = Date() })
            .onChange(of: current) { _, now in
                guard let now, Date().timeIntervalSince(userScrolledAt) > 3 else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { proxy.scrollTo(now, anchor: UnitPoint(x: 0, y: 0.3)) }
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.3)) } }
        }
    }
}

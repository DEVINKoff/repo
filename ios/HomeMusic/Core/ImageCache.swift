import SwiftUI
import UIKit

/// Covers through the shared session (the Hub's `/api/nd/cover/…` needs its cookie).
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    init() { cache.countLimit = 400 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        guard let result = try? await HubClient.shared.session.data(from: url),
              ((result.1 as? HTTPURLResponse)?.statusCode ?? 200) < 300,
              let image = UIImage(data: result.0) else { return nil }
        let prepared = await image.byPreparingForDisplay() ?? image
        cache.setObject(prepared, forKey: url as NSURL)
        return prepared
    }
}

/// A square (or round) cover with a soft placeholder, the way Apple Music shows artwork.
struct Cover: View {
    var url: String?
    var size: CGFloat? = nil
    var corner: CGFloat = 8
    var round = false
    var symbol = "music.note"

    @State private var image: UIImage?

    private var resolved: URL? { HubClient.shared.absolute(url) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(.systemGray5), Color(.systemGray4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: (size ?? 60) * 0.36, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
        .task(id: url) {
            guard let u = resolved else { image = nil; return }
            if let hit = ImageCache.shared.cached(u) { image = hit; return }
            image = nil
            image = await ImageCache.shared.image(u)
        }
    }
}

/// `watchOnScreen` / `touchTrack` of listen.ts: the catalog tracks on screen go to the Hub (top first, a touched one
/// first of all) so it picks their files in the background and most taps start at once.
@MainActor
final class OnScreen {
    static let shared = OnScreen()
    private var rows: [String: Int] = [:]
    private var first: String?
    private var lastSent = ""
    private var timer: Task<Void, Never>?

    func appear(_ ref: String, order: Int) { rows[ref] = order; schedule() }
    func disappear(_ ref: String) { if rows.removeValue(forKey: ref) != nil { schedule() } }

    func touch(_ ref: String) {
        guard first != ref else { return }
        first = ref
        schedule(now: true)
    }

    private func schedule(now: Bool = false) {
        timer?.cancel()
        timer = Task {
            try? await Task.sleep(for: .milliseconds(now ? 0 : 300))
            guard !Task.isCancelled else { return }
            send()
        }
    }

    private func send() {
        var refs = rows.sorted { $0.value < $1.value }.map(\.key)
        if let first, let i = refs.firstIndex(of: first) { refs.remove(at: i); refs.insert(first, at: 0) }
        refs = Array(refs.prefix(100))
        let key = refs.joined(separator: "|")
        guard key != lastSent, !refs.isEmpty else { return }
        lastSent = key
        Task {
            do { try await HubClient.shared.listenPrefetch(refs) } catch { lastSent = "" }
        }
    }
}

import SwiftUI
import ImageIO
import UIKit

/// Covers through the shared session (the Hub's `/api/nd/cover/…` needs its cookie).
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    /// Images are kept per size bucket: a list row never decodes (or holds) the 1200-px original.
    private func key(_ url: URL, _ px: Int?) -> NSString { "\(url.absoluteString)#\(px ?? 0)" as NSString }

    static func bucket(_ px: CGFloat?) -> Int? {
        guard let px, px.isFinite, px > 0 else { return nil }
        return min(2400, Int((px / 128).rounded(.up)) * 128)
    }

    func cached(_ url: URL, px: Int? = nil) -> UIImage? { cache.object(forKey: key(url, px)) }

    /// Forget every picture (a cover was replaced: the same address shows a new image).
    func removeAll() { cache.removeAllObjects() }

    func image(_ url: URL, px: Int? = nil) async -> UIImage? {
        if let hit = cached(url, px: px) { return hit }
        guard let result = try? await HubClient.shared.session.data(from: url),
              ((result.1 as? HTTPURLResponse)?.statusCode ?? 200) < 300,
              let image = Self.decode(result.0, px: px) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key(url, px), cost: cost)
        return image
    }

    /// Decoded off the main thread, straight to the needed size (ImageIO thumbnail), ready to draw.
    private static func decode(_ data: Data, px: Int?) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        if let px { opts[kCGImageSourceThumbnailMaxPixelSize] = px } else { opts[kCGImageSourceThumbnailMaxPixelSize] = 2400 }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

/// A square (or round) cover with a soft placeholder, the way Apple Music shows artwork.
struct Cover: View {
    var url: String?
    var size: CGFloat? = nil
    var corner: CGFloat = 8
    var round = false
    var symbol = "music.note"
    /// tried when `url` gives no image (a high-res variant the source doesn't have)
    var fallback: String? = nil
    /// decode at this many pixels instead of the on-screen size (a blurred backdrop needs very few)
    var pixels: CGFloat? = nil

    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    private var px: Int? { ImageCache.bucket(pixels ?? size.map { $0 * scale }) }

    private var resolved: URL? { HubClient.shared.absolute(url) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.asymmetric(insertion: .modifier(active: Develop(on: true), identity: Develop(on: false)),
                                            removal: .identity))
            } else {
                LinearGradient(colors: [Color(.systemGray5), Color(.systemGray4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: (size ?? 60) * 0.36, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(url == nil ? 1 : 0.5)
                if url != nil { Shimmer() }
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
        .task(id: url) {
            guard let u = resolved else { image = nil; return }
            if let hit = ImageCache.shared.cached(u, px: px) { image = hit; return }
            // keep showing the previous image until the new one is ready (no flash between tracks)
            // a cover that didn't come (no connection for a moment) is asked again, a few times, while on screen
            for delay in [0.0, 2, 5, 12, 30] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                if Task.isCancelled { return }
                let src = resolved ?? u // the Hub may have moved to its other address meanwhile
                var loaded = await ImageCache.shared.image(src, px: px)
                if loaded == nil, let f = HubClient.shared.absolute(fallback) { loaded = await ImageCache.shared.image(f, px: px) }
                if let loaded {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                    return
                }
            }
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


/// A cover appearing: from a soft blur and a little zoom, like a photo developing.
private struct Develop: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.blur(radius: on ? 10 : 0).scaleEffect(on ? 1.06 : 1).opacity(on ? 0 : 1)
    }
}

/// A soft light running across a placeholder while its picture loads.
struct Shimmer: View {
    @State private var run = false
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.6)
                .rotationEffect(.degrees(18))
                .offset(x: run ? g.size.width * 1.3 : -g.size.width * 0.9)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: false).delay(0.1)) { run = true }
        }
    }
}

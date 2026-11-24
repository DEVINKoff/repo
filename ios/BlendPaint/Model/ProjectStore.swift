import Foundation
import UIKit
import ImageIO

/// Keeps the layer stack of every texture you painted, so layers survive reconnects / app restarts.
enum ProjectStore {
    struct LayerMeta: Codable {
        var name: String
        var opacity: Float
        var blend: Int
        var visible: Bool
        var alphaLock: Bool
        var file: String
    }

    struct Meta: Codable {
        var width: Int
        var height: Int
        var active: Int
        var layers: [LayerMeta]
        var saved: Date
    }

    static var root: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var exports: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func key(file: String, object: String, image: String) -> String {
        let raw = "\(file)__\(object)__\(image)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    static func meta(for key: String) -> Meta? {
        let url = root.appendingPathComponent(key).appendingPathComponent("meta.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Meta.self, from: d)
    }

    static func save(key: String, engine: Engine) {
        guard engine.hasDocument else { return }
        let dir = root.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var metas: [LayerMeta] = []
        for (i, l) in engine.layers.enumerated() {
            guard let px = engine.layerPixels(l) else { continue }
            let file = "layer_\(i).png"
            let png: Data? = px.withUnsafeBytes { raw -> Data? in
                guard let base = raw.baseAddress,
                      let cg = Engine.cgImage(base, width: engine.width, height: engine.height, premultiplied: true) else { return nil }
                return UIImage(cgImage: cg).pngData()
            }
            guard let png else { continue }
            try? png.write(to: dir.appendingPathComponent(file), options: .atomic)
            metas.append(LayerMeta(name: l.name, opacity: l.opacity, blend: l.blendMode.rawValue,
                                   visible: l.visible, alphaLock: l.alphaLock, file: file))
        }
        let m = Meta(width: engine.width, height: engine.height, active: engine.activeIndex, layers: metas, saved: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(m) {
            try? d.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    static func load(key: String, engine: Engine) -> Bool {
        guard let m = meta(for: key), m.width == engine.width, m.height == engine.height else { return false }
        let dir = root.appendingPathComponent(key, isDirectory: true)
        var out: [(name: String, opacity: Float, blend: BlendMode, visible: Bool, alphaLock: Bool, premulRGBA: Data)] = []
        for l in m.layers {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(l.file)),
                  let px = decodePremultiplied(d, width: m.width, height: m.height) else { continue }
            out.append((l.name, l.opacity, BlendMode(rawValue: l.blend) ?? .normal, l.visible, l.alphaLock, px))
        }
        guard !out.isEmpty else { return false }
        engine.restoreLayers(out, active: m.active)
        return true
    }

    static func delete(key: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key, isDirectory: true))
    }

    static func decodePremultiplied(_ data: Data, width: Int, height: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var out = Data(count: width * height * 4)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? out : nil
    }
}

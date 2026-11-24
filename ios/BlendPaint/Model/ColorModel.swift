import SwiftUI
import UIKit

struct HSBA: Codable, Equatable, Hashable {
    var h: Double   // 0…1
    var s: Double
    var b: Double
    var a: Double = 1

    var uiColor: UIColor { UIColor(hue: h, saturation: s, brightness: b, alpha: a) }
    var color: Color { Color(uiColor) }

    /// straight sRGB components 0…1
    var rgba: SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, bb: CGFloat = 0, al: CGFloat = 0
        UIColor(hue: h, saturation: s, brightness: b, alpha: 1).getRed(&r, green: &g, blue: &bb, alpha: &al)
        return SIMD4(Float(r), Float(g), Float(bb), Float(a))
    }

    init(h: Double, s: Double, b: Double, a: Double = 1) {
        self.h = h; self.s = s; self.b = b; self.a = a
    }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        var hh: CGFloat = 0, ss: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hh, saturation: &ss, brightness: &bb, alpha: &aa)
        self.h = Double(hh); self.s = Double(ss); self.b = Double(bb); self.a = a
    }

    var hex: String {
        let c = rgba
        return String(format: "%02X%02X%02X", Int(round(c.x * 255)), Int(round(c.y * 255)), Int(round(c.z * 255)))
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
}

extension HSBA {
    static let defaultPalette: [HSBA] = [
        HSBA(h: 0, s: 0, b: 0), HSBA(h: 0, s: 0, b: 0.25), HSBA(h: 0, s: 0, b: 0.5), HSBA(h: 0, s: 0, b: 0.75),
        HSBA(h: 0, s: 0, b: 1), HSBA(h: 0.0, s: 0.85, b: 0.9), HSBA(h: 0.07, s: 0.85, b: 0.95), HSBA(h: 0.14, s: 0.8, b: 1),
        HSBA(h: 0.3, s: 0.7, b: 0.75), HSBA(h: 0.5, s: 0.7, b: 0.8), HSBA(h: 0.6, s: 0.75, b: 0.9), HSBA(h: 0.75, s: 0.6, b: 0.85),
        HSBA(h: 0.9, s: 0.55, b: 0.9), HSBA(h: 0.08, s: 0.45, b: 0.55), HSBA(h: 0.06, s: 0.35, b: 0.85), HSBA(h: 0.58, s: 0.2, b: 0.4),
    ]
}

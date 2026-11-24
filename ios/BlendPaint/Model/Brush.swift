import Foundation
import simd

enum BrushShape: Int, Codable, CaseIterable, Identifiable {
    case round = 0, square, spray, charcoal
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .round: return "Круглая"
        case .square: return "Квадратная"
        case .spray: return "Спрей"
        case .charcoal: return "Уголь"
        }
    }
}

enum AngleMode: Int, Codable, CaseIterable, Identifiable {
    case fixed = 0, followStroke, pencilAzimuth
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fixed: return "Фиксированный"
        case .followStroke: return "По штриху"
        case .pencilAzimuth: return "По наклону Pencil"
        }
    }
}

struct BrushSettings: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var category: String
    var symbol: String = "paintbrush.pointed"

    var size: Float = 0.15            // 0…1 slider
    var opacity: Float = 1            // stroke opacity cap
    var shape: BrushShape = .round
    var hardness: Float = 0.8
    var spacing: Float = 0.08         // fraction of diameter
    var flow: Float = 1
    var minSize: Float = 0.1          // fraction of size at zero pressure
    var pressureSize: Float = 0.8
    var pressureOpacity: Float = 0
    var tiltSize: Float = 0
    var tiltOpacity: Float = 0
    var streamline: Float = 0.2
    var sizeJitter: Float = 0
    var scatter: Float = 0
    var angleJitter: Float = 0
    var roundness: Float = 1
    var angle: Float = 0              // radians
    var angleMode: AngleMode = .fixed
    var grain: Float = 0
    var grainScale: Float = 1
    var isBuiltIn = true

    /// radius in texture pixels (2D canvas)
    func radius2D(textureMax: Int) -> Float {
        0.5 + pow(size, 2.2) * Float(textureMax) * 0.12
    }

    /// radius in screen points (3D view)
    func radius3D() -> Float {
        1 + pow(size, 2.2) * 220
    }

    static let defaults: [BrushSettings] = {
        var list: [BrushSettings] = []
        var b = BrushSettings(name: "Карандаш HB", category: "Скетч", symbol: "pencil")
        b.size = 0.08; b.hardness = 0.55; b.spacing = 0.06; b.flow = 0.85; b.grain = 0.75; b.grainScale = 0.6
        b.pressureSize = 0.4; b.pressureOpacity = 0.9; b.tiltSize = 0.9; b.tiltOpacity = 0.4; b.streamline = 0.1
        list.append(b)

        b = BrushSettings(name: "Технический карандаш", category: "Скетч", symbol: "pencil.tip")
        b.size = 0.05; b.hardness = 0.9; b.spacing = 0.05; b.pressureSize = 0.3; b.pressureOpacity = 0.6; b.streamline = 0.3
        list.append(b)

        b = BrushSettings(name: "Тушь", category: "Тушь", symbol: "pencil.and.scribble")
        b.size = 0.12; b.hardness = 0.95; b.spacing = 0.04; b.pressureSize = 1; b.minSize = 0.05; b.streamline = 0.45
        list.append(b)

        b = BrushSettings(name: "Студийное перо", category: "Тушь", symbol: "signature")
        b.size = 0.1; b.hardness = 1; b.spacing = 0.03; b.pressureSize = 0.85; b.minSize = 0.2; b.streamline = 0.65
        list.append(b)

        b = BrushSettings(name: "Маркер", category: "Рисование", symbol: "highlighter")
        b.size = 0.18; b.hardness = 0.9; b.flow = 0.35; b.pressureSize = 0.1; b.pressureOpacity = 0.4
        b.roundness = 0.4; b.angleMode = .pencilAzimuth; b.opacity = 0.85; b.spacing = 0.05
        list.append(b)

        b = BrushSettings(name: "Плоская кисть", category: "Рисование", symbol: "paintbrush")
        b.size = 0.2; b.hardness = 0.85; b.roundness = 0.25; b.angleMode = .followStroke; b.pressureSize = 0.5
        b.pressureOpacity = 0.3; b.spacing = 0.04
        list.append(b)

        b = BrushSettings(name: "Круглая мягкая", category: "Рисование", symbol: "circle.dotted")
        b.size = 0.25; b.hardness = 0.35; b.flow = 0.5; b.pressureSize = 0.6; b.pressureOpacity = 0.7; b.spacing = 0.06
        list.append(b)

        b = BrushSettings(name: "Мягкий аэрограф", category: "Аэрограф", symbol: "aqi.medium")
        b.size = 0.4; b.hardness = 0; b.flow = 0.07; b.pressureSize = 0; b.pressureOpacity = 1; b.spacing = 0.1; b.streamline = 0
        list.append(b)

        b = BrushSettings(name: "Жёсткий аэрограф", category: "Аэрограф", symbol: "aqi.high")
        b.size = 0.25; b.hardness = 0.8; b.flow = 0.2; b.pressureSize = 0; b.pressureOpacity = 1; b.spacing = 0.08
        list.append(b)

        b = BrushSettings(name: "Спрей", category: "Аэрограф", symbol: "sparkles")
        b.shape = .spray; b.size = 0.3; b.hardness = 0.2; b.flow = 0.7; b.pressureSize = 0.3; b.pressureOpacity = 0.6; b.spacing = 0.15
        list.append(b)

        b = BrushSettings(name: "Уголь", category: "Текстуры", symbol: "scribble")
        b.shape = .charcoal; b.size = 0.15; b.hardness = 0.5; b.flow = 0.8; b.grain = 0.85; b.grainScale = 0.8
        b.sizeJitter = 0.15; b.angleJitter = 1; b.pressureOpacity = 0.8; b.tiltSize = 1; b.spacing = 0.1
        list.append(b)

        b = BrushSettings(name: "Гранж / шум", category: "Текстуры", symbol: "circle.grid.cross")
        b.size = 0.3; b.hardness = 0.3; b.flow = 0.45; b.scatter = 0.6; b.sizeJitter = 0.5; b.angleJitter = 1
        b.grain = 1; b.grainScale = 2.5; b.spacing = 0.25; b.pressureOpacity = 0.6
        list.append(b)

        b = BrushSettings(name: "Царапины", category: "Текстуры", symbol: "line.diagonal")
        b.size = 0.04; b.hardness = 1; b.roundness = 0.15; b.angleMode = .followStroke; b.pressureSize = 1
        b.minSize = 0; b.sizeJitter = 0.3; b.streamline = 0.05
        list.append(b)

        b = BrushSettings(name: "Квадратная", category: "Утилиты", symbol: "square")
        b.shape = .square; b.size = 0.15; b.hardness = 1; b.pressureSize = 0; b.spacing = 0.03; b.streamline = 0
        list.append(b)

        b = BrushSettings(name: "Заливка мягкая (большая)", category: "Утилиты", symbol: "drop")
        b.size = 0.75; b.hardness = 0.2; b.flow = 1; b.pressureSize = 0; b.pressureOpacity = 0; b.spacing = 0.12; b.streamline = 0
        list.append(b)
        return list
    }()
}

// MARK: - stroke interpolation (CPU side)

struct StrokeSample {
    var p: SIMD2<Float>       // texture px (2D) or drawable px (3D)
    var pressure: Float       // 0…1 after curve
    var tilt: Float           // 0 = perpendicular … 1 = flat
    var azimuth: Float        // radians in the same space as p
}

final class StrokeBuilder {
    let brush: BrushSettings
    let baseRadius: Float      // in the same units as samples
    private var smoothed: SIMD2<Float>?
    private var last: StrokeSample?
    private var carry: Float = 0
    private var rng = SystemRandomNumberGenerator()
    private var lastDirection: Float = 0
    private(set) var dabCount = 0

    init(brush: BrushSettings, baseRadius: Float) {
        self.brush = brush
        self.baseRadius = max(baseRadius, 0.5)
    }

    private func stepAt(_ pressure: Float) -> Float {
        let r = max(baseRadius * (1 + (brush.minSize + (1 - brush.minSize) * pressure - 1) * brush.pressureSize), 0.35)
        return max(0.35, brush.spacing * 2 * r)
    }

    private func rand() -> Float { Float.random(in: -1...1, using: &rng) }

    private func makeDab(_ s: StrokeSample) -> GPUDab {
        let b = brush
        let pr = s.pressure
        var r = baseRadius * (1 + (b.minSize + (1 - b.minSize) * pr - 1) * b.pressureSize)
        r *= 1 + s.tilt * b.tiltSize * 1.5
        if b.sizeJitter > 0 { r *= max(0.05, 1 + rand() * b.sizeJitter) }
        // opacity cap of this dab (pressure/tilt → opacity); flow = how fast it builds up to it
        var alpha = 1 + (pr - 1) * b.pressureOpacity
        alpha *= 1 - s.tilt * b.tiltOpacity * 0.8
        var angle = b.angle
        switch b.angleMode {
        case .fixed: break
        case .followStroke: angle += lastDirection
        case .pencilAzimuth: angle += s.azimuth
        }
        if b.angleJitter > 0 { angle += rand() * .pi * b.angleJitter }
        var c = s.p
        if b.scatter > 0 {
            let a = Float.random(in: 0..<(2 * .pi), using: &rng)
            let d = Float.random(in: 0...1, using: &rng) * r * b.scatter * 2
            c += SIMD2(cos(a), sin(a)) * d
        }
        dabCount += 1
        return GPUDab(center: c, radius: max(r, 0.35), angle: angle, roundness: max(b.roundness, 0.05),
                      alpha: max(0, min(1, alpha)), seed: Float.random(in: 0...1, using: &rng),
                      flow: max(0.005, min(1, b.flow)))
    }

    func add(_ raw: StrokeSample) -> [GPUDab] {
        var s = raw
        if let sm = smoothed {
            let k = 1 - min(brush.streamline, 0.95) * 0.92
            s.p = sm + (raw.p - sm) * k
        }
        smoothed = s.p
        guard let l = last else {
            last = s
            return [makeDab(s)]
        }
        var out: [GPUDab] = []
        let delta = s.p - l.p
        let dist = simd_length(delta)
        if dist < 1e-4 { return [] }
        lastDirection = atan2(delta.y, delta.x)
        var pos = stepAt(l.pressure) - carry
        var lastEmit: Float = -1
        while pos <= dist {
            let f = pos / dist
            let smp = StrokeSample(p: l.p + delta * f,
                                   pressure: l.pressure + (s.pressure - l.pressure) * f,
                                   tilt: l.tilt + (s.tilt - l.tilt) * f,
                                   azimuth: l.azimuth + (s.azimuth - l.azimuth) * f)
            out.append(makeDab(smp))
            lastEmit = pos
            pos += stepAt(smp.pressure)
            if out.count > 4000 { break }
        }
        carry = lastEmit >= 0 ? dist - lastEmit : carry + dist
        last = s
        return out
    }

    /// pulls the lagging (streamlined) end toward the real pen position
    func finish(at raw: StrokeSample?) -> [GPUDab] {
        guard let raw, brush.streamline > 0, smoothed != nil else { return [] }
        var out: [GPUDab] = []
        for _ in 0..<6 {
            out += add(raw)
        }
        return out
    }
}

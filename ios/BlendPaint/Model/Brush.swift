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
        case .pencilAzimuth: return "По азимуту Pencil"
        }
    }
}

enum GrainMode: Int, Codable, CaseIterable, Identifiable {
    case texturized = 0, moving
    var id: Int { rawValue }
    var title: String { self == .texturized ? "Текстурированное" : "Движущееся" }
}

/// Procreate "Brush Studio"-style settings.
struct BrushSettings: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var category: String
    var symbol: String = "paintbrush.pointed"
    var isBuiltIn = true

    // Properties
    var size: Float = 0.15                 // 0…1 slider
    var opacity: Float = 1                 // stroke opacity cap
    var minSizeLimit: Float = 0            // fraction of max
    var maxSizeLimit: Float = 1

    // Stroke path
    var spacing: Float = 0.08              // fraction of diameter
    var jitter: Float = 0                  // lateral jitter
    var falloff: Float = 0                 // fades the stroke out along its length

    // Stabilization
    var streamline: Float = 0.2
    var stabilization: Float = 0
    var motionFilter: Float = 0

    // Taper
    var taperStart: Float = 0              // 0…1 → up to 30 diameters
    var taperEnd: Float = 0
    var taperTip: Float = 0.1              // tip size at the very end
    var taperOpacity: Float = 0

    // Shape
    var shape: BrushShape = .round
    var roundness: Float = 1
    var angle: Float = 0
    var angleMode: AngleMode = .fixed
    var angleJitter: Float = 0
    var scatter: Float = 0
    var stampCount: Int = 1

    // Grain
    var grain: Float = 0
    var grainScale: Float = 1
    var grainMode: GrainMode = .texturized

    // Rendering
    var hardness: Float = 0.8
    var flow: Float = 1

    // Color dynamics (per stroke)
    var hueJitter: Float = 0
    var satJitter: Float = 0
    var brightJitter: Float = 0

    // Dynamics
    var speedSize: Float = 0               // -1…1
    var speedOpacity: Float = 0
    var sizeJitter: Float = 0
    var opacityJitter: Float = 0

    // Apple Pencil
    var minSize: Float = 0.1               // size at zero pressure
    var pressureSize: Float = 0.8
    var pressureOpacity: Float = 0
    var pressureFlow: Float = 0
    var tiltSize: Float = 0
    var tiltOpacity: Float = 0

    private func limited(_ s: Float) -> Float { minSizeLimit + (maxSizeLimit - minSizeLimit) * s }

    /// radius in texture pixels (2D canvas)
    func radius2D(textureMax: Int) -> Float { 0.5 + pow(limited(size), 2.2) * Float(textureMax) * 0.12 }

    /// radius in screen points (3D view)
    func radius3D() -> Float { 1 + pow(limited(size), 2.2) * 220 }

    static let defaults: [BrushSettings] = {
        var list: [BrushSettings] = []
        func add(_ name: String, _ cat: String, _ sym: String, _ f: (inout BrushSettings) -> Void) {
            var b = BrushSettings(name: name, category: cat, symbol: sym)
            f(&b)
            list.append(b)
        }
        // Sketching
        add("6B Карандаш", "Скетч", "pencil") { b in
            b.size = 0.09; b.hardness = 0.45; b.spacing = 0.05; b.flow = 0.7; b.grain = 0.9; b.grainScale = 0.55
            b.pressureSize = 0.35; b.pressureOpacity = 1; b.tiltSize = 1.2; b.tiltOpacity = 0.5; b.streamline = 0.12
            b.taperStart = 0.08; b.taperEnd = 0.1; b.taperTip = 0.3
        }
        add("HB Карандаш", "Скетч", "pencil.tip") { b in
            b.size = 0.05; b.hardness = 0.7; b.spacing = 0.04; b.flow = 0.85; b.grain = 0.6; b.grainScale = 0.45
            b.pressureSize = 0.25; b.pressureOpacity = 0.9; b.tiltSize = 0.8; b.streamline = 0.15
            b.taperStart = 0.06; b.taperEnd = 0.08; b.taperTip = 0.4
        }
        // Inking
        add("Студийное перо", "Тушь", "signature") { b in
            b.size = 0.1; b.hardness = 1; b.spacing = 0.03; b.pressureSize = 0.9; b.minSize = 0.15
            b.streamline = 0.55; b.stabilization = 0.1; b.taperStart = 0.18; b.taperEnd = 0.25; b.taperTip = 0.05
        }
        add("Технический карандаш", "Тушь", "pencil.and.ruler") { b in
            b.size = 0.06; b.hardness = 1; b.spacing = 0.03; b.pressureSize = 0.15; b.streamline = 0.35
            b.motionFilter = 0.2
        }
        add("Сироп", "Тушь", "drop.fill") { b in
            b.size = 0.14; b.hardness = 0.97; b.spacing = 0.03; b.pressureSize = 1; b.minSize = 0.05
            b.streamline = 0.75; b.stabilization = 0.25; b.taperStart = 0.25; b.taperEnd = 0.35; b.taperTip = 0
            b.speedSize = -0.4
        }
        add("Гуашь", "Рисование", "paintbrush") { b in
            b.size = 0.2; b.hardness = 0.85; b.flow = 0.6; b.pressureSize = 0.4; b.pressureOpacity = 0.4
            b.pressureFlow = 0.6; b.grain = 0.55; b.grainMode = .moving; b.grainScale = 1.2; b.spacing = 0.05
            b.angleMode = .followStroke; b.roundness = 0.6; b.taperStart = 0.05; b.taperEnd = 0.1; b.taperTip = 0.4
        }
        add("Плоская кисть", "Рисование", "paintbrush.fill") { b in
            b.size = 0.2; b.hardness = 0.85; b.roundness = 0.22; b.angleMode = .followStroke; b.pressureSize = 0.5
            b.pressureOpacity = 0.3; b.spacing = 0.03; b.taperEnd = 0.12; b.taperTip = 0.5
        }
        add("Маркер", "Рисование", "highlighter") { b in
            b.size = 0.18; b.hardness = 0.9; b.flow = 0.35; b.pressureSize = 0.1; b.pressureOpacity = 0.4
            b.roundness = 0.4; b.angleMode = .pencilAzimuth; b.opacity = 0.85; b.spacing = 0.05
        }
        // Airbrushing
        add("Мягкая кисть", "Аэрограф", "circle.dotted") { b in
            b.size = 0.4; b.hardness = 0; b.flow = 0.08; b.pressureSize = 0; b.pressureOpacity = 1; b.pressureFlow = 0.5
            b.spacing = 0.1; b.streamline = 0
        }
        add("Средний аэрограф", "Аэрограф", "aqi.medium") { b in
            b.size = 0.25; b.hardness = 0.5; b.flow = 0.15; b.pressureSize = 0; b.pressureOpacity = 1; b.spacing = 0.08
        }
        add("Жёсткий аэрограф", "Аэрограф", "aqi.high") { b in
            b.size = 0.25; b.hardness = 0.85; b.flow = 0.2; b.pressureSize = 0; b.pressureOpacity = 1; b.spacing = 0.06
        }
        add("Спрей", "Аэрограф", "sparkles") { b in
            b.shape = .spray; b.size = 0.3; b.hardness = 0.2; b.flow = 0.7; b.pressureSize = 0.3
            b.pressureOpacity = 0.6; b.spacing = 0.15
        }
        // Textures
        add("Уголь", "Текстуры", "scribble") { b in
            b.shape = .charcoal; b.size = 0.15; b.hardness = 0.5; b.flow = 0.8; b.grain = 0.85; b.grainScale = 0.8
            b.sizeJitter = 0.15; b.angleJitter = 1; b.pressureOpacity = 0.8; b.tiltSize = 1; b.spacing = 0.1
        }
        add("Шумовая кисть", "Текстуры", "circle.grid.cross") { b in
            b.size = 0.3; b.hardness = 0.3; b.flow = 0.45; b.scatter = 0.6; b.sizeJitter = 0.5; b.angleJitter = 1
            b.grain = 1; b.grainScale = 2.5; b.spacing = 0.25; b.pressureOpacity = 0.6; b.stampCount = 2
        }
        add("Царапины", "Текстуры", "line.diagonal") { b in
            b.size = 0.04; b.hardness = 1; b.roundness = 0.15; b.angleMode = .followStroke; b.pressureSize = 1
            b.minSize = 0; b.sizeJitter = 0.3; b.streamline = 0.05; b.taperStart = 0.1; b.taperEnd = 0.15; b.taperTip = 0
        }
        add("Грязь / потёртости", "Текстуры", "aqi.low") { b in
            b.size = 0.35; b.hardness = 0.2; b.flow = 0.25; b.scatter = 0.9; b.sizeJitter = 0.6; b.angleJitter = 1
            b.grain = 1; b.grainScale = 1.6; b.grainMode = .moving; b.spacing = 0.3; b.stampCount = 3; b.opacityJitter = 0.5
        }
        // Utility
        add("Квадратная", "Утилиты", "square") { b in
            b.shape = .square; b.size = 0.15; b.hardness = 1; b.pressureSize = 0; b.spacing = 0.03; b.streamline = 0
        }
        add("Заливка (большая)", "Утилиты", "drop") { b in
            b.size = 0.75; b.hardness = 0.2; b.flow = 1; b.pressureSize = 0; b.pressureOpacity = 0; b.spacing = 0.12; b.streamline = 0
        }
        return list
    }()
}

// MARK: - stroke interpolation (CPU side)

struct StrokeSample {
    var p: SIMD2<Float>       // texture px (2D) or drawable px (3D)
    var pressure: Float       // 0…1 after curve
    var tilt: Float           // 0 = perpendicular … 1 = flat
    var azimuth: Float        // radians in the same space as p
    var time: Double = 0
}

/// Turns pen samples into dabs: pressure smoothing → stabilization → motion filtering →
/// StreamLine → spacing, with taper, speed and jitter dynamics (Procreate-like).
final class StrokeBuilder {
    let brush: BrushSettings
    let baseRadius: Float
    private let pressureSmoothing: Float
    private var rng = SystemRandomNumberGenerator()

    private var window: [SIMD2<Float>] = []
    private var smoothed: SIMD2<Float>?
    private var smoothPressure: Float?
    private var last: StrokeSample?
    private var carry: Float = 0
    private var length: Float = 0               // path length in px
    private var speed: Float = 0                // 0…1
    private var lastDirection: Float = 0
    private var pending: [(dab: GPUDab, at: Float)] = []
    private(set) var dabCount = 0

    private var diameter: Float { baseRadius * 2 }
    private var taperStartLen: Float { brush.taperStart * 30 * diameter }
    private var taperEndLen: Float { brush.taperEnd * 30 * diameter }

    init(brush: BrushSettings, baseRadius: Float, pressureSmoothing: Float = 0.2) {
        self.brush = brush
        self.baseRadius = max(baseRadius, 0.5)
        self.pressureSmoothing = pressureSmoothing
    }

    private func rand() -> Float { Float.random(in: -1...1, using: &rng) }

    private func radiusFor(_ pr: Float) -> Float {
        baseRadius * (1 + (brush.minSize + (1 - brush.minSize) * pr - 1) * brush.pressureSize)
    }

    private func stepAt(_ pressure: Float) -> Float {
        max(0.35, brush.spacing * 2 * max(radiusFor(pressure), 0.35))
    }

    private func makeDabs(_ s: StrokeSample, at L: Float) -> [GPUDab] {
        let b = brush
        let pr = s.pressure
        var r = radiusFor(pr)
        r *= 1 + s.tilt * b.tiltSize * 1.5
        r *= max(0.05, 1 + b.speedSize * speed)
        if b.sizeJitter > 0 { r *= max(0.05, 1 + rand() * b.sizeJitter) }
        var alpha = 1 + (pr - 1) * b.pressureOpacity
        alpha *= 1 - s.tilt * b.tiltOpacity * 0.8
        alpha *= max(0, 1 + b.speedOpacity * speed)
        if b.opacityJitter > 0 { alpha *= max(0, 1 - Float.random(in: 0...1, using: &rng) * b.opacityJitter) }
        if b.falloff > 0 {
            let fadeLen = (1 - b.falloff) * 150 * diameter + 2 * diameter
            alpha *= max(0, 1 - L / fadeLen)
        }
        if taperStartLen > 0 && L < taperStartLen {
            let t = L / taperStartLen
            let e = t * t * (3 - 2 * t)
            r *= b.taperTip + (1 - b.taperTip) * e
            alpha *= 1 - b.taperOpacity * (1 - e)
        }
        let flow = b.flow * (1 + (pr - 1) * b.pressureFlow)
        var out: [GPUDab] = []
        for _ in 0..<max(1, b.stampCount) {
            var angle = b.angle
            switch b.angleMode {
            case .fixed: break
            case .followStroke: angle += lastDirection
            case .pencilAzimuth: angle += s.azimuth
            }
            if b.angleJitter > 0 { angle += rand() * .pi * b.angleJitter }
            var c = s.p
            if b.jitter > 0 {
                let n = SIMD2<Float>(-sin(lastDirection), cos(lastDirection))
                c += n * rand() * r * b.jitter * 2
            }
            if b.scatter > 0 {
                let a = Float.random(in: 0..<(2 * .pi), using: &rng)
                c += SIMD2(cos(a), sin(a)) * Float.random(in: 0...1, using: &rng) * r * b.scatter * 2
            }
            dabCount += 1
            out.append(GPUDab(center: c, radius: max(r, 0.35), angle: angle, roundness: max(b.roundness, 0.05),
                              alpha: max(0, min(1, alpha)), seed: Float.random(in: 0...1, using: &rng),
                              flow: max(0.005, min(1, flow))))
        }
        return out
    }

    private func emit(_ dabs: [GPUDab], at L: Float) -> [GPUDab] {
        guard taperEndLen > 0 else { return dabs }
        for d in dabs { pending.append((d, L)) }
        // dabs further than the end-taper length from the pen are final
        var ready: [GPUDab] = []
        while let f = pending.first, f.at < length - taperEndLen {
            ready.append(f.dab)
            pending.removeFirst()
        }
        return ready
    }

    func add(_ raw: StrokeSample) -> [GPUDab] {
        var s = raw
        // 1. pressure smoothing
        if let sp = smoothPressure {
            s.pressure = sp + (raw.pressure - sp) * (1 - min(pressureSmoothing, 0.95))
        }
        smoothPressure = s.pressure
        // 2. stabilization: moving average over a window of samples
        if brush.stabilization > 0 {
            window.append(raw.p)
            let n = 1 + Int(brush.stabilization * 24)
            if window.count > n { window.removeFirst(window.count - n) }
            s.p = window.reduce(SIMD2<Float>.zero, +) / Float(window.count)
        }
        // 3. motion filtering: damp small jittery movements
        if let sm = smoothed, brush.motionFilter > 0 {
            let d = s.p - sm
            let m = simd_length(d)
            let th = brush.motionFilter * baseRadius * 0.9 + 0.5
            if m < th { s.p = sm + d * (m / th) * (m / th) }
        }
        // 4. StreamLine
        if let sm = smoothed {
            let k = 1 - min(brush.streamline, 0.95) * 0.92
            s.p = sm + (s.p - sm) * k
        }
        smoothed = s.p
        guard let l = last else {
            last = s
            return emit(makeDabs(s, at: 0), at: 0)
        }
        let delta = s.p - l.p
        let dist = simd_length(delta)
        if dist < 1e-4 { return [] }
        let dt = max(s.time - l.time, 1.0 / 240.0)
        let v = min(1, Float(Double(dist) / dt) / max(baseRadius * 60, 1))
        speed += (v - speed) * 0.25
        lastDirection = atan2(delta.y, delta.x)
        var out: [GPUDab] = []
        var pos = stepAt(l.pressure) - carry
        var lastEmit: Float = -1
        while pos <= dist {
            let f = pos / dist
            let smp = StrokeSample(p: l.p + delta * f,
                                   pressure: l.pressure + (s.pressure - l.pressure) * f,
                                   tilt: l.tilt + (s.tilt - l.tilt) * f,
                                   azimuth: l.azimuth + (s.azimuth - l.azimuth) * f,
                                   time: l.time + (s.time - l.time) * Double(f))
            out += emit(makeDabs(smp, at: length + pos), at: length + pos)
            lastEmit = pos
            pos += stepAt(smp.pressure)
            if out.count > 6000 { break }
        }
        carry = lastEmit >= 0 ? dist - lastEmit : carry + dist
        length += dist
        last = s
        return out
    }

    /// pulls the lagging (streamlined) end to the pen and applies the end taper
    func finish(at raw: StrokeSample?) -> [GPUDab] {
        var out: [GPUDab] = []
        if let raw, brush.streamline > 0 || brush.stabilization > 0, smoothed != nil {
            window.removeAll()
            for _ in 0..<6 { out += add(raw) }
        }
        if taperEndLen > 0 {
            for p in pending {
                let t = max(0, min(1, (length - p.at) / taperEndLen))
                let e = t * t * (3 - 2 * t)
                var d = p.dab
                d.radius = max(0.35, d.radius * (brush.taperTip + (1 - brush.taperTip) * e))
                d.alpha *= 1 - brush.taperOpacity * (1 - e)
                out.append(d)
            }
            pending.removeAll()
        }
        return out
    }
}

// MARK: - pressure curve (Procreate "Pressure and Smoothing")

enum PressureCurve {
    static let linear: [Double] = [0, 0, 1, 1]

    /// monotone cubic (Fritsch–Carlson) through control points → 65-entry LUT
    static func lut(_ flat: [Double]) -> [Float] {
        var pts: [(Double, Double)] = stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }
        pts.sort { $0.0 < $1.0 }
        if pts.count < 2 { pts = [(0, 0), (1, 1)] }
        let n = pts.count
        var m = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = max(pts[i + 1].0 - pts[i].0, 1e-6)
            d[i] = (pts[i + 1].1 - pts[i].1) / dx
        }
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        var out: [Float] = []
        for k in 0...64 {
            let x = Double(k) / 64
            var i = 0
            while i < n - 2 && x > pts[i + 1].0 { i += 1 }
            let x0 = pts[i].0, x1 = pts[i + 1].0
            let h = max(x1 - x0, 1e-6)
            let t = min(max((x - x0) / h, 0), 1)
            let t2 = t * t, t3 = t2 * t
            let y = (2 * t3 - 3 * t2 + 1) * pts[i].1 + (t3 - 2 * t2 + t) * h * m[i]
                + (-2 * t3 + 3 * t2) * pts[i + 1].1 + (t3 - t2) * h * m[i + 1]
            out.append(Float(min(max(y, 0), 1)))
        }
        return out
    }

    static func eval(_ lut: [Float], _ x: Float) -> Float {
        guard lut.count > 1 else { return x }
        let f = min(max(x, 0), 1) * Float(lut.count - 1)
        let i = min(Int(f), lut.count - 2)
        return lut[i] + (lut[i + 1] - lut[i]) * (f - Float(i))
    }
}

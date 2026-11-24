import SwiftUI

/// Procreate-style pressure curve: drag points, tap empty space to add, double-tap a point to remove.
struct PressureCurveEditor: View {
    @Binding var curve: [Double]
    @State private var dragging: Int?

    private var points: [CGPoint] {
        stride(from: 0, to: curve.count - 1, by: 2).map { CGPoint(x: curve[$0], y: curve[$0 + 1]) }
    }

    private func setPoints(_ p: [CGPoint]) {
        curve = p.sorted { $0.x < $1.x }.flatMap { [Double($0.x), Double($0.y)] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let s = geo.size
                let lut = PressureCurve.lut(curve)
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.35))
                    Path { p in
                        for i in 1..<4 {
                            let f = CGFloat(i) / 4
                            p.move(to: CGPoint(x: f * s.width, y: 0)); p.addLine(to: CGPoint(x: f * s.width, y: s.height))
                            p.move(to: CGPoint(x: 0, y: f * s.height)); p.addLine(to: CGPoint(x: s.width, y: f * s.height))
                        }
                    }
                    .stroke(.white.opacity(0.08), lineWidth: 1)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: s.height)); p.addLine(to: CGPoint(x: s.width, y: 0))
                    }
                    .stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Path { p in
                        for (i, v) in lut.enumerated() {
                            let pt = CGPoint(x: CGFloat(i) / CGFloat(lut.count - 1) * s.width, y: (1 - CGFloat(v)) * s.height)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    ForEach(Array(points.enumerated()), id: \.offset) { i, pt in
                        Circle()
                            .fill(.white)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                            .frame(width: dragging == i ? 24 : 18, height: dragging == i ? 24 : 18)
                            .position(x: pt.x * s.width, y: (1 - pt.y) * s.height)
                            .onTapGesture(count: 2) {
                                var p = points
                                guard p.count > 2, i != 0, i != p.count - 1 else { return }
                                p.remove(at: i)
                                setPoints(p)
                            }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let x = max(0, min(1, v.location.x / s.width))
                            let y = max(0, min(1, 1 - v.location.y / s.height))
                            var p = points
                            if dragging == nil {
                                // grab the nearest point, or add a new one
                                let near = p.enumerated().min { a, b in
                                    hypot(a.element.x - x, a.element.y - y) < hypot(b.element.x - x, b.element.y - y)
                                }
                                if let near, hypot(near.element.x - x, near.element.y - y) < 0.09 {
                                    dragging = near.offset
                                } else if p.count < 8 {
                                    p.append(CGPoint(x: x, y: y))
                                    p.sort { $0.x < $1.x }
                                    dragging = p.firstIndex { $0.x == x && $0.y == y }
                                    setPoints(p)
                                    return
                                }
                            }
                            guard let i = dragging, p.indices.contains(i) else { return }
                            let lo = i == 0 ? 0 : p[i - 1].x + 0.02
                            let hi = i == p.count - 1 ? 1 : p[i + 1].x - 0.02
                            var nx = max(lo, min(hi, x))
                            if i == 0 { nx = 0 }
                            if i == p.count - 1 { nx = 1 }
                            p[i] = CGPoint(x: nx, y: y)
                            curve = p.flatMap { [Double($0.x), Double($0.y)] }
                        }
                        .onEnded { _ in dragging = nil }
                )
            }
            .aspectRatio(1.4, contentMode: .fit)
            HStack {
                Button("Мягкая") { curve = [0, 0, 0.3, 0.5, 1, 1] }
                Button("Линейная") { curve = PressureCurve.linear }
                Button("Жёсткая") { curve = [0, 0, 0.6, 0.35, 1, 1] }
                Button("Плато") { curve = [0, 0.15, 0.5, 0.85, 1, 1] }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            Text("Тяни точки. Тап по пустому месту — новая точка, двойной тап — удалить.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

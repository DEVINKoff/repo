import SwiftUI
import simd

/// Blender-style navigation gizmo (X red, Y green, Z blue) in a Liquid Glass puck.
/// Tap an axis ball to snap the view, drag the puck to orbit.
struct NavGizmo: View {
    @Bindable var model: AppModel
    @State private var dragLast: CGPoint?
    @State private var pressed = false

    private struct Axis: Identifiable {
        let id: String
        let label: String
        let dir: SIMD3<Float>
        let color: Color
        let positive: Bool
    }

    private static let red = Color(red: 1, green: 0.2, blue: 0.32)
    private static let green = Color(red: 0.545, green: 0.863, blue: 0)
    private static let blue = Color(red: 0.157, green: 0.565, blue: 1)

    private static let axes: [Axis] = [
        Axis(id: "x", label: "X", dir: [1, 0, 0], color: red, positive: true),
        Axis(id: "-x", label: "", dir: [-1, 0, 0], color: red, positive: false),
        Axis(id: "y", label: "Y", dir: [0, 1, 0], color: green, positive: true),
        Axis(id: "-y", label: "", dir: [0, -1, 0], color: green, positive: false),
        Axis(id: "z", label: "Z", dir: [0, 0, 1], color: blue, positive: true),
        Axis(id: "-z", label: "", dir: [0, 0, -1], color: blue, positive: false),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let cam = model.engine.camera
            let basis = cam.basis
            let fwd = simd_normalize(cam.target - cam.eye)
            let size: CGFloat = 92
            let r: CGFloat = 32
            let proj = Self.project(basis: basis, fwd: fwd, size: size, r: r)

            ZStack {
                Circle()
                    .fill(.clear)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .opacity(pressed ? 1 : 0.85)
                ForEach(proj.filter { $0.axis.positive }) { q in
                    let a = q.axis, p = q.point, depth = q.depth
                    Path { path in
                        path.move(to: CGPoint(x: size / 2, y: size / 2))
                        path.addLine(to: p)
                    }
                    .stroke(a.color.opacity(depth > 0 ? 0.45 : 0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                ForEach(proj) { q in
                    let a = q.axis, p = q.point, depth = q.depth
                    let ballR: CGFloat = a.positive ? 10 : 8
                    ZStack {
                        Circle()
                            .fill(a.positive ? a.color : a.color.opacity(0.28))
                        if !a.positive {
                            Circle().strokeBorder(a.color.opacity(0.9), lineWidth: 1.5)
                        }
                        if !a.label.isEmpty {
                            Text(a.label)
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(.black.opacity(0.75))
                        }
                    }
                    .frame(width: ballR * 2, height: ballR * 2)
                    .scaleEffect(1 - CGFloat(depth) * 0.12)
                    .opacity(depth > 0.2 ? 0.75 : 1)
                    .position(p)
                    .onTapGesture { snap(a.dir) }
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        pressed = true
                        let last = dragLast ?? v.startLocation
                        model.orbitView(dx: Float(v.location.x - last.x), dy: Float(v.location.y - last.y))
                        dragLast = v.location
                    }
                    .onEnded { _ in
                        dragLast = nil
                        withAnimation(.easeOut(duration: 0.25)) { pressed = false }
                    }
            )
        }
    }

    private struct Projected: Identifiable {
        let axis: Axis
        let point: CGPoint
        let depth: Float
        var id: String { axis.id }
    }

    private static func project(basis: (right: SIMD3<Float>, up: SIMD3<Float>), fwd: SIMD3<Float>,
                                size: CGFloat, r: CGFloat) -> [Projected] {
        axes.map { a in
            let x = simd_dot(a.dir, basis.right)
            let y = simd_dot(a.dir, basis.up)
            let depth = simd_dot(a.dir, fwd)          // > 0 = pointing away
            return Projected(axis: a, point: CGPoint(x: size / 2 + CGFloat(x) * r, y: size / 2 - CGFloat(y) * r), depth: depth)
        }
        .sorted { $0.depth > $1.depth }                // far first
    }

    private func snap(_ dir: SIMD3<Float>) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // camera sits on the side the axis points to, looking back at the target
        if abs(dir.z) > 0.5 {
            model.snapView(yaw: -.pi / 2, pitch: dir.z > 0 ? 1.55 : -1.55)
        } else {
            model.snapView(yaw: atan2(dir.y, dir.x), pitch: 0)
        }
    }
}

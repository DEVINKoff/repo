import SwiftUI

struct ColorPanel: View {
    @Bindable var model: AppModel
    @State var hexText = ""
    @State var original: HSBA?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text("Цвет").font(.title3.bold())
                    Spacer()
                    HStack(spacing: 0) {
                        Rectangle().fill((original ?? model.color).color)
                            .onTapGesture { if let o = original { model.color = o } }
                        Rectangle().fill(model.color.color)
                    }
                    .frame(width: 70, height: 30)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.4)))
                    Button {
                        model.showColors = false
                        model.setTool(.eyedropper)
                    } label: {
                        Image(systemName: "eyedropper").frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                }

                ColorWheel(color: $model.color)
                    .frame(width: 290, height: 290)

                VStack(spacing: 10) {
                    channel("H", value: $model.color.h, gradient: hueGradient)
                    channel("S", value: $model.color.s, gradient: [HSBA(h: model.color.h, s: 0, b: model.color.b).color,
                                                                   HSBA(h: model.color.h, s: 1, b: model.color.b).color])
                    channel("B", value: $model.color.b, gradient: [.black, HSBA(h: model.color.h, s: model.color.s, b: 1).color])
                }

                HStack {
                    Text("#").foregroundStyle(.secondary)
                    TextField("RRGGBB", text: $hexText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onSubmit {
                            if let c = HSBA(hex: hexText) { model.color = c; model.pushHistory() }
                        }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))

                if !model.colorHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Недавние").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(model.colorHistory.enumerated()), id: \.offset) { _, c in
                                    swatch(c, size: 30)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Палитра").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.palette.append(model.color)
                            model.saveColors()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 8), count: 8), spacing: 8) {
                        ForEach(Array(model.palette.enumerated()), id: \.offset) { i, c in
                            swatch(c, size: 32)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        model.palette.remove(at: i)
                                        model.saveColors()
                                    } label: { Label("Удалить", systemImage: "trash") }
                                    Button {
                                        model.palette[i] = model.color
                                        model.saveColors()
                                    } label: { Label("Заменить текущим", systemImage: "arrow.triangle.2.circlepath") }
                                }
                        }
                    }
                }
            }
            .padding(18)
        }
        .onAppear {
            original = model.color
            hexText = model.color.hex
        }
        .onChange(of: model.color) { _, c in hexText = c.hex }
        .onDisappear { model.saveColors() }
    }

    private var hueGradient: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { HSBA(h: $0, s: 1, b: 1).color }
    }

    private func swatch(_ c: HSBA, size: CGFloat) -> some View {
        Circle()
            .fill(c.color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white.opacity(c == model.color ? 1 : 0.2), lineWidth: c == model.color ? 2 : 1))
            .onTapGesture {
                model.color = c
            }
    }

    private func channel(_ name: String, value: Binding<Double>, gradient: [Color]) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.caption.bold()).frame(width: 14)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .shadow(radius: 2)
                        .frame(width: 22, height: 22)
                        .offset(x: CGFloat(value.wrappedValue) * (g.size.width - 22))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    value.wrappedValue = max(0, min(1, Double((d.location.x - 11) / max(g.size.width - 22, 1))))
                })
            }
            .frame(height: 22)
            Text("\(Int(round(value.wrappedValue * (name == "H" ? 360 : 100))))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// Hue ring + saturation/brightness square
struct ColorWheel: View {
    @Binding var color: HSBA
    @State var dragTarget = 0   // 1 ring, 2 square

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let ring: CGFloat = 26
            let inner: CGFloat = (size - ring * 2) / CGFloat(2.0).squareRoot() - 8
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .strokeBorder(AngularGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { HSBA(h: $0, s: 1, b: 1).color },
                                                  center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                                  lineWidth: ring)
                    .frame(width: size, height: size)
                ZStack {
                    LinearGradient(colors: [.white, HSBA(h: color.h, s: 1, b: 1).color], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: inner, height: inner)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // hue knob
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .background(Circle().fill(HSBA(h: color.h, s: 1, b: 1).color))
                    .frame(width: ring + 4, height: ring + 4)
                    .shadow(radius: 3)
                    .position(x: center.x + CGFloat(cos(color.h * 2 * Double.pi)) * (size / 2 - ring / 2),
                              y: center.y + CGFloat(sin(color.h * 2 * Double.pi)) * (size / 2 - ring / 2))
                // SV knob
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .background(Circle().fill(color.color))
                    .frame(width: 26, height: 26)
                    .shadow(radius: 3)
                    .position(x: center.x - inner / 2 + CGFloat(color.s) * inner,
                              y: center.y - inner / 2 + CGFloat(1 - color.b) * inner)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let dx = g.location.x - center.x, dy = g.location.y - center.y
                        if dragTarget == 0 {
                            let dist = sqrt(dx * dx + dy * dy)
                            dragTarget = dist > size / 2 - ring - 6 ? 1 : 2
                        }
                        if dragTarget == 1 {
                            var a = atan2(dy, dx) / (2 * .pi)
                            if a < 0 { a += 1 }
                            color.h = Double(a)
                        } else {
                            color.s = Double(max(0, min(1, (g.location.x - (center.x - inner / 2)) / inner)))
                            color.b = Double(max(0, min(1, 1 - (g.location.y - (center.y - inner / 2)) / inner)))
                        }
                    }
                    .onEnded { _ in dragTarget = 0 }
            )
        }
    }
}

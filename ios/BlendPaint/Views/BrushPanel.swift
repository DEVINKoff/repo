import SwiftUI

struct BrushLibrary: View {
    @Bindable var model: AppModel
    @State var showStudio = false

    private var categories: [String] {
        var seen: [String] = []
        for b in model.brushes where !seen.contains(b.category) { seen.append(b.category) }
        return seen
    }

    private var selectedID: UUID { model.tool == .eraser ? model.eraserBrushID : model.brushID }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Инструмент", selection: Binding(get: { model.tool == .eraser ? Tool.eraser : Tool.brush },
                                                            set: { model.setTool($0) })) {
                        Label("Кисть", systemImage: "paintbrush.pointed").tag(Tool.brush)
                        Label("Ластик", systemImage: "eraser").tag(Tool.eraser)
                    }
                    .pickerStyle(.segmented)
                }
                ForEach(categories, id: \.self) { cat in
                    Section(cat) {
                        ForEach(model.brushes.filter { $0.category == cat }) { b in
                            HStack(spacing: 12) {
                                Image(systemName: b.symbol)
                                    .frame(width: 26)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(b.name).font(.subheadline)
                                    BrushStrokePreview(brush: b, color: .white)
                                        .frame(height: 26)
                                }
                                Spacer()
                                if b.id == selectedID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectBrush(b.id) }
                            .swipeActions {
                                if !b.isBuiltIn {
                                    Button(role: .destructive) { model.deleteBrush(b.id) } label: { Label("Удалить", systemImage: "trash") }
                                }
                                Button { model.duplicateBrush(b.id) } label: { Label("Копия", systemImage: "plus.square.on.square") }
                            }
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showStudio) {
                NavigationStack {
                    BrushEditor(model: model, index: model.activeBrushIndex)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Готово") { showStudio = false }
                                    .buttonStyle(.glassProminent)
                            }
                        }
                }
            }
            .navigationTitle(model.tool == .eraser ? "Ластик" : "Кисти")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showStudio = true
                    } label: {
                        Label("Студия кисти", systemImage: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(role: .destructive) { model.resetBrushes() } label: { Label("Сбросить библиотеку", systemImage: "arrow.counterclockwise") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}

/// Procreate "Brush Studio": sections on the left, live drawing pad on the right.
enum StudioSection: String, CaseIterable, Identifiable {
    case stroke, stabilization, taper, shape, grain, rendering, color, dynamics, pencil, properties
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stroke: return "Траектория штриха"
        case .stabilization: return "Стабилизация"
        case .taper: return "Сужение"
        case .shape: return "Форма"
        case .grain: return "Зерно"
        case .rendering: return "Рендеринг"
        case .color: return "Динамика цвета"
        case .dynamics: return "Динамика"
        case .pencil: return "Apple Pencil"
        case .properties: return "Свойства"
        }
    }
    var symbol: String {
        switch self {
        case .stroke: return "scribble.variable"
        case .stabilization: return "waveform.path"
        case .taper: return "chevron.left.forwardslash.chevron.right"
        case .shape: return "seal"
        case .grain: return "circle.grid.3x3.fill"
        case .rendering: return "drop.halffull"
        case .color: return "paintpalette"
        case .dynamics: return "speedometer"
        case .pencil: return "applepencil.tip"
        case .properties: return "slider.horizontal.3"
        }
    }
}

struct BrushEditor: View {
    @Bindable var model: AppModel
    let index: Int
    @State var section: StudioSection = .stroke
    @State var padStrokes: [[StrokeSample]] = []

    var body: some View {
        if model.brushes.indices.contains(index) {
            HStack(spacing: 0) {
                List(StudioSection.allCases, selection: Binding(get: { section }, set: { if let v = $0 { section = v } })) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
                .listStyle(.sidebar)
                .frame(width: 210)
                Form {
                    settings(for: section)
                }
                .frame(minWidth: 300)
                VStack(spacing: 10) {
                    HStack {
                        Text("Площадка для рисования").font(.headline)
                        Spacer()
                        Button("Очистить") { padStrokes = [] }
                            .buttonStyle(.glass)
                    }
                    DrawingPad(brush: model.brushes[index], color: model.color.color, strokes: $padStrokes,
                               curve: { model.applyPressureCurve($0) })
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
                    Text("Рисуй Apple Pencil — меняй настройки, и штрихи перерисуются вживую.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(minWidth: 280)
            }
            .navigationTitle(model.brushes[index].name)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: model.brushes) { _, _ in model.saveBrushes() }
        } else {
            Text("Кисть не найдена")
        }
    }

    private var b: Binding<BrushSettings> { $model.brushes[index] }

    @ViewBuilder
    private func settings(for s: StudioSection) -> some View {
        switch s {
        case .stroke:
            Section {
                slider("Интервал", b.spacing, 0.01...1)
                slider("Дрожание", b.jitter)
                slider("Затухание", b.falloff)
            } footer: { Text("Интервал — расстояние между отпечатками. Затухание гасит штрих по длине.") }
        case .stabilization:
            Section("StreamLine") {
                slider("Количество", b.streamline)
            }
            Section("Стабилизация") {
                slider("Количество", b.stabilization)
            }
            Section {
                slider("Фильтрация движения", b.motionFilter)
            } footer: { Text("Фильтрация убирает мелкую дрожь руки, стабилизация усредняет форму линии.") }
        case .taper:
            Section("Сужение по нажатию / касанию") {
                slider("Начало", b.taperStart)
                slider("Конец", b.taperEnd)
                slider("Размер кончика", b.taperTip)
                slider("Непрозрачность сужения", b.taperOpacity)
            }
        case .shape:
            Section("Источник формы") {
                Picker("Кончик", selection: b.shape) {
                    ForEach(BrushShape.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Свойства формы") {
                slider("Рассеивание", b.scatter)
                Stepper("Число отпечатков: \(model.brushes[index].stampCount)", value: b.stampCount, in: 1...8)
                slider("Округлость", b.roundness, 0.05...1)
                slider("Угол", Binding(get: { model.brushes[index].angle / .pi * 180 },
                                       set: { model.brushes[index].angle = $0 / 180 * .pi }), 0...180, unit: "°")
                Picker("Поворот", selection: b.angleMode) {
                    ForEach(AngleMode.allCases) { Text($0.title).tag($0) }
                }
                slider("Разброс угла", b.angleJitter)
            }
        case .grain:
            Section("Поведение зерна") {
                Picker("Режим", selection: b.grainMode) {
                    ForEach(GrainMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Глубина", b.grain)
                slider("Масштаб", b.grainScale, 0.1...4, unit: "×")
            }
        case .rendering:
            Section {
                slider("Поток", b.flow)
                slider("Жёсткость края", b.hardness)
            } footer: { Text("Поток — сколько краски даёт один отпечаток; непрозрачность — потолок всего штриха (как «Наложение» в Procreate).") }
        case .color:
            Section("Цвет на каждый штрих") {
                slider("Оттенок", b.hueJitter)
                slider("Насыщенность", b.satJitter)
                slider("Яркость", b.brightJitter)
            }
        case .dynamics:
            Section("Скорость") {
                slider("Размер", b.speedSize, -1...1, unit: "±")
                slider("Непрозрачность", b.speedOpacity, -1...1, unit: "±")
            }
            Section("Дрожание") {
                slider("Размер", b.sizeJitter)
                slider("Непрозрачность", b.opacityJitter)
            }
        case .pencil:
            Section("Нажатие") {
                slider("Размер", b.pressureSize)
                slider("Мин. размер", b.minSize)
                slider("Непрозрачность", b.pressureOpacity)
                slider("Поток", b.pressureFlow)
            }
            Section("Наклон") {
                slider("Размер", b.tiltSize)
                slider("Непрозрачность", b.tiltOpacity)
            }
        case .properties:
            Section("Кисть") {
                TextField("Название", text: b.name)
                TextField("Категория", text: b.category)
            }
            Section("Ограничения размера и непрозрачности") {
                slider("Размер", b.size)
                slider("Непрозрачность", b.opacity)
                slider("Мин. предел размера", b.minSizeLimit)
                slider("Макс. предел размера", b.maxSizeLimit)
            }
            Section {
                Button { model.duplicateBrush(model.brushes[index].id) } label: { Label("Дублировать кисть", systemImage: "plus.square.on.square") }
                if let def = BrushSettings.defaults.first(where: { $0.name == model.brushes[index].name }), model.brushes[index].isBuiltIn {
                    Button {
                        var d = def
                        d.id = model.brushes[index].id
                        model.brushes[index] = d
                    } label: { Label("Сбросить настройки", systemImage: "arrow.counterclockwise") }
                }
            }
        }
    }

    private func slider(_ title: String, _ v: Binding<Float>, _ range: ClosedRange<Float> = 0...1, unit: String = "%") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Group {
                    switch unit {
                    case "%": Text("\(Int(round(v.wrappedValue / max(range.upperBound, 0.0001) * 100)))%")
                    case "±": Text("\(Int(round(v.wrappedValue * 100)))%")
                    case "×": Text(String(format: "%.2f×", v.wrappedValue))
                    default: Text("\(Int(round(v.wrappedValue)))\(unit)")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Slider(value: v, in: range)
        }
    }
}

/// Renders dabs with CoreGraphics (used by the stroke previews and the drawing pad).
enum DabPainter {
    static func draw(_ dabs: [GPUDab], brush: BrushSettings, color: Color, in ctx: GraphicsContext) {
        let soft = brush.hardness < 0.6
        let grainy = brush.grain > 0.2 || brush.shape == .spray || brush.shape == .charcoal
        for d in dabs.prefix(6000) {
            let r = CGFloat(d.radius)
            let rect = CGRect(x: -r, y: -r * CGFloat(d.roundness), width: 2 * r, height: 2 * r * CGFloat(d.roundness))
            var c = ctx
            c.translateBy(x: CGFloat(d.center.x), y: CGFloat(d.center.y))
            c.rotate(by: .radians(Double(d.angle)))
            var a = Double(d.alpha) * Double(d.flow) * (soft ? 0.45 : 0.95)
            if grainy { a *= 0.55 + 0.45 * Double(d.seed) }
            c.opacity = min(1, a) * Double(brush.opacity)
            let shape: Path = brush.shape == .square ? Path(rect) : Path(ellipseIn: rect)
            if soft {
                c.fill(shape, with: .radialGradient(Gradient(colors: [color, color.opacity(Double(brush.hardness)), color.opacity(0)]),
                                                    center: .zero, startRadius: 0, endRadius: r))
            } else {
                c.fill(shape, with: .color(color))
            }
        }
    }
}

/// Drawing pad that keeps the raw pen samples, so every settings change redraws the strokes.
struct DrawingPad: View {
    let brush: BrushSettings
    let color: Color
    @Binding var strokes: [[StrokeSample]]
    let curve: (Float) -> Float
    @State private var live: [StrokeSample] = []

    var body: some View {
        ZStack {
            Color(white: 0.11)
            Canvas { ctx, size in
                let base = Float(min(size.width, size.height)) * 0.09 * (0.25 + brush.size * 0.75)
                for s in strokes + (live.isEmpty ? [] : [live]) {
                    let builder = StrokeBuilder(brush: brush, baseRadius: base)
                    var dabs: [GPUDab] = []
                    for p in s { dabs += builder.add(p) }
                    dabs += builder.finish(at: s.last)
                    DabPainter.draw(dabs, brush: brush, color: color, in: ctx)
                }
            }
            PadInput { samples, phase in
                let conv = samples.map { r in
                    StrokeSample(p: SIMD2(Float(r.location.x), Float(r.location.y)), pressure: curve(r.pressure),
                                 tilt: max(0, min(1, 1 - r.altitude / (.pi / 2))), azimuth: r.azimuth, time: r.time)
                }
                switch phase {
                case .began: live = conv
                case .moved: live += conv
                case .ended:
                    live += conv
                    if !live.isEmpty { strokes.append(live) }
                    if strokes.count > 12 { strokes.removeFirst() }
                    live = []
                case .cancelled: live = []
                }
            }
        }
    }
}

private struct PadInput: UIViewRepresentable {
    enum Phase { case began, moved, ended, cancelled }
    let onSamples: ([RawSample], Phase) -> Void

    func makeUIView(context: Context) -> PadView {
        let v = PadView()
        v.onSamples = onSamples
        return v
    }
    func updateUIView(_ v: PadView, context: Context) { v.onSamples = onSamples }

    final class PadView: UIView {
        var onSamples: (([RawSample], Phase) -> Void)?
        private weak var touch: UITouch?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }

        private func samples(_ t: UITouch, _ e: UIEvent?) -> [RawSample] {
            (e?.coalescedTouches(for: t) ?? [t]).map { c in
                RawSample(location: c.location(in: self),
                          pressure: c.type == .pencil && c.maximumPossibleForce > 0 ? Float(c.force / c.maximumPossibleForce) : 0.6,
                          altitude: c.type == .pencil ? Float(c.altitudeAngle) : .pi / 2,
                          azimuth: c.type == .pencil ? Float(c.azimuthAngle(in: self)) : 0,
                          time: c.timestamp)
            }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touch == nil, let t = touches.first else { return }
            touch = t
            onSamples?(samples(t, event), .began)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touch, touches.contains(t) else { return }
            onSamples?(samples(t, event), .moved)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touch, touches.contains(t) else { return }
            onSamples?(samples(t, event), .ended)
            touch = nil
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touch, touches.contains(t) else { return }
            onSamples?([], .cancelled)
            touch = nil
        }
    }
}

/// Renders an S-curve stroke with the real dab generator (pressure ramps up and down).
struct BrushStrokePreview: View {
    let brush: BrushSettings
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            var b = brush
            b.scatter = min(b.scatter, 0.6)
            b.stabilization = 0
            b.falloff = 0
            let base = Float(size.height) * 0.32 * (0.4 + b.size * 0.6)
            let builder = StrokeBuilder(brush: b, baseRadius: base, pressureSmoothing: 0)
            var dabs: [GPUDab] = []
            let n = 60
            var last: StrokeSample?
            for i in 0...n {
                let t = Float(i) / Float(n)
                let x = 8 + t * Float(size.width - 16)
                let y = Float(size.height) * 0.5 + sin(t * .pi * 2) * Float(size.height) * 0.22
                let s = StrokeSample(p: SIMD2(x, y), pressure: sin(t * .pi), tilt: 0.2, azimuth: 0.6, time: Double(i) / 120)
                dabs += builder.add(s)
                last = s
            }
            dabs += builder.finish(at: last)
            DabPainter.draw(dabs, brush: b, color: color, in: ctx)
        }
    }
}

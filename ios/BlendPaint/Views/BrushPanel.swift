import SwiftUI

struct BrushLibrary: View {
    @Bindable var model: AppModel

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
            .navigationTitle(model.tool == .eraser ? "Ластик" : "Кисти")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        BrushEditor(model: model, index: model.activeBrushIndex)
                    } label: {
                        Label("Настроить", systemImage: "slider.horizontal.3")
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

struct BrushEditor: View {
    @Bindable var model: AppModel
    let index: Int

    var body: some View {
        if model.brushes.indices.contains(index) {
            Form {
                Section {
                    BrushStrokePreview(brush: model.brushes[index], color: model.color.color)
                        .frame(height: 70)
                        .listRowBackground(Color.black.opacity(0.35))
                    TextField("Название", text: $model.brushes[index].name)
                    TextField("Категория", text: $model.brushes[index].category)
                }
                Section("Основное") {
                    slider("Размер", $model.brushes[index].size)
                    slider("Непрозрачность", $model.brushes[index].opacity)
                    slider("Поток", $model.brushes[index].flow)
                    slider("Жёсткость", $model.brushes[index].hardness)
                    slider("Интервал", $model.brushes[index].spacing, 0.01...1)
                    slider("Стабилизация (StreamLine)", $model.brushes[index].streamline)
                }
                Section("Форма") {
                    Picker("Кончик", selection: $model.brushes[index].shape) {
                        ForEach(BrushShape.allCases) { Text($0.title).tag($0) }
                    }
                    slider("Округлость", $model.brushes[index].roundness, 0.05...1)
                    slider("Угол", Binding(get: { model.brushes[index].angle / .pi * 180 },
                                           set: { model.brushes[index].angle = $0 / 180 * .pi }), 0...180, unit: "°")
                    Picker("Поворот", selection: $model.brushes[index].angleMode) {
                        ForEach(AngleMode.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Apple Pencil") {
                    slider("Давление → размер", $model.brushes[index].pressureSize)
                    slider("Мин. размер", $model.brushes[index].minSize)
                    slider("Давление → непрозрачность", $model.brushes[index].pressureOpacity)
                    slider("Наклон → размер", $model.brushes[index].tiltSize)
                    slider("Наклон → непрозрачность", $model.brushes[index].tiltOpacity)
                }
                Section("Динамика") {
                    slider("Разброс размера", $model.brushes[index].sizeJitter)
                    slider("Рассеивание", $model.brushes[index].scatter)
                    slider("Разброс угла", $model.brushes[index].angleJitter)
                }
                Section("Зерно") {
                    slider("Сила зерна", $model.brushes[index].grain)
                    slider("Масштаб зерна", $model.brushes[index].grainScale, 0.1...4)
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
            .navigationTitle(model.brushes[index].name)
            .onChange(of: model.brushes) { _, _ in model.saveBrushes() }
        } else {
            Text("Кисть не найдена")
        }
    }

    private func slider(_ title: String, _ v: Binding<Float>, _ range: ClosedRange<Float> = 0...1, unit: String = "%") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(unit == "%" ? "\(Int(round(v.wrappedValue / max(range.upperBound, 0.0001) * 100)))%" : "\(Int(round(v.wrappedValue)))\(unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: v, in: range)
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
            let base = Float(size.height) * 0.32 * (0.4 + b.size * 0.6)
            let builder = StrokeBuilder(brush: b, baseRadius: base)
            var dabs: [GPUDab] = []
            let n = 60
            for i in 0...n {
                let t = Float(i) / Float(n)
                let x = 8 + t * Float(size.width - 16)
                let y = Float(size.height) * 0.5 + sin(t * .pi * 2) * Float(size.height) * 0.22
                let p = sin(t * .pi)
                dabs += builder.add(StrokeSample(p: SIMD2(x, y), pressure: p, tilt: 0.2, azimuth: 0.6))
            }
            let soft = brush.hardness < 0.6
            for d in dabs.prefix(1500) {
                let r = CGFloat(d.radius)
                let rect = CGRect(x: -r, y: -r * CGFloat(d.roundness), width: 2 * r, height: 2 * r * CGFloat(d.roundness))
                var c = ctx
                c.translateBy(x: CGFloat(d.center.x), y: CGFloat(d.center.y))
                c.rotate(by: .radians(Double(d.angle)))
                c.opacity = Double(d.alpha) * (soft ? 0.35 : 0.9) * Double(brush.opacity)
                let shape: Path = brush.shape == .square ? Path(rect) : Path(ellipseIn: rect)
                c.fill(shape, with: .color(color))
            }
        }
    }
}

import SwiftUI

struct LayersPanel: View {
    @Bindable var model: AppModel
    @State var renaming: LayerInfo?
    @State var newName = ""
    @State var opacityDraft: Double = 1
    @State var opacityStart: Double?

    private var active: LayerInfo? { model.layers.first { $0.id == model.activeLayerID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Слои").font(.title3.bold())
                Text("\(model.layers.count)/\(model.engine.maxLayers)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.layerAction { _ = model.engine.addLayer() }
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.layers.count >= model.engine.maxLayers || !model.engine.hasDocument)
            }
            .padding(16)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.layers.reversed()) { l in
                        LayerRow(layer: l, selected: l.id == model.activeLayerID,
                                 toggleVisible: {
                                     model.layerAction { model.engine.setLayerProperty(l.id, name: "Видимость") { $0.visible.toggle() } }
                                 })
                            .onTapGesture {
                                model.engine.selectLayer(l.id)
                                model.refreshLayers()
                            }
                            .contextMenu { menu(for: l) }
                    }
                }
                .padding(.horizontal, 12)
            }

            if let a = active {
                Divider().padding(.top, 6)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Непрозрачность").font(.subheadline)
                        Spacer()
                        Text("\(Int(round(opacityDraft * 100)))%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $opacityDraft, in: 0...1, onEditingChanged: { editing in
                        if editing {
                            opacityStart = Double(a.opacity)
                        } else {
                            let final = Float(opacityDraft)
                            if let s = opacityStart { model.engine.previewLayerOpacity(a.id, Float(s)) }
                            model.layerAction { model.engine.setLayerProperty(a.id, name: "Непрозрачность") { $0.opacity = final } }
                            opacityStart = nil
                        }
                    })
                    .onChange(of: opacityDraft) { _, v in
                        if opacityStart != nil { model.engine.previewLayerOpacity(a.id, Float(v)) }
                    }
                    HStack {
                        Menu {
                            ForEach(BlendMode.allCases) { m in
                                Button {
                                    model.layerAction { model.engine.setLayerProperty(a.id, name: "Режим наложения") { $0.blendMode = m } }
                                } label: {
                                    if m == a.blend { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                                }
                            }
                        } label: {
                            Label(a.blend.title, systemImage: "circle.lefthalf.striped.horizontal")
                                .font(.subheadline)
                        }
                        .buttonStyle(.glass)
                        Spacer()
                        Button {
                            model.layerAction { model.engine.setLayerProperty(a.id, name: "Альфа-замок") { $0.alphaLock.toggle() } }
                        } label: {
                            Image(systemName: a.alphaLock ? "lock.fill" : "lock.open")
                                .frame(width: 20, height: 20)
                        }
                        .glassButton(a.alphaLock)
                        .help("Защита прозрачности")
                    }
                    HStack(spacing: 8) {
                        smallAction("plus.square.on.square", "Дубл.") { model.engine.duplicateLayer(a.id) }
                        smallAction("arrow.down.to.line", "Вниз") { model.engine.mergeDown(a.id) }
                        smallAction("paintbrush", "Залить") { model.engine.fillLayer(a.id, color: model.color.rgba) }
                        smallAction("xmark.square", "Очистить") { model.engine.clearLayer(a.id) }
                        smallAction("trash", "Удалить", role: .destructive) { model.engine.deleteLayer(a.id) }
                            .disabled(model.layers.count < 2)
                    }
                }
                .padding(16)
                .onAppear { opacityDraft = Double(a.opacity) }
                .onChange(of: a.id) { _, _ in opacityDraft = Double(a.opacity) }
                .onChange(of: a.opacity) { _, v in if opacityStart == nil { opacityDraft = Double(v) } }
            }
        }
        .alert("Имя слоя", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Имя", text: $newName)
            Button("Готово") {
                if let r = renaming {
                    let n = newName
                    model.layerAction { model.engine.setLayerProperty(r.id, name: "Переименовать") { $0.name = n } }
                }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        }
    }

    private func smallAction(_ symbol: String, _ title: String, role: ButtonRole? = nil, _ f: @escaping () -> Void) -> some View {
        Button(role: role) {
            model.layerAction(f)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
    }

    @ViewBuilder
    private func menu(for l: LayerInfo) -> some View {
        Button { newName = l.name; renaming = l } label: { Label("Переименовать", systemImage: "pencil") }
        Button { model.layerAction { model.engine.duplicateLayer(l.id) } } label: { Label("Дублировать", systemImage: "plus.square.on.square") }
        Button { model.layerAction { model.engine.moveLayer(l.id, by: 1) } } label: { Label("Поднять", systemImage: "arrow.up") }
        Button { model.layerAction { model.engine.moveLayer(l.id, by: -1) } } label: { Label("Опустить", systemImage: "arrow.down") }
        Button { model.layerAction { model.engine.mergeDown(l.id) } } label: { Label("Объединить с нижним", systemImage: "arrow.down.to.line") }
        Button { model.layerAction { model.engine.fillLayer(l.id, color: model.color.rgba) } } label: { Label("Залить цветом", systemImage: "drop.fill") }
        Button { model.layerAction { model.engine.clearLayer(l.id) } } label: { Label("Очистить", systemImage: "xmark.square") }
        Button { model.layerAction { model.engine.setLayerProperty(l.id, name: "Альфа-замок") { $0.alphaLock.toggle() } } } label: {
            Label(l.alphaLock ? "Снять защиту прозрачности" : "Защитить прозрачность", systemImage: "lock")
        }
        Button { model.layerAction { model.engine.flattenAll() } } label: { Label("Свести все слои", systemImage: "square.stack.3d.down.forward") }
        Divider()
        Button(role: .destructive) { model.layerAction { model.engine.deleteLayer(l.id) } } label: { Label("Удалить", systemImage: "trash") }
    }
}

struct LayerRow: View {
    let layer: LayerInfo
    let selected: Bool
    let toggleVisible: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CheckerBackground()
                if let t = layer.thumbnail {
                    Image(decorative: t, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(layer.name).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(layer.blend.short).font(.caption.bold())
                    if layer.opacity < 0.999 { Text("\(Int(round(layer.opacity * 100)))%").font(.caption) }
                    if layer.alphaLock { Image(systemName: "lock.fill").font(.caption2) }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: toggleVisible) {
                Image(systemName: layer.visible ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(layer.visible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(selected ? Color.accentColor.opacity(0.32) : Color.white.opacity(0.05))
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct CheckerBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) {
                    let odd = (Int(x / s) + Int(y / s)) % 2 == 1
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(odd ? Color(white: 0.75) : Color(white: 0.92)))
                }
            }
        }
    }
}

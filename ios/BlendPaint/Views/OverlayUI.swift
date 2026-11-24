import SwiftUI

struct OverlayUI: View {
    @Bindable var model: AppModel
    @Binding var share: ShareItem?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopBar(model: model, share: $share)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                Spacer()
                BottomBar(model: model)
                    .padding(.bottom, 16)
            }
            HStack {
                if model.settings.sidebarOnRight { Spacer() }
                SideBar(model: model)
                    .padding(.horizontal, 14)
                if !model.settings.sidebarOnRight { Spacer() }
            }
        }
    }
}

// MARK: - top bar

struct TopBar: View {
    @Bindable var model: AppModel
    @Binding var share: ShareItem?

    var body: some View {
        HStack(alignment: .top) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        model.showConnect.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 9, height: 9)
                                .shadow(color: statusColor.opacity(0.8), radius: 4)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.session?.object ?? "Blender")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .contentTransition(.interpolate)
                                    .animation(.spring(duration: 0.4), value: model.session?.object)
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 4)
                        .frame(maxWidth: 260, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                    .popover(isPresented: $model.showConnect) {
                        ConnectPanel(model: model).frame(width: 380, height: 520)
                    }

                    Menu {
                        Section("Blender") {
                            Button { model.requestSession() } label: { Label("Запросить выбранное", systemImage: "arrow.down.circle") }
                            Button { model.resendFull() } label: { Label("Отправить текстуру целиком", systemImage: "arrow.up.circle") }
                            Button { model.saveInBlender() } label: { Label("Сохранить изображение в Blender", systemImage: "square.and.arrow.down") }
                        }
                        Section("iPad") {
                            Button { model.saveProject() } label: { Label("Сохранить слои", systemImage: "tray.and.arrow.down") }
                            Button {
                                if let u = model.exportPNG() { share = ShareItem(url: u) }
                            } label: { Label("Экспорт PNG…", systemImage: "square.and.arrow.up") }
                        }
                        Section {
                            Button { withAnimation { model.uiHidden = true } } label: { Label("Скрыть интерфейс (4 пальца)", systemImage: "arrow.up.left.and.arrow.down.right") }
                            Button { model.showSettings = true } label: { Label("Настройки", systemImage: "gearshape") }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                }
            }

            Spacer(minLength: 20)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    toolButton(.brush, "paintbrush.pointed.fill", popover: $model.showBrushes)
                    toolButton(.eraser, "eraser.fill", popover: $model.showBrushes)
                    Button {
                        model.setTool(model.tool == .eyedropper ? .brush : .eyedropper)
                    } label: {
                        Image(systemName: "eyedropper.halffull").frame(width: 24, height: 24)
                    }
                    .glassButton(model.tool == .eyedropper)

                    if model.sceneObjects.count > 1 {
                        Button {
                            model.showObjects.toggle()
                        } label: {
                            Image(systemName: "cube.transparent").frame(width: 24, height: 24)
                        }
                        .glassButton(model.focusName != nil)
                        .popover(isPresented: $model.showObjects) {
                            ObjectsPanel(model: model).frame(width: 320, height: 520)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }

                    Button {
                        model.showLayers.toggle()
                    } label: {
                        Image(systemName: "square.3.layers.3d").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .popover(isPresented: $model.showLayers) {
                        LayersPanel(model: model).frame(width: 360, height: 600)
                    }

                    Button {
                        model.showColors.toggle()
                    } label: {
                        Circle()
                            .fill(model.color.color)
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glass)
                    .popover(isPresented: $model.showColors) {
                        ColorPanel(model: model).frame(width: 340, height: 600)
                    }
                }
            }
            .popover(isPresented: $model.showBrushes) {
                BrushLibrary(model: model).frame(width: 380, height: 640)
            }
        }
    }

    @ViewBuilder
    private func toolButton(_ t: Tool, _ symbol: String, popover: Binding<Bool>) -> some View {
        Button {
            if model.tool == t {
                popover.wrappedValue.toggle()
            } else {
                model.setTool(t)
            }
        } label: {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .glassButton(model.tool == t)
    }

    private var statusColor: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var subtitle: String {
        if let s = model.session { return "\(s.image.name) · \(s.image.width)×\(s.image.height)" }
        switch model.connection {
        case .connected(let h): return "Подключено · \(h)"
        case .connecting(let h): return "Подключение к \(h)…"
        case .failed(let e): return e
        case .disconnected: return "Не подключено"
        }
    }
}

// MARK: - side bar (size / opacity like Procreate)

struct SideBar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            VerticalSlider(value: Binding(get: { Double(model.activeBrush.size) },
                                          set: { model.activeBrush.size = Float($0) }),
                           label: "Размер", symbol: "circle.circle",
                           preview: { v in AnyView(sizePreview(v)) })
                .frame(width: 40, height: 210)

            Button {
                model.setTool(model.tool == .eyedropper ? .brush : .eyedropper)
            } label: {
                Image(systemName: "eyedropper")
                    .frame(width: 22, height: 22)
            }
            .glassButton(model.tool == .eyedropper)

            VerticalSlider(value: Binding(get: { Double(model.activeBrush.opacity) },
                                          set: { model.activeBrush.opacity = Float($0) }),
                           label: "Непрозрачность", symbol: "circle.lefthalf.filled",
                           preview: nil)
                .frame(width: 40, height: 210)

            VStack(spacing: 10) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .disabled(!model.canUndo)
                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .disabled(!model.canRedo)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func sizePreview(_ v: Double) -> some View {
        var b = model.activeBrush
        b.size = Float(v)
        let r: CGFloat
        if model.engine.hasDocument {
            r = CGFloat(b.radius2D(textureMax: max(model.engine.width, model.engine.height))) * model.canvasTransform.scale
        } else {
            r = CGFloat(b.radius3D())
        }
        let d = max(4, min(220, r * 2))
        return Circle()
            .stroke(.white, lineWidth: 1.5)
            .background(Circle().fill(model.color.color.opacity(0.35)))
            .frame(width: d, height: d)
    }
}

struct VerticalSlider: View {
    @Binding var value: Double
    let label: String
    let symbol: String
    let preview: ((Double) -> AnyView)?
    @State var dragging = false
    @State var startValue: Double = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white.opacity(dragging ? 0.75 : 0.55))
                    .frame(height: max(geo.size.width, h * value))
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(.black.opacity(0.6))
                    .padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging {
                            dragging = true
                            startValue = value
                        }
                        // relative drag (fine control), like Procreate
                        let dv = -Double(g.translation.height / h)
                        value = max(0, min(1, startValue + dv))
                    }
                    .onEnded { _ in dragging = false }
            )
            .overlay(alignment: .leading) {
                if dragging {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(round(value * 100)))%").font(.title3.monospacedDigit().bold())
                        }
                        if let preview { preview(value) }
                    }
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    .fixedSize()
                    .offset(x: geo.size.width + 18)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - bottom bar

struct BottomBar: View {
    @Bindable var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(ViewMode.allCases) { m in
                        Button {
                            withAnimation(.spring(duration: 0.35)) { model.viewMode = m }
                        } label: {
                            Label(m.title, systemImage: m.symbol)
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline)
                        }
                        .glassButton(model.viewMode == m)
                    }
                }

                if let s = model.session, !s.uvMaps.isEmpty {
                    Menu {
                        ForEach(Array(s.uvMaps.enumerated()), id: \.offset) { i, name in
                            Button {
                                model.setPaintUV(i)
                            } label: {
                                if i == model.paintUVIndex {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    } label: {
                        Label(s.uvMaps.indices.contains(model.paintUVIndex) ? s.uvMaps[model.paintUVIndex] : "UV",
                              systemImage: "square.on.square.dashed")
                            .font(.subheadline)
                    }
                    .buttonStyle(.glass)
                }

                Button {
                    model.showWireframe.toggle()
                    model.engine.requestRedraw()
                } label: {
                    Image(systemName: "squareshape.split.3x3")
                        .frame(width: 22, height: 22)
                }
                .glassButton(model.showWireframe)

                Menu {
                    Picker("Свет", selection: $model.lighting) {
                        ForEach(LightingPreset.allCases) { p in
                            Label(p.title, systemImage: p.symbol).tag(p)
                        }
                    }
                } label: {
                    Image(systemName: model.lighting.symbol)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)

                if model.focusName != nil {
                    Button {
                        model.unfocus()
                    } label: {
                        Label("Вся модель", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline)
                    }
                    .buttonStyle(.glassProminent)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                Button {
                    model.fitCanvas()
                    model.resetCamera()
                } label: {
                    Image(systemName: "viewfinder")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
            }
        }
    }
}

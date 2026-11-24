import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

extension View {
    @ViewBuilder
    func glassButton(_ prominent: Bool) -> some View {
        if prominent {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.glass)
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) var phase
    @State var share: ShareItem?

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.035).ignoresSafeArea()
            Workspace(model: model)
                .ignoresSafeArea()

            if !model.uiHidden {
                OverlayUI(model: model, share: $share)
                    .transition(.opacity)
            } else {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(duration: 0.3)) { model.uiHidden = false }
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .padding(20)
                    }
                    Spacer()
                }
            }

            if model.session == nil && !model.loading {
                EmptyStateCard(model: model)
            }

            if model.loading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Получаю меш и текстуру из Blender…").font(.callout)
                }
                .padding(28)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
            }

            VStack(spacing: 10) {
                if let n = model.noTextureObject {
                    NoTextureBanner(model: model, name: n)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                }
                if !model.sceneStatus.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.sceneStatus).font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
                }
                Spacer()
            }
            .padding(.top, 76)
            .animation(.spring(duration: 0.4), value: model.noTextureObject)

            if let offer = model.restoreOffer {
                VStack {
                    RestoreBanner(model: model, meta: offer)
                        .padding(.top, 76)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack(spacing: 8) {
                Spacer()
                ForEach(model.toasts) { t in
                    HStack(spacing: 8) {
                        Image(systemName: t.level == "error" ? "exclamationmark.triangle.fill" :
                                t.level == "warning" ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(t.level == "error" ? .red : t.level == "warning" ? .yellow : .green)
                        Text(t.text).font(.callout).lineLimit(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 92)
            .allowsHitTesting(false)
        }
        .sheet(item: $share) { item in
            ActivityView(items: [item.url])
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsPanel(model: model)
        }
        .onChange(of: phase) { _, p in
            if p == .background || p == .inactive { model.autosave() }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

struct Workspace: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.viewMode {
        case .canvas:
            CanvasViewRep(model: model)
        case .model:
            ModelViewRep(model: model)
        case .split:
            GeometryReader { geo in
                let w = geo.size.width
                let left = max(200, min(w - 200, w * model.splitFraction))
                HStack(spacing: 0) {
                    CanvasViewRep(model: model)
                        .frame(width: left)
                    ZStack {
                        Rectangle().fill(Color.black).frame(width: 2)
                        Capsule()
                            .fill(.white.opacity(0.55))
                            .frame(width: 5, height: 54)
                    }
                    .frame(width: 22)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                            .onChanged { v in
                                model.splitFraction = max(0.2, min(0.8, v.location.x / max(w, 1)))
                            }
                    )
                    ModelViewRep(model: model)
                }
            }
            .coordinateSpace(.named("split"))
        }
    }
}

struct EmptyStateCard: View {
    @Bindable var model: AppModel
    @State var showConnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange.gradient)
                VStack(alignment: .leading) {
                    Text("BlendPaint").font(.largeTitle.bold())
                    Text("Рисуй текстуры Blender на iPad").foregroundStyle(.secondary)
                }
            }
            if model.connection.isConnected {
                Label("Blender подключён\(model.blenderVersion.isEmpty ? "" : " (\(model.blenderVersion))")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("В Blender выбери меш, в Shader Editor кликни по ноде Image Texture — с включённым «Follow selection» она сразу появится здесь. Или нажми «Send to iPad» в панели BlendPaint (N-панель).")
                    .foregroundStyle(.secondary)
                Button {
                    model.requestSession()
                } label: {
                    Label("Запросить текущий выбор", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Установи аддон BlendPaint Bridge в Blender (Edit → Preferences → Add-ons → Install from Disk).")
                    step(2, "Сервер стартует сам; IP ПК виден в N-панели → вкладка BlendPaint.")
                    step(3, "iPad и ПК должны быть в одной Wi‑Fi/LAN сети.")
                }
                Button {
                    showConnect = true
                } label: {
                    Label(connectTitle, systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .popover(isPresented: $showConnect) {
                    ConnectPanel(model: model).frame(width: 380, height: 520)
                }
            }
        }
        .padding(28)
        .frame(width: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
    }

    private var connectTitle: String {
        switch model.connection {
        case .connecting(let h): return "Подключаюсь к \(h)…"
        case .failed: return "Подключиться заново"
        default: return "Подключиться к Blender"
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .glassEffect(.regular.tint(.orange.opacity(0.5)), in: .circle)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct NoTextureBanner: View {
    @Bindable var model: AppModel
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.plus").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("У «\(name)» нет текстуры").font(.headline)
                Text("Создать новую и рисовать на ней?").font(.caption).foregroundStyle(.secondary)
            }
            ForEach([1024, 2048, 4096], id: \.self) { s in
                Button("\(s / 1024)K") { model.createTexture(size: s) }
                    .buttonStyle(.glassProminent)
            }
            Button {
                withAnimation { model.noTextureObject = nil }
            } label: { Image(systemName: "xmark") }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ObjectsPanel: View {
    @Bindable var model: AppModel
    @State var query = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    model.unfocus()
                    model.showObjects = false
                } label: {
                    Label("Вся модель", systemImage: "square.grid.3x3.fill")
                }
                ForEach(model.sceneObjects.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { n in
                    Button {
                        model.focus(n)
                    } label: {
                        HStack {
                            Image(systemName: n == model.session?.object ? "paintbrush.pointed.fill" : "cube")
                                .foregroundStyle(n == model.session?.object ? Color.accentColor : .secondary)
                            Text(n).lineLimit(1)
                            Spacer()
                            if n == model.focusName { Image(systemName: "scope").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .searchable(text: $query, prompt: "Поиск детали")
            .navigationTitle("Объекты (\(model.sceneObjects.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.requestScene() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

struct RestoreBanner: View {
    @Bindable var model: AppModel
    let meta: ProjectStore.Meta

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.3.layers.3d.down.right")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Есть сохранённые слои (\(meta.layers.count))").font(.headline)
                Text(meta.saved.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Button("Восстановить") { withAnimation { model.acceptRestore() } }
                .buttonStyle(.glassProminent)
            Button("Нет") { withAnimation { model.declineRestore() } }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

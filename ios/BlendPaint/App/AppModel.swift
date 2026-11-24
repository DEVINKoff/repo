import SwiftUI
import UIKit
import Observation
import simd

enum Tool: String, CaseIterable, Identifiable {
    case brush, eraser, eyedropper
    var id: String { rawValue }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case canvas, split, model
    var id: String { rawValue }
    var title: String {
        switch self {
        case .canvas: return "2D"
        case .split: return "2D + 3D"
        case .model: return "3D"
        }
    }
    var symbol: String {
        switch self {
        case .canvas: return "square.grid.3x3.square"
        case .split: return "rectangle.split.2x1"
        case .model: return "cube.transparent"
        }
    }
}

enum ViewKind { case canvas, model }

enum ConnState: Equatable {
    case disconnected, connecting(String), connected(String), failed(String)
    var isConnected: Bool { if case .connected = self { return true }; return false }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let level: String
}

struct LayerInfo: Identifiable, Equatable {
    let id: UUID
    let name: String
    let opacity: Float
    let blend: BlendMode
    let visible: Bool
    let alphaLock: Bool
    let thumbnail: CGImage?
    static func == (a: LayerInfo, b: LayerInfo) -> Bool {
        a.id == b.id && a.name == b.name && a.opacity == b.opacity && a.blend == b.blend &&
            a.visible == b.visible && a.alphaLock == b.alphaLock && a.thumbnail === b.thumbnail
    }
}

struct SessionInfo: Equatable {
    let id: Int
    let file: String
    let object: String
    let material: String
    let image: ImageInfo
    let uvMaps: [String]
    let materialDesc: MaterialDesc
    var program: MaterialProgram?
    var key: String { ProjectStore.key(file: file, object: object, image: image.name) }
}

struct AppSettings: Codable, Equatable {
    var fingerPainting = false
    var pressureGamma: Double = 0.65
    var occlusion = true
    var paintBackfaces = false
    var facingFade: Double = 0.15
    var syncFPS: Double = 15
    var liveSync = true
    var wireOpacity: Double = 0.35
    var autoConnect = true
    var showCursor = true
    var paintedAsBase = true
    var sidebarOnRight = false
    var autosave = true
    var exactShader = true
}

/// Raw input sample from a view (points / radians in view space)
struct RawSample {
    var location: CGPoint
    var pressure: Float
    var altitude: Float
    var azimuth: Float
}

struct CanvasTransform {
    var scale: CGFloat = 1
    var rotation: CGFloat = 0
    var offset: CGPoint = .zero

    func toView(_ p: CGPoint) -> CGPoint {
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(x: offset.x + scale * (c * p.x - s * p.y), y: offset.y + scale * (s * p.x + c * p.y))
    }

    func toCanvas(_ v: CGPoint) -> CGPoint {
        let c = cos(-rotation), s = sin(-rotation)
        let x = (v.x - offset.x) / scale, y = (v.y - offset.y) / scale
        return CGPoint(x: c * x - s * y, y: s * x + c * y)
    }

    mutating func apply(pan: CGPoint, pinch: CGFloat, rotate: CGFloat, around ctr: CGPoint) {
        let ds = max(0.02 / scale, min(pinch, 64 / scale))
        let c = cos(rotate), s = sin(rotate)
        let dx = offset.x - ctr.x, dy = offset.y - ctr.y
        offset = CGPoint(x: ctr.x + ds * (c * dx - s * dy) + pan.x, y: ctr.y + ds * (s * dx + c * dy) + pan.y)
        scale *= ds
        rotation += rotate
    }

    mutating func fit(texture: CGSize, in view: CGSize) {
        guard texture.width > 0, view.width > 0 else { return }
        scale = min(view.width / texture.width, view.height / texture.height) * 0.86
        rotation = 0
        offset = CGPoint(x: (view.width - texture.width * scale) / 2, y: (view.height - texture.height * scale) / 2)
    }

    func ndcMatrix(view: CGSize) -> simd_float4x4 {
        let w = Float(max(view.width, 1)), h = Float(max(view.height, 1))
        let s = Float(scale), c = Float(cos(rotation)), sn = Float(sin(rotation))
        let ox = Float(offset.x), oy = Float(offset.y)
        return simd_float4x4(columns: (SIMD4(2 / w * s * c, -2 / h * s * sn, 0, 0),
                                       SIMD4(2 / w * -s * sn, -2 / h * s * c, 0, 0),
                                       SIMD4(0, 0, 1, 0),
                                       SIMD4(2 / w * ox - 1, 1 - 2 / h * oy, 0, 1)))
    }
}

@Observable
final class AppModel {
    @ObservationIgnored let engine: Engine
    @ObservationIgnored let client = BlenderClient()
    @ObservationIgnored weak var modelView: ModelMTKView?
    @ObservationIgnored weak var canvasView: CanvasMTKView?
    @ObservationIgnored var canvasTransform = CanvasTransform()
    @ObservationIgnored var needsFit = true
    @ObservationIgnored private var builder: StrokeBuilder?
    @ObservationIgnored private var strokeKind: ViewKind = .canvas
    @ObservationIgnored private var lastRaw: StrokeSample?
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private var lastSync = Date.distantPast
    @ObservationIgnored private var reconnectWork: DispatchWorkItem?
    @ObservationIgnored private var documentDirty = false
    private var lastHost: String? {
        get { UserDefaults.standard.string(forKey: "lastHost") }
        set { UserDefaults.standard.set(newValue, forKey: "lastHost") }
    }

    // connection
    var connection: ConnState = .disconnected
    var hosts: [DiscoveredHost] = []
    var scanning = false
    var manualHost: String = UserDefaults.standard.string(forKey: "lastHost") ?? ""
    var blenderVersion = ""
    var port: UInt16 = 47800

    // session
    var session: SessionInfo?
    var paintUVIndex = 0
    var loading = false
    var restoreOffer: ProjectStore.Meta?

    // tools
    var tool: Tool = .brush
    @ObservationIgnored private var previousTool: Tool = .brush
    var brushes: [BrushSettings] = []
    var brushID: UUID
    var eraserBrushID: UUID
    var color = HSBA(h: 0.6, s: 0.7, b: 0.85)
    var colorHistory: [HSBA] = []
    var palette: [HSBA] = HSBA.defaultPalette

    // layers
    var layers: [LayerInfo] = []
    var activeLayerID: UUID?
    var canUndo = false
    var canRedo = false

    // view
    var viewMode: ViewMode = .split
    var showWireframe = true
    var lighting: LightingPreset = .studio { didSet { engine.lighting = lighting; engine.requestRedraw() } }
    var uiHidden = false
    var splitFraction: CGFloat = 0.5
    var toasts: [Toast] = []
    var settings = AppSettings() { didSet { applySettings(); saveSettings() } }

    // panels
    var showLayers = false
    var showBrushes = false
    var showColors = false
    var showConnect = false
    var showSettings = false
    var showBrushEditor = false

    init() {
        guard let e = Engine() else { fatalError("Metal is not available") }
        engine = e
        let defaults = BrushSettings.defaults
        brushID = defaults[0].id
        eraserBrushID = defaults[6].id
        loadSettings()
        loadBrushes()
        loadColors()
        engine.lighting = lighting
        engine.onNeedsDisplay = { [weak self] in
            self?.canvasView?.setNeedsDisplay()
            self?.modelView?.setNeedsDisplay()
        }
        engine.onLayersChanged = { [weak self] in self?.refreshLayers() }
        engine.tileSender = { [weak self] rects, payload in
            guard let self, let s = self.session else { return }
            self.client.send(["type": "tiles", "sessionId": s.id, "rects": rects], payload: payload)
        }
        client.onState = { [weak self] st in self?.handleState(st) }
        client.onMessage = { [weak self] type, hdr, payload in self?.handleMessage(type, hdr, payload) }
        applySettings()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
        if settings.autoConnect, let h = lastHost, !h.isEmpty {
            connect(h)
        }
    }

    // MARK: - persistence

    private func loadSettings() {
        if let d = UserDefaults.standard.data(forKey: "settings.v2"), let s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            settings = s
        }
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings.v2") }
    }

    private func applySettings() {
        engine.occlusion = settings.occlusion
        engine.paintBackfaces = settings.paintBackfaces
        engine.facingFade = Float(settings.facingFade)
        if engine.usingProgram != (settings.exactShader && session?.program != nil) {
            applyProgram()
        }
        if engine.showPaintedAsBase != settings.paintedAsBase {
            engine.showPaintedAsBase = settings.paintedAsBase
            if let s = session { engine.setMaterial(s.materialDesc, paintImage: s.image.name, paintNonColor: s.image.colorspace == "Non-Color") }
        }
        canvasView?.configureGestures()
        modelView?.configureGestures()
        engine.requestRedraw()
    }

    private func loadBrushes() {
        if let d = UserDefaults.standard.data(forKey: "brushes.v1"), let b = try? JSONDecoder().decode([BrushSettings].self, from: d), !b.isEmpty {
            brushes = b
        } else {
            brushes = BrushSettings.defaults
        }
        if let s = UserDefaults.standard.string(forKey: "brushID"), let u = UUID(uuidString: s), brushes.contains(where: { $0.id == u }) {
            brushID = u
        } else {
            brushID = brushes[0].id
        }
        if let s = UserDefaults.standard.string(forKey: "eraserID"), let u = UUID(uuidString: s), brushes.contains(where: { $0.id == u }) {
            eraserBrushID = u
        } else {
            eraserBrushID = brushes[min(6, brushes.count - 1)].id
        }
    }

    func saveBrushes() {
        if let d = try? JSONEncoder().encode(brushes) { UserDefaults.standard.set(d, forKey: "brushes.v1") }
        UserDefaults.standard.set(brushID.uuidString, forKey: "brushID")
        UserDefaults.standard.set(eraserBrushID.uuidString, forKey: "eraserID")
    }

    private func loadColors() {
        if let d = UserDefaults.standard.data(forKey: "palette.v1"), let p = try? JSONDecoder().decode([HSBA].self, from: d) { palette = p }
        if let d = UserDefaults.standard.data(forKey: "history.v1"), let p = try? JSONDecoder().decode([HSBA].self, from: d) { colorHistory = p }
        if let d = UserDefaults.standard.data(forKey: "color.v1"), let c = try? JSONDecoder().decode(HSBA.self, from: d) { color = c }
    }

    func saveColors() {
        if let d = try? JSONEncoder().encode(palette) { UserDefaults.standard.set(d, forKey: "palette.v1") }
        if let d = try? JSONEncoder().encode(colorHistory) { UserDefaults.standard.set(d, forKey: "history.v1") }
        if let d = try? JSONEncoder().encode(color) { UserDefaults.standard.set(d, forKey: "color.v1") }
    }

    func pushHistory() {
        if colorHistory.first == color { return }
        colorHistory.removeAll { $0 == color }
        colorHistory.insert(color, at: 0)
        if colorHistory.count > 14 { colorHistory.removeLast(colorHistory.count - 14) }
        saveColors()
    }

    // MARK: - brushes

    var activeBrushIndex: Int {
        let id = tool == .eraser ? eraserBrushID : brushID
        return brushes.firstIndex { $0.id == id } ?? 0
    }

    var activeBrush: BrushSettings {
        get { brushes[activeBrushIndex] }
        set { brushes[activeBrushIndex] = newValue; saveBrushes() }
    }

    func selectBrush(_ id: UUID) {
        if tool == .eraser { eraserBrushID = id } else { brushID = id; if tool == .eyedropper { tool = .brush } }
        saveBrushes()
    }

    func duplicateBrush(_ id: UUID) {
        guard let i = brushes.firstIndex(where: { $0.id == id }) else { return }
        var b = brushes[i]
        b.id = UUID()
        b.name += " копия"
        b.isBuiltIn = false
        brushes.insert(b, at: i + 1)
        selectBrush(b.id)
    }

    func deleteBrush(_ id: UUID) {
        guard brushes.count > 1 else { return }
        brushes.removeAll { $0.id == id }
        if !brushes.contains(where: { $0.id == brushID }) { brushID = brushes[0].id }
        if !brushes.contains(where: { $0.id == eraserBrushID }) { eraserBrushID = brushes[0].id }
        saveBrushes()
    }

    func resetBrushes() {
        brushes = BrushSettings.defaults
        brushID = brushes[0].id
        eraserBrushID = brushes[6].id
        saveBrushes()
    }

    func setTool(_ t: Tool) {
        if t != tool { previousTool = tool }
        tool = t
    }

    func pencilDoubleTap() {
        switch UIPencilInteraction.preferredTapAction {
        case .switchPrevious:
            setTool(previousTool)
        case .showColorPalette:
            showColors.toggle()
        case .ignore:
            break
        default:
            setTool(tool == .eraser ? .brush : .eraser)
        }
    }

    // MARK: - connection

    func connect(_ host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        var hostPart = h
        var p = port
        if let idx = h.lastIndex(of: ":"), let pp = UInt16(h[h.index(after: idx)...]) {
            hostPart = String(h[..<idx])
            p = pp
        }
        reconnectWork?.cancel()
        lastHost = h
        manualHost = h
        client.connect(host: hostPart, port: p)
    }

    func disconnect() {
        lastHost = nil
        reconnectWork?.cancel()
        client.disconnect()
        connection = .disconnected
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        hosts = []
        HostScanner.scan(port: port, found: { [weak self] ip in
            guard let self else { return }
            if !self.hosts.contains(where: { $0.ip == ip }) { self.hosts.append(DiscoveredHost(ip: ip)) }
        }, finished: { [weak self] in
            self?.scanning = false
        })
    }

    private func handleState(_ st: BlenderClient.State) {
        switch st {
        case .disconnected:
            connection = .disconnected
            scheduleReconnect()
        case .connecting(let h):
            connection = .connecting(h)
        case .connected(let h):
            connection = .connected(h)
            client.send(["type": "hello", "client": UIDevice.current.name, "version": 1])
            client.send(["type": "request_session"])
            toast("Подключено к Blender (\(h))")
        case .failed(let e):
            connection = .failed(e)
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard settings.autoConnect, let h = lastHost, !h.isEmpty else { return }
        reconnectWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.connection.isConnected else { return }
            if case .connecting = self.connection { return }
            self.connect(h)
        }
        reconnectWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    func requestSession() { client.send(["type": "request_session"]) }
    func saveInBlender() { client.send(["type": "save_image"]) }

    func resendFull() {
        engine.markDirtyFull()
        engine.markAllSync()
        toast("Текстура отправлена целиком")
    }

    // network queue
    private func handleMessage(_ type: String, _ hdr: Data, _ payload: Data) {
        let dec = JSONDecoder()
        switch type {
        case "hello":
            if let h = try? dec.decode(HelloHeader.self, from: hdr) {
                DispatchQueue.main.async { self.blenderVersion = h.blender ?? "" }
            }
        case "session":
            do {
                let s = try dec.decode(SessionHeader.self, from: hdr)
                DispatchQueue.main.async { self.loading = true }
                var image: Data?
                var textures: [(TextureInfo, Data)] = []
                for b in s.blobs {
                    if b.id == "image" {
                        image = Deflate.decompress(payload.blob(b), rawLength: b.rawLength ?? 0)
                    } else if b.id.hasPrefix("tex:"), let info = s.textures.first(where: { "tex:" + $0.name == b.id }),
                              let d = Deflate.decompress(payload.blob(b), rawLength: b.rawLength ?? 0) {
                        textures.append((info, d))
                    }
                }
                DispatchQueue.main.async {
                    self.applySession(s, payload: payload, image: image, textures: textures)
                    self.loading = false
                }
            } catch {
                DispatchQueue.main.async { self.toast("Ошибка сессии: \(error.localizedDescription)", level: "error") }
            }
        case "material":
            guard let m = try? dec.decode(MaterialHeader.self, from: hdr) else { return }
            var textures: [(TextureInfo, Data)] = []
            for b in m.blobs {
                if let info = m.textures.first(where: { "tex:" + $0.name == b.id }),
                   let d = Deflate.decompress(payload.blob(b), rawLength: b.rawLength ?? 0) {
                    textures.append((info, d))
                }
            }
            DispatchQueue.main.async {
                guard let s = self.session, s.id == m.sessionId else { return }
                for (info, d) in textures {
                    self.engine.addExtraTexture(name: info.name, width: info.width, height: info.height, straightRGBA: d, colorspace: info.colorspace)
                }
                self.session = SessionInfo(id: s.id, file: s.file, object: s.object, material: s.material, image: s.image,
                                           uvMaps: s.uvMaps, materialDesc: m.materialDesc, program: m.program)
                self.engine.setMaterial(m.materialDesc, paintImage: s.image.name, paintNonColor: s.image.colorspace == "Non-Color")
                self.applyProgram()
            }
        case "status":
            if let st = try? dec.decode(StatusHeader.self, from: hdr) {
                DispatchQueue.main.async { self.toast(st.message, level: st.level ?? "info") }
            }
        default:
            break
        }
    }

    private func buffer(_ payload: Data, _ b: BlobInfo?) -> MTLBuffer? {
        guard let b, b.length > 0 else { return nil }
        return payload.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return engine.device.makeBuffer(bytes: base.advanced(by: b.offset), length: b.length, options: .storageModeShared)
        }
    }

    private func applySession(_ s: SessionHeader, payload: Data, image: Data?, textures: [(TextureInfo, Data)]) {
        if engine.strokeActive { engine.cancelStroke() }
        autosave()
        let blobs = Dictionary(s.blobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        engine.clearExtraTextures()
        for (info, d) in textures {
            engine.addExtraTexture(name: info.name, width: info.width, height: info.height, straightRGBA: d, colorspace: info.colorspace)
        }
        engine.newDocument(width: s.image.width, height: s.image.height, straightRGBA: image)
        if image == nil { toast("Не удалось распаковать текстуру", level: "error") }

        // mesh
        if let pb = blobs["positions"], let pos = buffer(payload, pb), let nrm = buffer(payload, blobs["normals"]),
           let idx = buffer(payload, blobs["indices"]) {
            var uvs: [MTLBuffer] = []
            for i in 0..<s.mesh.uvMaps.count {
                if let b = buffer(payload, blobs["uv:\(i)"]) { uvs.append(b) }
            }
            if uvs.isEmpty, let zero = engine.device.makeBuffer(length: max(8, s.mesh.vertexCount * 8), options: .storageModeShared) {
                uvs.append(zero)
            }
            // normalize to a unit sphere
            let n = s.mesh.vertexCount
            let p = pos.contents().bindMemory(to: Float.self, capacity: n * 3)
            var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude), mx = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in 0..<n {
                let v = SIMD3(p[i * 3], p[i * 3 + 1], p[i * 3 + 2])
                mn = simd_min(mn, v); mx = simd_max(mx, v)
            }
            let center = n > 0 ? (mn + mx) * 0.5 : .zero
            var r: Float = 0
            for i in 0..<n {
                r = max(r, simd_length(SIMD3(p[i * 3], p[i * 3 + 1], p[i * 3 + 2]) - center))
            }
            r = max(r, 1e-4)
            let model = simd_float4x4.scale(1 / r) * simd_float4x4.translation(-center)
            let edges = buffer(payload, blobs["edges"])
            let mesh = MeshGPU(positions: pos, normals: nrm, uvs: uvs, uvNames: s.mesh.uvMaps, indices: idx,
                               indexCount: s.mesh.indexCount, paintIndexCount: s.mesh.paintIndexCount,
                               edges: edges, edgeIndexCount: s.mesh.edgeIndexCount ?? 0, model: model)
            for (i, name) in (s.mesh.colorAttrs ?? []).enumerated() {
                if let b = buffer(payload, blobs["col:\(i)"]) {
                    mesh.colors.append(b)
                    mesh.colorNames.append(name)
                }
            }
            paintUVIndex = s.mesh.uvMaps.firstIndex(of: s.paintUV) ?? 0
            engine.setMesh(mesh, paintUV: paintUVIndex)
        }
        engine.setMaterial(s.materialDesc, paintImage: s.image.name, paintNonColor: s.image.colorspace == "Non-Color")
        session = SessionInfo(id: s.sessionId, file: s.file, object: s.object, material: s.material, image: s.image,
                              uvMaps: s.mesh.uvMaps, materialDesc: s.materialDesc, program: s.program)
        engine.setProgram(nil) { _ in }
        applyProgram()
        engine.camera = OrbitCamera()
        needsFit = true
        documentDirty = false
        canvasView?.fitIfNeeded()
        restoreOffer = ProjectStore.meta(for: session!.key).flatMap { m in
            (m.width == s.image.width && m.height == s.image.height && m.layers.count > 0) ? m : nil
        }
        refreshLayers()
        engine.requestRedraw()
        toast("\(s.object) • \(s.image.name) \(s.image.width)×\(s.image.height)")
    }

    @ObservationIgnored private var lastUnsupported: [String] = []
    var shaderStatus = ""

    /// Compile the Blender node tree translated by the add-on (falls back to the simple preview on error)
    func applyProgram() {
        guard settings.exactShader, let p = session?.program else {
            engine.setProgram(nil) { _ in }
            shaderStatus = ""
            return
        }
        shaderStatus = "Компиляция шейдера…"
        engine.setProgram(p) { [weak self] err in
            guard let self else { return }
            if let err {
                self.shaderStatus = "Упрощённое превью"
                self.toast("Шейдер не скомпилировался, показываю упрощённое превью: \(err)", level: "warning")
            } else {
                self.shaderStatus = ""
                if !p.unsupported.isEmpty && p.unsupported != self.lastUnsupported {
                    self.toast("Приблизительно: \(p.unsupported.prefix(4).joined(separator: ", "))", level: "warning")
                }
                self.lastUnsupported = p.unsupported
            }
        }
    }

    func acceptRestore() {
        guard let s = session else { return }
        if ProjectStore.load(key: s.key, engine: engine) {
            toast("Слои восстановлены")
        }
        restoreOffer = nil
    }

    func declineRestore() { restoreOffer = nil }

    func autosave() {
        guard settings.autosave, documentDirty, let s = session, engine.hasDocument else { return }
        ProjectStore.save(key: s.key, engine: engine)
        documentDirty = false
    }

    func saveProject() {
        guard let s = session else { return }
        ProjectStore.save(key: s.key, engine: engine)
        documentDirty = false
        toast("Слои сохранены на iPad")
    }

    func setPaintUV(_ i: Int) {
        paintUVIndex = i
        engine.setPaintUV(i)
    }

    // MARK: - tick / sync

    private func tick() {
        let interval = 1.0 / max(settings.syncFPS, 1)
        guard Date().timeIntervalSince(lastSync) >= interval else { return }
        lastSync = Date()
        let can = settings.liveSync || !engine.strokeActive
        engine.syncTick(canSend: can && connection.isConnected && session != nil && client.pendingBytes < 8 * 1024 * 1024)
    }

    // MARK: - layers

    func refreshLayers() {
        layers = engine.layers.map {
            LayerInfo(id: $0.id, name: $0.name, opacity: $0.opacity, blend: $0.blendMode, visible: $0.visible,
                      alphaLock: $0.alphaLock, thumbnail: $0.thumbnail)
        }
        activeLayerID = engine.activeLayer?.id
        canUndo = engine.canUndo
        canRedo = engine.canRedo
    }

    func undo() { engine.undo(); documentDirty = true }
    func redo() { engine.redo(); documentDirty = true }

    func layerAction(_ f: () -> Void) {
        f()
        documentDirty = true
        refreshLayers()
    }

    // MARK: - input

    private func convert(_ r: RawSample, kind: ViewKind, scale: CGFloat) -> StrokeSample {
        let pr = Float(pow(Double(max(0, min(1, r.pressure))), settings.pressureGamma))
        let tilt = max(0, min(1, 1 - r.altitude / (.pi / 2)))
        switch kind {
        case .canvas:
            let c = canvasTransform.toCanvas(r.location)
            return StrokeSample(p: SIMD2(Float(c.x), Float(c.y)), pressure: pr, tilt: tilt,
                                azimuth: r.azimuth - Float(canvasTransform.rotation))
        case .model:
            return StrokeSample(p: SIMD2(Float(r.location.x * scale), Float(r.location.y * scale)), pressure: pr,
                                tilt: tilt, azimuth: r.azimuth)
        }
    }

    func cursorRadius(_ kind: ViewKind) -> CGFloat {
        guard engine.hasDocument else { return 0 }
        let b = activeBrush
        switch kind {
        case .canvas: return CGFloat(b.radius2D(textureMax: max(engine.width, engine.height))) * canvasTransform.scale
        case .model: return CGFloat(b.radius3D())
        }
    }

    var isStroking: Bool { builder != nil }

    func strokeBegan(_ kind: ViewKind, _ samples: [RawSample], scale: CGFloat) {
        guard engine.hasDocument, let first = samples.first else { return }
        if tool == .eyedropper {
            eyedrop(kind, at: first.location)
            return
        }
        let b = activeBrush
        let radius: Float = kind == .canvas ? b.radius2D(textureMax: max(engine.width, engine.height)) : b.radius3D() * Float(scale)
        builder = StrokeBuilder(brush: b, baseRadius: radius)
        strokeKind = kind
        engine.beginStroke(brush: b, mode: tool == .eraser ? .erase : .paint, color: color.rgba, is3D: kind == .model)
        strokeMoved(samples, scale: scale)
        if tool == .brush { pushHistory() }
    }

    func strokeMoved(_ samples: [RawSample], scale: CGFloat) {
        guard let builder else {
            if tool == .eyedropper, let l = samples.last { eyedrop(lastEyedropKind, at: l.location) }
            return
        }
        var dabs: [GPUDab] = []
        for r in samples {
            let s = convert(r, kind: strokeKind, scale: scale)
            lastRaw = s
            dabs += builder.add(s)
        }
        submit(dabs)
    }

    private func submit(_ dabs: [GPUDab]) {
        guard !dabs.isEmpty else { return }
        switch strokeKind {
        case .canvas:
            engine.addDabs2D(dabs)
        case .model:
            if let ctx = modelView?.projectionContext() { engine.addDabs3D(dabs, ctx: ctx) }
        }
    }

    func strokeEnded() {
        guard let builder else { return }
        submit(builder.finish(at: lastRaw))
        engine.endStroke()
        self.builder = nil
        lastRaw = nil
        documentDirty = true
        refreshLayers()
    }

    func strokeCancelled() {
        guard builder != nil else { return }
        engine.cancelStroke()
        builder = nil
        lastRaw = nil
    }

    // MARK: - eyedropper

    var eyedropPreview: HSBA?
    @ObservationIgnored private var lastEyedropKind: ViewKind = .canvas

    func eyedrop(_ kind: ViewKind, at p: CGPoint) {
        lastEyedropKind = kind
        var px: (Int, Int)?
        switch kind {
        case .canvas:
            let c = canvasTransform.toCanvas(p)
            px = (Int(c.x), Int(c.y))
        case .model:
            guard let mv = modelView, let aux = mv.auxTexture else { break }
            let s = mv.contentScaleFactor
            if let a = engine.readAux(aux, x: Int(p.x * s), y: Int(p.y * s)), a.w > 0.5 {
                var u = a.x - floor(a.x), v = a.y - floor(a.y)
                if u < 0 { u += 1 }
                if v < 0 { v += 1 }
                px = (Int(u * Float(engine.width)), Int((1 - v) * Float(engine.height)))
            }
        }
        guard let pxv = px, let c = engine.sampleComposite(x: pxv.0, y: pxv.1) else { return }
        if c.w < 0.01 { return }
        color = HSBA(r: Double(c.x), g: Double(c.y), b: Double(c.z))
        eyedropPreview = color
    }

    func eyedropEnded() {
        if eyedropPreview != nil {
            pushHistory()
            eyedropPreview = nil
            if tool == .eyedropper { tool = previousTool == .eyedropper ? .brush : previousTool }
        }
    }

    // MARK: - misc

    func toast(_ text: String, level: String = "info") {
        let t = Toast(text: text, level: level)
        withAnimation(.spring(duration: 0.35)) { toasts.append(t) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (level == "error" ? 5 : 2.6)) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.toasts.removeAll { $0.id == t.id } }
        }
    }

    func resetCamera() {
        engine.camera = OrbitCamera()
        engine.requestRedraw()
    }

    func fitCanvas() {
        needsFit = true
        canvasView?.fitIfNeeded()
        engine.requestRedraw()
    }

    func exportPNG() -> URL? {
        guard let img = engine.flattenedImage(), let data = UIImage(cgImage: img).pngData() else { return nil }
        let name = (session?.image.name ?? "texture").replacingOccurrences(of: "/", with: "_")
        let url = ProjectStore.exports.appendingPathComponent(name.hasSuffix(".png") ? name : name + ".png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            toast("Не удалось сохранить PNG", level: "error")
            return nil
        }
    }
}

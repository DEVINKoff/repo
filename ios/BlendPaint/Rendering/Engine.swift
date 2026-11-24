import Metal
import MetalKit
import MetalPerformanceShaders
import UIKit
import simd

enum BlendMode: Int, CaseIterable, Codable, Identifiable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn,
         hardLight, softLight, difference, exclusion, add, subtract
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .normal: return "Обычный"
        case .multiply: return "Умножение"
        case .screen: return "Экран"
        case .overlay: return "Перекрытие"
        case .darken: return "Затемнение"
        case .lighten: return "Замена светлым"
        case .colorDodge: return "Осветление основы"
        case .colorBurn: return "Затемнение основы"
        case .hardLight: return "Жёсткий свет"
        case .softLight: return "Мягкий свет"
        case .difference: return "Разница"
        case .exclusion: return "Исключение"
        case .add: return "Добавление"
        case .subtract: return "Вычитание"
        }
    }
    var short: String {
        switch self {
        case .normal: return "N"
        case .multiply: return "M"
        case .screen: return "S"
        case .overlay: return "O"
        case .darken: return "D"
        case .lighten: return "L"
        case .colorDodge: return "CD"
        case .colorBurn: return "CB"
        case .hardLight: return "HL"
        case .softLight: return "SL"
        case .difference: return "Di"
        case .exclusion: return "E"
        case .add: return "A"
        case .subtract: return "Su"
        }
    }
}

final class PaintLayer: Identifiable {
    let id = UUID()
    var name: String
    var texture: MTLTexture
    var opacity: Float = 1
    var blendMode: BlendMode = .normal
    var visible = true
    var alphaLock = false
    var thumbnail: CGImage?

    init(name: String, texture: MTLTexture) {
        self.name = name
        self.texture = texture
    }
}

final class MeshGPU {
    let positions: MTLBuffer
    let normals: MTLBuffer
    let uvs: [MTLBuffer]
    let uvNames: [String]
    let indices: MTLBuffer
    let indexCount: Int
    let paintIndexCount: Int
    let edges: MTLBuffer?
    let edgeIndexCount: Int
    let model: simd_float4x4

    init(positions: MTLBuffer, normals: MTLBuffer, uvs: [MTLBuffer], uvNames: [String], indices: MTLBuffer,
         indexCount: Int, paintIndexCount: Int, edges: MTLBuffer?, edgeIndexCount: Int, model: simd_float4x4) {
        self.positions = positions; self.normals = normals; self.uvs = uvs; self.uvNames = uvNames
        self.indices = indices; self.indexCount = indexCount; self.paintIndexCount = paintIndexCount
        self.edges = edges; self.edgeIndexCount = edgeIndexCount; self.model = model
    }
}

enum StrokeMode { case paint, erase }

enum LightingPreset: Int, CaseIterable, Identifiable, Codable {
    case studio, outdoor, unlit, clay
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .studio: return "Студия"
        case .outdoor: return "Улица"
        case .unlit: return "Без света"
        case .clay: return "Глина"
        }
    }
    var symbol: String {
        switch self {
        case .studio: return "light.max"
        case .outdoor: return "sun.max"
        case .unlit: return "circle.lefthalf.filled"
        case .clay: return "cube"
        }
    }
}

/// What the 3D view hands to the engine for projection painting.
struct ProjectionContext {
    let aux: MTLTexture
    let viewport: SIMD2<Float>
    let view: simd_float4x4
    let viewProj: simd_float4x4
    let camPos: SIMD3<Float>
}

private struct UndoTile {
    let origin: MTLOrigin
    let size: MTLSize
    var texture: MTLTexture
}

private final class PixelRecord {
    let layerID: UUID
    var tiles: [UndoTile]
    let bytes: Int
    init(layerID: UUID, tiles: [UndoTile]) {
        self.layerID = layerID
        self.tiles = tiles
        self.bytes = tiles.reduce(0) { $0 + $1.size.width * $1.size.height * 4 }
    }
}

private enum UndoEntry {
    case pixels(PixelRecord)
    case action(name: String, bytes: Int, undo: () -> Void, redo: () -> Void)

    var bytes: Int {
        switch self {
        case .pixels(let p): return p.bytes
        case .action(_, let b, _, _): return b
        }
    }
}

final class Engine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary

    private var dabPipeline: MTLRenderPipelineState!
    private var projPipeline: MTLRenderPipelineState!
    private var uvMaskPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!
    private var mergePipeline: MTLRenderPipelineState!
    private(set) var canvasPipeline: MTLRenderPipelineState!
    private(set) var wirePipeline: MTLRenderPipelineState!
    private var meshPipeline: MTLRenderPipelineState!
    private var bgPipeline: MTLRenderPipelineState!
    private var unpremulPipeline: MTLComputePipelineState!
    private var premulPipeline: MTLComputePipelineState!
    private var dilatePipeline: MTLComputePipelineState!
    private var meshDepth: MTLDepthStencilState!
    private var bgDepth: MTLDepthStencilState!

    private(set) var grainTexture: MTLTexture!
    private var whiteTexture: MTLTexture!
    private var flatNormalTexture: MTLTexture!

    // document
    private(set) var width = 0
    private(set) var height = 0
    private(set) var layers: [PaintLayer] = []
    private(set) var activeIndex = 0
    private(set) var composite: MTLTexture?
    private(set) var exportTex: MTLTexture?
    private var exportSRGB: MTLTexture?
    private var stroke: MTLTexture?
    private var strokeTemp: MTLTexture?
    private var uvMask: MTLTexture?
    private var tilesX = 0
    private var tilesY = 0
    private var strokeFlags: MTLBuffer?
    private var syncFlags: MTLBuffer?
    var maxLayers = 16

    // mesh / material
    private(set) var mesh: MeshGPU?
    private(set) var paintUV = 0
    private var secondaryUV = 0
    private var material: MaterialDesc?
    private var paintImageName = ""
    private var paintImageNonColor = false
    private var extraTextures: [String: (linear: MTLTexture, srgb: MTLTexture, nonColor: Bool)] = [:]
    private var meshUniformsBase = MeshUniforms()
    private var slotTextures: [MTLTexture] = []
    var showPaintedAsBase = true
    var lighting: LightingPreset = .studio
    var camera = OrbitCamera()

    // stroke
    private(set) var strokeActive = false
    private var strokeIs3D = false
    private var strokeMode: StrokeMode = .paint
    private var strokeColor = SIMD4<Float>(0, 0, 0, 1)
    private var strokeOpacity: Float = 1
    private var strokeBrush = BrushSettings.defaults[0]
    var occlusion = true
    var paintBackfaces = false
    var facingFade: Float = 0.15

    // dirty tracking for the composite
    private var dirtyFull = true
    private var dirtyMin = SIMD2<Int>(Int.max, Int.max)
    private var dirtyMax = SIMD2<Int>(Int.min, Int.min)

    // undo
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var undoBytes = 0
    var undoBudget = 700 * 1024 * 1024

    // sync
    private var syncInFlight = false
    /// rect infos + payload, called on main
    var tileSender: (([[String: Any]], Data) -> Void)?

    // callbacks (main thread)
    var onNeedsDisplay: (() -> Void)?
    var onLayersChanged: (() -> Void)?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasDocument: Bool { width > 0 }
    var activeLayer: PaintLayer? { layers.indices.contains(activeIndex) ? layers[activeIndex] : nil }

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let lib = d.makeDefaultLibrary() else {
            return nil
        }
        device = d
        queue = q
        library = lib
        do {
            try buildPipelines()
        } catch {
            print("Pipeline error: \(error)")
            return nil
        }
        grainTexture = makeGrainTexture()
        whiteTexture = makeSolidTexture(SIMD4(255, 255, 255, 255))
        flatNormalTexture = makeSolidTexture(SIMD4(128, 128, 255, 255))
        slotTextures = Array(repeating: whiteTexture!, count: 6)
    }

    // MARK: - setup

    private func renderPipe(_ v: String, _ f: String, _ formats: [MTLPixelFormat], blend: Int = 0,
                            depth: MTLPixelFormat = .invalid) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: v)
        d.fragmentFunction = library.makeFunction(name: f)
        for (i, fmt) in formats.enumerated() {
            d.colorAttachments[i].pixelFormat = fmt
        }
        let c = d.colorAttachments[0]!
        if blend == 1 {          // coverage accumulation: r = a + r * (1 - a)
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceColor
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        } else if blend == 2 {   // premultiplied over
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        d.depthAttachmentPixelFormat = depth
        return try device.makeRenderPipelineState(descriptor: d)
    }

    private func computePipe(_ name: String) throws -> MTLComputePipelineState {
        guard let f = library.makeFunction(name: name) else {
            throw NSError(domain: "BlendPaint", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(name)"])
        }
        return try device.makeComputePipelineState(function: f)
    }

    private func buildPipelines() throws {
        dabPipeline = try renderPipe("dabVertex", "dabFragment", [.r16Float])
        projPipeline = try renderPipe("projVertex", "projFragment", [.r16Float])
        uvMaskPipeline = try renderPipe("uvMaskVertex", "uvMaskFragment", [.r8Unorm])
        compositePipeline = try renderPipe("fullscreenVertex", "compositeFragment", [.rgba8Unorm])
        mergePipeline = try renderPipe("fullscreenVertex", "mergeFragment", [.rgba8Unorm])
        canvasPipeline = try renderPipe("canvasVertex", "canvasFragment", [.bgra8Unorm])
        wirePipeline = try renderPipe("wireVertex", "wireFragment", [.bgra8Unorm], blend: 2)
        meshPipeline = try renderPipe("meshVertex", "meshFragment", [.bgra8Unorm_srgb, .rgba32Float], depth: .depth32Float)
        bgPipeline = try renderPipe("fullscreenVertex", "backgroundFragment", [.bgra8Unorm_srgb, .rgba32Float], depth: .depth32Float)
        unpremulPipeline = try computePipe("unpremultiplyKernel")
        premulPipeline = try computePipe("premultiplyKernel")
        dilatePipeline = try computePipe("dilateKernel")

        let md = MTLDepthStencilDescriptor()
        md.depthCompareFunction = .less
        md.isDepthWriteEnabled = true
        meshDepth = device.makeDepthStencilState(descriptor: md)
        let bd = MTLDepthStencilDescriptor()
        bd.depthCompareFunction = .always
        bd.isDepthWriteEnabled = false
        bgDepth = device.makeDepthStencilState(descriptor: bd)
    }

    func makeTexture(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage,
                     storage: MTLStorageMode = .private, mipmapped: Bool = false) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: max(w, 1), height: max(h, 1), mipmapped: mipmapped)
        d.usage = usage
        d.storageMode = storage
        return device.makeTexture(descriptor: d)
    }

    private func makeSolidTexture(_ c: SIMD4<UInt8>) -> MTLTexture {
        let t = makeTexture(.rgba8Unorm, 1, 1, [.shaderRead, .pixelFormatView], storage: .shared)!
        var px = [c.x, c.y, c.z, c.w]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }

    private func makeGrainTexture() -> MTLTexture {
        let n = 256
        var data = [UInt8](repeating: 0, count: n * n)
        var rng = SystemRandomNumberGenerator()
        func lattice(_ period: Int) -> [Float] { (0..<(period * period)).map { _ in Float.random(in: 0...1, using: &rng) } }
        let octaves = [(8, Float(0.45)), (16, Float(0.3)), (32, Float(0.15)), (64, Float(0.1))]
        let grids = octaves.map { lattice($0.0) }
        for y in 0..<n {
            for x in 0..<n {
                var v: Float = 0
                for (oi, o) in octaves.enumerated() {
                    let p = o.0
                    let fx = Float(x) / Float(n) * Float(p), fy = Float(y) / Float(n) * Float(p)
                    let ix = Int(fx), iy = Int(fy)
                    let tx = fx - Float(ix), ty = fy - Float(iy)
                    let g = grids[oi]
                    func at(_ a: Int, _ b: Int) -> Float { g[(b % p) * p + (a % p)] }
                    let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
                    let a = at(ix, iy) + (at(ix + 1, iy) - at(ix, iy)) * sx
                    let b = at(ix, iy + 1) + (at(ix + 1, iy + 1) - at(ix, iy + 1)) * sx
                    v += (a + (b - a) * sy) * o.1
                }
                let contrast = min(max((v - 0.5) * 2.2 + 0.55, 0), 1)
                data[y * n + x] = UInt8(contrast * 255)
            }
        }
        let t = makeTexture(.r8Unorm, n, n, [.shaderRead], storage: .shared)!
        t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: data, bytesPerRow: n)
        return t
    }

    func requestRedraw() { onNeedsDisplay?() }

    // MARK: - document

    /// `straightRGBA` – top-left origin, straight alpha, width*height*4 bytes (or nil for empty)
    func newDocument(width w: Int, height h: Int, straightRGBA: Data?) {
        width = w
        height = h
        tilesX = (w + kTileSize - 1) / kTileSize
        tilesY = (h + kTileSize - 1) / kTileSize
        composite = makeTexture(.rgba8Unorm, w, h, [.renderTarget, .shaderRead])
        exportTex = makeTexture(.rgba8Unorm, w, h, [.shaderRead, .shaderWrite, .pixelFormatView], mipmapped: true)
        exportSRGB = exportTex?.makeTextureView(pixelFormat: .rgba8Unorm_srgb)
        stroke = makeTexture(.r16Float, w, h, [.renderTarget, .shaderRead, .shaderWrite])
        strokeTemp = makeTexture(.r16Float, w, h, [.shaderRead, .shaderWrite])
        uvMask = makeTexture(.r8Unorm, w, h, [.renderTarget, .shaderRead])
        let flagBytes = max(tilesX * tilesY, 1) * 4
        strokeFlags = device.makeBuffer(length: flagBytes, options: .storageModeShared)
        syncFlags = device.makeBuffer(length: flagBytes, options: .storageModeShared)
        if let a = strokeFlags { memset(a.contents(), 0, a.length) }
        if let b = syncFlags { memset(b.contents(), 0, b.length) }
        undoStack.removeAll(); redoStack.removeAll(); undoBytes = 0
        strokeActive = false
        let layerBytes = w * h * 4
        maxLayers = max(3, min(40, (1400 * 1024 * 1024) / max(layerBytes, 1)))

        layers = []
        let base = PaintLayer(name: "Текстура из Blender", texture: newLayerTexture())
        layers.append(base)
        if let cmd = queue.makeCommandBuffer() {
            clear(cmd, base.texture)
            clear(cmd, stroke!, r: 0)
            if let data = straightRGBA, data.count == layerBytes {
                uploadStraight(cmd, data, into: base.texture)
            }
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        let paint = PaintLayer(name: "Слой 1", texture: newLayerTexture())
        if let cmd = queue.makeCommandBuffer() {
            clear(cmd, paint.texture)
            cmd.commit()
        }
        layers.append(paint)
        activeIndex = 1
        markDirtyFull()
        rebuildUVMask()
        updateThumbnails()
        onLayersChanged?()
        requestRedraw()
    }

    /// Replace the layer stack with saved layers (premultiplied RGBA8 data each)
    func restoreLayers(_ saved: [(name: String, opacity: Float, blend: BlendMode, visible: Bool, alphaLock: Bool, premulRGBA: Data)], active: Int) {
        guard hasDocument else { return }
        var newLayers: [PaintLayer] = []
        guard let cmd = queue.makeCommandBuffer() else { return }
        for s in saved where s.premulRGBA.count == width * height * 4 {
            let l = PaintLayer(name: s.name, texture: newLayerTexture())
            l.opacity = s.opacity; l.blendMode = s.blend; l.visible = s.visible; l.alphaLock = s.alphaLock
            uploadRaw(cmd, s.premulRGBA, into: l.texture)
            newLayers.append(l)
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        guard !newLayers.isEmpty else { return }
        layers = newLayers
        activeIndex = min(max(active, 0), layers.count - 1)
        undoStack.removeAll(); redoStack.removeAll(); undoBytes = 0
        markDirtyFull()
        markAllSync()
        updateThumbnails()
        onLayersChanged?()
        requestRedraw()
    }

    private func newLayerTexture() -> MTLTexture {
        makeTexture(.rgba8Unorm, width, height, [.renderTarget, .shaderRead, .shaderWrite])!
    }

    private func clear(_ cmd: MTLCommandBuffer, _ t: MTLTexture, r: Double = 0, g: Double = 0, b: Double = 0, a: Double = 0) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = t
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: r, green: g, blue: b, alpha: a)
        cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    private func makeBuffer(_ data: Data) -> MTLBuffer? {
        data.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: data.count, options: .storageModeShared)
        }
    }

    private func uploadRaw(_ cmd: MTLCommandBuffer, _ data: Data, into t: MTLTexture) {
        guard let buf = makeBuffer(data), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: buf, sourceOffset: 0, sourceBytesPerRow: t.width * 4, sourceBytesPerImage: t.width * t.height * 4,
                  sourceSize: MTLSize(width: t.width, height: t.height, depth: 1),
                  to: t, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
    }

    private func uploadStraight(_ cmd: MTLCommandBuffer, _ data: Data, into t: MTLTexture) {
        guard let staging = makeTexture(.rgba8Unorm, t.width, t.height, [.shaderRead]) else { return }
        uploadRaw(cmd, data, into: staging)
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(premulPipeline)
        enc.setTexture(staging, index: 0)
        enc.setTexture(t, index: 1)
        enc.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }

    // MARK: - mesh & material

    func setMesh(_ m: MeshGPU, paintUV: Int) {
        mesh = m
        self.paintUV = min(max(paintUV, 0), m.uvs.count - 1)
        rebuildUVMask()
        rebuildMaterialBinding()
        requestRedraw()
    }

    func setPaintUV(_ i: Int) {
        guard let m = mesh, m.uvs.indices.contains(i) else { return }
        paintUV = i
        rebuildUVMask()
        rebuildMaterialBinding()
        requestRedraw()
    }

    func setMaterial(_ desc: MaterialDesc, paintImage: String, paintNonColor: Bool) {
        material = desc
        paintImageName = paintImage
        paintImageNonColor = paintNonColor
        rebuildMaterialBinding()
        requestRedraw()
    }

    func addExtraTexture(name: String, width w: Int, height h: Int, straightRGBA: Data, colorspace: String) {
        guard let t = makeTexture(.rgba8Unorm, w, h, [.shaderRead, .pixelFormatView], mipmapped: true),
              let cmd = queue.makeCommandBuffer() else { return }
        uploadRaw(cmd, straightRGBA, into: t)
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
        }
        cmd.commit()
        let srgb = t.makeTextureView(pixelFormat: .rgba8Unorm_srgb) ?? t
        extraTextures[name] = (t, srgb, colorspace == "Non-Color" || colorspace.lowercased().contains("raw"))
    }

    func clearExtraTextures() { extraTextures.removeAll() }

    private func rebuildUVMask() {
        guard let m = mesh, let mask = uvMask, let cmd = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = mask
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(uvMaskPipeline)
            enc.setVertexBuffer(m.uvs[paintUV], offset: 0, index: 0)
            if m.paintIndexCount > 0 {
                enc.drawIndexedPrimitives(type: .triangle, indexCount: m.paintIndexCount, indexType: .uint32,
                                          indexBuffer: m.indices, indexBufferOffset: 0)
            }
            enc.endEncoding()
        }
        cmd.commit()
    }

    private func uvIndex(_ name: String?) -> Int {
        guard let m = mesh else { return 0 }
        if let n = name, let i = m.uvNames.firstIndex(of: n) { return i }
        return paintUV
    }

    private func rebuildMaterialBinding() {
        var u = MeshUniforms()
        let white: MTLTexture = whiteTexture!
        var tex: [MTLTexture] = [white, white, white, flatNormalTexture!, white, white]
        secondaryUV = paintUV
        let slots = material?.slots ?? [:]
        var paintedUsed = false

        func bind(_ key: String, _ slot: Int, color: Bool) -> (on: Bool, chan: Int32, uvSel: Int32) {
            guard let s = slots[key], s.kind == "texture", let img = s.image else { return (false, 4, 0) }
            var t: MTLTexture?
            if img == paintImageName {
                t = (color && !paintImageNonColor) ? exportSRGB : exportTex
                paintedUsed = true
            } else if let e = extraTextures[img] {
                t = (color && !e.nonColor) ? e.srgb : e.linear
            }
            guard let tt = t else { return (false, 4, 0) }
            tex[slot] = tt
            let ui = uvIndex(s.uv)
            var sel: Int32 = 0
            if ui != paintUV { secondaryUV = ui; sel = 1 }
            return (true, s.channelIndex, sel)
        }

        if let v = slots["baseColor"]?.value { u.baseColor = v.color }
        if let v = slots["metallic"]?.value { u.params.x = v.scalar }
        if let v = slots["roughness"]?.value { u.params.y = v.scalar }
        if let v = slots["alpha"]?.value { u.params.z = v.scalar }
        if let v = slots["specular"]?.value { u.params2.x = v.scalar }
        if let v = slots["emission"]?.value { let c = v.color; u.emission = SIMD4(c.x, c.y, c.z, 0) }
        if let v = slots["emissionStrength"]?.value { u.emission.w = v.scalar }
        if material?.shader == "emission" {
            u.emission = SIMD4(u.baseColor.x, u.baseColor.y, u.baseColor.z, max(u.emission.w, 1))
        }

        let b = bind("baseColor", 0, color: true)
        let mt = bind("metallic", 1, color: false)
        let r = bind("roughness", 2, color: false)
        let n = bind("normal", 3, color: false)
        let e = bind("emission", 4, color: true)
        let a = bind("alpha", 5, color: false)
        u.texOn = SIMD4(b.on ? 1 : 0, mt.on ? 1 : 0, r.on ? 1 : 0, n.on ? 1 : 0)
        u.texOn2 = SIMD4(e.on ? 1 : 0, a.on ? 1 : 0, 0, 0)
        u.chan = SIMD4(mt.chan, r.chan, a.chan, 4)
        u.uvSel = SIMD4(b.uvSel, mt.uvSel, r.uvSel, n.uvSel)
        u.uvSel2 = SIMD4(e.uvSel, a.uvSel, 0, 0)
        if n.on, let s = slots["normal"]?.strength { u.params.w = Float(s) }
        if material?.shader == "emission", b.on {
            u.texOn2.x = 1
            tex[4] = tex[0]
            u.uvSel2.x = b.uvSel
        }
        // The painted texture is not wired into a recognized slot → show it as base color
        if !paintedUsed && showPaintedAsBase {
            tex[0] = paintImageNonColor ? (exportTex ?? white) : (exportSRGB ?? white)
            u.texOn.x = 1
            u.uvSel.x = 0
        }
        meshUniformsBase = u
        slotTextures = tex
    }

    private func applyLighting(_ u: inout MeshUniforms) {
        let back = simd_normalize(camera.eye - camera.target)
        let (right, up) = camera.basis
        func camDir(_ x: Float, _ y: Float, _ z: Float) -> SIMD4<Float> {
            let d = simd_normalize(right * x + up * y + back * z)
            return SIMD4(d.x, d.y, d.z, 0)
        }
        switch lighting {
        case .studio, .clay, .unlit:
            u.light0Dir = camDir(-0.55, 0.75, 0.6)
            u.light0Color = SIMD4(2.7, 2.6, 2.45, 0)
            u.light1Dir = camDir(0.8, 0.3, -0.5)
            u.light1Color = SIMD4(1.1, 1.25, 1.5, 0)
            u.skyTop = SIMD4(0.42, 0.44, 0.5, 0)
            u.skyBottom = SIMD4(0.1, 0.1, 0.11, 0)
        case .outdoor:
            u.light0Dir = simd_normalize(SIMD4<Float>(0.45, -0.35, 0.82, 0))
            u.light0Color = SIMD4(3.4, 3.15, 2.8, 0)
            u.light1Dir = SIMD4(0, 0, 1, 0)
            u.light1Color = .zero
            u.skyTop = SIMD4(0.33, 0.5, 0.9, 0)
            u.skyBottom = SIMD4(0.2, 0.17, 0.13, 0)
        }
        u.lighting = UInt32(lighting.rawValue)
    }

    func encodeMesh(_ enc: MTLRenderCommandEncoder, aspect: Float) {
        var u = meshUniformsBase
        let view = camera.view
        let proj = camera.projection(aspect: aspect)
        u.view = view
        u.viewProj = proj * view
        let eye = camera.eye
        u.camPos = SIMD4(eye.x, eye.y, eye.z, 1)
        applyLighting(&u)

        enc.setRenderPipelineState(bgPipeline)
        enc.setDepthStencilState(bgDepth)
        enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 4)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        guard let m = mesh else { return }
        u.model = m.model
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(meshDepth)
        enc.setCullMode(.none)
        enc.setVertexBuffer(m.positions, offset: 0, index: 0)
        enc.setVertexBuffer(m.normals, offset: 0, index: 1)
        enc.setVertexBuffer(m.uvs[paintUV], offset: 0, index: 2)
        enc.setVertexBuffer(m.uvs[min(secondaryUV, m.uvs.count - 1)], offset: 0, index: 3)
        for (i, t) in slotTextures.enumerated() {
            enc.setFragmentTexture(t, index: i)
        }
        enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 4)
        enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 4)
        if m.paintIndexCount > 0 {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.paintIndexCount, indexType: .uint32,
                                      indexBuffer: m.indices, indexBufferOffset: 0)
        }
        let rest = m.indexCount - m.paintIndexCount
        if rest > 0 {
            u.neutral = 1
            enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 4)
            enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 4)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: rest, indexType: .uint32,
                                      indexBuffer: m.indices, indexBufferOffset: m.paintIndexCount * 4)
        }
    }

    // MARK: - composite

    func markDirtyFull() {
        dirtyFull = true
    }

    private func markDirty(x0: Float, y0: Float, x1: Float, y1: Float) {
        let a = SIMD2(max(0, Int(floor(x0))), max(0, Int(floor(y0))))
        let b = SIMD2(min(width, Int(ceil(x1))), min(height, Int(ceil(y1))))
        if b.x <= a.x || b.y <= a.y { return }
        dirtyMin = pointwiseMin(dirtyMin, a)
        dirtyMax = pointwiseMax(dirtyMax, b)
    }

    private var hasDirty: Bool { dirtyFull || (dirtyMax.x > dirtyMin.x && dirtyMax.y > dirtyMin.y) }

    func encodeCompositeIfNeeded(_ cmd: MTLCommandBuffer) {
        guard hasDocument, hasDirty, let composite, let exportTex, let stroke else { return }
        let full = dirtyFull
        var rx = 0, ry = 0, rw = width, rh = height
        if !full {
            rx = dirtyMin.x; ry = dirtyMin.y
            rw = dirtyMax.x - dirtyMin.x; rh = dirtyMax.y - dirtyMin.y
        }
        dirtyFull = false
        dirtyMin = SIMD2(Int.max, Int.max)
        dirtyMax = SIMD2(Int.min, Int.min)

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = composite
        rp.colorAttachments[0].loadAction = full ? .clear : .load
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(compositePipeline)
        enc.setScissorRect(MTLScissorRect(x: rx, y: ry, width: rw, height: rh))
        enc.setFragmentTexture(stroke, index: 1)
        var u = CompositeUniforms()
        if !full {
            u.clearPass = 1
            enc.setFragmentTexture(whiteTexture!, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            u.clearPass = 0
        }
        for (i, l) in layers.enumerated() where l.visible {
            u.layerOpacity = l.opacity
            u.blendMode = UInt32(l.blendMode.rawValue)
            u.alphaLock = l.alphaLock ? 1 : 0
            if strokeActive && i == activeIndex {
                u.strokeMode = strokeMode == .erase ? 2 : 1
                u.strokeOpacity = strokeOpacity
                u.brushColor = strokeColor
            } else {
                u.strokeMode = 0
            }
            enc.setFragmentTexture(l.texture, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()

        guard let ce = cmd.makeComputeCommandEncoder() else { return }
        ce.setComputePipelineState(unpremulPipeline)
        ce.setTexture(composite, index: 0)
        ce.setTexture(exportTex, index: 1)
        var rect = SIMD4<UInt32>(UInt32(rx), UInt32(ry), UInt32(rw), UInt32(rh))
        ce.setBytes(&rect, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 0)
        ce.dispatchThreads(MTLSize(width: rw, height: rh, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        ce.endEncoding()
        if exportTex.mipmapLevelCount > 1, let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: exportTex)
            blit.endEncoding()
        }
    }

    // MARK: - strokes

    func beginStroke(brush: BrushSettings, mode: StrokeMode, color: SIMD4<Float>, is3D: Bool) {
        guard hasDocument, let flags = strokeFlags else { return }
        if strokeActive { endStroke() }
        strokeBrush = brush
        strokeMode = mode
        strokeColor = color
        strokeOpacity = brush.opacity
        strokeIs3D = is3D
        strokeActive = true
        memset(flags.contents(), 0, flags.length)
    }

    private func dabUniforms() -> DabUniforms {
        DabUniforms(targetSize: SIMD2(Float(width), Float(height)), hardness: strokeBrush.hardness,
                    shape: UInt32(strokeBrush.shape.rawValue), grainAmount: strokeBrush.grain,
                    grainScale: strokeBrush.grainScale, tilesX: UInt32(tilesX))
    }

    func addDabs2D(_ dabs: [GPUDab]) {
        guard strokeActive, !strokeIs3D, !dabs.isEmpty, let stroke, let sf = strokeFlags, let yf = syncFlags,
              let cmd = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = stroke
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        var u = dabUniforms()
        enc.setRenderPipelineState(dabPipeline)
        let buf = dabs.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<DabUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<DabUniforms>.stride, index: 1)
        enc.setFragmentTexture(grainTexture, index: 0)
        enc.setFragmentBuffer(sf, offset: 0, index: 2)
        enc.setFragmentBuffer(yf, offset: 0, index: 3)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: dabs.count)
        enc.endEncoding()
        cmd.commit()
        for d in dabs {
            let r = d.radius * 1.15 + 3
            markDirty(x0: d.center.x - r, y0: d.center.y - r, x1: d.center.x + r, y1: d.center.y + r)
        }
        requestRedraw()
    }

    func addDabs3D(_ dabs: [GPUDab], ctx: ProjectionContext) {
        guard strokeActive, strokeIs3D, !dabs.isEmpty, let m = mesh, m.paintIndexCount > 0, let stroke,
              let sf = strokeFlags, let yf = syncFlags, let cmd = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = stroke
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(projPipeline)
        enc.setCullMode(.none)
        enc.setVertexBuffer(m.positions, offset: 0, index: 0)
        enc.setVertexBuffer(m.normals, offset: 0, index: 1)
        enc.setVertexBuffer(m.uvs[paintUV], offset: 0, index: 2)
        enc.setFragmentTexture(ctx.aux, index: 0)
        enc.setFragmentTexture(grainTexture, index: 1)
        enc.setFragmentBuffer(sf, offset: 0, index: 5)
        enc.setFragmentBuffer(yf, offset: 0, index: 6)
        let chunk = 48
        var start = 0
        while start < dabs.count {
            let part = Array(dabs[start..<min(start + chunk, dabs.count)])
            start += chunk
            var mn = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var mx = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for d in part {
                let r = d.radius * 1.15 + 2
                mn = simd_min(mn, d.center - r)
                mx = simd_max(mx, d.center + r)
            }
            var u = ProjUniforms(model: m.model, viewProj: ctx.viewProj, view: ctx.view,
                                 camPos: SIMD4(ctx.camPos.x, ctx.camPos.y, ctx.camPos.z, 1),
                                 viewport: ctx.viewport, bboxMin: mn, bboxMax: mx,
                                 hardness: strokeBrush.hardness, shape: UInt32(strokeBrush.shape.rawValue),
                                 grainAmount: strokeBrush.grain, grainScale: strokeBrush.grainScale,
                                 dabCount: UInt32(part.count), tilesX: UInt32(tilesX),
                                 flags: (occlusion ? 1 : 0) | (paintBackfaces ? 2 : 0), facingFade: facingFade)
            enc.setVertexBytes(&u, length: MemoryLayout<ProjUniforms>.stride, index: 3)
            enc.setFragmentBytes(&u, length: MemoryLayout<ProjUniforms>.stride, index: 3)
            part.withUnsafeBytes { raw in
                enc.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 4)
            }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.paintIndexCount, indexType: .uint32,
                                      indexBuffer: m.indices, indexBufferOffset: 0)
        }
        enc.endEncoding()
        cmd.commit()
        markDirtyFull()
        requestRedraw()
    }

    private func readAndClearFlags(_ buf: MTLBuffer) -> [Int] {
        let n = tilesX * tilesY
        let p = buf.contents().bindMemory(to: UInt32.self, capacity: n)
        var out: [Int] = []
        for i in 0..<n where p[i] != 0 {
            p[i] = 0
            out.append(i)
        }
        return out
    }

    private func tileRect(_ i: Int) -> (MTLOrigin, MTLSize) {
        let tx = i % tilesX, ty = i / tilesX
        let x = tx * kTileSize, y = ty * kTileSize
        return (MTLOrigin(x: x, y: y, z: 0),
                MTLSize(width: min(kTileSize, width - x), height: min(kTileSize, height - y), depth: 1))
    }

    func endStroke() {
        guard strokeActive, let stroke, let strokeTemp, let uvMask, let sf = strokeFlags, let yf = syncFlags else { return }
        guard let layer = activeLayer else { cancelStroke(); return }
        if let cmd = queue.makeCommandBuffer() {
            if strokeIs3D, let ce = cmd.makeComputeCommandEncoder() {
                var tx = UInt32(tilesX)
                ce.setComputePipelineState(dilatePipeline)
                ce.setBuffer(sf, offset: 0, index: 0)
                ce.setBuffer(yf, offset: 0, index: 1)
                ce.setBytes(&tx, length: 4, index: 2)
                ce.setTexture(uvMask, index: 1)
                let grid = MTLSize(width: width, height: height, depth: 1)
                let tg = MTLSize(width: 16, height: 16, depth: 1)
                for _ in 0..<2 {
                    ce.setTexture(stroke, index: 0); ce.setTexture(strokeTemp, index: 2)
                    ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
                    ce.setTexture(strokeTemp, index: 0); ce.setTexture(stroke, index: 2)
                    ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
                }
                ce.endEncoding()
            }
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        let tiles = readAndClearFlags(sf)
        let wasActive = strokeActive
        strokeActive = false
        guard wasActive, !tiles.isEmpty, let cmd = queue.makeCommandBuffer() else {
            if let cmd = queue.makeCommandBuffer() { clear(cmd, stroke); cmd.commit() }
            markDirtyFull()
            requestRedraw()
            return
        }
        // undo snapshot of the touched tiles
        var undoTiles: [UndoTile] = []
        var bbMin = SIMD2<Int>(Int.max, Int.max), bbMax = SIMD2<Int>(0, 0)
        if let blit = cmd.makeBlitCommandEncoder() {
            for t in tiles {
                let (o, s) = tileRect(t)
                guard let tex = makeTexture(.rgba8Unorm, s.width, s.height, [.shaderRead]) else { continue }
                blit.copy(from: layer.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: o, sourceSize: s,
                          to: tex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                undoTiles.append(UndoTile(origin: o, size: s, texture: tex))
                bbMin = pointwiseMin(bbMin, SIMD2(o.x, o.y))
                bbMax = pointwiseMax(bbMax, SIMD2(o.x + s.width, o.y + s.height))
            }
            blit.endEncoding()
        }
        // merge stroke → layer
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = layer.texture
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(mergePipeline)
            enc.setScissorRect(MTLScissorRect(x: bbMin.x, y: bbMin.y, width: bbMax.x - bbMin.x, height: bbMax.y - bbMin.y))
            var u = CompositeUniforms()
            u.brushColor = strokeColor
            u.strokeOpacity = strokeOpacity
            u.strokeMode = strokeMode == .erase ? 2 : 1
            u.alphaLock = layer.alphaLock ? 1 : 0
            enc.setFragmentTexture(stroke, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        clear(cmd, stroke)
        cmd.commit()

        pushUndo(.pixels(PixelRecord(layerID: layer.id, tiles: undoTiles)))
        if strokeIs3D {
            markDirtyFull()
        } else {
            markDirty(x0: Float(bbMin.x), y0: Float(bbMin.y), x1: Float(bbMax.x), y1: Float(bbMax.y))
        }
        scheduleThumbnail(layer)
        requestRedraw()
    }

    func cancelStroke() {
        guard strokeActive, let stroke, let sf = strokeFlags else { return }
        strokeActive = false
        _ = readAndClearFlags(sf)
        if let cmd = queue.makeCommandBuffer() {
            clear(cmd, stroke)
            cmd.commit()
        }
        markDirtyFull()
        requestRedraw()
    }

    // MARK: - undo

    private func pushUndo(_ e: UndoEntry) {
        undoStack.append(e)
        undoBytes += e.bytes
        for r in redoStack { undoBytes -= r.bytes }
        redoStack.removeAll()
        while undoBytes > undoBudget && undoStack.count > 1 {
            let first = undoStack.removeFirst()
            undoBytes -= first.bytes
        }
        onLayersChanged?()
    }

    private func swapPixels(_ rec: PixelRecord) {
        guard let layer = layers.first(where: { $0.id == rec.layerID }), let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return }
        for i in rec.tiles.indices {
            let t = rec.tiles[i]
            guard let tmp = makeTexture(.rgba8Unorm, t.size.width, t.size.height, [.shaderRead]) else { continue }
            blit.copy(from: layer.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: t.origin, sourceSize: t.size,
                      to: tmp, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.copy(from: t.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: t.size,
                      to: layer.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: t.origin)
            rec.tiles[i].texture = tmp
            markSync(x: t.origin.x, y: t.origin.y, w: t.size.width, h: t.size.height)
            markDirty(x0: Float(t.origin.x), y0: Float(t.origin.y),
                      x1: Float(t.origin.x + t.size.width), y1: Float(t.origin.y + t.size.height))
        }
        blit.endEncoding()
        cmd.commit()
        scheduleThumbnail(layer)
    }

    func undo() {
        if strokeActive { cancelStroke(); return }
        guard let e = undoStack.popLast() else { return }
        switch e {
        case .pixels(let p): swapPixels(p)
        case .action(_, _, let u, _): u()
        }
        redoStack.append(e)
        onLayersChanged?()
        requestRedraw()
    }

    func redo() {
        guard let e = redoStack.popLast() else { return }
        switch e {
        case .pixels(let p): swapPixels(p)
        case .action(_, _, _, let r): r()
        }
        undoStack.append(e)
        onLayersChanged?()
        requestRedraw()
    }

    private func performAction(_ name: String, bytes: Int = 0, redo: @escaping () -> Void, undo: @escaping () -> Void) {
        redo()
        pushUndo(.action(name: name, bytes: bytes, undo: undo, redo: redo))
        structureChanged()
    }

    private func structureChanged() {
        markDirtyFull()
        markAllSync()
        onLayersChanged?()
        requestRedraw()
    }

    // MARK: - sync flags

    func markAllSync() {
        guard let yf = syncFlags else { return }
        let n = tilesX * tilesY
        let p = yf.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in 0..<n { p[i] = 1 }
    }

    private func markSync(x: Int, y: Int, w: Int, h: Int) {
        guard let yf = syncFlags, w > 0, h > 0 else { return }
        let p = yf.contents().bindMemory(to: UInt32.self, capacity: tilesX * tilesY)
        for ty in (y / kTileSize)...min(tilesY - 1, (y + h - 1) / kTileSize) {
            for tx in (x / kTileSize)...min(tilesX - 1, (x + w - 1) / kTileSize) {
                p[ty * tilesX + tx] = 1
            }
        }
    }

    /// Reads back changed tiles of the flattened texture and hands them to `tileSender`.
    func syncTick(canSend: Bool) {
        guard canSend, !syncInFlight, hasDocument, let yf = syncFlags, let exportTex, tileSender != nil else { return }
        let tiles = readAndClearFlags(yf)
        guard !tiles.isEmpty else { return }
        // merge horizontal runs of tiles into rects
        var rects: [TileRect] = []
        var i = 0
        while i < tiles.count {
            let row = tiles[i] / tilesX
            let x0 = tiles[i] % tilesX
            var x1 = x0
            var j = i + 1
            while j < tiles.count && tiles[j] / tilesX == row && tiles[j] % tilesX == x1 + 1 {
                x1 += 1
                j += 1
            }
            let px = x0 * kTileSize, py = row * kTileSize
            rects.append(TileRect(x: px, y: py, w: min((x1 + 1) * kTileSize, width) - px, h: min(kTileSize, height - py)))
            i = j
        }
        let total = rects.reduce(0) { $0 + $1.w * $1.h * 4 }
        guard let cmd = queue.makeCommandBuffer(),
              let buf = device.makeBuffer(length: total, options: .storageModeShared) else { return }
        encodeCompositeIfNeeded(cmd)
        var offsets: [Int] = []
        if let blit = cmd.makeBlitCommandEncoder() {
            var off = 0
            for r in rects {
                offsets.append(off)
                blit.copy(from: exportTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: r.x, y: r.y, z: 0),
                          sourceSize: MTLSize(width: r.w, height: r.h, depth: 1), to: buf, destinationOffset: off,
                          destinationBytesPerRow: r.w * 4, destinationBytesPerImage: r.w * r.h * 4)
                off += r.w * r.h * 4
            }
            blit.endEncoding()
        }
        syncInFlight = true
        cmd.addCompletedHandler { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                var payload = Data()
                var infos: [[String: Any]] = []
                for (k, r) in rects.enumerated() {
                    let ptr = buf.contents().advanced(by: offsets[k])
                    let n = r.w * r.h * 4
                    var info: [String: Any] = ["x": r.x, "y": r.y, "w": r.w, "h": r.h, "offset": payload.count]
                    if let d = Deflate.compress(UnsafeRawPointer(ptr), count: n) {
                        info["length"] = d.count
                        payload.append(d)
                    } else {
                        info["length"] = n
                        info["compression"] = "none"
                        payload.append(Data(bytes: ptr, count: n))
                    }
                    infos.append(info)
                }
                DispatchQueue.main.async {
                    self?.tileSender?(infos, payload)
                    self?.syncInFlight = false
                }
            }
        }
        cmd.commit()
    }

    // MARK: - layers

    func selectLayer(_ id: UUID) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        if strokeActive { endStroke() }
        activeIndex = i
        onLayersChanged?()
    }

    @discardableResult
    func addLayer(name: String? = nil) -> Bool {
        guard hasDocument, layers.count < maxLayers else { return false }
        let l = PaintLayer(name: name ?? "Слой \(layers.count)", texture: newLayerTexture())
        if let cmd = queue.makeCommandBuffer() { clear(cmd, l.texture); cmd.commit() }
        let index = activeIndex + 1
        let prevActive = activeIndex
        performAction("Новый слой", redo: { [weak self] in
            guard let self else { return }
            self.layers.insert(l, at: min(index, self.layers.count))
            self.activeIndex = min(index, self.layers.count - 1)
        }, undo: { [weak self] in
            guard let self else { return }
            self.layers.removeAll { $0.id == l.id }
            self.activeIndex = min(prevActive, self.layers.count - 1)
        })
        return true
    }

    func deleteLayer(_ id: UUID) {
        guard layers.count > 1, let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let l = layers[i]
        let prevActive = activeIndex
        performAction("Удалить слой", bytes: width * height * 4, redo: { [weak self] in
            guard let self else { return }
            self.layers.removeAll { $0.id == l.id }
            self.activeIndex = min(max(0, i - 1), self.layers.count - 1)
        }, undo: { [weak self] in
            guard let self else { return }
            self.layers.insert(l, at: min(i, self.layers.count))
            self.activeIndex = prevActive
        })
    }

    func duplicateLayer(_ id: UUID) {
        guard layers.count < maxLayers, let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let src = layers[i]
        let l = PaintLayer(name: src.name + " копия", texture: newLayerTexture())
        l.opacity = src.opacity; l.blendMode = src.blendMode; l.alphaLock = src.alphaLock
        copyTexture(src.texture, to: l.texture)
        let prevActive = activeIndex
        performAction("Дублировать", bytes: width * height * 4, redo: { [weak self] in
            guard let self else { return }
            self.layers.insert(l, at: min(i + 1, self.layers.count))
            self.activeIndex = min(i + 1, self.layers.count - 1)
        }, undo: { [weak self] in
            guard let self else { return }
            self.layers.removeAll { $0.id == l.id }
            self.activeIndex = prevActive
        })
        scheduleThumbnail(l)
    }

    func moveLayer(_ id: UUID, by delta: Int) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard layers.indices.contains(j) else { return }
        let activeID = activeLayer?.id
        func move(_ from: Int, _ to: Int) {
            let l = layers.remove(at: from)
            layers.insert(l, at: to)
            if let a = activeID, let ai = layers.firstIndex(where: { $0.id == a }) { activeIndex = ai }
        }
        performAction("Переместить слой", redo: { move(i, j) }, undo: { move(j, i) })
    }

    func setLayerProperty(_ id: UUID, name: String = "Свойство слоя", apply: @escaping (PaintLayer) -> Void) {
        guard let l = layers.first(where: { $0.id == id }) else { return }
        let before = (l.opacity, l.blendMode, l.visible, l.alphaLock, l.name)
        apply(l)
        let after = (l.opacity, l.blendMode, l.visible, l.alphaLock, l.name)
        pushUndo(.action(name: name, bytes: 0, undo: { [weak self] in
            l.opacity = before.0; l.blendMode = before.1; l.visible = before.2; l.alphaLock = before.3; l.name = before.4
            self?.structureChanged()
        }, redo: { [weak self] in
            l.opacity = after.0; l.blendMode = after.1; l.visible = after.2; l.alphaLock = after.3; l.name = after.4
            self?.structureChanged()
        }))
        structureChanged()
    }

    /// live (non-undoable) preview, e.g. while dragging an opacity slider
    func previewLayerOpacity(_ id: UUID, _ v: Float) {
        guard let l = layers.first(where: { $0.id == id }) else { return }
        l.opacity = v
        markDirtyFull()
        markAllSync()
        requestRedraw()
    }

    private func copyTexture(_ a: MTLTexture, to b: MTLTexture) {
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: a, to: b)
        blit.endEncoding()
        cmd.commit()
    }

    private func snapshotFull(_ l: PaintLayer) -> PixelRecord? {
        guard let t = makeTexture(.rgba8Unorm, width, height, [.shaderRead]) else { return nil }
        copyTexture(l.texture, to: t)
        return PixelRecord(layerID: l.id, tiles: [UndoTile(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1), texture: t)])
    }

    func clearLayer(_ id: UUID) { fillLayer(id, color: nil) }

    /// color: straight sRGB RGBA, nil = transparent
    func fillLayer(_ id: UUID, color: SIMD4<Float>?) {
        guard let l = layers.first(where: { $0.id == id }), let rec = snapshotFull(l), let cmd = queue.makeCommandBuffer() else { return }
        if let c = color {
            clear(cmd, l.texture, r: Double(c.x * c.w), g: Double(c.y * c.w), b: Double(c.z * c.w), a: Double(c.w))
        } else {
            clear(cmd, l.texture)
        }
        cmd.commit()
        pushUndo(.pixels(rec))
        scheduleThumbnail(l)
        structureChanged()
    }

    func mergeDown(_ id: UUID) {
        guard let i = layers.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let top = layers[i], bottom = layers[i - 1]
        guard let before = makeTexture(.rgba8Unorm, width, height, [.shaderRead]) else { return }
        copyTexture(bottom.texture, to: before)
        let prevActive = activeIndex
        performAction("Объединить вниз", bytes: width * height * 8, redo: { [weak self] in
            guard let self else { return }
            self.drawLayer(top, onto: bottom.texture)
            self.layers.removeAll { $0.id == top.id }
            self.activeIndex = self.layers.firstIndex(where: { $0.id == bottom.id }) ?? 0
            self.scheduleThumbnail(bottom)
        }, undo: { [weak self] in
            guard let self else { return }
            self.copyTexture(before, to: bottom.texture)
            if let bi = self.layers.firstIndex(where: { $0.id == bottom.id }) {
                self.layers.insert(top, at: bi + 1)
            }
            self.activeIndex = prevActive
            self.scheduleThumbnail(bottom)
        })
    }

    private func drawLayer(_ l: PaintLayer, onto target: MTLTexture) {
        guard let cmd = queue.makeCommandBuffer(), let stroke else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(compositePipeline)
            var u = CompositeUniforms()
            u.layerOpacity = l.visible ? l.opacity : 0
            u.blendMode = UInt32(l.blendMode.rawValue)
            enc.setFragmentTexture(l.texture, index: 0)
            enc.setFragmentTexture(stroke, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.commit()
    }

    /// Flatten everything into a single layer (undoable)
    func flattenAll() {
        guard layers.count > 1, let flat = makeTexture(.rgba8Unorm, width, height, [.renderTarget, .shaderRead, .shaderWrite]),
              let cmd = queue.makeCommandBuffer() else { return }
        clear(cmd, flat)
        cmd.commit()
        for l in layers where l.visible { drawLayer(l, onto: flat) }
        let old = layers
        let oldActive = activeIndex
        let merged = PaintLayer(name: "Объединённый", texture: flat)
        performAction("Свести слои", bytes: width * height * 4, redo: { [weak self] in
            self?.layers = [merged]
            self?.activeIndex = 0
        }, undo: { [weak self] in
            self?.layers = old
            self?.activeIndex = oldActive
        })
        scheduleThumbnail(merged)
    }

    // MARK: - thumbnails

    private var thumbPending = Set<UUID>()
    private var thumbScheduled = false

    func scheduleThumbnail(_ l: PaintLayer) {
        thumbPending.insert(l.id)
        guard !thumbScheduled else { return }
        thumbScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.thumbScheduled = false
            let ids = self.thumbPending
            self.thumbPending.removeAll()
            for l in self.layers where ids.contains(l.id) { self.makeThumbnail(l) }
        }
    }

    func updateThumbnails() {
        for l in layers { scheduleThumbnail(l) }
    }

    private func makeThumbnail(_ l: PaintLayer) {
        guard hasDocument else { return }
        let maxDim = 96
        let tw = width >= height ? maxDim : max(1, maxDim * width / height)
        let th = height >= width ? maxDim : max(1, maxDim * height / width)
        guard let dst = makeTexture(.rgba8Unorm, tw, th, [.shaderRead, .shaderWrite]),
              let buf = device.makeBuffer(length: tw * th * 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer() else { return }
        let scale = MPSImageBilinearScale(device: device)
        scale.encode(commandBuffer: cmd, sourceTexture: l.texture, destinationTexture: dst)
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: dst, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: tw, height: th, depth: 1),
                      to: buf, destinationOffset: 0, destinationBytesPerRow: tw * 4, destinationBytesPerImage: tw * th * 4)
            blit.endEncoding()
        }
        cmd.addCompletedHandler { [weak self, weak l] _ in
            let img = Engine.cgImage(buf.contents(), width: tw, height: th, premultiplied: true)
            DispatchQueue.main.async {
                l?.thumbnail = img
                self?.onLayersChanged?()
            }
        }
        cmd.commit()
    }

    static func cgImage(_ ptr: UnsafeRawPointer, width: Int, height: Int, premultiplied: Bool) -> CGImage? {
        let data = Data(bytes: ptr, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: (premultiplied ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.last).rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - readback

    private func readback(_ t: MTLTexture, x: Int = 0, y: Int = 0, w: Int, h: Int, bpp: Int = 4,
                          prepare: ((MTLCommandBuffer) -> Void)? = nil) -> MTLBuffer? {
        guard let buf = device.makeBuffer(length: w * h * bpp, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer() else { return nil }
        prepare?(cmd)
        guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: w * bpp, destinationBytesPerImage: w * h * bpp)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return buf
    }

    /// straight sRGB color of the flattened texture at texture pixel
    func sampleComposite(x: Int, y: Int) -> SIMD4<Float>? {
        guard hasDocument, let exportTex, x >= 0, y >= 0, x < width, y < height else { return nil }
        guard let b = readback(exportTex, x: x, y: y, w: 1, h: 1, prepare: { self.encodeCompositeIfNeeded($0) }) else { return nil }
        let p = b.contents().bindMemory(to: UInt8.self, capacity: 4)
        return SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3])) / 255
    }

    func readAux(_ aux: MTLTexture, x: Int, y: Int) -> SIMD4<Float>? {
        guard x >= 0, y >= 0, x < aux.width, y < aux.height,
              let b = readback(aux, x: x, y: y, w: 1, h: 1, bpp: 16) else { return nil }
        let p = b.contents().bindMemory(to: Float.self, capacity: 4)
        return SIMD4(p[0], p[1], p[2], p[3])
    }

    func flattenedImage() -> CGImage? {
        guard hasDocument, let exportTex,
              let b = readback(exportTex, w: width, h: height, prepare: { self.encodeCompositeIfNeeded($0) }) else { return nil }
        return Engine.cgImage(b.contents(), width: width, height: height, premultiplied: false)
    }

    func layerPixels(_ l: PaintLayer) -> Data? {
        guard let b = readback(l.texture, w: width, h: height) else { return nil }
        return Data(bytes: b.contents(), count: width * height * 4)
    }
}

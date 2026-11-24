import MetalKit
import UIKit
import SwiftUI

/// Shared touch / Pencil / gesture handling for the 2D canvas and the 3D viewport.
class PaintInputView: MTKView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    weak var model: AppModel?
    var kind: ViewKind { .canvas }

    private var drawingTouch: UITouch?
    private let cursorLayer = CAShapeLayer()
    private let loupeLayer = CAShapeLayer()
    private let loupeFill = CAShapeLayer()

    let pan1 = UIPanGestureRecognizer()
    let pan2 = UIPanGestureRecognizer()
    let pan3 = UIPanGestureRecognizer()
    let pinch = UIPinchGestureRecognizer()
    let rotate = UIRotationGestureRecognizer()
    let tap2 = UITapGestureRecognizer()
    let tap3 = UITapGestureRecognizer()
    let tap4 = UITapGestureRecognizer()
    let longPress = UILongPressGestureRecognizer()

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero, device: model.engine.device)
        isMultipleTouchEnabled = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        framebufferOnly = true

        cursorLayer.fillColor = UIColor.clear.cgColor
        cursorLayer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        cursorLayer.lineWidth = 1
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.6
        cursorLayer.shadowRadius = 1
        cursorLayer.shadowOffset = .zero
        cursorLayer.isHidden = true
        layer.addSublayer(cursorLayer)

        loupeFill.isHidden = true
        loupeLayer.isHidden = true
        loupeLayer.fillColor = UIColor.clear.cgColor
        loupeLayer.strokeColor = UIColor.white.cgColor
        loupeLayer.lineWidth = 3
        loupeLayer.shadowColor = UIColor.black.cgColor
        loupeLayer.shadowOpacity = 0.4
        loupeLayer.shadowRadius = 6
        layer.addSublayer(loupeFill)
        layer.addSublayer(loupeLayer)

        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for g in [pan1, pan2, pan3, pinch, rotate, tap2, tap3, tap4, longPress] as [UIGestureRecognizer] {
            g.allowedTouchTypes = direct
            g.delegate = self
            addGestureRecognizer(g)
        }
        pan1.addTarget(self, action: #selector(onPan1(_:)))
        pan2.addTarget(self, action: #selector(onTransform(_:)))
        pan3.addTarget(self, action: #selector(onPan3(_:)))
        pinch.addTarget(self, action: #selector(onTransform(_:)))
        rotate.addTarget(self, action: #selector(onTransform(_:)))
        pan1.minimumNumberOfTouches = 1; pan1.maximumNumberOfTouches = 1
        pan2.minimumNumberOfTouches = 2; pan2.maximumNumberOfTouches = 2
        pan3.minimumNumberOfTouches = 3; pan3.maximumNumberOfTouches = 3
        tap2.numberOfTouchesRequired = 2
        tap2.addTarget(self, action: #selector(onUndo))
        tap3.numberOfTouchesRequired = 3
        tap3.addTarget(self, action: #selector(onRedo))
        tap4.numberOfTouchesRequired = 4
        tap4.addTarget(self, action: #selector(onToggleUI))
        longPress.minimumPressDuration = 0.4
        longPress.addTarget(self, action: #selector(onLongPress(_:)))
        tap2.require(toFail: tap3)
        tap3.require(toFail: tap4)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        configureGestures()
    }

    required init(coder: NSCoder) { fatalError() }

    // render at the full Retina resolution (CAMetalLayer-backed views default to 1×)
    var renderScale: CGFloat { 1 }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyScale()
    }

    func applyScale() {
        guard window != nil else { return }
        let scale = (window?.screen.nativeScale ?? traitCollection.displayScale) * renderScale
        if abs(contentScaleFactor - scale) > 0.01 {
            contentScaleFactor = scale
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    func configureGestures() {
        let finger = model?.settings.fingerPainting ?? false
        pan1.isEnabled = !finger
        longPress.isEnabled = true
    }

    // MARK: pencil double tap

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        model?.pencilDoubleTap()
    }

    // MARK: touches (Pencil, and fingers when finger-painting is on)

    private func shouldDraw(_ t: UITouch, _ event: UIEvent?) -> Bool {
        if t.type == .pencil { return true }
        guard model?.settings.fingerPainting == true, t.type == .direct else { return false }
        let fingers = event?.allTouches?.filter { $0.type == .direct }.count ?? 1
        return fingers == 1
    }

    private func samples(_ t: UITouch, _ event: UIEvent?) -> [RawSample] {
        let list = event?.coalescedTouches(for: t) ?? [t]
        return list.map { c in
            let pressure: Float
            if c.type == .pencil, c.maximumPossibleForce > 0 {
                pressure = Float(c.force / c.maximumPossibleForce)
            } else {
                pressure = 1
            }
            return RawSample(location: c.location(in: self), pressure: pressure,
                             altitude: c.type == .pencil ? Float(c.altitudeAngle) : .pi / 2,
                             azimuth: c.type == .pencil ? Float(c.azimuthAngle(in: self)) : 0)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // a second finger while finger-painting → that was a gesture, not a stroke
        if let d = drawingTouch, d.type == .direct, touches.contains(where: { $0.type == .direct }) {
            model?.strokeCancelled()
            drawingTouch = nil
            hideCursor()
            return
        }
        guard drawingTouch == nil, let t = touches.first(where: { shouldDraw($0, event) }) else { return }
        drawingTouch = t
        let s = samples(t, event)
        model?.strokeBegan(kind, s, scale: contentScaleFactor)
        updateCursor(s.last?.location)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = drawingTouch, touches.contains(t) else { return }
        let s = samples(t, event)
        model?.strokeMoved(s, scale: contentScaleFactor)
        updateCursor(s.last?.location)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = drawingTouch, touches.contains(t) else { return }
        model?.strokeMoved(samples(t, event), scale: contentScaleFactor)
        model?.strokeEnded()
        model?.eyedropEnded()
        drawingTouch = nil
        hideCursor()
        hideLoupe()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = drawingTouch, touches.contains(t) else { return }
        if t.type == .pencil {
            model?.strokeEnded()
        } else {
            model?.strokeCancelled()
        }
        drawingTouch = nil
        hideCursor()
    }

    // MARK: cursor / loupe

    private func updateCursor(_ p: CGPoint?) {
        guard let p, let m = model, m.settings.showCursor, m.tool != .eyedropper else { hideCursor(); return }
        let r = max(2, m.cursorRadius(kind))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).cgPath
        cursorLayer.isHidden = false
        CATransaction.commit()
        if m.tool == .eyedropper || m.eyedropPreview != nil { showLoupe(at: p) }
    }

    private func hideCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = true
        CATransaction.commit()
    }

    func showLoupe(at p: CGPoint) {
        guard let c = model?.eyedropPreview ?? model?.color else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r: CGFloat = 44
        let center = CGPoint(x: p.x, y: p.y - 70)
        let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        loupeFill.path = UIBezierPath(ovalIn: rect).cgPath
        loupeFill.fillColor = c.uiColor.withAlphaComponent(1).cgColor
        loupeLayer.path = UIBezierPath(ovalIn: rect).cgPath
        loupeFill.isHidden = false
        loupeLayer.isHidden = false
        CATransaction.commit()
    }

    func hideLoupe() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loupeFill.isHidden = true
        loupeLayer.isHidden = true
        CATransaction.commit()
    }

    // MARK: gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let transforms: [UIGestureRecognizer] = [pan2, pinch, rotate]
        return transforms.contains(g) && transforms.contains(other)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if let t = drawingTouch, t.type == .pencil { return false }
        return true
    }

    @objc func onUndo() { model?.undo() }
    @objc func onRedo() { model?.redo() }
    @objc func onToggleUI() {
        withAnimation(.spring(duration: 0.3)) { model?.uiHidden.toggle() }
    }

    @objc func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard let m = model else { return }
        let p = g.location(in: self)
        switch g.state {
        case .began, .changed:
            m.strokeCancelled()
            drawingTouch = nil
            m.eyedrop(kind, at: p)
            showLoupe(at: p)
        default:
            m.eyedropEnded()
            hideLoupe()
        }
    }

    @objc func onPan1(_ g: UIPanGestureRecognizer) {}
    @objc func onPan3(_ g: UIPanGestureRecognizer) {}
    @objc func onTransform(_ g: UIGestureRecognizer) {}
}

// MARK: - 2D canvas

final class CanvasMTKView: PaintInputView, MTKViewDelegate {
    override var kind: ViewKind { .canvas }
    private var lastPinchCenter: CGPoint?

    override init(model: AppModel) {
        super.init(model: model)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.075, green: 0.078, blue: 0.09, alpha: 1)
        delegate = self
        model.canvasView = self
    }

    required init(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitIfNeeded()
        setNeedsDisplay()
    }

    func fitIfNeeded() {
        guard let m = model, m.needsFit, m.engine.hasDocument, bounds.width > 10 else { return }
        m.canvasTransform.fit(texture: CGSize(width: m.engine.width, height: m.engine.height), in: bounds.size)
        m.needsFit = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let m = model, let drawable = currentDrawable, let rpd = currentRenderPassDescriptor,
              let cmd = m.engine.queue.makeCommandBuffer() else { return }
        let e = m.engine
        e.encodeCompositeIfNeeded(cmd)
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if e.hasDocument, let comp = e.exportTex {
            let zoom = m.canvasTransform.scale * contentScaleFactor
            var u = CanvasUniforms(transform: m.canvasTransform.ndcMatrix(view: bounds.size),
                                   texSize: SIMD2(Float(e.width), Float(e.height)),
                                   checker: Float(10 * contentScaleFactor), nearest: zoom > 6 ? 1 : 0,
                                   wireColor: SIMD4(1, 1, 1, Float(m.settings.wireOpacity)))
            enc.setRenderPipelineState(e.canvasPipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            enc.setFragmentTexture(comp, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if m.showWireframe, let mesh = e.mesh, let edges = mesh.edges, mesh.edgeIndexCount > 0 {
                enc.setRenderPipelineState(e.wirePipeline)
                enc.setVertexBuffer(mesh.uvs[e.paintUV], offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
                enc.drawIndexedPrimitives(type: .line, indexCount: mesh.edgeIndexCount, indexType: .uint32,
                                          indexBuffer: edges, indexBufferOffset: 0)
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    override func configureGestures() {
        super.configureGestures()
        pan3.isEnabled = false
    }

    // one finger (finger painting off) → pan
    @objc override func onPan1(_ g: UIPanGestureRecognizer) {
        guard let m = model else { return }
        let t = g.translation(in: self)
        m.canvasTransform.apply(pan: t, pinch: 1, rotate: 0, around: .zero)
        g.setTranslation(.zero, in: self)
        setNeedsDisplay()
    }

    @objc override func onTransform(_ g: UIGestureRecognizer) {
        guard let m = model else { return }
        if g.state == .began { m.strokeCancelled() }
        var pan = CGPoint.zero
        var s: CGFloat = 1
        var r: CGFloat = 0
        if g === pan2 {
            pan = pan2.translation(in: self)
            pan2.setTranslation(.zero, in: self)
        } else if g === pinch {
            s = pinch.scale
            pinch.scale = 1
        } else if g === rotate {
            r = rotate.rotation
            rotate.rotation = 0
        }
        let c = g.numberOfTouches >= 2 ? g.location(in: self) : (lastPinchCenter ?? g.location(in: self))
        lastPinchCenter = c
        m.canvasTransform.apply(pan: pan, pinch: s, rotate: r, around: c)
        if g.state == .ended {
            // snap rotation to 90° steps when close
            let q = m.canvasTransform.rotation / (.pi / 2)
            if abs(q - q.rounded()) * (.pi / 2) < 0.07 {
                let snapped = q.rounded() * (.pi / 2)
                m.canvasTransform.apply(pan: .zero, pinch: 1, rotate: snapped - m.canvasTransform.rotation, around: c)
            }
        }
        setNeedsDisplay()
    }
}

// MARK: - 3D viewport

final class ModelMTKView: PaintInputView, MTKViewDelegate {
    override var kind: ViewKind { .model }
    override var renderScale: CGFloat { CGFloat(max(0.4, min(1, model?.settings.renderScale ?? 1))) }
    private(set) var auxTexture: MTLTexture?
    private var depthTexture: MTLTexture?

    override init(model: AppModel) {
        super.init(model: model)
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .invalid
        delegate = self
        model.modelView = self
    }

    required init(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        auxTexture = nil
        depthTexture = nil
    }

    private func ensureTargets() {
        guard let e = model?.engine else { return }
        let w = Int(drawableSize.width), h = Int(drawableSize.height)
        guard w > 0, h > 0 else { return }
        if auxTexture?.width != w || auxTexture?.height != h {
            auxTexture = e.makeTexture(.rgba32Float, w, h, [.renderTarget, .shaderRead])
            depthTexture = e.makeTexture(.depth32Float, w, h, [.renderTarget], storage: .memoryless)
        }
    }

    func projectionContext() -> ProjectionContext? {
        guard let e = model?.engine, let aux = auxTexture else { return nil }
        let aspect = Float(drawableSize.width / max(drawableSize.height, 1))
        let view = e.camera.view
        return ProjectionContext(aux: aux, viewport: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                                 view: view, viewProj: e.camera.projection(aspect: aspect) * view, camPos: e.camera.eye)
    }

    func draw(in view: MTKView) {
        guard let m = model, let drawable = currentDrawable, let cmd = m.engine.queue.makeCommandBuffer() else { return }
        ensureTargets()
        guard let aux = auxTexture, let depth = depthTexture else { return }
        m.engine.encodeCompositeIfNeeded(cmd)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1)
        rp.colorAttachments[1].texture = aux
        rp.colorAttachments[1].loadAction = .clear
        rp.colorAttachments[1].storeAction = .store
        rp.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.depthAttachment.texture = depth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .dontCare
        rp.depthAttachment.clearDepth = 1
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        m.engine.encodeMesh(enc, aspect: Float(drawableSize.width / max(drawableSize.height, 1)))
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    override func configureGestures() {
        super.configureGestures()
        let finger = model?.settings.fingerPainting ?? false
        pan3.isEnabled = finger
    }

    private func orbit(_ t: CGPoint) {
        guard let e = model?.engine else { return }
        e.camera.yaw -= Float(t.x) * 0.008
        e.camera.pitch = max(-1.55, min(1.55, e.camera.pitch + Float(t.y) * 0.008))
        setNeedsDisplay()
    }

    private func panTarget(_ t: CGPoint) {
        guard let e = model?.engine else { return }
        let (r, u) = e.camera.basis
        let k = e.camera.distance * 0.0018
        e.camera.target += (-r * Float(t.x) + u * Float(t.y)) * k
        setNeedsDisplay()
    }

    @objc override func onPan1(_ g: UIPanGestureRecognizer) {
        orbit(g.translation(in: self))
        g.setTranslation(.zero, in: self)
    }

    @objc override func onPan3(_ g: UIPanGestureRecognizer) {
        panTarget(g.translation(in: self))
        g.setTranslation(.zero, in: self)
    }

    @objc override func onTransform(_ g: UIGestureRecognizer) {
        guard let m = model else { return }
        if g.state == .began { m.strokeCancelled() }
        if g === pan2 {
            let t = pan2.translation(in: self)
            if m.settings.fingerPainting { orbit(t) } else { panTarget(t) }
            pan2.setTranslation(.zero, in: self)
        } else if g === pinch {
            m.engine.camera.distance = max(0.15, min(40, m.engine.camera.distance / Float(max(pinch.scale, 0.01))))
            pinch.scale = 1
            setNeedsDisplay()
        }
    }
}

// MARK: - SwiftUI wrappers

struct CanvasViewRep: UIViewRepresentable {
    let model: AppModel
    func makeUIView(context: Context) -> CanvasMTKView { CanvasMTKView(model: model) }
    func updateUIView(_ v: CanvasMTKView, context: Context) { v.setNeedsDisplay() }
}

struct ModelViewRep: UIViewRepresentable {
    let model: AppModel
    func makeUIView(context: Context) -> ModelMTKView { ModelMTKView(model: model) }
    func updateUIView(_ v: ModelMTKView, context: Context) { v.setNeedsDisplay() }
}

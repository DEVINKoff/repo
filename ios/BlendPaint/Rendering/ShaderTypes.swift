import simd

// Mirrors of the structs in Shaders.metal (same field order and SIMD types → same layout).

let kTileSize = 256

struct GPUDab {
    var center: SIMD2<Float>
    var radius: Float
    var angle: Float
    var roundness: Float
    var alpha: Float
    var seed: Float
    var flow: Float = 1
}

struct DabUniforms {
    var targetSize: SIMD2<Float>
    var hardness: Float
    var shape: UInt32
    var grainAmount: Float
    var grainScale: Float
    var tilesX: UInt32
    var pad: UInt32 = 0
}

struct ProjUniforms {
    var model: simd_float4x4
    var viewProj: simd_float4x4
    var view: simd_float4x4
    var camPos: SIMD4<Float>
    var viewport: SIMD2<Float>
    var bboxMin: SIMD2<Float>
    var bboxMax: SIMD2<Float>
    var hardness: Float
    var shape: UInt32
    var grainAmount: Float
    var grainScale: Float
    var dabCount: UInt32
    var tilesX: UInt32
    var flags: UInt32
    var facingFade: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

struct CompositeUniforms {
    var brushColor: SIMD4<Float> = .zero
    var layerOpacity: Float = 1
    var strokeOpacity: Float = 1
    var blendMode: UInt32 = 0
    var strokeMode: UInt32 = 0
    var alphaLock: UInt32 = 0
    var clearPass: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

struct CanvasUniforms {
    var transform: simd_float4x4
    var texSize: SIMD2<Float>
    var checker: Float
    var nearest: UInt32
    var wireColor: SIMD4<Float>
}

struct MeshUniforms {
    var model = matrix_identity_float4x4
    var viewProj = matrix_identity_float4x4
    var view = matrix_identity_float4x4
    var camPos = SIMD4<Float>(0, 0, 0, 1)
    var baseColor = SIMD4<Float>(0.8, 0.8, 0.8, 1)
    var emission = SIMD4<Float>(0, 0, 0, 0)
    var light0Dir = SIMD4<Float>(0, 0, 1, 0)
    var light0Color = SIMD4<Float>(1, 1, 1, 0)
    var light1Dir = SIMD4<Float>(0, 0, 1, 0)
    var light1Color = SIMD4<Float>(0, 0, 0, 0)
    var skyTop = SIMD4<Float>(0.3, 0.3, 0.3, 0)
    var skyBottom = SIMD4<Float>(0.1, 0.1, 0.1, 0)
    var params = SIMD4<Float>(0, 0.5, 1, 1)      // metallic, roughness, alpha, normalStrength
    var params2 = SIMD4<Float>(0.5, 1, 0, 0)     // specular, exposure
    var texOn = SIMD4<Int32>(repeating: 0)
    var texOn2 = SIMD4<Int32>(repeating: 0)
    var chan = SIMD4<Int32>(repeating: 4)
    var uvSel = SIMD4<Int32>(repeating: 0)
    var uvSel2 = SIMD4<Int32>(repeating: 0)
    var lighting: UInt32 = 0
    var neutral: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var objInv = matrix_identity_float4x4
}

// MARK: - math

extension simd_float4x4 {
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0),
                                       SIMD4(0, y, 0, 0),
                                       SIMD4(0, 0, z, -1),
                                       SIMD4(0, 0, z * near, 0)))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        var s = simd_cross(f, up)
        if simd_length(s) < 1e-5 { s = simd_cross(f, SIMD3(0, 1, 0)) }
        s = simd_normalize(s)
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0),
                                       SIMD4(s.y, u.y, -f.y, 0),
                                       SIMD4(s.z, u.z, -f.z, 0),
                                       SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }
}

struct OrbitCamera {
    var yaw: Float = -.pi * 0.5 + 0.6
    var pitch: Float = 0.25
    var distance: Float = 3.2
    var target = SIMD3<Float>(0, 0, 0)
    var fovY: Float = 0.7

    var eye: SIMD3<Float> {
        let cp = cos(pitch)
        return target + distance * SIMD3(cp * cos(yaw), cp * sin(yaw), sin(pitch))
    }

    var view: simd_float4x4 { .lookAt(eye: eye, target: target, up: SIMD3(0, 0, 1)) }

    func projection(aspect: Float) -> simd_float4x4 {
        .perspective(fovY: fovY, aspect: max(aspect, 0.01), near: max(0.01, distance * 0.02), far: distance * 10 + 10)
    }

    /// camera-space right/up vectors in world space
    var basis: (right: SIMD3<Float>, up: SIMD3<Float>) {
        let v = view
        let r = SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x)
        let u = SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
        return (r, u)
    }
}

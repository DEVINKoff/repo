import Foundation
import Compression

// Messages exchanged with the Blender add-on (see blender_addon/blendpaint_bridge).

struct MessageType: Decodable { let type: String }

struct BlobInfo: Codable {
    let id: String
    let offset: Int
    let length: Int
    let compression: String?
    let rawLength: Int?
}

struct ImageInfo: Codable, Equatable {
    let name: String
    let width: Int
    let height: Int
    let isFloat: Bool
    let colorspace: String
    let alphaMode: String?
}

struct MeshInfo: Codable, Equatable {
    let name: String
    let vertexCount: Int
    let indexCount: Int
    let edgeIndexCount: Int?
    let paintIndexCount: Int
    let uvMaps: [String]
    let activeUV: String
    let renderUV: String
    let colorAttrs: [String]?
    let renderColor: String?
}

struct ProgramTexture: Codable, Equatable {
    let image: String
    let paint: Bool
    let srgb: Bool
}

/// Blender node tree translated to MSL by the add-on (blendpaint_bridge/shadergen.py)
struct MaterialProgram: Codable, Equatable {
    let code: String
    let textures: [ProgramTexture]
    let uvSlots: [String]
    let colorSlots: [String]
    let unsupported: [String]
}

enum SlotValue: Codable, Equatable {
    case scalar(Double)
    case vector([Double])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            self = .scalar(d)
        } else {
            self = .vector(try c.decode([Double].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .scalar(let d): try c.encode(d)
        case .vector(let v): try c.encode(v)
        }
    }

    var scalar: Float {
        switch self {
        case .scalar(let d): return Float(d)
        case .vector(let v): return Float(v.first ?? 0)
        }
    }

    var color: SIMD4<Float> {
        switch self {
        case .scalar(let d): return SIMD4(Float(d), Float(d), Float(d), 1)
        case .vector(let v):
            let f = v.map { Float($0) }
            return SIMD4(f.count > 0 ? f[0] : 0, f.count > 1 ? f[1] : 0, f.count > 2 ? f[2] : 0, f.count > 3 ? f[3] : 1)
        }
    }
}

struct SlotDesc: Codable, Equatable {
    let kind: String            // "value" | "texture" | "none"
    let value: SlotValue?
    let image: String?
    let node: String?
    let channel: String?        // "rgb" | "r" | "g" | "b" | "a"
    let uv: String?
    let normalMap: Bool?
    let strength: Double?

    var channelIndex: Int32 {
        switch channel {
        case "r": return 0
        case "g": return 1
        case "b": return 2
        case "a": return 3
        default: return 4
        }
    }
}

struct MaterialDesc: Codable, Equatable {
    let name: String
    let shader: String
    let slots: [String: SlotDesc]
    let blend: String?
    let paintedFound: Bool?
}

struct TextureInfo: Codable {
    let name: String
    let width: Int
    let height: Int
    let colorspace: String
}

struct SessionHeader: Codable {
    let sessionId: Int
    let file: String
    let object: String
    let material: String
    let node: String
    let image: ImageInfo
    let mesh: MeshInfo
    let paintUV: String
    let materialDesc: MaterialDesc
    let program: MaterialProgram?
    let textures: [TextureInfo]
    let blobs: [BlobInfo]
}

struct MaterialHeader: Codable {
    let sessionId: Int
    let materialDesc: MaterialDesc
    let program: MaterialProgram?
    let textures: [TextureInfo]
    let blobs: [BlobInfo]
}

struct StatusHeader: Codable {
    let level: String?
    let message: String
}

struct HelloHeader: Codable {
    let server: String?
    let version: Int?
    let blender: String?
}

/// Rect sent to Blender (top-left origin, straight-alpha RGBA8, raw deflate)
struct TileRect {
    var x: Int, y: Int, w: Int, h: Int
}

extension Data {
    func blob(_ b: BlobInfo) -> Data {
        let s = startIndex + b.offset
        return subdata(in: s..<(s + b.length))
    }
}

enum Deflate {
    static func decompress(_ data: Data, rawLength: Int) -> Data? {
        if rawLength == 0 { return Data() }
        var out = Data(count: rawLength)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, rawLength, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == rawLength ? out : nil
    }

    /// Raw DEFLATE (no zlib header) – Python side uses zlib.decompress(data, -15)
    static func compress(_ src: UnsafeRawPointer, count: Int) -> Data? {
        let cap = count + count / 8 + 4096
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            guard let d = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(d, cap, src.assumingMemoryBound(to: UInt8.self), count, nil, COMPRESSION_ZLIB)
        }
        if n == 0 { return nil }
        out.count = n
        return out
    }
}

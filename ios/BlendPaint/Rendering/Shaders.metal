#include <metal_stdlib>
using namespace metal;

// Keep these structs in sync with ShaderTypes.swift
constant uint TILE_SIZE = 256;

struct Dab {
    float2 center;
    float radius;
    float angle;
    float roundness;
    float alpha;
    float seed;
    float pad;
};

struct DabUniforms {
    float2 targetSize;
    float hardness;
    uint shape;
    float grainAmount;
    float grainScale;
    uint tilesX;
    uint pad;
};

struct ProjUniforms {
    float4x4 model;
    float4x4 viewProj;
    float4x4 view;
    float4 camPos;
    float2 viewport;
    float2 bboxMin;
    float2 bboxMax;
    float hardness;
    uint shape;
    float grainAmount;
    float grainScale;
    uint dabCount;
    uint tilesX;
    uint flags;          // bit0 occlusion, bit1 paint backfaces
    float facingFade;
    float pad0;
    float pad1;
};

struct CompositeUniforms {
    float4 brushColor;
    float layerOpacity;
    float strokeOpacity;
    uint blendMode;
    uint strokeMode;     // 0 none, 1 paint, 2 erase
    uint alphaLock;
    uint clearPass;
    uint pad0;
    uint pad1;
};

struct CanvasUniforms {
    float4x4 transform;  // canvas pixels -> NDC
    float2 texSize;
    float checker;
    uint nearest;
    float4 wireColor;
};

struct MeshUniforms {
    float4x4 model;
    float4x4 viewProj;
    float4x4 view;
    float4 camPos;
    float4 baseColor;
    float4 emission;
    float4 light0Dir;
    float4 light0Color;
    float4 light1Dir;
    float4 light1Color;
    float4 skyTop;
    float4 skyBottom;
    float4 params;       // metallic, roughness, alpha, normalStrength
    float4 params2;      // specular, exposure, -, -
    int4 texOn;          // base, metal, rough, normal
    int4 texOn2;         // emission, alpha
    int4 chan;           // metal, rough, alpha
    int4 uvSel;          // base, metal, rough, normal
    int4 uvSel2;         // emission, alpha
    uint lighting;       // 0 studio, 1 outdoor, 2 unlit, 3 clay
    uint neutral;
    uint pad0;
    uint pad1;
};

// ------------------------------------------------------------------ helpers

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// l: position in dab space, |l| == 1 is the edge
static float dabCoverage(float2 l, float radius, float hardness, uint shape, float seed) {
    float d = (shape == 1) ? max(fabs(l.x), fabs(l.y)) : length(l);
    float aa = 1.5 / max(radius, 1.0);
    float inner = min(hardness, 1.0 - aa);
    float a = 1.0 - smoothstep(inner, 1.0, d);
    if (shape == 2) {            // spray: random speckles
        float cell = max(radius * 0.06, 1.0);
        float n = hash21(floor(l * radius / cell) + seed * 17.0);
        a *= step(0.72, n) * (1.0 - d * 0.6);
    } else if (shape == 3) {     // charcoal: broken edge + noise
        float n = valueNoise(l * 3.5 + seed * 11.0) * 0.6 + valueNoise(l * 9.0 + seed * 3.0) * 0.4;
        a *= smoothstep(0.25, 0.75, n + (1.0 - d) * 0.35);
    }
    return a;
}

static float4 applyStroke(float4 s, float a, float3 color, uint mode, uint lock) {
    if (mode == 2) {
        return lock != 0 ? s : s * (1.0 - a);
    }
    if (lock != 0) {
        return float4(s.rgb * (1.0 - a) + color * s.a * a, s.a);
    }
    return float4(color * a + s.rgb * (1.0 - a), a + s.a * (1.0 - a));
}

static float3 blendFn(float3 s, float3 d, uint mode) {
    switch (mode) {
        case 1: return s * d;                                   // multiply
        case 2: return s + d - s * d;                           // screen
        case 3: return select(1.0 - 2.0 * (1.0 - s) * (1.0 - d), 2.0 * s * d, d <= 0.5); // overlay
        case 4: return min(s, d);                               // darken
        case 5: return max(s, d);                               // lighten
        case 6: return select(min(float3(1.0), d / max(float3(1.0) - s, float3(1e-4))), float3(1.0), s >= 1.0);  // color dodge
        case 7: return select(float3(1.0) - min(float3(1.0), (float3(1.0) - d) / max(s, float3(1e-4))), float3(0.0), s <= 0.0); // color burn
        case 8: return select(1.0 - 2.0 * (1.0 - s) * (1.0 - d), 2.0 * s * d, s <= 0.5); // hard light
        case 9: {                                                // soft light (W3C)
            float3 dd = select(sqrt(d), ((16.0 * d - 12.0) * d + 4.0) * d, d <= 0.25);
            return select(d + (2.0 * s - 1.0) * (dd - d), d - (1.0 - 2.0 * s) * d * (1.0 - d), s <= 0.5);
        }
        case 10: return fabs(s - d);                            // difference
        case 11: return s + d - 2.0 * s * d;                    // exclusion
        case 12: return min(float3(1.0), s + d);                // add
        case 13: return max(float3(0.0), d - s);                // subtract
        default: return s;
    }
}

static float4 blendPremul(float4 S, float4 D, uint mode) {
    if (mode == 0) {
        return S + D * (1.0 - S.a);
    }
    float3 sc = S.a > 0.0 ? S.rgb / S.a : float3(0.0);
    float3 dc = D.a > 0.0 ? D.rgb / D.a : float3(0.0);
    float3 B = clamp(blendFn(sc, dc, mode), 0.0, 1.0);
    float3 rgb = (1.0 - D.a) * S.rgb + (1.0 - S.a) * D.rgb + S.a * D.a * B;
    return float4(rgb, S.a + D.a * (1.0 - S.a));
}

static void markTile(float2 pixel, uint tilesX, device uint* a, device uint* b) {
    uint2 t = uint2(pixel) / TILE_SIZE;
    uint idx = t.y * tilesX + t.x;
    a[idx] = 1;
    b[idx] = 1;
}

// ------------------------------------------------------------------ fullscreen

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// ------------------------------------------------------------------ 2D dabs (canvas space)

struct DabVOut {
    float4 position [[position]];
    float2 local;
    float alpha;
    float radius;
    float seed;
};

vertex DabVOut dabVertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device Dab* dabs [[buffer(0)]],
                         constant DabUniforms& u [[buffer(1)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    Dab d = dabs[iid];
    float pad = 1.0 + 2.0 / max(d.radius * d.roundness, 0.5);
    float2 l = corners[vid] * pad;
    float2 q = float2(l.x * d.radius, l.y * d.radius * d.roundness);
    float s = sin(d.angle), c = cos(d.angle);
    float2 p = d.center + float2(q.x * c - q.y * s, q.x * s + q.y * c);
    DabVOut o;
    o.position = float4(p.x / u.targetSize.x * 2.0 - 1.0, 1.0 - p.y / u.targetSize.y * 2.0, 0.0, 1.0);
    o.local = l;
    o.alpha = d.alpha;
    o.radius = d.radius;
    o.seed = d.seed;
    return o;
}

fragment float4 dabFragment(DabVOut in [[stage_in]],
                            constant DabUniforms& u [[buffer(1)]],
                            texture2d<float> grain [[texture(0)]],
                            device uint* flagsA [[buffer(2)]],
                            device uint* flagsB [[buffer(3)]]) {
    float a = dabCoverage(in.local, in.radius, u.hardness, u.shape, in.seed) * in.alpha;
    if (u.grainAmount > 0.0) {
        constexpr sampler gs(filter::linear, address::repeat);
        float g = grain.sample(gs, in.position.xy / (256.0 * max(u.grainScale, 0.05))).r;
        a *= mix(1.0, g, u.grainAmount);
    }
    if (a <= 0.0005) {
        discard_fragment();
    }
    markTile(in.position.xy, u.tilesX, flagsA, flagsB);
    return float4(a);
}

// ------------------------------------------------------------------ 3D projection dabs (UV space)

struct ProjVOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
};

vertex ProjVOut projVertex(uint vid [[vertex_id]],
                           const device packed_float3* P [[buffer(0)]],
                           const device packed_float3* N [[buffer(1)]],
                           const device float2* UV [[buffer(2)]],
                           constant ProjUniforms& u [[buffer(3)]]) {
    float2 uv = UV[vid];
    ProjVOut o;
    o.position = float4(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0, 0.0, 1.0);
    o.world = (u.model * float4(float3(P[vid]), 1.0)).xyz;
    o.normal = float3(N[vid]);
    return o;
}

fragment float4 projFragment(ProjVOut in [[stage_in]],
                             constant ProjUniforms& u [[buffer(3)]],
                             constant Dab* dabs [[buffer(4)]],
                             device uint* flagsA [[buffer(5)]],
                             device uint* flagsB [[buffer(6)]],
                             texture2d<float> aux [[texture(0)]],
                             texture2d<float> grain [[texture(1)]]) {
    float4 clip = u.viewProj * float4(in.world, 1.0);
    if (clip.w <= 0.0) {
        discard_fragment();
    }
    float2 ndc = clip.xy / clip.w;
    float2 sp = float2((ndc.x * 0.5 + 0.5) * u.viewport.x, (0.5 - ndc.y * 0.5) * u.viewport.y);
    if (sp.x < u.bboxMin.x || sp.y < u.bboxMin.y || sp.x > u.bboxMax.x || sp.y > u.bboxMax.y) {
        discard_fragment();
    }
    float3 V = normalize(u.camPos.xyz - in.world);
    float facing = dot(normalize(in.normal), V);
    if (facing <= 0.0 && (u.flags & 2u) == 0u) {
        discard_fragment();
    }
    if ((u.flags & 1u) != 0u) {
        uint2 ip = uint2(clamp(sp, float2(0.0), u.viewport - 1.0));
        float4 ax = aux.read(ip);
        float viewDepth = -(u.view * float4(in.world, 1.0)).z;
        if (ax.w < 0.5 || viewDepth > ax.z + 0.004 + 0.004 * viewDepth) {
            discard_fragment();
        }
    }
    float keep = 1.0;
    for (uint i = 0; i < u.dabCount; i++) {
        Dab d = dabs[i];
        float2 rel = sp - d.center;
        float s = sin(d.angle), c = cos(d.angle);
        float2 q = float2(rel.x * c + rel.y * s, -rel.x * s + rel.y * c);
        float2 l = float2(q.x / d.radius, q.y / max(d.radius * d.roundness, 0.5));
        if (dot(l, l) > 1.2) {
            continue;
        }
        keep *= 1.0 - dabCoverage(l, d.radius, u.hardness, u.shape, d.seed) * d.alpha;
    }
    float a = 1.0 - keep;
    if (u.grainAmount > 0.0) {
        constexpr sampler gs(filter::linear, address::repeat);
        a *= mix(1.0, grain.sample(gs, sp / (256.0 * max(u.grainScale, 0.05))).r, u.grainAmount);
    }
    if (u.facingFade > 0.0) {
        a *= smoothstep(0.0, u.facingFade, fabs(facing));
    }
    if (a <= 0.0005) {
        discard_fragment();
    }
    markTile(in.position.xy, u.tilesX, flagsA, flagsB);
    return float4(a);
}

// UV island mask (used for seam dilation after 3D strokes)
struct MaskVOut { float4 position [[position]]; };

vertex MaskVOut uvMaskVertex(uint vid [[vertex_id]], const device float2* UV [[buffer(0)]]) {
    float2 uv = UV[vid];
    MaskVOut o;
    o.position = float4(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 uvMaskFragment(MaskVOut in [[stage_in]]) {
    return float4(1.0);
}

kernel void dilateKernel(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::read> mask [[texture(1)]],
                         texture2d<float, access::write> dst [[texture(2)]],
                         device uint* flagsA [[buffer(0)]],
                         device uint* flagsB [[buffer(1)]],
                         constant uint& tilesX [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint w = src.get_width(), h = src.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float v = src.read(gid).r;
    if (v > 0.0 || mask.read(gid).r > 0.5) {
        dst.write(float4(v), gid);
        return;
    }
    float m = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 p = int2(gid) + int2(dx, dy);
            if (p.x < 0 || p.y < 0 || p.x >= int(w) || p.y >= int(h)) continue;
            m = max(m, src.read(uint2(p)).r);
        }
    }
    dst.write(float4(m), gid);
    if (m > 0.0) {
        markTile(float2(gid), tilesX, flagsA, flagsB);
    }
}

// ------------------------------------------------------------------ compositing (framebuffer fetch)

fragment float4 compositeFragment(FSOut in [[stage_in]],
                                  float4 dst [[color(0)]],
                                  texture2d<float> layer [[texture(0)]],
                                  texture2d<float> stroke [[texture(1)]],
                                  constant CompositeUniforms& u [[buffer(0)]]) {
    if (u.clearPass != 0) {
        return float4(0.0);
    }
    uint2 p = uint2(in.position.xy);
    float4 s = layer.read(p);
    if (u.strokeMode != 0) {
        s = applyStroke(s, stroke.read(p).r * u.strokeOpacity, u.brushColor.rgb, u.strokeMode, u.alphaLock);
    }
    s *= u.layerOpacity;
    return blendPremul(s, dst, u.blendMode);
}

fragment float4 mergeFragment(FSOut in [[stage_in]],
                              float4 dst [[color(0)]],
                              texture2d<float> stroke [[texture(1)]],
                              constant CompositeUniforms& u [[buffer(0)]]) {
    uint2 p = uint2(in.position.xy);
    return applyStroke(dst, stroke.read(p).r * u.strokeOpacity, u.brushColor.rgb, u.strokeMode, u.alphaLock);
}

kernel void unpremultiplyKernel(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                constant uint4& rect [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= rect.z || gid.y >= rect.w) return;
    uint2 p = gid + rect.xy;
    float4 c = src.read(p);
    if (c.a > 0.0) {
        c.rgb = min(c.rgb / c.a, float3(1.0));
    } else {
        c = float4(0.0);
    }
    dst.write(c, p);
}

kernel void premultiplyKernel(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    dst.write(float4(c.rgb * c.a, c.a), gid);
}

// ------------------------------------------------------------------ 2D canvas display

struct CanvasVOut {
    float4 position [[position]];
    float2 uv;
};

vertex CanvasVOut canvasVertex(uint vid [[vertex_id]], constant CanvasUniforms& u [[buffer(0)]]) {
    const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 c = corners[vid];
    CanvasVOut o;
    o.position = u.transform * float4(c * u.texSize, 0.0, 1.0);
    o.uv = c;
    return o;
}

fragment float4 canvasFragment(CanvasVOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant CanvasUniforms& u [[buffer(0)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    constexpr sampler nea(filter::nearest, address::clamp_to_edge);
    float4 c = u.nearest != 0 ? tex.sample(nea, in.uv) : tex.sample(lin, in.uv);
    float2 cp = floor(in.position.xy / u.checker);
    float ch = (int(cp.x + cp.y) & 1) != 0 ? 0.78 : 0.92;
    return float4(c.rgb + ch * (1.0 - c.a), 1.0);
}

vertex float4 wireVertex(uint vid [[vertex_id]],
                         const device float2* UV [[buffer(0)]],
                         constant CanvasUniforms& u [[buffer(1)]]) {
    float2 uv = UV[vid];
    float2 px = float2(uv.x, 1.0 - uv.y) * u.texSize;
    return u.transform * float4(px, 0.0, 1.0);
}

fragment float4 wireFragment(constant CanvasUniforms& u [[buffer(0)]]) {
    return float4(u.wireColor.rgb * u.wireColor.a, u.wireColor.a);
}

// ------------------------------------------------------------------ 3D preview

struct MeshVOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uvA;
    float2 uvB;
    float viewDepth;
};

struct MeshFOut {
    float4 color [[color(0)]];
    float4 aux [[color(1)]];
};

vertex MeshVOut meshVertex(uint vid [[vertex_id]],
                           const device packed_float3* P [[buffer(0)]],
                           const device packed_float3* N [[buffer(1)]],
                           const device float2* UVA [[buffer(2)]],
                           const device float2* UVB [[buffer(3)]],
                           constant MeshUniforms& u [[buffer(4)]]) {
    float4 w = u.model * float4(float3(P[vid]), 1.0);
    MeshVOut o;
    o.position = u.viewProj * w;
    o.world = w.xyz;
    o.normal = float3(N[vid]);
    o.uvA = UVA[vid];
    o.uvB = UVB[vid];
    o.viewDepth = -(u.view * w).z;
    return o;
}

static float4 sampleSlot(texture2d<float> t, float2 uv) {
    constexpr sampler s(filter::linear, mip_filter::none, address::repeat);
    return t.sample(s, float2(uv.x, 1.0 - uv.y));
}

static float pickChannel(float4 c, int ch) {
    switch (ch) {
        case 0: return c.r;
        case 1: return c.g;
        case 2: return c.b;
        case 3: return c.a;
        default: return dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    }
}

static float D_GGX(float NdH, float a) {
    float a2 = a * a;
    float d = NdH * NdH * (a2 - 1.0) + 1.0;
    return a2 / (M_PI_F * d * d + 1e-6);
}

static float V_Smith(float NdV, float NdL, float a) {
    float k = a * 0.5;
    return 1.0 / ((NdV * (1.0 - k) + k) * (NdL * (1.0 - k) + k) + 1e-5) * 0.25;
}

static float3 F_Schlick(float3 f0, float c) {
    return f0 + (1.0 - f0) * pow(1.0 - c, 5.0);
}

static float3 skyColor(float3 dir, constant MeshUniforms& u) {
    float t = clamp(dir.z * 0.5 + 0.5, 0.0, 1.0);
    return mix(u.skyBottom.rgb, u.skyTop.rgb, smoothstep(0.0, 1.0, t));
}

static float3 tonemap(float3 x) {
    // ACES fitted (Narkowicz)
    x *= 0.8;
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

fragment MeshFOut meshFragment(MeshVOut in [[stage_in]],
                               bool front [[front_facing]],
                               constant MeshUniforms& u [[buffer(4)]],
                               texture2d<float> baseTex [[texture(0)]],
                               texture2d<float> metalTex [[texture(1)]],
                               texture2d<float> roughTex [[texture(2)]],
                               texture2d<float> normalTex [[texture(3)]],
                               texture2d<float> emisTex [[texture(4)]],
                               texture2d<float> alphaTex [[texture(5)]]) {
    MeshFOut o;
    o.aux = float4(in.uvA, in.viewDepth, u.neutral != 0 ? 0.0 : 1.0);

    float3 N = normalize(in.normal);
    float3 V = normalize(u.camPos.xyz - in.world);
    if (dot(N, V) < 0.0) {
        N = -N;
    }

    if (u.neutral != 0) {
        float l = 0.35 + 0.5 * max(dot(N, normalize(u.light0Dir.xyz)), 0.0);
        o.color = float4(float3(l * 0.45), 1.0);
        return o;
    }

    float4 base = u.baseColor;
    if (u.texOn.x != 0) {
        float4 t = sampleSlot(baseTex, u.uvSel.x != 0 ? in.uvB : in.uvA);
        base = float4(t.rgb, t.a);
    }
    float alpha = u.params.z;
    if (u.texOn2.y != 0) {
        alpha = pickChannel(sampleSlot(alphaTex, u.uvSel2.y != 0 ? in.uvB : in.uvA), u.chan.z);
    }
    if (u.lighting == 2) {                       // unlit / texture check
        o.color = float4(base.rgb, 1.0);
        if (base.a < 0.5 && u.texOn.x != 0) {
            float2 cp = floor(in.position.xy / 10.0);
            o.color = float4(float3((int(cp.x + cp.y) & 1) != 0 ? 0.35 : 0.55), 1.0);
        }
        return o;
    }
    if (alpha < 0.999) {                          // hashed transparency like Eevee
        float h = hash21(floor(in.position.xy) + fract(in.world.xy * 37.0));
        if (alpha < h) {
            discard_fragment();
        }
    }

    float metallic = u.params.x;
    if (u.texOn.y != 0) metallic = pickChannel(sampleSlot(metalTex, u.uvSel.y != 0 ? in.uvB : in.uvA), u.chan.x);
    float roughness = u.params.y;
    if (u.texOn.z != 0) roughness = pickChannel(sampleSlot(roughTex, u.uvSel.z != 0 ? in.uvB : in.uvA), u.chan.y);
    roughness = clamp(roughness, 0.045, 1.0);

    if (u.texOn.w != 0) {
        float2 uv = u.uvSel.w != 0 ? in.uvB : in.uvA;
        float3 tn = sampleSlot(normalTex, uv).xyz * 2.0 - 1.0;
        tn.xy *= u.params.w;
        // cotangent frame from screen-space derivatives (no tangents needed)
        float3 dp1 = dfdx(in.world), dp2 = dfdy(in.world);
        float2 duv1 = dfdx(uv), duv2 = dfdy(uv);
        float3 dp2perp = cross(dp2, N);
        float3 dp1perp = cross(N, dp1);
        float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
        float3 B = dp2perp * duv1.y + dp1perp * duv2.y;
        float invmax = rsqrt(max(max(dot(T, T), dot(B, B)), 1e-12));
        float3x3 TBN = float3x3(T * invmax, B * invmax, N);
        N = normalize(TBN * normalize(tn));
    }

    float3 albedo = (u.lighting == 3) ? float3(0.7) : base.rgb;
    if (u.lighting == 3) { metallic = 0.0; roughness = 0.55; }

    float specLevel = u.params2.x;
    float3 f0 = mix(float3(0.08 * specLevel), albedo, metallic);
    float3 diffuseColor = albedo * (1.0 - metallic);
    float a = roughness * roughness;
    float NdV = max(dot(N, V), 1e-4);

    float3 color = float3(0.0);
    for (int i = 0; i < 2; i++) {
        float3 L = normalize(i == 0 ? u.light0Dir.xyz : u.light1Dir.xyz);
        float3 lc = i == 0 ? u.light0Color.rgb : u.light1Color.rgb;
        float NdL = max(dot(N, L), 0.0);
        if (NdL <= 0.0) continue;
        float3 H = normalize(L + V);
        float NdH = max(dot(N, H), 0.0);
        float3 F = F_Schlick(f0, max(dot(H, V), 0.0));
        float3 spec = D_GGX(NdH, a) * V_Smith(NdV, NdL, a) * F;
        color += (diffuseColor / M_PI_F * (1.0 - F) + spec) * lc * NdL;
    }
    float3 R = reflect(-V, N);
    float3 envSpec = mix(skyColor(R, u), skyColor(N, u), roughness);
    float3 Fa = f0 + (max(float3(1.0 - roughness), f0) - f0) * pow(1.0 - NdV, 5.0);
    color += diffuseColor * skyColor(N, u) + envSpec * Fa;

    float3 emission = u.emission.rgb;
    if (u.texOn2.x != 0) emission = sampleSlot(emisTex, u.uvSel2.x != 0 ? in.uvB : in.uvA).rgb;
    color += emission * u.emission.w;

    color = tonemap(color * u.params2.y);
    o.color = float4(color, 1.0);
    return o;
}

struct BgOut {
    float4 color [[color(0)]];
    float4 aux [[color(1)]];
};

fragment BgOut backgroundFragment(FSOut in [[stage_in]], constant MeshUniforms& u [[buffer(4)]]) {
    BgOut o;
    float t = in.uv.y;
    float3 top = float3(0.11, 0.115, 0.13);
    float3 bottom = float3(0.035, 0.037, 0.045);
    o.color = float4(mix(top, bottom, t), 1.0);
    o.aux = float4(0.0);
    return o;
}

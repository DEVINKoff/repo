#define BP_ALPHA 1
// BP_TEMPLATE_ABI 3
#include <metal_stdlib>
using namespace metal;

#ifndef BP_ALPHA
#define BP_ALPHA 1
#endif

// Runtime-compiled material preview. The Blender add-on translates the node tree to MSL and the
// app pastes it at the MATERIAL marker below. Keep MeshUniforms in sync with ShaderTypes.swift.

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
    float4 params;
    float4 params2;      // specular, exposure
    int4 texOn;
    int4 texOn2;
    int4 chan;
    int4 uvSel;
    int4 uvSel2;
    uint lighting;       // 0 studio, 1 outdoor, 2 unlit, 3 clay
    uint neutral;
    uint pad0;           // bit0: col0 present, bit1: col1 present
    uint pad1;
    float4x4 objInv;     // world -> object local (Texture Coordinate > Object)
};

struct MVOut {
    float4 position [[position]];
    float3 world;
    float3 objPos;
    float3 normal;
    float2 uvA;
    float2 uv0;
    float2 uv1;
    float2 uv2;
    float2 uv3;
    float4 col0;
    float4 col1;
    float viewDepth;
};

struct MFOut {
    float4 color [[color(0)]];
    float4 aux [[color(1)]];
};

struct Surf {
    float3 base;
    float alpha;
    float metallic;
    float roughness;
    float3 N;
    float3 emission;
    float specular;
    float transmission;
    float coat;
    float coatRough;
    float3 coatN;
    float sss;
};

// ------------------------------------------------------------------ helpers used by generated code

static Surf surfDefault() {
    Surf s;
    s.base = float3(0.8); s.alpha = 1.0; s.metallic = 0.0; s.roughness = 0.5; s.N = float3(0.0);
    s.emission = float3(0.0); s.specular = 0.5; s.transmission = 0.0; s.coat = 0.0; s.coatRough = 0.03;
    s.coatN = float3(0.0); s.sss = 0.0;
    return s;
}

static Surf surfEmission(float3 c) {
    Surf s = surfDefault();
    s.base = float3(0.0); s.specular = 0.0; s.emission = c;
    return s;
}

static float3 mixN(float3 a, float3 b, float f) {
    if (dot(a, a) < 0.25) return b;
    if (dot(b, b) < 0.25) return a;
    return normalize(mix(a, b, f) + 1e-6);
}

static Surf surfMix(Surf a, Surf b, float f) {
    Surf s;
    s.base = mix(a.base, b.base, f);
    s.alpha = mix(a.alpha, b.alpha, f);
    s.metallic = mix(a.metallic, b.metallic, f);
    s.roughness = mix(a.roughness, b.roughness, f);
    s.N = mixN(a.N, b.N, f);
    s.emission = mix(a.emission, b.emission, f);
    s.specular = mix(a.specular, b.specular, f);
    s.transmission = mix(a.transmission, b.transmission, f);
    s.coat = mix(a.coat, b.coat, f);
    s.coatRough = mix(a.coatRough, b.coatRough, f);
    s.coatN = mixN(a.coatN, b.coatN, f);
    s.sss = mix(a.sss, b.sss, f);
    return s;
}

static Surf surfAdd(Surf a, Surf b) {
    Surf s = surfMix(a, b, 0.5);
    s.base = min(a.base * a.alpha + b.base * b.alpha, float3(1.0));
    s.emission = a.emission + b.emission;
    s.alpha = saturate(a.alpha + b.alpha);
    return s;
}

static float luma(float4 c) { return dot(c.rgb, float3(0.2126, 0.7152, 0.0722)); }

static float3 srgb2lin(float3 c) {
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
}

static float4 texSample(texture2d<float> t, float2 uv, int interp, int ext) {
    constexpr sampler sRep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    constexpr sampler sClamp(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
    constexpr sampler sZero(filter::linear, mip_filter::linear, address::clamp_to_zero, max_anisotropy(8));
    constexpr sampler sMirror(filter::linear, mip_filter::linear, address::mirrored_repeat, max_anisotropy(8));
    constexpr sampler nRep(mag_filter::nearest, min_filter::linear, mip_filter::linear, address::repeat);
    constexpr sampler nClamp(mag_filter::nearest, min_filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 st = float2(uv.x, 1.0 - uv.y);
    if (interp == 1) {
        return ext == 0 ? t.sample(nRep, st) : t.sample(nClamp, st);
    }
    switch (ext) {
        case 1: return t.sample(sClamp, st);
        case 2: return t.sample(sZero, st);
        case 3: return t.sample(sMirror, st);
        default: return t.sample(sRep, st);
    }
}

static float3 rgb2hsv(float3 c) {
    float cmax = max(c.r, max(c.g, c.b));
    float cmin = min(c.r, min(c.g, c.b));
    float cdelta = cmax - cmin;
    float v = cmax;
    float s = cmax != 0.0 ? cdelta / cmax : 0.0;
    float h = 0.0;
    if (s != 0.0) {
        float3 cc = (float3(cmax) - c) / cdelta;
        if (c.r == cmax) h = cc.b - cc.g;
        else if (c.g == cmax) h = 2.0 + cc.r - cc.b;
        else h = 4.0 + cc.g - cc.r;
        h /= 6.0;
        if (h < 0.0) h += 1.0;
    }
    return float3(h, s, v);
}

static float3 hsv2rgb(float3 hsv) {
    float h = hsv.x, s = hsv.y, v = hsv.z;
    if (s == 0.0) return float3(v);
    if (h == 1.0) h = 0.0;
    h *= 6.0;
    float i = floor(h);
    float f = h - i;
    float p = v * (1.0 - s), q = v * (1.0 - s * f), t = v * (1.0 - s * (1.0 - f));
    if (i == 0.0) return float3(v, t, p);
    if (i == 1.0) return float3(q, v, p);
    if (i == 2.0) return float3(p, v, t);
    if (i == 3.0) return float3(p, q, v);
    if (i == 4.0) return float3(t, p, v);
    return float3(v, p, q);
}

static float3 rgb2hsl(float3 c) {
    float cmax = max(c.r, max(c.g, c.b));
    float cmin = min(c.r, min(c.g, c.b));
    float l = (cmax + cmin) * 0.5;
    if (cmax == cmin) return float3(0.0, 0.0, l);
    float d = cmax - cmin;
    float s = l > 0.5 ? d / (2.0 - cmax - cmin) : d / (cmax + cmin);
    float h;
    if (cmax == c.r) h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
    else if (cmax == c.g) h = (c.b - c.r) / d + 2.0;
    else h = (c.r - c.g) / d + 4.0;
    return float3(h / 6.0, s, l);
}

static float hue2c(float p, float q, float t) {
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

static float3 hsl2rgb(float3 hsl) {
    float h = hsl.x, s = hsl.y, l = hsl.z;
    if (s == 0.0) return float3(l);
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float p = 2.0 * l - q;
    return float3(hue2c(p, q, h + 1.0 / 3.0), hue2c(p, q, h), hue2c(p, q, h - 1.0 / 3.0));
}

static float4 rampBlend(int m, float f, float4 a, float4 b) {
    float fm = 1.0 - f;
    float3 c1 = a.rgb, c2 = b.rgb, r = c1;
    switch (m) {
        case 0: r = mix(c1, c2, f); break;
        case 1: r = mix(c1, min(c1, c2), f); break;
        case 2: r = c1 * (fm + f * c2); break;
        case 3: {
            float3 tmp = fm + f * c2;
            r = select(saturate(1.0 - (1.0 - c1) / max(tmp, float3(1e-6))), float3(0.0), tmp <= 0.0);
            break;
        }
        case 4: r = mix(c1, max(c1, c2), f); break;
        case 5: r = 1.0 - (fm + f * (1.0 - c2)) * (1.0 - c1); break;
        case 6: {
            float3 tmp = 1.0 - f * c2;
            r = select(min(c1 / max(tmp, float3(1e-6)), float3(1.0)), float3(1.0), tmp <= 0.0);
            r = select(r, float3(0.0), c1 == 0.0);
            break;
        }
        case 7: r = c1 + f * c2; break;
        case 8: r = select(1.0 - (fm + 2.0 * f * (1.0 - c2)) * (1.0 - c1), c1 * (fm + 2.0 * f * c2), c1 < 0.5); break;
        case 9: {
            float3 scr = 1.0 - (1.0 - c2) * (1.0 - c1);
            r = fm * c1 + f * ((1.0 - c1) * c2 * c1 + c1 * scr);
            break;
        }
        case 10: r = c1 + f * (2.0 * c2 - 1.0); break;
        case 11: r = mix(c1, fabs(c1 - c2), f); break;
        case 12: r = max(mix(c1, c1 + c2 - 2.0 * c1 * c2, f), float3(0.0)); break;
        case 13: r = c1 - f * c2; break;
        case 14: r = select(fm * c1 + f * c1 / c2, c1, c2 == 0.0); break;
        case 15: {
            float3 h2 = rgb2hsv(c2);
            if (h2.y != 0.0) { float3 h1 = rgb2hsv(c1); h1.x = h2.x; r = mix(c1, hsv2rgb(h1), f); }
            break;
        }
        case 16: {
            float3 h1 = rgb2hsv(c1);
            if (h1.y != 0.0) { float3 h2 = rgb2hsv(c2); h1.y = fm * h1.y + f * h2.y; r = hsv2rgb(h1); }
            break;
        }
        case 17: {
            float3 h1 = rgb2hsv(c1), h2 = rgb2hsv(c2);
            h1.z = fm * h1.z + f * h2.z;
            r = hsv2rgb(h1);
            break;
        }
        case 18: {
            float3 h2 = rgb2hsv(c2);
            if (h2.y != 0.0) { float3 h1 = rgb2hsv(c1); h1.x = h2.x; h1.y = h2.y; r = mix(c1, hsv2rgb(h1), f); }
            break;
        }
        default: break;
    }
    return float4(r, a.a);
}

static float4 hueSat(float hue, float sat, float val, float fac, float4 c) {
    float3 hsv = rgb2hsv(c.rgb);
    hsv.x = fract(hsv.x + hue + 0.5);
    hsv.y = saturate(hsv.y * sat);
    hsv.z *= val;
    return float4(max(mix(c.rgb, hsv2rgb(hsv), fac), float3(0.0)), c.a);
}

static float4 brightContrast(float4 c, float bright, float contrast) {
    float a = 1.0 + contrast;
    float b = bright - contrast * 0.5;
    return float4(max(a * c.rgb + b, float3(0.0)), c.a);
}

static float clampRange(float v, float a, float b) { return a > b ? clamp(v, b, a) : clamp(v, a, b); }

static float safeDiv(float a, float b) { return b != 0.0 ? a / b : 0.0; }
static float3 safeDiv3(float3 a, float3 b) { return select(a / b, float3(0.0), b == 0.0); }
static float safePow(float a, float b) {
    if (a < 0.0 && b != floor(b)) return 0.0;
    return a < 0.0 ? (fmod(fabs(b), 2.0) == 1.0 ? -pow(-a, b) : pow(-a, b)) : pow(a, b);
}
static float safeLog(float a, float b) { return (a > 0.0 && b > 0.0 && b != 1.0) ? log(a) / log(b) : 0.0; }
static float safeFmod(float a, float b) { return b != 0.0 ? fmod(a, b) : 0.0; }
static float safeFloorMod(float a, float b) { return b != 0.0 ? a - floor(a / b) * b : 0.0; }
static float wrapF(float v, float mx, float mn) {
    float r = mx - mn;
    return r != 0.0 ? v - r * floor((v - mn) / r) : mn;
}
static float pingpong(float a, float b) { return b != 0.0 ? fabs(fract((a - b) / (b * 2.0)) * b * 2.0 - b) : 0.0; }
static float smoothMin(float a, float b, float c) {
    if (c != 0.0) { float h = max(c - fabs(a - b), 0.0) / c; return min(a, b) - h * h * h * c * (1.0 / 6.0); }
    return min(a, b);
}
static float3 projectV(float3 a, float3 b) { float d = dot(b, b); return d != 0.0 ? b * (dot(a, b) / d) : float3(0.0); }
static float3 safeNormalize(float3 v) { float l = length(v); return l != 0.0 ? v / l : float3(0.0); }

static float mapRange(float v, float fmin, float fmax, float tmin, float tmax, float steps, int mode, bool clampIt) {
    float f = fmax != fmin ? (v - fmin) / (fmax - fmin) : 0.0;
    float r;
    if (mode == 1) {
        f = steps > 0.0 ? floor(f * (steps + 1.0)) / steps : 0.0;
        r = tmin + f * (tmax - tmin);
    } else if (mode == 2) {
        f = fmin > fmax ? 1.0 - smoothstep(fmax, fmin, v) : smoothstep(fmin, fmax, v);
        r = tmin + f * (tmax - tmin);
    } else if (mode == 3) {
        float x = fmin > fmax ? 1.0 - saturate((v - fmax) / (fmin - fmax)) : saturate((v - fmin) / max(fmax - fmin, 1e-8));
        f = x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
        r = tmin + f * (tmax - tmin);
    } else {
        r = tmin + f * (tmax - tmin);
    }
    if (clampIt && mode < 2) r = tmin > tmax ? clamp(r, tmax, tmin) : clamp(r, tmin, tmax);
    return r;
}

static float lutEval(constant float* l, float x) {
    float t = saturate(x) * 32.0;
    int i = min(int(floor(t)), 31);
    return mix(l[i], l[i + 1], t - float(i));
}

static float3x3 eulerXYZ(float3 r) {
    float cx = cos(r.x), sx = sin(r.x), cy = cos(r.y), sy = sin(r.y), cz = cos(r.z), sz = sin(r.z);
    float3x3 rx = float3x3(float3(1, 0, 0), float3(0, cx, sx), float3(0, -sx, cx));
    float3x3 ry = float3x3(float3(cy, 0, -sy), float3(0, 1, 0), float3(sy, 0, cy));
    float3x3 rz = float3x3(float3(cz, sz, 0), float3(-sz, cz, 0), float3(0, 0, 1));
    return rz * ry * rx;
}

static float3 mapping(float3 v, float3 loc, float3 rot, float3 scl, int mode) {
    float3x3 R = eulerXYZ(rot);
    switch (mode) {
        case 1: return transpose(R) * (v - loc) / select(scl, float3(1.0), scl == 0.0);
        case 2: return R * (v * scl);
        case 3: return safeNormalize(R * (v / select(scl, float3(1.0), scl == 0.0)));
        default: return R * (v * scl) + loc;
    }
}

static float3 normalMapTS(float3 c, float strength, float2 uv, float3 P, float3 N) {
    float3 tn = normalize(c * 2.0 - 1.0);
    float3 dp1 = dfdx(P), dp2 = dfdy(P);
    float2 duv1 = dfdx(uv), duv2 = dfdy(uv);
    float3 dp2perp = cross(dp2, N);
    float3 dp1perp = cross(N, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;
    float invmax = rsqrt(max(max(dot(T, T), dot(B, B)), 1e-20));
    float3 n = normalize(T * invmax * tn.x + B * invmax * tn.y + N * tn.z);
    return normalize(mix(N, n, max(strength, 0.0)));
}

static float3 bumpNormal(float h, float strength, float dist, bool invert, float3 Nin, float3 P) {
    float3 dPdx = dfdx(P), dPdy = dfdy(P);
    float3 Rx = cross(dPdy, Nin);
    float3 Ry = cross(Nin, dPdx);
    float det = dot(dPdx, Rx);
    float3 grad = dfdx(h) * Rx + dfdy(h) * Ry;
    float d = invert ? -dist : dist;
    float3 g = d * sign(det) * grad;
    float slope = length(g) / max(fabs(det), 1e-20);
    if (slope > 1.5) g *= 1.5 / slope;          // tame extreme per-pixel slopes
    float3 nb = normalize(fabs(det) * Nin - g + 1e-12);
    return normalize(mix(Nin, nb, saturate(strength)));
}

static float fresnelDielectric(float cosi, float eta) {
    float c = fabs(cosi);
    float g = eta * eta - 1.0 + c * c;
    if (g > 0.0) {
        g = sqrt(g);
        float A = (g - c) / (g + c);
        float B = (c * (g + c) - 1.0) / (c * (g - c) + 1.0);
        return 0.5 * A * A * (1.0 + B * B);
    }
    return 1.0;
}

static float fresnelNode(float ior, float3 N, float3 V, bool front) {
    float eta = max(ior, 1e-5);
    eta = front ? eta : 1.0 / eta;
    return fresnelDielectric(dot(V, N), eta);
}

static float2 layerWeight(float blend, float3 N, float3 V, bool front) {
    float b = clamp(blend, 0.0, 0.99999);
    float eta = max(1.0 - b, 1e-5);
    eta = front ? 1.0 / eta : eta;
    float fres = fresnelDielectric(dot(V, N), eta);
    float facing = fabs(dot(V, N));
    if (b != 0.5) {
        b = b < 0.5 ? 2.0 * b : 0.5 / (1.0 - b);
        facing = pow(facing, b);
    }
    return float2(fres, 1.0 - facing);
}

static float3 hash33(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

static float gnoise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n000 = dot(hash33(i + float3(0, 0, 0)) * 2.0 - 1.0, f - float3(0, 0, 0));
    float n100 = dot(hash33(i + float3(1, 0, 0)) * 2.0 - 1.0, f - float3(1, 0, 0));
    float n010 = dot(hash33(i + float3(0, 1, 0)) * 2.0 - 1.0, f - float3(0, 1, 0));
    float n110 = dot(hash33(i + float3(1, 1, 0)) * 2.0 - 1.0, f - float3(1, 1, 0));
    float n001 = dot(hash33(i + float3(0, 0, 1)) * 2.0 - 1.0, f - float3(0, 0, 1));
    float n101 = dot(hash33(i + float3(1, 0, 1)) * 2.0 - 1.0, f - float3(1, 0, 1));
    float n011 = dot(hash33(i + float3(0, 1, 1)) * 2.0 - 1.0, f - float3(0, 1, 1));
    float n111 = dot(hash33(i + float3(1, 1, 1)) * 2.0 - 1.0, f - float3(1, 1, 1));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

// Band-limited fBm: octaves smaller than a pixel fade to their mean (0) instead of aliasing into
// per-pixel "white noise" — also much cheaper, since those octaves are skipped.
static float fbm(float3 p, float detail, float rough, float fw) {
    float sum = 0.0, amp = 1.0, norm = 0.0;
    float d = clamp(detail, 0.0, 7.0);       // preview: at most 8 octaves
    int oct = int(d);
    float foot = fw;
    for (int i = 0; i <= oct + 1; i++) {
        float w = (i <= oct) ? 1.0 : (d - float(oct));
        float fade = saturate(1.6 - foot * 1.6);
        if (fade <= 0.0 || w <= 0.0) break;
        sum += gnoise(p) * amp * fade * w;
        norm += amp * w;
        amp *= saturate(rough);
        p *= 2.0;
        foot *= 2.0;
    }
    return (sum / max(norm, 1e-6)) * 0.5 + 0.5;
}

static float3 noiseDistort(float3 p, float distortion) {
    if (distortion != 0.0) {
        p += float3(gnoise(p + 13.5), gnoise(p + 27.1), gnoise(p + 41.7)) * distortion;
    }
    return p;
}

static float noiseFac(float3 p, float detail, float rough, float distortion) {
    float fw = length(fwidth(p));
    return fbm(noiseDistort(p, distortion), detail, rough, fw);
}

static float3 noiseColor(float3 p, float detail, float rough, float distortion) {
    float fw = length(fwidth(p));
    float3 q = noiseDistort(p, distortion);
    return float3(fbm(q, detail, rough, fw), fbm(q + float3(37.0, 17.0, 11.0), detail, rough, fw),
                  fbm(q + float3(-23.0, 5.0, 61.0), detail, rough, fw));
}

static float checker(float3 p) {
    p = (p + 0.000001) * 0.999999;
    int xi = int(fabs(floor(p.x))), yi = int(fabs(floor(p.y))), zi = int(fabs(floor(p.z)));
    return (int((xi % 2) == (yi % 2)) == (zi % 2)) ? 1.0 : 0.0;
}

static float gradientTex(float3 p, int t) {
    switch (t) {
        case 1: { float r = max(p.x, 0.0); return r * r; }
        case 2: { float r = saturate(p.x); float t2 = r * r; return 3.0 * t2 - 2.0 * t2 * r; }
        case 3: return (p.x + p.y) * 0.5;
        case 4: return max(1.0 - length(p), 0.0);
        case 5: { float r = max(1.0 - length(p), 0.0); return r * r; }
        case 6: return atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;
        default: return p.x;
    }
}

static float4 whiteNoise(float3 p) {
    float3 h = hash33(floor(p * 1000.0) + 0.5);
    return float4(h, h.x);
}

// ------------------------------------------------------------------ lighting

static float D_GGX(float NdH, float a) {
    float a2 = a * a;
    float d = NdH * NdH * (a2 - 1.0) + 1.0;
    return a2 / (M_PI_F * d * d + 1e-6);
}

static float V_Smith(float NdV, float NdL, float a) {
    float k = a * 0.5;
    return 1.0 / ((NdV * (1.0 - k) + k) * (NdL * (1.0 - k) + k) + 1e-5) * 0.25;
}

static float3 F_Schlick(float3 f0, float c) { return f0 + (1.0 - f0) * pow(1.0 - c, 5.0); }

static float3 skyColor(float3 dir, constant MeshUniforms& u) {
    float t = clamp(dir.z * 0.5 + 0.5, 0.0, 1.0);
    return mix(u.skyBottom.rgb, u.skyTop.rgb, smoothstep(0.0, 1.0, t));
}

static float3 agxContrast(float3 x) {
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

// Blender's default view transform (AgX), minimal fitted version; input/output linear sRGB
static float3 tonemap(float3 c) {
    const float3x3 m = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    const float3x3 mi = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                 float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                 float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
    const float minEv = -12.47393, maxEv = 4.026069;
    float3 v = m * max(c, float3(1e-10));
    v = clamp(log2(v), minEv, maxEv);
    v = (v - minEv) / (maxEv - minEv);
    v = agxContrast(v);
    v = mi * v;
    return pow(max(v, float3(0.0)), float3(2.2));
}

// Blender Material Preview: studio HDRI locked to the view (World Space Lighting off)
static float3 envSample(texture2d<float> env, float3 dirW, float lod, constant MeshUniforms& u) {
    constexpr sampler es(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float3 d = (u.view * float4(dirW, 0.0)).xyz;
    float3 b = float3(d.x, -d.z, d.y);
    float uu = -atan2(b.y, b.x) / (2.0 * M_PI_F) + 0.5;
    float vv = atan2(b.z, length(b.xy)) / M_PI_F + 0.5;
    return env.sample(es, float2(uu, 1.0 - vv), level(lod)).rgb * u.params2.w;
}

static float hashPix(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// ------------------------------------------------------------------ entry points

vertex MVOut matVertex(uint vid [[vertex_id]],
                       const device packed_float3* Pb [[buffer(0)]],
                       const device packed_float3* Nb [[buffer(1)]],
                       const device float2* UVA [[buffer(2)]],
                       constant MeshUniforms& u [[buffer(4)]],
                       const device float2* UV0 [[buffer(5)]],
                       const device float2* UV1 [[buffer(6)]],
                       const device float2* UV2 [[buffer(7)]],
                       const device float2* UV3 [[buffer(8)]],
                       const device float4* C0 [[buffer(9)]],
                       const device float4* C1 [[buffer(10)]]) {
    float3 p = float3(Pb[vid]);
    float4 w = u.model * float4(p, 1.0);
    MVOut o;
    o.position = u.viewProj * w;
    o.world = w.xyz;
    o.objPos = p;
    o.normal = float3(Nb[vid]);
    o.uvA = UVA[vid];
    o.uv0 = UV0[vid];
    o.uv1 = UV1[vid];
    o.uv2 = UV2[vid];
    o.uv3 = UV3[vid];
    o.col0 = (u.pad0 & 1u) != 0u ? C0[vid] : float4(1.0);
    o.col1 = (u.pad0 & 2u) != 0u ? C1[vid] : float4(1.0);
    o.viewDepth = -(u.view * w).z;
    return o;
}

fragment MFOut matFragment(MVOut in [[stage_in]],
                           bool front [[front_facing]],
                           constant MeshUniforms& u [[buffer(4)]],
                           constant float* MP [[buffer(12)]],
                           array<texture2d<float>, 12> tex [[texture(0)]],
                           texture2d<float> envTex [[texture(12)]]) {
    MFOut o;
    o.aux = float4(in.uvA, in.viewDepth, float(u.pad1));      // w = object id

    float3 Ng = normalize(in.normal);
    float3 V = normalize(u.camPos.xyz - in.world);
    if (dot(Ng, V) < 0.0) Ng = -Ng;
    float3 N = Ng;

    if (u.neutral != 0) {
        float l = 0.35 + 0.5 * max(dot(N, normalize(u.light0Dir.xyz)), 0.0);
        o.color = float4(float3(l * 0.45), 1.0);
        return o;
    }

    float3 P = in.world;
    float3 Pobj = in.objPos;
    float3 Ploc = (u.objInv * float4(Pobj, 1.0)).xyz;
    // Generated = object-local bounding box 0…1 (baseColor/emission carry the local bbox here)
    float3 GEN = (Ploc - u.baseColor.xyz) / max(u.emission.xyz - u.baseColor.xyz, float3(1e-6));
    float2 uv0 = in.uv0, uv1 = in.uv1, uv2 = in.uv2, uv3 = in.uv3;
    float4 col0 = in.col0, col1 = in.col1;

    Surf s = surfDefault();
    {
    Surf v0 = surfDefault();
    float v1 = noiseFac(GEN * MP[0], 2.0, 0.5, 0.0);
    Surf v2 = surfDefault();
    v2.alpha = 0.0;
    Surf v3 = surfDefault();
    v3.base = float3(0.0); v3.specular = 0.0;
    v3.emission = float4(MP[1], MP[2], MP[3], MP[4]).rgb * MP[5];
    v0 = surfMix(v2, v3, saturate(v1));
    s = v0;
    }

    float3 Nn = dot(s.N, s.N) > 0.25 ? normalize(s.N) : N;
    float3 base = max(s.base, float3(0.0));

    if (u.lighting == 2) {
        o.color = float4(base + s.emission, 1.0);
        return o;
    }
#if BP_ALPHA
    // only compiled in when the material can be transparent: discard disables the GPU's
    // hidden-surface removal, which is very expensive on LEGO/Mecabricks models (hidden studs/tubes)
    if (s.alpha < 0.999) {
        float h = hashPix(floor(in.position.xy) + fract(in.world.xy * 37.0));
        if (s.alpha < h) discard_fragment();
    }
#endif

    float metallic = saturate(s.metallic);
    float roughness = clamp(s.roughness, 0.045, 1.0);
    if (u.lighting == 3) { base = float3(0.7); metallic = 0.0; roughness = 0.55; }

    float trans = saturate(s.transmission) * (1.0 - metallic);
    float3 f0 = mix(float3(0.08 * saturate(s.specular)), base, metallic);
    float3 diffuseColor = base * (1.0 - metallic) * (1.0 - trans);
    float a = roughness * roughness;
    {   // specular AA (Tokuyoshi/Kaplanyan): widen the lobe where the normal varies within a pixel
        float3 dnx = dfdx(Nn), dny = dfdy(Nn);
        float variance = 0.25 * (dot(dnx, dnx) + dot(dny, dny));
        a = sqrt(saturate(a * a + min(0.5 * variance, 0.012)));   // gentle: only kills sparkle
    }
    float NdV = max(dot(Nn, V), 1e-4);
    float wrap = saturate(s.sss) * 0.5;

    float3 coatN = dot(s.coatN, s.coatN) > 0.25 ? normalize(s.coatN) : N;
    float coat = saturate(s.coat);
    float ca = max(clamp(s.coatRough, 0.03, 1.0), 0.03);
    ca *= ca;
    float coatF = coat * F_Schlick(float3(0.04), max(dot(coatN, V), 1e-4)).x;

    float3 color = float3(0.0);
    if (u.lighting == 4) {
        // image-based lighting from Blender's studio HDRIs
        float maxLod = float(envTex.get_num_mip_levels()) - 1.0;
        float3 Rv = reflect(-V, Nn);
        float3 irr = envSample(envTex, Nn, maxLod - 1.0, u);
        float3 spec = envSample(envTex, Rv, sqrt(roughness) * (maxLod - 1.5), u);
        float3 Fe = f0 + (max(float3(1.0 - roughness), f0) - f0) * pow(1.0 - NdV, 5.0);
        color = diffuseColor * irr + spec * Fe;
        if (trans > 0.0) {
            color += trans * base * envSample(envTex, -V, roughness * (maxLod - 2.0), u);
        }
        if (coat > 0.0) {
            float3 cR = reflect(-V, coatN);
            color = color * (1.0 - coatF) + envSample(envTex, cR, sqrt(ca) * (maxLod - 1.5), u) * coatF;
        }
        color += s.emission;
        color += float3(1.0, 0.62, 0.25) * pow(1.0 - NdV, 2.0) * u.params2.z * 2.0;
        o.color = float4(tonemap(color * u.params2.y), 1.0);
        return o;
    }
    for (int i = 0; i < 2; i++) {
        float3 L = normalize(i == 0 ? u.light0Dir.xyz : u.light1Dir.xyz);
        float3 lc = i == 0 ? u.light0Color.rgb : u.light1Color.rgb;
        float NdLr = dot(Nn, L);
        float NdL = saturate((NdLr + wrap) / (1.0 + wrap));
        if (NdL <= 0.0) continue;
        float3 H = normalize(L + V);
        float NdH = max(dot(Nn, H), 0.0);
        float3 F = F_Schlick(f0, max(dot(H, V), 0.0));
        float3 spec = D_GGX(NdH, a) * V_Smith(NdV, max(NdLr, 1e-4), a) * F * saturate(NdLr * 4.0);
        float3 lit = (diffuseColor / M_PI_F * (1.0 - F) + spec) * lc * NdL;
        if (coat > 0.0) {
            float cNdL = max(dot(coatN, L), 0.0);
            float cNdH = max(dot(coatN, H), 0.0);
            float cNdV = max(dot(coatN, V), 1e-4);
            float3 cspec = D_GGX(cNdH, ca) * V_Smith(cNdV, max(cNdL, 1e-4), ca) * 0.04 * coat;
            lit = lit * (1.0 - coatF) + cspec * lc * cNdL;
        }
        color += lit;
    }
    float3 R = reflect(-V, Nn);
    float3 envSpec = mix(skyColor(R, u), skyColor(Nn, u), roughness);
    float3 Fa = f0 + (max(float3(1.0 - roughness), f0) - f0) * pow(1.0 - NdV, 5.0);
    float3 ambient = diffuseColor * skyColor(Nn, u) + envSpec * Fa;
    if (trans > 0.0) {
        ambient += trans * base * mix(skyColor(-V, u), skyColor(R, u), 0.3) * 1.2;
    }
    if (coat > 0.0) {
        ambient = ambient * (1.0 - coatF) + skyColor(reflect(-V, coatN), u) * coatF;
    }
    color += ambient + s.emission;
    // selection pulse (params2.z)
    color += float3(1.0, 0.62, 0.25) * pow(1.0 - NdV, 2.0) * u.params2.z * 2.0;
    o.color = float4(tonemap(color * u.params2.y), 1.0);
    return o;
}

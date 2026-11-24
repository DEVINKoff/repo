"""Blender shader node tree -> Metal (MSL) translator for the BlendPaint iPad preview.

The generated code is a straight-line block that is pasted into `matFragment` of
ios/BlendPaint/Resources/MaterialTemplate.txt at the //@@MATERIAL@@ marker. It may use:
    tex[k]            texture array (raw, non-sRGB views; sRGB decode happens in code)
    P, Pobj, N, Ng, V, front, uv0..uv3, col0, col1, GEN (generated coords)
and must assign the surface to `s` (struct Surf).
"""
import math

MAX_TEX = 12
MAX_UV = 4
MAX_COL = 2

_T_FLOAT, _T_VEC, _T_COL, _T_SURF = "float", "float3", "float4", "Surf"

_SOCK_TYPE = {"VALUE": _T_FLOAT, "INT": _T_FLOAT, "BOOLEAN": _T_FLOAT, "RGBA": _T_COL,
              "VECTOR": _T_VEC, "SHADER": _T_SURF}

_RAMP = {"MIX": 0, "DARKEN": 1, "MULTIPLY": 2, "BURN": 3, "LIGHTEN": 4, "SCREEN": 5, "DODGE": 6,
         "ADD": 7, "OVERLAY": 8, "SOFT_LIGHT": 9, "LINEAR_LIGHT": 10, "DIFFERENCE": 11,
         "EXCLUSION": 12, "SUBTRACT": 13, "DIVIDE": 14, "HUE": 15, "SATURATION": 16, "VALUE": 17,
         "COLOR": 18}

_NON_COLOR = ("non-color", "raw", "linear", "data", "xyz", "acescg", "aces2065")


def _f(x):
    try:
        x = float(x)
    except (TypeError, ValueError):
        return "0.0"
    if math.isnan(x) or math.isinf(x):
        x = 0.0 if math.isnan(x) else (1e30 if x > 0 else -1e30)
    s = repr(x)
    if "e" in s or "E" in s:
        return "%.8e" % x
    return s if "." in s else s + ".0"


def _lit(v, t):
    if t == _T_FLOAT:
        if isinstance(v, (list, tuple)):
            v = v[0] if v else 0.0
        return _f(v)
    vals = list(v) if isinstance(v, (list, tuple)) else [v, v, v]
    if t == _T_VEC:
        vals = (vals + [0, 0, 0])[:3]
        return "float3(%s)" % ", ".join(_f(x) for x in vals)
    if t == _T_COL:
        if len(vals) == 3:
            vals.append(1.0)
        vals = (vals + [0, 0, 0, 1])[:4]
        return "float4(%s)" % ", ".join(_f(x) for x in vals)
    return "surfDefault()"


def _conv(e, ft, tt):
    if ft == tt:
        return e
    if tt == _T_SURF:
        if ft == _T_COL:
            return "surfEmission((%s).rgb)" % e
        if ft == _T_VEC:
            return "surfEmission(%s)" % e
        return "surfEmission(float3(%s))" % e
    if ft == _T_SURF:
        return _lit(0, tt)
    if ft == _T_FLOAT:
        return {"float3": "float3(%s)" % e, "float4": "float4(float3(%s), 1.0)" % e}[tt]
    if ft == _T_VEC:
        return {"float": "dot(%s, float3(1.0 / 3.0))" % e, "float4": "float4(%s, 1.0)" % e}[tt]
    if ft == _T_COL:
        return {"float": "luma(%s)" % e, "float3": "(%s).rgb" % e}[tt]
    return e


def _sock(sockets, ref):
    for x in sockets:
        if x.identifier == ref.identifier:
            return x
    for x in sockets:
        if x.name == ref.name:
            return x
    return None


def _group_output(tree):
    outs = [n for n in tree.nodes if n.type == 'GROUP_OUTPUT']
    return next((n for n in outs if getattr(n, "is_active_output", False)), outs[0] if outs else None)


def _trace(sock, stack, depth=0):
    """-> ('node', node, out_socket, stack) | ('value', socket) | None"""
    if sock is None or depth > 64:
        return None
    if not sock.is_linked:
        return ("value", sock)
    link = sock.links[0]
    if getattr(link, "is_muted", False) or not getattr(link, "is_valid", True):
        return ("value", sock)
    node, out = link.from_node, link.from_socket
    if node.type == 'REROUTE':
        return _trace(node.inputs[0], stack, depth + 1)
    if getattr(node, "mute", False):
        for il in node.internal_links:
            if il.to_socket == out:
                return _trace(il.from_socket, stack, depth + 1)
        return None
    if node.type == 'GROUP':
        if not node.node_tree:
            return None
        go = _group_output(node.node_tree)
        inner = _sock(go.inputs, out) if go else None
        return _trace(inner, stack + (node,), depth + 1) if inner is not None else None
    if node.type == 'GROUP_INPUT':
        if not stack:
            return None
        outer = _sock(stack[-1].inputs, out)
        return _trace(outer, stack[:-1], depth + 1) if outer is not None else None
    return ("node", node, out, stack)


def _default(sock):
    v = getattr(sock, "default_value", None)
    if v is None:
        return None
    try:
        return [float(x) for x in v]
    except TypeError:
        return float(v)


def _is_color_space(img):
    name = img.colorspace_settings.name.lower()
    return not any(k in name for k in _NON_COLOR)


class Compiler:
    def __init__(self, mat, obj, paint_image, uv_names, render_uv, color_names, render_color):
        self.mat = mat
        self.obj = obj
        self.paint_image = paint_image
        self.uv_names = list(uv_names)
        self.render_uv = render_uv or (uv_names[0] if uv_names else "")
        self.color_names = list(color_names)
        self.render_color = render_color or (color_names[0] if color_names else "")
        self.lines = []
        self.n = 0
        self.memo = {}
        self.textures = []      # dicts
        self.tex_index = {}
        self.uv_slots = []      # uv map names
        self.col_slots = []     # color attribute names
        self.unsupported = set()
        self.uses_alpha = False

    # ---------------------------------------------------------------- helpers
    def var(self, t, expr):
        name = "v%d" % self.n
        self.n += 1
        self.lines.append("%s %s = %s;" % (t, name, expr))
        return name

    def uv(self, name):
        name = name or self.render_uv
        if name not in self.uv_names:
            name = self.render_uv
        if name not in self.uv_slots:
            if len(self.uv_slots) >= MAX_UV:
                self.unsupported.add("more than 4 UV maps in one material")
                return "uv0"
            self.uv_slots.append(name)
        return "uv%d" % self.uv_slots.index(name)

    def col(self, name):
        name = name or self.render_color
        if name not in self.color_names:
            return None
        if name not in self.col_slots:
            if len(self.col_slots) >= MAX_COL:
                self.unsupported.add("more than 2 color attributes")
                return "col0"
            self.col_slots.append(name)
        return "col%d" % self.col_slots.index(name)

    def tex(self, img, interp, ext):
        key = img.name
        if key not in self.tex_index:
            if len(self.textures) >= MAX_TEX:
                self.unsupported.add("more than %d textures" % MAX_TEX)
                return None
            self.tex_index[key] = len(self.textures)
            self.textures.append({"image": img.name, "paint": img.name == self.paint_image,
                                  "srgb": _is_color_space(img)})
        return self.tex_index[key]

    def inp(self, node, key, stack, t, fallback=None):
        """Expression for a node input (by identifier or name) converted to type t."""
        s = None
        if isinstance(key, int):
            s = node.inputs[key] if key < len(node.inputs) else None
        else:
            s = next((x for x in node.inputs if x.identifier == key), None) or node.inputs.get(key)
        if s is None:
            return fallback if fallback is not None else _lit(0, t)
        return self.sock_expr(s, stack, t, fallback)

    def linked(self, node, key, stack):
        s = next((x for x in node.inputs if x.identifier == key), None) or node.inputs.get(key)
        if s is None:
            return False
        tr = _trace(s, stack)
        return tr is not None and tr[0] == "node"

    def sock_expr(self, s, stack, t, fallback=None):
        tr = _trace(s, stack)
        if tr is None:
            return fallback if fallback is not None else _lit(0, t)
        if tr[0] == "value":
            vs = tr[1]
            if vs.type == 'SHADER':
                return _lit(0, t) if t != _T_SURF else "surfDefault()"
            d = _default(vs)
            if d is None:
                return fallback if fallback is not None else _lit(0, t)
            return _conv(_lit(d, _SOCK_TYPE.get(vs.type, _T_FLOAT)), _SOCK_TYPE.get(vs.type, _T_FLOAT), t)
        _, node, out, st = tr
        e, et = self.output(node, out, st)
        return _conv(e, et, t)

    # ---------------------------------------------------------------- nodes
    def output(self, node, out, stack):
        key = (node.as_pointer(), out.identifier, tuple(n.as_pointer() for n in stack))
        if key in self.memo:
            return self.memo[key]
        try:
            res = self._node(node, out, stack)
        except Exception as e:  # noqa
            print("BlendPaint shadergen: %s failed: %s" % (node.bl_idname, e))
            res = None
        if res is None:
            self.unsupported.add(node.bl_idname)
            t = _SOCK_TYPE.get(out.type, _T_FLOAT)
            d = _default(out)
            res = (_lit(d if d is not None else (0.5 if t != _T_SURF else 0), t), t)
        self.memo[key] = res
        return res

    def _node(self, n, out, st):
        t = n.type
        oid = out.identifier
        F, V3, C, S = _T_FLOAT, _T_VEC, _T_COL, _T_SURF

        # ------------------------------------------------ inputs / constants
        if t == 'RGB':
            return _lit(_default(n.outputs[0]), C), C
        if t == 'VALUE':
            return _lit(_default(n.outputs[0]), F), F
        if t == 'TEX_IMAGE':
            if not n.image:
                return "float4(0.0, 0.0, 0.0, 1.0)" if oid == "Color" else "0.0", (C if oid == "Color" else F)
            k = self.tex(n.image, n.interpolation, n.extension)
            if k is None:
                return None
            if self.linked(n, "Vector", st):
                uv = "(%s).xy" % self.inp(n, "Vector", st, V3)
            else:
                uv = self.uv(None)
            interp = 1 if n.interpolation == 'Closest' else 0
            ext = {"REPEAT": 0, "EXTEND": 1, "CLIP": 2, "MIRROR": 3}.get(n.extension, 0)
            key = ("img", n.as_pointer(), tuple(x.as_pointer() for x in st))
            if key not in self.memo:
                raw = self.var(C, "texSample(tex[%d], %s, %d, %d)" % (k, uv, interp, ext))
                if self.textures[k]["srgb"]:
                    rgb = self.var(C, "float4(srgb2lin(%s.rgb), %s.a)" % (raw, raw))
                else:
                    rgb = raw
                self.memo[key] = (raw, rgb)
            raw, rgb = self.memo[key]
            if oid == "Alpha":
                return "%s.a" % raw, F
            return "float4(%s.rgb, 1.0)" % rgb, C
        if t == 'UVMAP':
            return "float3(%s, 0.0)" % self.uv(n.uv_map), V3
        if t == 'TEX_COORD':
            m = {"UV": "float3(%s, 0.0)" % self.uv(None), "Generated": "GEN", "Normal": "N",
                 "Object": "Pobj", "Reflection": "reflect(-V, N)", "Camera": "float3(0.0)",
                 "Window": "float3(0.5, 0.5, 0.0)"}
            return m.get(oid, "float3(0.0)"), V3
        if t in ('ATTRIBUTE', 'VERTEX_COLOR'):
            name = n.attribute_name if t == 'ATTRIBUTE' else n.layer_name
            if t == 'ATTRIBUTE' and name in self.uv_names:
                uvv = "float3(%s, 0.0)" % self.uv(name)
                return {"Vector": (uvv, V3), "Color": ("float4(%s, 1.0)" % uvv, C),
                        "Fac": ("(%s).x" % uvv, F), "Alpha": ("1.0", F)}.get(oid, (uvv, V3))
            c = self.col(name)
            if c is None:
                c = "float4(0.0, 0.0, 0.0, 1.0)" if (t == 'ATTRIBUTE' and name) else "float4(1.0)"
            return {"Color": ("float4(%s.rgb, 1.0)" % c, C), "Vector": ("%s.rgb" % c, V3),
                    "Fac": ("luma(%s)" % c, F), "Alpha": ("%s.a" % c, F)}.get(oid, (c, C))
        if t == 'NEW_GEOMETRY':
            m = {"Position": ("Pobj", V3), "Normal": ("N", V3), "True Normal": ("Ng", V3),
                 "Incoming": ("V", V3), "Backfacing": ("(front ? 0.0 : 1.0)", F),
                 "Pointiness": ("0.5", F), "Random Per Island": ("0.0", F),
                 "Tangent": ("normalize(cross(N, float3(0.0, 0.0, 1.0)) + 1e-5)", V3),
                 "Parametric": ("float3(0.0)", V3)}
            return m.get(oid, ("0.0", F))
        if t == 'OBJECT_INFO':
            ob = self.obj
            col = list(ob.color) if ob else [1, 1, 1, 1]
            m = {"Location": ("float3(0.0)", V3), "Color": (_lit(col, C), C), "Alpha": ("1.0", F),
                 "Random": ("0.5", F)}
            return m.get(oid, ("0.0", F))
        if t == 'LIGHT_PATH':
            return ("1.0" if oid in ("Is Camera Ray", "Ray Length") else "0.0"), F
        if t == 'AMBIENT_OCCLUSION':
            if oid == "AO":
                return "1.0", F
            return self.inp(n, "Color", st, C), C
        if t == 'FRESNEL':
            nn = self.inp(n, "Normal", st, V3, "N") if self.linked(n, "Normal", st) else "N"
            return "fresnelNode(%s, %s, V, front)" % (self.inp(n, "IOR", st, F), nn), F
        if t == 'LAYER_WEIGHT':
            nn = self.inp(n, "Normal", st, V3, "N") if self.linked(n, "Normal", st) else "N"
            v = self.var("float2", "layerWeight(%s, %s, V, front)" % (self.inp(n, "Blend", st, F), nn))
            return ("%s.x" % v if oid == "Fresnel" else "%s.y" % v), F

        # ------------------------------------------------ converters
        if t == 'MIX':
            dt = n.data_type
            if dt == 'RGBA':
                fac = self.inp(n, "Factor_Float", st, F)
                if n.clamp_factor:
                    fac = "saturate(%s)" % fac
                a = self.inp(n, "A_Color", st, C)
                b = self.inp(n, "B_Color", st, C)
                r = "rampBlend(%d, %s, %s, %s)" % (_RAMP.get(n.blend_type, 0), fac, a, b)
                if n.clamp_result:
                    r = "saturate(%s)" % r
                return self.var(C, r), C
            if dt == 'VECTOR':
                if n.factor_mode == 'NON_UNIFORM':
                    fac = self.inp(n, "Factor_Vector", st, V3)
                else:
                    fac = "float3(%s)" % self.inp(n, "Factor_Float", st, F)
                if n.clamp_factor:
                    fac = "saturate(%s)" % fac
                return self.var(V3, "mix(%s, %s, %s)" % (self.inp(n, "A_Vector", st, V3), self.inp(n, "B_Vector", st, V3), fac)), V3
            fac = self.inp(n, "Factor_Float", st, F)
            if n.clamp_factor:
                fac = "saturate(%s)" % fac
            return self.var(F, "mix(%s, %s, %s)" % (self.inp(n, "A_Float", st, F), self.inp(n, "B_Float", st, F), fac)), F
        if t == 'MIX_RGB':
            r = "rampBlend(%d, %s, %s, %s)" % (_RAMP.get(n.blend_type, 0), self.inp(n, "Fac", st, F),
                                                self.inp(n, "Color1", st, C), self.inp(n, "Color2", st, C))
            if n.use_clamp:
                r = "saturate(%s)" % r
            return self.var(C, r), C
        if t == 'MATH':
            return self.var(F, self._math(n, st)), F
        if t == 'VECT_MATH':
            return self._vmath(n, st, oid)
        if t in ('SEPARATE_COLOR', 'SEPRGB', 'SEPARATE_RGB'):
            c = self.inp(n, "Color", st, C)
            mode = getattr(n, "mode", "RGB")
            if mode == 'HSV':
                c = self.var(C, "float4(rgb2hsv(%s.rgb), %s.a)" % (c, c))
            elif mode == 'HSL':
                c = self.var(C, "float4(rgb2hsl(%s.rgb), %s.a)" % (c, c))
            else:
                c = self.var(C, c)
            idx = [o.identifier for o in n.outputs].index(oid) if oid in [o.identifier for o in n.outputs] else 0
            comp = "xyzw"[min(idx, 3)]
            if oid == "Alpha":
                comp = "w"
            return "%s.%s" % (c, comp), F
        if t in ('SEPXYZ', 'SEPARATE_XYZ'):
            v = self.var(V3, self.inp(n, "Vector", st, V3))
            return "%s.%s" % (v, {"X": "x", "Y": "y", "Z": "z"}.get(oid, "x")), F
        if t in ('COMBINE_COLOR', 'COMBRGB', 'COMBINE_RGB'):
            vals = [self.sock_expr(s, st, F) for s in n.inputs if s.enabled][:3]
            while len(vals) < 3:
                vals.append("0.0")
            mode = getattr(n, "mode", "RGB")
            rgb = "float3(%s)" % ", ".join(vals)
            if mode == 'HSV':
                rgb = "hsv2rgb(%s)" % rgb
            elif mode == 'HSL':
                rgb = "hsl2rgb(%s)" % rgb
            return self.var(C, "float4(%s, 1.0)" % rgb), C
        if t in ('COMBXYZ', 'COMBINE_XYZ'):
            vals = [self.sock_expr(s, st, F) for s in n.inputs if s.enabled][:3]
            return self.var(V3, "float3(%s)" % ", ".join(vals)), V3
        if t == 'INVERT':
            c = self.inp(n, "Color", st, C)
            return self.var(C, "float4(mix(%s.rgb, 1.0 - %s.rgb, %s), %s.a)" % (c, c, self.inp(n, "Fac", st, F), c)), C
        if t == 'HUE_SAT':
            return self.var(C, "hueSat(%s, %s, %s, %s, %s)" % (
                self.inp(n, "Hue", st, F), self.inp(n, "Saturation", st, F), self.inp(n, "Value", st, F),
                self.inp(n, "Fac", st, F), self.inp(n, "Color", st, C))), C
        if t == 'BRIGHTCONTRAST':
            c = self.inp(n, "Color", st, C)
            return self.var(C, "brightContrast(%s, %s, %s)" % (c, self.inp(n, "Bright", st, F), self.inp(n, "Contrast", st, F))), C
        if t == 'GAMMA':
            c = self.inp(n, "Color", st, C)
            return self.var(C, "float4(pow(max(%s.rgb, 0.0), float3(%s)), %s.a)" % (c, self.inp(n, "Gamma", st, F), c)), C
        if t == 'RGBTOBW':
            return "luma(%s)" % self.inp(n, "Color", st, C), F
        if t == 'CLAMP':
            v, a, b = self.inp(n, "Value", st, F), self.inp(n, "Min", st, F), self.inp(n, "Max", st, F)
            if n.clamp_type == 'RANGE':
                return self.var(F, "clampRange(%s, %s, %s)" % (v, a, b)), F
            return self.var(F, "clamp(%s, %s, %s)" % (v, a, b)), F
        if t == 'MAP_RANGE':
            if n.data_type != 'FLOAT':
                return None
            it = {"LINEAR": 0, "STEPPED": 1, "SMOOTHSTEP": 2, "SMOOTHERSTEP": 3}.get(n.interpolation_type, 0)
            steps = self.inp(n, "Steps", st, F, "4.0") if it == 1 else "4.0"
            return self.var(F, "mapRange(%s, %s, %s, %s, %s, %s, %d, %s)" % (
                self.inp(n, "Value", st, F), self.inp(n, "From Min", st, F), self.inp(n, "From Max", st, F),
                self.inp(n, "To Min", st, F), self.inp(n, "To Max", st, F), steps, it,
                "true" if n.clamp else "false")), F
        if t == 'VALTORGB':
            return self._ramp(n, st, oid)
        if t in ('CURVE_RGB', 'CURVE_FLOAT', 'CURVE_VEC'):
            return self._curve(n, st)
        if t == 'MAPPING':
            vt = n.vector_type
            v = self.inp(n, "Vector", st, V3)
            loc = self.inp(n, "Location", st, V3, "float3(0.0)") if vt in ('POINT', 'TEXTURE') else "float3(0.0)"
            rot = self.inp(n, "Rotation", st, V3)
            scl = self.inp(n, "Scale", st, V3, "float3(1.0)") if vt != 'NORMAL' or True else "float3(1.0)"
            mode = {"POINT": 0, "TEXTURE": 1, "VECTOR": 2, "NORMAL": 3}.get(vt, 0)
            return self.var(V3, "mapping(%s, %s, %s, %s, %d)" % (v, loc, rot, scl, mode)), V3
        if t == 'NORMAL_MAP':
            c = self.inp(n, "Color", st, C)
            strength = self.inp(n, "Strength", st, F)
            if n.space == 'TANGENT':
                uv = self.uv(n.uv_map or None)
                return self.var(V3, "normalMapTS(%s.rgb, %s, %s, Pobj, N)" % (c, strength, uv)), V3
            return self.var(V3, "normalize(mix(N, normalize(%s.rgb * 2.0 - 1.0), saturate(%s)))" % (c, strength)), V3
        if t == 'BUMP':
            base_n = self.inp(n, "Normal", st, V3) if self.linked(n, "Normal", st) else "N"
            h = self.var(F, self.inp(n, "Height", st, F))
            return self.var(V3, "bumpNormal(%s, %s, %s, %s, %s, Pobj)" % (
                h, self.inp(n, "Strength", st, F), self.inp(n, "Distance", st, F), "true" if n.invert else "false",
                base_n)), V3

        # ------------------------------------------------ procedural textures
        if t in ('TEX_NOISE', 'TEX_CHECKER', 'TEX_GRADIENT', 'TEX_WHITE_NOISE', 'TEX_VORONOI', 'TEX_WAVE',
                 'TEX_MAGIC', 'TEX_MUSGRAVE', 'TEX_BRICK'):
            vec = self.inp(n, "Vector", st, V3) if self.linked(n, "Vector", st) else "GEN"
            if t == 'TEX_NOISE':
                args = "%s * %s, %s, %s, %s" % (vec, self.inp(n, "Scale", st, F), self.inp(n, "Detail", st, F),
                                                self.inp(n, "Roughness", st, F), self.inp(n, "Distortion", st, F))
                if oid == "Fac":
                    return self.var(F, "noiseFac(%s)" % args), F
                return self.var(C, "float4(noiseColor(%s), 1.0)" % args), C
            if t == 'TEX_CHECKER':
                f = self.var(F, "checker(%s * %s)" % (vec, self.inp(n, "Scale", st, F)))
                if oid == "Fac":
                    return f, F
                return self.var(C, "mix(%s, %s, %s)" % (self.inp(n, "Color2", st, C), self.inp(n, "Color1", st, C), f)), C
            if t == 'TEX_GRADIENT':
                g = {"LINEAR": 0, "QUADRATIC": 1, "EASING": 2, "DIAGONAL": 3, "SPHERICAL": 4,
                     "QUADRATIC_SPHERE": 5, "RADIAL": 6}.get(n.gradient_type, 0)
                f = self.var(F, "gradientTex(%s, %d)" % (vec, g))
                return (f, F) if oid == "Fac" else ("float4(float3(%s), 1.0)" % f, C)
            if t == 'TEX_WHITE_NOISE':
                f = self.var(C, "whiteNoise(%s)" % vec)
                return ("%s.w" % f, F) if oid == "Value" else ("float4(%s.rgb, 1.0)" % f, C)
            # voronoi/wave/magic/brick: smooth noise as a stand-in
            self.unsupported.add(n.bl_idname)
            sc = self.inp(n, "Scale", st, F, "5.0") if n.inputs.get("Scale") is not None else "5.0"
            if out.type == 'VALUE':
                return self.var(F, "noiseFac(%s * %s, 2.0, 0.5, 0.0)" % (vec, sc)), F
            return self.var(C, "float4(noiseColor(%s * %s, 2.0, 0.5, 0.0), 1.0)" % (vec, sc)), C

        # ------------------------------------------------ shaders
        if out.type == 'SHADER':
            return self._shader(n, st), S
        return None

    def _math(self, n, st):
        op = n.operation
        F = _T_FLOAT
        a = self.inp(n, "Value", st, F)
        b = self.inp(n, "Value_001", st, F)
        c = self.inp(n, "Value_002", st, F)
        e = {
            "ADD": "(%s + %s)" % (a, b), "SUBTRACT": "(%s - %s)" % (a, b), "MULTIPLY": "(%s * %s)" % (a, b),
            "DIVIDE": "safeDiv(%s, %s)" % (a, b), "MULTIPLY_ADD": "(%s * %s + %s)" % (a, b, c),
            "POWER": "safePow(%s, %s)" % (a, b), "LOGARITHM": "safeLog(%s, %s)" % (a, b),
            "SQRT": "sqrt(max(%s, 0.0))" % a, "INVERSE_SQRT": "rsqrt(max(%s, 1e-8))" % a,
            "ABSOLUTE": "fabs(%s)" % a, "EXPONENT": "exp(%s)" % a, "MINIMUM": "min(%s, %s)" % (a, b),
            "MAXIMUM": "max(%s, %s)" % (a, b), "LESS_THAN": "(%s < %s ? 1.0 : 0.0)" % (a, b),
            "GREATER_THAN": "(%s > %s ? 1.0 : 0.0)" % (a, b), "SIGN": "sign(%s)" % a,
            "COMPARE": "(fabs(%s - %s) <= max(%s, 1e-5) ? 1.0 : 0.0)" % (a, b, c),
            "SMOOTH_MIN": "smoothMin(%s, %s, %s)" % (a, b, c), "SMOOTH_MAX": "-smoothMin(-%s, -%s, %s)" % (a, b, c),
            "ROUND": "floor(%s + 0.5)" % a, "FLOOR": "floor(%s)" % a, "CEIL": "ceil(%s)" % a,
            "TRUNC": "trunc(%s)" % a, "FRACT": "(%s - floor(%s))" % (a, a), "MODULO": "safeFmod(%s, %s)" % (a, b),
            "FLOORED_MODULO": "safeFloorMod(%s, %s)" % (a, b), "WRAP": "wrapF(%s, %s, %s)" % (a, b, c),
            "SNAP": "(floor(safeDiv(%s, %s)) * %s)" % (a, b, b), "PINGPONG": "pingpong(%s, %s)" % (a, b),
            "SINE": "sin(%s)" % a, "COSINE": "cos(%s)" % a, "TANGENT": "tan(%s)" % a,
            "ARCSINE": "asin(clamp(%s, -1.0, 1.0))" % a, "ARCCOSINE": "acos(clamp(%s, -1.0, 1.0))" % a,
            "ARCTANGENT": "atan(%s)" % a, "ARCTAN2": "atan2(%s, %s)" % (a, b), "SINH": "sinh(%s)" % a,
            "COSH": "cosh(%s)" % a, "TANH": "tanh(%s)" % a, "RADIANS": "(%s * 0.017453292)" % a,
            "DEGREES": "(%s * 57.29578)" % a,
        }.get(op)
        if e is None:
            self.unsupported.add("Math:" + op)
            e = a
        return "saturate(%s)" % e if n.use_clamp else e

    def _vmath(self, n, st, oid):
        V3, F = _T_VEC, _T_FLOAT
        op = n.operation
        a = self.inp(n, "Vector", st, V3)
        b = self.inp(n, "Vector_001", st, V3)
        c = self.inp(n, "Vector_002", st, V3)
        sc = self.inp(n, "Scale", st, F, "1.0")
        vec = {
            "ADD": "(%s + %s)" % (a, b), "SUBTRACT": "(%s - %s)" % (a, b), "MULTIPLY": "(%s * %s)" % (a, b),
            "DIVIDE": "safeDiv3(%s, %s)" % (a, b), "MULTIPLY_ADD": "(%s * %s + %s)" % (a, b, c),
            "CROSS_PRODUCT": "cross(%s, %s)" % (a, b), "PROJECT": "projectV(%s, %s)" % (a, b),
            "REFLECT": "reflect(%s, normalize(%s))" % (a, b), "REFRACT": "refract(%s, normalize(%s), %s)" % (a, b, sc),
            "FACEFORWARD": "faceforward(%s, %s, %s)" % (a, b, c), "SCALE": "(%s * %s)" % (a, sc),
            "NORMALIZE": "safeNormalize(%s)" % a, "ABSOLUTE": "fabs(%s)" % a, "MINIMUM": "min(%s, %s)" % (a, b),
            "MAXIMUM": "max(%s, %s)" % (a, b), "FLOOR": "floor(%s)" % a, "CEIL": "ceil(%s)" % a,
            "FRACTION": "fract(%s)" % a, "MODULO": "fmod(%s, %s)" % (a, b), "SNAP": "(floor(safeDiv3(%s, %s)) * %s)" % (a, b, b),
            "SINE": "sin(%s)" % a, "COSINE": "cos(%s)" % a, "TANGENT": "tan(%s)" % a,
            "WRAP": "float3(wrapF(%s.x, %s.x, %s.x), wrapF(%s.y, %s.y, %s.y), wrapF(%s.z, %s.z, %s.z))" % (a, b, c, a, b, c, a, b, c),
        }.get(op)
        val = {"DOT_PRODUCT": "dot(%s, %s)" % (a, b), "DISTANCE": "distance(%s, %s)" % (a, b),
               "LENGTH": "length(%s)" % a}.get(op)
        if vec is None and val is None:
            self.unsupported.add("VectorMath:" + op)
            vec = a
        if val is not None:
            v = self.var(F, val)
            return (v, F) if oid == "Value" else ("float3(%s)" % v, V3)
        v = self.var(V3, vec)
        return (v, V3) if oid == "Vector" else ("0.0", F)

    def _ramp(self, n, st, oid):
        F, C = _T_FLOAT, _T_COL
        cr = n.color_ramp
        els = sorted(cr.elements, key=lambda e: e.position)
        fac = self.var(F, "saturate(%s)" % self.inp(n, "Fac", st, F))
        res = "v%d" % self.n
        self.n += 1
        cols = [_lit(list(e.color), C) for e in els]
        pos = [e.position for e in els]
        interp = cr.interpolation
        self.lines.append("float4 %s = %s;" % (res, cols[0]))
        for i in range(1, len(els)):
            p0, p1 = pos[i - 1], pos[i]
            if interp == 'CONSTANT':
                self.lines.append("if (%s >= %s) { %s = %s; }" % (fac, _f(p1), res, cols[i]))
            else:
                w = "saturate((%s - %s) / %s)" % (fac, _f(p0), _f(max(p1 - p0, 1e-6)))
                if interp == 'EASE':
                    w = "smoothstep(0.0, 1.0, %s)" % w
                self.lines.append("if (%s >= %s) { %s = mix(%s, %s, %s); }" % (fac, _f(p0), res, cols[i - 1], cols[i], w))
        return ("%s.a" % res, F) if oid == "Alpha" else ("float4(%s.rgb, 1.0)" % res, C)

    def _curve(self, n, st):
        F, V3, C = _T_FLOAT, _T_VEC, _T_COL
        m = n.mapping
        try:
            m.initialize()
        except Exception:  # noqa
            pass
        N = 33

        def lut(curve):
            name = "lut%d" % self.n
            self.n += 1
            vals = [m.evaluate(curve, i / (N - 1)) for i in range(N)]
            self.lines.append("const float %s[%d] = {%s};" % (name, N, ", ".join(_f(v) for v in vals)))
            return name

        if n.type == 'CURVE_FLOAT':
            l = lut(m.curves[0])
            v = self.inp(n, "Value", st, F)
            return self.var(F, "mix(%s, lutEval(%s, %s), %s)" % (v, l, v, self.inp(n, "Factor", st, F))), F
        if n.type == 'CURVE_VEC':
            ls = [lut(m.curves[i]) for i in range(3)]
            v = self.var(V3, self.inp(n, "Vector", st, V3))
            return self.var(V3, "mix(%s, float3(lutEval(%s, %s.x * 0.5 + 0.5) * 2.0 - 1.0, lutEval(%s, %s.y * 0.5 + 0.5) * 2.0 - 1.0, lutEval(%s, %s.z * 0.5 + 0.5) * 2.0 - 1.0), %s)"
                            % (v, ls[0], v, ls[1], v, ls[2], v, self.inp(n, "Fac", st, F))), V3
        lc = lut(m.curves[3])
        lr, lg, lb = lut(m.curves[0]), lut(m.curves[1]), lut(m.curves[2])
        c = self.var(C, self.inp(n, "Color", st, C))
        curved = ("float3(lutEval(%s, lutEval(%s, %s.r)), lutEval(%s, lutEval(%s, %s.g)), lutEval(%s, lutEval(%s, %s.b)))"
                  % (lr, lc, c, lg, lc, c, lb, lc, c))
        return self.var(C, "float4(mix(%s.rgb, %s, %s), %s.a)" % (c, curved, self.inp(n, "Fac", st, F), c)), C

    def _shader(self, n, st):
        F, V3, C, S = _T_FLOAT, _T_VEC, _T_COL, _T_SURF
        t = n.type

        def nrm(key):
            return self.inp(n, key, st, V3) if self.linked(n, key, st) else "N"

        def get(*keys, typ=F, default="0.0"):
            for k in keys:
                if next((x for x in n.inputs if x.identifier == k), None) is not None or n.inputs.get(k) is not None:
                    return self.inp(n, k, st, typ)
            return default

        sv = "v%d" % self.n
        self.n += 1
        L = self.lines
        L.append("Surf %s = surfDefault();" % sv)
        if t == 'BSDF_PRINCIPLED':
            L.append("%s.base = %s.rgb;" % (sv, get("Base Color", typ=C, default="float4(0.8)")))
            L.append("%s.metallic = %s;" % (sv, get("Metallic")))
            L.append("%s.roughness = %s;" % (sv, get("Roughness", default="0.5")))
            alpha = get("Alpha", default="1.0")
            if alpha not in ("1.0",):
                self.uses_alpha = True
            L.append("%s.alpha = %s;" % (sv, alpha))
            L.append("%s.N = %s;" % (sv, nrm("Normal")))
            L.append("%s.specular = %s;" % (sv, get("Specular IOR Level", "Specular", default="0.5")))
            L.append("%s.transmission = %s;" % (sv, get("Transmission Weight", "Transmission")))
            L.append("%s.coat = %s;" % (sv, get("Coat Weight", "Clearcoat")))
            L.append("%s.coatRough = %s;" % (sv, get("Coat Roughness", "Clearcoat Roughness", default="0.03")))
            L.append("%s.coatN = %s;" % (sv, nrm("Coat Normal") if n.inputs.get("Coat Normal") else
                                         (nrm("Clearcoat Normal") if n.inputs.get("Clearcoat Normal") else "N")))
            L.append("%s.sss = %s;" % (sv, get("Subsurface Weight", "Subsurface")))
            em = get("Emission Color", "Emission", typ=C, default="float4(0.0)")
            L.append("%s.emission = %s.rgb * %s;" % (sv, em, get("Emission Strength", default="1.0")))
        elif t in ('BSDF_DIFFUSE', 'BSDF_TRANSLUCENT', 'SUBSURFACE_SCATTERING', 'BSDF_TOON', 'BSDF_SHEEN',
                   'BSDF_VELVET', 'BSDF_HAIR', 'BSDF_HAIR_PRINCIPLED', 'BSDF_RAY_PORTAL'):
            L.append("%s.base = %s.rgb;" % (sv, get("Color", "Base Color", typ=C, default="float4(0.8)")))
            L.append("%s.roughness = 1.0; %s.specular = 0.0;" % (sv, sv))
            L.append("%s.N = %s;" % (sv, nrm("Normal")))
            if t == 'SUBSURFACE_SCATTERING':
                L.append("%s.sss = 1.0;" % sv)
        elif t in ('BSDF_GLOSSY', 'BSDF_ANISOTROPIC', 'BSDF_METALLIC'):
            L.append("%s.base = %s.rgb;" % (sv, get("Color", "Base Color", typ=C, default="float4(0.8)")))
            L.append("%s.metallic = 1.0; %s.roughness = %s;" % (sv, sv, get("Roughness", default="0.5")))
            L.append("%s.N = %s;" % (sv, nrm("Normal")))
        elif t in ('BSDF_GLASS', 'BSDF_REFRACTION'):
            L.append("%s.base = %s.rgb;" % (sv, get("Color", typ=C, default="float4(1.0)")))
            L.append("%s.roughness = %s; %s.transmission = 1.0; %s.specular = 0.5;" % (sv, get("Roughness"), sv, sv))
            L.append("%s.N = %s;" % (sv, nrm("Normal")))
        elif t == 'EMISSION':
            L.append("%s.base = float3(0.0); %s.specular = 0.0;" % (sv, sv))
            L.append("%s.emission = %s.rgb * %s;" % (sv, get("Color", typ=C, default="float4(1.0)"), get("Strength", default="1.0")))
        elif t == 'BACKGROUND':
            L.append("%s.base = float3(0.0); %s.emission = %s.rgb * %s;" % (sv, sv, get("Color", typ=C), get("Strength", default="1.0")))
        elif t in ('BSDF_TRANSPARENT', 'HOLDOUT'):
            self.uses_alpha = True
            L.append("%s.alpha = 0.0;" % sv)
        elif t == 'MIX_SHADER':
            fac = self.inp(n, "Fac", st, F)
            a = self.inp(n, "Shader", st, S, "surfDefault()")
            b = self.inp(n, "Shader_001", st, S, "surfDefault()")
            L.append("%s = surfMix(%s, %s, saturate(%s));" % (sv, a, b, fac))
        elif t == 'ADD_SHADER':
            a = self.inp(n, "Shader", st, S, "surfDefault()")
            b = self.inp(n, "Shader_001", st, S, "surfDefault()")
            L.append("%s = surfAdd(%s, %s);" % (sv, a, b))
        elif t == 'SPECULAR_BSDF' or t == 'EEVEE_SPECULAR':
            L.append("%s.base = %s.rgb;" % (sv, get("Base Color", typ=C, default="float4(0.8)")))
            L.append("%s.roughness = %s;" % (sv, get("Roughness", default="0.5")))
            L.append("%s.N = %s;" % (sv, nrm("Normal")))
            em = get("Emissive Color", typ=C, default="float4(0.0)")
            L.append("%s.emission = %s.rgb;" % (sv, em))
        else:
            self.unsupported.add(n.bl_idname)
            c = None
            for k in ("Color", "Base Color"):
                if n.inputs.get(k) is not None:
                    c = self.inp(n, k, st, C)
                    break
            if c:
                L.append("%s.base = %s.rgb;" % (sv, c))
        return sv

    # ---------------------------------------------------------------- entry
    def compile(self):
        nt = self.mat.node_tree
        outs = [n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL']
        out = next((n for n in outs if n.is_active_output and n.target in ('ALL', 'EEVEE')), None) \
            or next((n for n in outs if n.is_active_output), outs[0] if outs else None)
        if out is None:
            body = "s = surfDefault();"
        else:
            e = self.sock_expr(out.inputs["Surface"], (), _T_SURF, "surfDefault()")
            body = "s = %s;" % e
        code = "\n".join("    " + l for l in self.lines + [body])
        return {
            "code": code,
            "textures": self.textures,
            "uvSlots": self.uv_slots,
            "colorSlots": self.col_slots,
            "unsupported": sorted(self.unsupported),
            "alpha": self.uses_alpha,
        }


def compile_material(mat, obj, paint_image, uv_names, render_uv, color_names, render_color):
    if not mat or not mat.node_tree:
        return None
    c = Compiler(mat, obj, paint_image, uv_names, render_uv, color_names, render_color)
    try:
        return c.compile()
    except Exception as e:  # noqa
        import traceback
        traceback.print_exc()
        return {"code": "    s = surfDefault();", "textures": [], "uvSlots": [], "colorSlots": [],
                "unsupported": ["compiler error: %s" % e]}

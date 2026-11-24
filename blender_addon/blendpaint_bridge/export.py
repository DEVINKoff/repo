"""Scene -> iPad export: mesh with every UV map, image pixels and a simplified shader description."""
import math
import zlib

import bpy
import numpy as np

EXTRA_TEXTURE_MAX = 1024


# --------------------------------------------------------------------------- selection

def find_paint_node(mat):
    """Image node the user wants to paint: the active node in the shader editor if it is an
    Image Texture, else the one feeding Base Color, else the first Image Texture."""
    if not mat or not mat.use_nodes or not mat.node_tree:
        return None
    nodes = mat.node_tree.nodes
    act = nodes.active
    if act and act.type == 'TEX_IMAGE' and act.image:
        return act
    for n in nodes:
        if n.type == 'BSDF_PRINCIPLED':
            s = n.inputs.get("Base Color")
            if s and s.is_linked:
                fn = s.links[0].from_node
                if fn.type == 'TEX_IMAGE' and fn.image:
                    return fn
    for n in nodes:
        if n.type == 'TEX_IMAGE' and n.image:
            return n
    return None


def current_target(pinned=None):
    """Returns (obj, mat, node) or None."""
    if pinned:
        obj = bpy.data.objects.get(pinned[0])
        mat = bpy.data.materials.get(pinned[1])
        node = mat.node_tree.nodes.get(pinned[2]) if mat and mat.node_tree else None
        if obj and mat and node and node.type == 'TEX_IMAGE' and node.image:
            return obj, mat, node
    vl = getattr(bpy.context, "view_layer", None)
    obj = vl.objects.active if vl else None
    if not obj or obj.type != 'MESH':
        return None
    mat = obj.active_material
    node = find_paint_node(mat)
    if not node:
        return None
    return obj, mat, node


def target_key(t):
    if not t:
        return None
    obj, mat, node = t
    img = node.image
    return (obj.name, mat.name, node.name, img.name if img else "", tuple(img.size) if img else (0, 0))


# --------------------------------------------------------------------------- mesh

def export_mesh(obj, mat):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    eo = obj.evaluated_get(depsgraph)
    me = eo.to_mesh()
    try:
        me.calc_loop_triangles()
        nv, nl, nt = len(me.vertices), len(me.loops), len(me.loop_triangles)
        co = np.empty(nv * 3, np.float32)
        me.vertices.foreach_get("co", co)
        lv = np.empty(nl, np.int32)
        me.loops.foreach_get("vertex_index", lv)
        pos = co.reshape(-1, 3)[lv]

        nrm = np.empty(nl * 3, np.float32)
        if hasattr(me, "corner_normals"):
            me.corner_normals.foreach_get("vector", nrm)
        else:  # Blender < 4.1
            me.calc_normals_split()
            me.loops.foreach_get("normal", nrm)
        nrm = nrm.reshape(-1, 3)

        m = np.array(obj.matrix_world, dtype=np.float64)
        m3 = m[:3, :3]
        pos = (pos.astype(np.float64) @ m3.T + m[:3, 3]).astype(np.float32)
        try:
            nm = np.linalg.inv(m3).T
        except np.linalg.LinAlgError:
            nm = m3
        nrm = nrm.astype(np.float64) @ nm.T
        ln = np.linalg.norm(nrm, axis=1, keepdims=True)
        ln[ln == 0] = 1
        nrm = (nrm / ln).astype(np.float32)

        tris = np.empty(nt * 3, np.int32)
        me.loop_triangles.foreach_get("loops", tris)
        tris = tris.reshape(-1, 3)
        mi = np.empty(nt, np.int32)
        me.loop_triangles.foreach_get("material_index", mi)

        slots = [i for i, s in enumerate(obj.material_slots) if s.material == mat]
        if not slots:
            slots = [0]
        paint_mask = np.isin(mi, slots)
        paint_tris = tris[paint_mask]
        other_tris = tris[~paint_mask]
        all_tris = np.concatenate([paint_tris, other_tris]).astype(np.uint32).ravel()

        # real polygon edges (no triangulation diagonals) of the paintable faces, as loop-index pairs
        npoly = len(me.polygons)
        starts = np.empty(npoly, np.int32)
        totals = np.empty(npoly, np.int32)
        pmi = np.empty(npoly, np.int32)
        me.polygons.foreach_get("loop_start", starts)
        me.polygons.foreach_get("loop_total", totals)
        me.polygons.foreach_get("material_index", pmi)
        poly_of_loop = np.repeat(np.arange(npoly, dtype=np.int32), totals)
        idx = np.arange(nl, dtype=np.int32)
        local = idx - starts[poly_of_loop]
        nxt = np.where(local == totals[poly_of_loop] - 1, starts[poly_of_loop], idx + 1)
        emask = np.isin(pmi, slots)[poly_of_loop]
        edges = np.stack([idx[emask], nxt[emask]], axis=1).astype(np.uint32).ravel()

        uv_names, uv_blobs = [], []
        active_uv = me.uv_layers.active.name if me.uv_layers.active else ""
        render_uv = ""
        for layer in me.uv_layers:
            arr = np.empty(nl * 2, np.float32)
            layer.data.foreach_get("uv", arr)
            uv_names.append(layer.name)
            uv_blobs.append(arr.tobytes())
            if getattr(layer, "active_render", False):
                render_uv = layer.name
        if not render_uv:
            render_uv = active_uv
        if not uv_names:
            # no UVs: give a degenerate map so the app still opens
            uv_names.append("(no UV)")
            uv_blobs.append(np.zeros(nl * 2, np.float32).tobytes())

        parts = [pos.tobytes(), nrm.tobytes()] + uv_blobs + [edges.tobytes(), all_tris.tobytes()]
        info = {
            "name": obj.name,
            "vertexCount": int(nl),
            "indexCount": int(all_tris.size),
            "edgeIndexCount": int(edges.size),
            "paintIndexCount": int(paint_tris.size),
            "uvMaps": uv_names,
            "activeUV": active_uv,
            "renderUV": render_uv,
        }
        return info, parts
    finally:
        eo.to_mesh_clear()


# --------------------------------------------------------------------------- image

def image_rgba8(img, max_size=0):
    """Image pixels as top-left-origin RGBA8 bytes (straight alpha). Optional downscale."""
    w, h = img.size
    if w == 0 or h == 0:
        raise RuntimeError(f"Image '{img.name}' has no pixel data (missing file?)")
    buf = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(buf)
    a = buf.reshape(h, w, 4)[::-1]
    if max_size and max(w, h) > max_size:
        step = int(math.ceil(max(w, h) / max_size))
        a = a[::step, ::step]
    a = np.ascontiguousarray(a)
    hh, ww = a.shape[0], a.shape[1]
    u8 = (np.clip(a, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    return ww, hh, u8.tobytes()


def deflate(data, level=1):
    c = zlib.compressobj(level, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def inflate(data):
    return zlib.decompress(data, -15)


# --------------------------------------------------------------------------- material

def _default(sock):
    v = getattr(sock, "default_value", None)
    if v is None:
        return None
    try:
        return [float(x) for x in v]
    except TypeError:
        return float(v)


def _uv_for(node):
    vec = node.inputs.get("Vector")
    if vec and vec.is_linked:
        fn = vec.links[0].from_node
        while fn.type == 'REROUTE' and fn.inputs[0].is_linked:
            fn = fn.inputs[0].links[0].from_node
        if fn.type == 'UVMAP':
            return fn.uv_map or None
        if fn.type == 'TEX_COORD':
            return None
        if fn.type == 'MAPPING':
            return _uv_for(fn)
    return None


_CHANNEL = {"Red": "r", "Green": "g", "Blue": "b", "R": "r", "G": "g", "B": "b",
            "X": "r", "Y": "g", "Z": "b"}
_PASS = {'HUE_SAT', 'GAMMA', 'BRIGHTCONTRAST', 'INVERT', 'CURVE_RGB', 'VALTORGB', 'RGBTOBW',
         'MAP_RANGE', 'CLAMP', 'MATH'}


def resolve(sock, depth=0):
    if sock is None:
        return {"kind": "none"}
    if not sock.is_linked or depth > 12:
        v = _default(sock)
        return {"kind": "value", "value": v} if v is not None else {"kind": "none"}
    link = sock.links[0]
    node, out = link.from_node, link.from_socket
    t = node.type
    if t == 'REROUTE':
        return resolve(node.inputs[0], depth + 1)
    if t == 'TEX_IMAGE':
        if not node.image:
            return {"kind": "none"}
        return {"kind": "texture", "image": node.image.name, "node": node.name,
                "channel": "a" if out.name == "Alpha" else "rgb", "uv": _uv_for(node)}
    if t in ('SEPARATE_COLOR', 'SEPRGB', 'SEPARATE_RGB', 'SEPXYZ', 'SEPARATE_XYZ'):
        r = resolve(node.inputs[0], depth + 1)
        if r["kind"] == "texture":
            r["channel"] = _CHANNEL.get(out.name, "r")
        return r
    if t == 'NORMAL_MAP':
        r = resolve(node.inputs.get("Color"), depth + 1)
        if r["kind"] == "texture":
            r["normalMap"] = True
            s = node.inputs.get("Strength")
            r["strength"] = float(s.default_value) if s else 1.0
            return r
        return {"kind": "none"}
    if t in ('MIX', 'MIX_RGB'):
        for name in ("A", "Color1", "B", "Color2"):
            for s in node.inputs:
                if s.name == name and s.enabled and s.is_linked:
                    r = resolve(s, depth + 1)
                    if r["kind"] == "texture":
                        return r
        for s in node.inputs:
            if s.name in ("A", "Color1") and s.enabled:
                return resolve(s, depth + 1)
        return {"kind": "none"}
    if t in _PASS:
        for s in node.inputs:
            if s.is_linked:
                r = resolve(s, depth + 1)
                if r["kind"] == "texture":
                    return r
        return {"kind": "none"}
    return {"kind": "none"}


def _find_surface_shader(mat):
    nt = mat.node_tree
    outs = [n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL']
    out = next((n for n in outs if n.is_active_output), outs[0] if outs else None)
    if not out:
        return None
    s = out.inputs.get("Surface")
    if not s or not s.is_linked:
        return None
    node = s.links[0].from_node
    for _ in range(16):
        if node.type == 'REROUTE' and node.inputs[0].is_linked:
            node = node.inputs[0].links[0].from_node
        elif node.type in ('MIX_SHADER', 'ADD_SHADER'):
            cand = None
            for sk in node.inputs:
                if sk.type == 'SHADER' and sk.is_linked:
                    fn = sk.links[0].from_node
                    if fn.type == 'BSDF_PRINCIPLED':
                        cand = fn
                        break
                    if cand is None:
                        cand = fn
            if cand is None:
                return None
            node = cand
        else:
            return node
    return node


def _inp(node, *names):
    for n in names:
        s = node.inputs.get(n)
        if s is not None:
            return s
    return None


def material_desc(mat, paint_image_name):
    desc = {"name": mat.name, "shader": "none", "slots": {}, "blend": getattr(mat, "blend_method", "OPAQUE")}
    if not mat.use_nodes:
        c = list(mat.diffuse_color)
        desc["shader"] = "principled"
        desc["slots"] = {"baseColor": {"kind": "value", "value": c}}
        return desc
    sh = _find_surface_shader(mat)
    if sh is None:
        return desc
    slots = {}
    if sh.type == 'BSDF_PRINCIPLED':
        desc["shader"] = "principled"
        slots["baseColor"] = resolve(_inp(sh, "Base Color"))
        slots["metallic"] = resolve(_inp(sh, "Metallic"))
        slots["roughness"] = resolve(_inp(sh, "Roughness"))
        slots["alpha"] = resolve(_inp(sh, "Alpha"))
        slots["normal"] = resolve(_inp(sh, "Normal"))
        slots["emission"] = resolve(_inp(sh, "Emission Color", "Emission"))
        slots["emissionStrength"] = resolve(_inp(sh, "Emission Strength"))
        slots["specular"] = resolve(_inp(sh, "Specular IOR Level", "Specular"))
    elif sh.type in ('BSDF_DIFFUSE', 'BSDF_GLOSSY', 'BSDF_TOON', 'BSDF_SHEEN'):
        desc["shader"] = "principled"
        slots["baseColor"] = resolve(_inp(sh, "Color"))
        slots["roughness"] = resolve(_inp(sh, "Roughness"))
        slots["normal"] = resolve(_inp(sh, "Normal"))
        if sh.type == 'BSDF_GLOSSY':
            slots["metallic"] = {"kind": "value", "value": 1.0}
    elif sh.type == 'EMISSION':
        desc["shader"] = "emission"
        slots["baseColor"] = resolve(_inp(sh, "Color"))
        slots["emissionStrength"] = resolve(_inp(sh, "Strength"))
    elif sh.type == 'BSDF_TRANSPARENT':
        desc["shader"] = "transparent"
    else:
        desc["shader"] = "unknown:" + sh.type
        c = _inp(sh, "Color", "Base Color")
        if c:
            slots["baseColor"] = resolve(c)
    desc["slots"] = slots
    desc["paintedFound"] = any(v.get("kind") == "texture" and v.get("image") == paint_image_name
                               for v in slots.values())
    return desc


def extra_images(desc, paint_image_name):
    names = []
    for v in desc.get("slots", {}).values():
        if v.get("kind") == "texture" and v.get("image") != paint_image_name and v["image"] not in names:
            names.append(v["image"])
    return names


def build_extra_blobs(names):
    """Returns list of (info, bytes) for the extra (non-painted) textures used by the material."""
    out = []
    for name in names:
        img = bpy.data.images.get(name)
        if not img:
            continue
        try:
            w, h, data = image_rgba8(img, EXTRA_TEXTURE_MAX)
        except Exception as e:  # noqa
            print("BlendPaint: skip texture", name, e)
            continue
        out.append(({"name": name, "width": w, "height": h,
                     "colorspace": img.colorspace_settings.name}, deflate(data)))
    return out

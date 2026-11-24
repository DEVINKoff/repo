"""Scene -> iPad export: mesh with every UV map, image pixels and a simplified shader description."""
import math
import zlib

import bpy
import numpy as np

EXTRA_TEXTURE_MAX = 2048


# --------------------------------------------------------------------------- selection

def _iter_image_nodes(tree, seen=None):
    """All Image Texture nodes of a node tree, descending into node groups (Mecabricks etc.)."""
    if tree is None:
        return
    seen = seen if seen is not None else set()
    if tree.as_pointer() in seen:
        return
    seen.add(tree.as_pointer())
    for n in tree.nodes:
        if n.type == 'TEX_IMAGE' and n.image:
            yield n
        elif n.type == 'GROUP' and n.node_tree:
            yield from _iter_image_nodes(n.node_tree, seen)


def _editor_active_image(mat):
    """Image node that is active in an open Shader Editor showing this material —
    including when the user has Tab-ed into a node group."""
    wm = getattr(bpy.context, "window_manager", None)
    if not wm or not mat or not mat.node_tree:
        return None
    for win in wm.windows:
        for area in win.screen.areas:
            if area.type != 'NODE_EDITOR':
                continue
            sp = area.spaces.active
            if getattr(sp, "tree_type", "") != 'ShaderNodeTree' or sp.node_tree != mat.node_tree:
                continue
            tree = sp.edit_tree or sp.node_tree
            n = tree.nodes.active if tree else None
            if n and n.type == 'TEX_IMAGE' and n.image:
                return n
            if n and n.type == 'GROUP' and n.node_tree:
                inner = n.node_tree.nodes.active
                if inner and inner.type == 'TEX_IMAGE' and inner.image:
                    return inner
                first = next(_iter_image_nodes(n.node_tree), None)
                if first:
                    return first
    return None


def find_paint_node(mat):
    """Image node the user wants to paint: the active node in the Shader Editor (also inside
    groups), else the active group's image, else the one feeding Base Color, else the first one."""
    if not mat or not mat.use_nodes or not mat.node_tree:
        return None
    n = _editor_active_image(mat)
    if n:
        return n
    act = mat.node_tree.nodes.active
    if act and act.type == 'TEX_IMAGE' and act.image:
        return act
    if act and act.type == 'GROUP' and act.node_tree:
        inner = act.node_tree.nodes.active
        if inner and inner.type == 'TEX_IMAGE' and inner.image:
            return inner
        first = next(_iter_image_nodes(act.node_tree), None)
        if first:
            return first
    # whatever drives Base Color of the surface shader (follows groups)
    try:
        sh, stack = _find_surface_shader(mat)
        if sh is not None:
            r = resolve(_inp(sh, "Base Color", "Color"), stack)
            if r.get("kind") == "texture":
                for n in _iter_image_nodes(mat.node_tree):
                    if n.image.name == r["image"]:
                        return n
    except Exception as e:  # noqa
        print("BlendPaint: base color lookup failed:", e)
    return next(_iter_image_nodes(mat.node_tree), None)


def current_target(pinned=None):
    """Returns (obj, mat, node) or None."""
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
        # box filter (averaging), not nearest sampling → no pixelation
        step = int(math.ceil(max(w, h) / max_size))
        hh, ww = (a.shape[0] // step) * step, (a.shape[1] // step) * step
        a = a[:hh, :ww].reshape(hh // step, step, ww // step, step, 4).mean(axis=(1, 3))
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


def _sock(sockets, ref):
    """Find the matching socket on the other side of a group boundary."""
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


def _link_from(sock, stack, depth=0):
    """Follows a link backwards through reroutes and group boundaries.
    Returns (node, out_socket, stack) of the real source node or None."""
    if sock is None or not sock.is_linked or depth > 48:
        return None
    link = sock.links[0]
    if getattr(link, "is_muted", False):
        return None
    node, out = link.from_node, link.from_socket
    if node.type == 'REROUTE':
        return _link_from(node.inputs[0], stack, depth + 1)
    if node.type == 'GROUP':
        if not node.node_tree:
            return None
        go = _group_output(node.node_tree)
        inner = _sock(go.inputs, out) if go else None
        return _link_from(inner, stack + (node,), depth + 1)
    if node.type == 'GROUP_INPUT':
        if not stack:
            return None
        outer = _sock(stack[-1].inputs, out)
        return _link_from(outer, stack[:-1], depth + 1)
    return node, out, stack


def _uv_for(node, stack=()):
    vec = node.inputs.get("Vector")
    src = _link_from(vec, stack)
    if not src:
        return None
    fn, _, st = src
    if fn.type == 'UVMAP':
        return fn.uv_map or None
    if fn.type == 'MAPPING':
        return _uv_for(fn, st)
    if fn.type == 'ATTRIBUTE' and getattr(fn, "attribute_name", ""):
        return fn.attribute_name
    return None


_CHANNEL = {"Red": "r", "Green": "g", "Blue": "b", "R": "r", "G": "g", "B": "b",
            "X": "r", "Y": "g", "Z": "b"}
_PASS = {'HUE_SAT', 'GAMMA', 'BRIGHTCONTRAST', 'INVERT', 'CURVE_RGB', 'VALTORGB', 'RGBTOBW',
         'MAP_RANGE', 'CLAMP', 'MATH', 'MIX_RGB', 'MIX', 'CURVE_FLOAT'}


def _value_through_groups(sock, stack):
    """Default value of an unlinked socket; if it is a group-output input we just use its default."""
    v = _default(sock)
    return {"kind": "value", "value": v} if v is not None else {"kind": "none"}


def resolve(sock, stack=(), depth=0):
    if sock is None:
        return {"kind": "none"}
    if depth > 24:
        return {"kind": "none"}
    if not sock.is_linked:
        return _value_through_groups(sock, stack)
    src = _link_from(sock, stack)
    if not src:
        # linked to a Group Input whose outer socket is unlinked → use the group node's value
        link = sock.links[0]
        fn = link.from_node
        if fn.type == 'GROUP_INPUT' and stack:
            outer = _sock(stack[-1].inputs, link.from_socket)
            if outer is not None:
                return resolve(outer, stack[:-1], depth + 1)
        return {"kind": "none"}
    node, out, st = src
    t = node.type
    if t == 'TEX_IMAGE':
        if not node.image:
            return {"kind": "none"}
        return {"kind": "texture", "image": node.image.name, "node": node.name,
                "channel": "a" if out.name == "Alpha" else "rgb", "uv": _uv_for(node, st)}
    if t in ('SEPARATE_COLOR', 'SEPRGB', 'SEPARATE_RGB', 'SEPXYZ', 'SEPARATE_XYZ'):
        r = resolve(node.inputs[0], st, depth + 1)
        if r["kind"] == "texture":
            r["channel"] = _CHANNEL.get(out.name, "r")
        return r
    if t == 'NORMAL_MAP':
        r = resolve(node.inputs.get("Color"), st, depth + 1)
        if r["kind"] == "texture":
            r["normalMap"] = True
            s = node.inputs.get("Strength")
            r["strength"] = float(s.default_value) if s and not s.is_linked else 1.0
            return r
        return {"kind": "none"}
    if t in _PASS:
        # prefer an image anywhere upstream (Mecabricks mixes base color with decals etc.)
        first_value = None
        for s in node.inputs:
            if not s.enabled or s.type == 'SHADER':
                continue
            if s.is_linked:
                r = resolve(s, st, depth + 1)
                if r["kind"] == "texture":
                    return r
                if first_value is None and r["kind"] == "value":
                    first_value = r
        if t in ('MIX', 'MIX_RGB'):
            for name in ("A", "Color1"):
                for s in node.inputs:
                    if s.name == name and s.enabled:
                        return resolve(s, st, depth + 1)
        return first_value or {"kind": "none"}
    if t in ('RGB', 'VALUE'):
        try:
            return {"kind": "value", "value": _default(out)}
        except Exception:  # noqa
            return {"kind": "none"}
    return {"kind": "none"}


def _follow_shader(sock, stack, depth=0):
    """Returns (bsdf_node, stack) feeding a shader socket, descending into groups/mix shaders."""
    src = _link_from(sock, stack)
    if not src or depth > 16:
        return None, stack
    node, _, st = src
    if node.type in ('MIX_SHADER', 'ADD_SHADER'):
        cands = []
        for sk in node.inputs:
            if sk.type == 'SHADER':
                n, s2 = _follow_shader(sk, st, depth + 1)
                if n is not None:
                    cands.append((n, s2))
        for n, s2 in cands:
            if n.type == 'BSDF_PRINCIPLED':
                return n, s2
        for n, s2 in cands:
            if n.type not in ('BSDF_TRANSPARENT', 'HOLDOUT'):
                return n, s2
        return cands[0] if cands else (None, stack)
    return node, st


def _find_surface_shader(mat):
    nt = mat.node_tree
    outs = [n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL']
    out = next((n for n in outs if n.is_active_output), outs[0] if outs else None)
    if not out:
        return None, ()
    return _follow_shader(out.inputs.get("Surface"), ())


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
    sh, st = _find_surface_shader(mat)
    if sh is None:
        return desc
    slots = {}
    if sh.type == 'BSDF_PRINCIPLED':
        desc["shader"] = "principled"
        slots["baseColor"] = resolve(_inp(sh, "Base Color"), st)
        slots["metallic"] = resolve(_inp(sh, "Metallic"), st)
        slots["roughness"] = resolve(_inp(sh, "Roughness"), st)
        slots["alpha"] = resolve(_inp(sh, "Alpha"), st)
        slots["normal"] = resolve(_inp(sh, "Normal"), st)
        slots["emission"] = resolve(_inp(sh, "Emission Color", "Emission"), st)
        slots["emissionStrength"] = resolve(_inp(sh, "Emission Strength"), st)
        slots["specular"] = resolve(_inp(sh, "Specular IOR Level", "Specular"), st)
    elif sh.type in ('BSDF_DIFFUSE', 'BSDF_GLOSSY', 'BSDF_TOON', 'BSDF_SHEEN'):
        desc["shader"] = "principled"
        slots["baseColor"] = resolve(_inp(sh, "Color"), st)
        slots["roughness"] = resolve(_inp(sh, "Roughness"), st)
        slots["normal"] = resolve(_inp(sh, "Normal"), st)
        if sh.type == 'BSDF_GLOSSY':
            slots["metallic"] = {"kind": "value", "value": 1.0}
    elif sh.type == 'EMISSION':
        desc["shader"] = "emission"
        slots["baseColor"] = resolve(_inp(sh, "Color"), st)
        slots["emissionStrength"] = resolve(_inp(sh, "Strength"), st)
    elif sh.type == 'BSDF_TRANSPARENT':
        desc["shader"] = "transparent"
    else:
        desc["shader"] = "unknown:" + sh.type
        c = _inp(sh, "Color", "Base Color")
        if c:
            slots["baseColor"] = resolve(c, st)
    for k in ("normal",):
        if slots.get(k, {}).get("kind") == "value":
            slots[k] = {"kind": "none"}      # plain normal vectors are meaningless for preview
    desc["slots"] = slots
    desc["paintedFound"] = any(v.get("kind") == "texture" and v.get("image") == paint_image_name
                               for v in slots.values())
    return desc


def paint_uv_for(desc, paint_image_name):
    for v in desc.get("slots", {}).values():
        if v.get("kind") == "texture" and v.get("image") == paint_image_name and v.get("uv"):
            return v["uv"]
    return None


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

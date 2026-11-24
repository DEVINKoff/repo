bl_info = {
    "name": "BlendPaint Bridge (iPad)",
    "author": "DEVINK",
    "version": (1, 0, 0),
    "blender": (3, 6, 0),
    "location": "Shader Editor / 3D View > Sidebar > BlendPaint",
    "description": "Live texture painting from the BlendPaint iPad app",
    "category": "Paint",
}

import json
import queue
import threading
import time

import bpy
import numpy as np
from bpy.app.handlers import persistent

from . import export
from . import shadergen
from .server import BridgeServer, DEFAULT_PORT, PROTOCOL_VERSION, local_ips


class _State:
    server = None
    inbox = queue.Queue()
    session = None            # dict, see _start_session
    session_counter = 0
    scene_counter = 0
    scene_job = None
    last_key = None
    last_follow_check = 0.0
    material_dirty_at = 0.0
    last_material_json = ""
    sent_extra = set()
    status = ""
    client_name = ""
    lock = threading.Lock()


S = _State()


def _prefs():
    try:
        return bpy.context.preferences.addons[__package__].preferences
    except (KeyError, AttributeError):
        return None


def _wm_props():
    return bpy.context.window_manager.blendpaint


def _view_layer():
    vl = getattr(bpy.context, "view_layer", None)
    if vl:
        return vl
    wm = bpy.context.window_manager
    return wm.windows[0].view_layer if wm and wm.windows else None


def _tag_redraw():
    wm = bpy.context.window_manager
    if not wm:
        return
    for win in wm.windows:
        for area in win.screen.areas:
            if area.type in ('VIEW_3D', 'IMAGE_EDITOR', 'NODE_EDITOR'):
                area.tag_redraw()


# --------------------------------------------------------------------------- network callbacks
# (called from network threads; never touch bpy here)

def _on_connect(client):
    client.send({"type": "hello", "server": "BlendPaint Bridge", "version": PROTOCOL_VERSION,
                 "blender": bpy.app.version_string})
    S.inbox.put(({"type": "_connected"}, b""))


def _on_message(client, header, payload):
    t = header.get("type")
    if t == "tiles":
        _apply_tiles(header, payload)
    else:
        S.inbox.put((header, payload))


def _apply_tiles(header, payload):
    s = S.session
    if not s or header.get("sessionId") != s["id"]:
        return
    H, W = s["h"], s["w"]
    buf = s["buf"]
    for r in header.get("rects", []):
        x, y, w, h = int(r["x"]), int(r["y"]), int(r["w"]), int(r["h"])
        if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > W or y + h > H:
            continue
        raw = payload[r["offset"]:r["offset"] + r["length"]]
        if r.get("compression") == "none":
            data = raw
        else:
            try:
                data = export.inflate(raw)
            except Exception:  # noqa
                continue
        if len(data) != w * h * 4:
            continue
        tile = np.frombuffer(data, np.uint8).reshape(h, w, 4).astype(np.float32)
        tile *= (1.0 / 255.0)
        by0 = H - (y + h)
        with S.lock:
            buf[by0:by0 + h, x:x + w] = tile[::-1]
            s["dirty"] = True


# --------------------------------------------------------------------------- session

def _start_session(target):
    obj, mat, node = target
    img = node.image
    w, h = img.size
    if w == 0 or h == 0:
        raise RuntimeError(f"Image '{img.name}' has no pixel data")
    fbuf = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(fbuf)
    fbuf = fbuf.reshape(h, w, 4)
    u8 = (np.clip(fbuf[::-1], 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)

    mesh_info, mesh_parts, col_blobs = export.export_mesh(obj, mat)
    desc = export.material_desc(mat, img.name)
    paint_uv = export.paint_uv_for(desc, img.name) or export._uv_for(node) or mesh_info["renderUV"] or (mesh_info["uvMaps"][0] if mesh_info["uvMaps"] else "")
    program = _compile(mat, obj, img.name, mesh_info)
    extras = export.build_extra_blobs(_needed_images(desc, program, img.name))

    blobs, chunks, off = [], [], 0

    def add(bid, data, **extra):
        nonlocal off
        d = {"id": bid, "offset": off, "length": len(data)}
        d.update(extra)
        blobs.append(d)
        chunks.append(data)
        off += len(data)

    add("positions", mesh_parts[0])
    add("normals", mesh_parts[1])
    for i, name in enumerate(mesh_info["uvMaps"]):
        add("uv:%d" % i, mesh_parts[2 + i])
    for i, cb in enumerate(col_blobs):
        add("col:%d" % i, cb)
    add("edges", mesh_parts[-2])
    add("indices", mesh_parts[-1])
    add("image", export.deflate(u8.tobytes()), compression="deflate", rawLength=w * h * 4)
    for info, data in extras:
        add("tex:" + info["name"], data, compression="deflate", rawLength=info["width"] * info["height"] * 4)

    S.session_counter += 1
    with S.lock:
        S.session = {"id": S.session_counter, "object": obj.name, "material": mat.name, "node": node.name,
                     "image": img.name, "w": w, "h": h, "buf": fbuf, "dirty": False, "mesh": mesh_info,
                     "last_flush": 0.0, "flush_cost": 0.0}
    S.sent_extra = set(i["name"] for i, _ in extras)
    S.last_material_json = json.dumps([desc, program], sort_keys=True)

    header = {
        "type": "session",
        "sessionId": S.session_counter,
        "file": bpy.path.basename(bpy.data.filepath) or "untitled.blend",
        "object": obj.name,
        "material": mat.name,
        "node": node.name,
        "image": {"name": img.name, "width": w, "height": h, "isFloat": bool(img.is_float),
                  "colorspace": img.colorspace_settings.name,
                  "alphaMode": getattr(img, "alpha_mode", "STRAIGHT")},
        "mesh": mesh_info,
        "paintUV": paint_uv,
        "materialDesc": desc,
        "program": program,
        "textures": [i for i, _ in extras],
        "blobs": blobs,
    }
    S.server.send(header, b"".join(chunks))
    S.last_key = export.target_key(target)
    S.status = f"Sent {obj.name} / {img.name} ({w}x{h})"


def _compile(mat, obj, image_name, mesh_info):
    return shadergen.compile_material(mat, obj, image_name, mesh_info["uvMaps"], mesh_info["renderUV"],
                                      mesh_info.get("colorAttrs", []), mesh_info.get("renderColor", ""))


def _needed_images(desc, program, paint_image):
    names = export.extra_images(desc, paint_image)
    for t in (program or {}).get("textures", []):
        if not t.get("paint") and t["image"] not in names:
            names.append(t["image"])
    return names


def send_scene():
    """Starts streaming all meshes (visible / selected / collection) to the iPad, one object per
    message, so neither side has to hold one giant payload. Runs incrementally in the pump."""
    if not S.server or not S.server.connected:
        return False
    import mathutils
    props = _wm_props()
    objs = export.scene_objects(props.scene_source)
    if not objs:
        return False
    bmin, bmax = [1e30] * 3, [-1e30] * 3
    for o in objs:
        for c in o.bound_box:
            w = o.matrix_world @ mathutils.Vector(c)
            bmin = [min(a, b) for a, b in zip(bmin, w)]
            bmax = [max(a, b) for a, b in zip(bmax, w)]
    S.scene_counter += 1
    sid = S.scene_counter
    S.server.send({"type": "scene_begin", "sceneId": sid, "count": len(objs), "bmin": bmin, "bmax": bmax})
    S.scene_job = _scene_stream([o.name for o in objs], sid)
    S.status = "Sending scene: %d objects" % len(objs)
    return True


def _scene_stream(names, sid):
    programs = []           # json strings, index = program id on the iPad
    prog_key = {}
    sent_tex = set()
    total = 0
    sent = 0
    for name in names:
        o = bpy.data.objects.get(name)
        if o is None or o.type != 'MESH':
            continue
        try:
            r = export.export_object(o)
        except Exception as e:  # noqa
            print("BlendPaint: scene skip", name, e)
            r = None
        if not r:
            yield
            continue
        info, ob_blobs, slot_mats = r
        total += info["vertexCount"]
        if total > 12_000_000:
            S.server.send({"type": "status", "level": "warning",
                           "message": "Сцена слишком большая — отправлена часть объектов"})
            break
        subs, used_uv, used_col = [], {info["renderUV"]}, set()
        for slot, start, count in info["ranges"]:
            mat = slot_mats[slot] if slot < len(slot_mats) else None
            pi = -1
            if mat is not None and mat.node_tree is not None:
                key = (mat.name, tuple(info["uvMaps"]), tuple(info["colorAttrs"]))
                if key not in prog_key:
                    p = shadergen.compile_material(mat, o, "", info["uvMaps"], info["renderUV"],
                                                   info["colorAttrs"], info["renderColor"])
                    js = json.dumps(p, sort_keys=True)
                    if js not in programs:
                        programs.append(js)
                        new_tex = [t["image"] for t in p.get("textures", []) if t["image"] not in sent_tex]
                        for tinfo, data in export.build_extra_blobs(new_tex, 1024):
                            S.server.send({"type": "scene_texture", "sceneId": sid, "texture": tinfo,
                                           "compression": "deflate",
                                           "rawLength": tinfo["width"] * tinfo["height"] * 4}, data)
                        sent_tex.update(new_tex)
                        S.server.send({"type": "scene_material", "sceneId": sid, "index": len(programs) - 1,
                                       "program": p})
                    prog_key[key] = programs.index(js)
                pi = prog_key[key]
                p = json.loads(programs[pi])
                used_uv.update(p.get("uvSlots", []))
                used_col.update(p.get("colorSlots", []))
            subs.append({"program": pi, "start": start, "count": count})
        # only the UV maps / color attributes the materials actually read
        uv_names = [n for n in info["uvMaps"] if n in used_uv] or info["uvMaps"][:1]
        col_names = [n for n in info["colorAttrs"] if n in used_col]
        blobs, chunks, off = [], [], 0

        def add(bid, data):
            nonlocal off
            blobs.append({"id": bid, "offset": off, "length": len(data)})
            chunks.append(data)
            off += len(data)

        add("pos", ob_blobs["pos"])
        add("nrm", ob_blobs["nrm"])
        add("idx", ob_blobs["idx"])
        for i, n in enumerate(uv_names):
            add("uv%d" % i, ob_blobs["uv%d" % info["uvMaps"].index(n)])
        for i, n in enumerate(col_names):
            add("col%d" % i, ob_blobs["col%d" % info["colorAttrs"].index(n)])
        S.server.send({"type": "scene_object", "sceneId": sid, "object": {
            "name": info["name"], "vertexCount": info["vertexCount"], "indexCount": info["indexCount"],
            "uvMaps": uv_names, "colorAttrs": col_names, "submeshes": subs,
            "bmin": info["bmin"], "bmax": info["bmax"]}, "blobs": blobs}, b"".join(chunks))
        sent += 1
        yield
    S.server.send({"type": "scene_end", "sceneId": sid, "count": sent, "materials": len(programs)})
    S.status = "Scene sent: %d objects, %d materials" % (sent, len(programs))


def _run_scene_job():
    job = S.scene_job
    if job is None or not S.server or not S.server.connected:
        S.scene_job = None
        return
    c = S.server.client
    if c is not None and c.bytes_pending > 48 * 1024 * 1024:
        return              # let the network catch up
    t0 = time.perf_counter()
    try:
        while time.perf_counter() - t0 < 0.03:
            next(job)
    except StopIteration:
        S.scene_job = None
    except Exception as e:  # noqa
        print("BlendPaint scene job error:", e)
        S.scene_job = None


def _select_object(name):
    obj = bpy.data.objects.get(name)
    if not obj or obj.type != 'MESH':
        return
    vl = bpy.context.view_layer
    try:
        for o in vl.objects:
            if o.select_get() and o != obj:
                o.select_set(False)
        obj.select_set(True)
        vl.objects.active = obj
    except Exception as e:  # noqa
        print("BlendPaint select:", e)
    r = export.find_object_paint_slot(obj)
    if not r:
        S.server.send({"type": "no_texture", "object": name})
        S.last_key = None
        return
    slot, mat, node = r
    obj.active_material_index = slot
    try:
        _flush(force=True)
        _start_session((obj, mat, node))
    except Exception as e:  # noqa
        S.server.send({"type": "status", "level": "error", "message": str(e)})


def _create_texture(name, size, color=(0.8, 0.8, 0.8, 1.0)):
    obj = bpy.data.objects.get(name)
    if not obj or obj.type != 'MESH':
        return
    mat = obj.active_material
    if mat is None:
        mat = bpy.data.materials.new(obj.name + "_Mat")
        mat.use_nodes = True
        if obj.material_slots:
            obj.material_slots[obj.active_material_index].material = mat
        else:
            obj.data.materials.append(mat)
    img = bpy.data.images.new(obj.name + "_Paint", size, size, alpha=True)
    img.generated_color = color
    nt = mat.node_tree
    node = nt.nodes.new('ShaderNodeTexImage')
    node.image = img
    node.location = (-450, 300)
    bsdf = next((n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED'), None)
    if bsdf and not bsdf.inputs["Base Color"].is_linked:
        nt.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
    nt.nodes.active = node
    _select_object(name)


def send_current(force=True):
    if not S.server or not S.server.connected:
        S.status = "iPad not connected"
        return False
    t = export.current_target()
    if not t:
        S.status = "Select a mesh whose active material has an Image Texture node"
        S.server.send({"type": "status", "level": "warning", "message": S.status})
        return False
    if not force and export.target_key(t) == S.last_key:
        return False
    try:
        _flush(force=True)
        _start_session(t)
        return True
    except Exception as e:  # noqa
        S.status = "Error: %s" % e
        S.server.send({"type": "status", "level": "error", "message": str(e)})
        print("BlendPaint:", e)
        return False


def _flush(force=False):
    s = S.session
    if not s or not s["dirty"]:
        return
    now = time.perf_counter()
    p = _prefs()
    min_interval = p.flush_interval if p else 0.08
    interval = max(min_interval, s["flush_cost"] * 1.5)
    if not force and now - s["last_flush"] < interval:
        return
    img = bpy.data.images.get(s["image"])
    if not img or tuple(img.size) != (s["w"], s["h"]):
        return
    t0 = time.perf_counter()
    with S.lock:
        img.pixels.foreach_set(s["buf"].reshape(-1))
        s["dirty"] = False
    img.update()
    s["flush_cost"] = time.perf_counter() - t0
    s["last_flush"] = time.perf_counter()
    _tag_redraw()


def _send_material_update():
    s = S.session
    if not s:
        return
    mat = bpy.data.materials.get(s["material"])
    if not mat:
        return
    desc = export.material_desc(mat, s["image"])
    obj = bpy.data.objects.get(s["object"])
    program = _compile(mat, obj, s["image"], s["mesh"])
    js = json.dumps([desc, program], sort_keys=True)
    if js == S.last_material_json:
        return
    S.last_material_json = js
    new = [n for n in _needed_images(desc, program, s["image"]) if n not in S.sent_extra]
    extras = export.build_extra_blobs(new)
    blobs, chunks, off = [], [], 0
    for info, data in extras:
        blobs.append({"id": "tex:" + info["name"], "offset": off, "length": len(data),
                      "compression": "deflate", "rawLength": info["width"] * info["height"] * 4})
        chunks.append(data)
        off += len(data)
        S.sent_extra.add(info["name"])
    S.server.send({"type": "material", "sessionId": s["id"], "materialDesc": desc, "program": program,
                   "textures": [i for i, _ in extras], "blobs": blobs}, b"".join(chunks))


def _save_image():
    s = S.session
    if not s:
        return
    _flush(force=True)
    img = bpy.data.images.get(s["image"])
    if not img:
        return
    try:
        if img.filepath and not img.packed_file:
            img.save()
            msg = f"Saved {img.name} to {img.filepath}"
        else:
            img.pack()
            msg = f"Packed {img.name} into the .blend (save the .blend file)"
        S.server.send({"type": "status", "level": "info", "message": msg})
        S.status = msg
    except Exception as e:  # noqa
        S.server.send({"type": "status", "level": "error", "message": str(e)})


# --------------------------------------------------------------------------- main-thread pump

def _pump():
    if not S.server:
        return 0.25
    try:
        while True:
            header, payload = S.inbox.get_nowait()
            t = header.get("type")
            if t == "_connected":
                S.status = "iPad connected"
                S.last_key = None
                S.session = None
                S.scene_job = None
                _tag_redraw()
            elif t == "hello":
                S.client_name = header.get("client", "iPad")
            elif t == "request_session":
                send_current(force=True)
            elif t == "request_scene":
                send_scene()
            elif t == "select_object":
                _select_object(header.get("name", ""))
            elif t == "create_texture":
                _create_texture(header.get("name", ""), int(header.get("size", 2048)))
            elif t == "save_image":
                _save_image()
            elif t == "set_follow":
                _wm_props().follow_selection = bool(header.get("value", True))
    except queue.Empty:
        pass
    except Exception as e:  # noqa
        print("BlendPaint pump error:", e)

    try:
        _flush()
    except Exception as e:  # noqa
        print("BlendPaint flush error:", e)
    if S.scene_job is not None:
        _run_scene_job()

    now = time.time()
    if S.server.connected:
        props = _wm_props()
        if props.follow_selection and now - S.last_follow_check > 0.35:
            S.last_follow_check = now
            t = export.current_target()
            if t and export.target_key(t) != S.last_key:
                send_current(force=True)
        if S.material_dirty_at and now - S.material_dirty_at > 0.35:
            S.material_dirty_at = 0.0
            try:
                _send_material_update()
            except Exception as e:  # noqa
                print("BlendPaint material update error:", e)
    return 0.016 if ((S.session and S.session["dirty"]) or S.scene_job is not None) else 0.03


@persistent
def _on_depsgraph(scene, depsgraph):
    if not S.session:
        return
    for u in depsgraph.updates:
        idt = u.id
        if isinstance(idt, (bpy.types.Material, bpy.types.ShaderNodeTree)):
            S.material_dirty_at = time.time()
            return


@persistent
def _on_load(*_):
    S.session = None
    S.last_key = None


def start_server():
    if S.server and S.server.running:
        return True
    p = _prefs()
    port = p.port if p else DEFAULT_PORT
    S.server = BridgeServer(_on_message, _on_connect, port)
    ok = S.server.start()
    S.status = f"Listening on port {port}" if ok else f"Cannot listen: {S.server.error}"
    if not ok:
        S.server = None
    return ok


def stop_server():
    if S.server:
        S.server.stop()
    S.server = None
    S.session = None
    S.status = "Stopped"


# --------------------------------------------------------------------------- UI

class BLENDPAINT_Props(bpy.types.PropertyGroup):
    scene_source: bpy.props.EnumProperty(
        name="Scene", default='VISIBLE',
        items=[('VISIBLE', "Visible meshes", "Every visible mesh in the view layer"),
               ('SELECTED', "Selected meshes", "Only the selected meshes"),
               ('COLLECTION', "Active collection", "Meshes of the active object's collection")])
    follow_selection: bpy.props.BoolProperty(
        name="Follow selection", default=True,
        description="Automatically send the active object / active Image Texture node to the iPad")


class BLENDPAINT_Prefs(bpy.types.AddonPreferences):
    bl_idname = __package__
    port: bpy.props.IntProperty(name="Port", default=DEFAULT_PORT, min=1024, max=65535)
    auto_start: bpy.props.BoolProperty(name="Start server with Blender", default=True)
    flush_interval: bpy.props.FloatProperty(
        name="Min update interval (s)", default=0.06, min=0.0, max=1.0,
        description="How often painted pixels are pushed into the Blender image")

    def draw(self, context):
        c = self.layout.column()
        c.prop(self, "port")
        c.prop(self, "auto_start")
        c.prop(self, "flush_interval")


class BLENDPAINT_OT_server(bpy.types.Operator):
    bl_idname = "blendpaint.server"
    bl_label = "Start / Stop BlendPaint server"
    action: bpy.props.EnumProperty(items=[("START", "Start", ""), ("STOP", "Stop", "")])

    def execute(self, context):
        if self.action == "START":
            if not start_server():
                self.report({'ERROR'}, S.status)
        else:
            stop_server()
        return {'FINISHED'}


class BLENDPAINT_OT_send(bpy.types.Operator):
    bl_idname = "blendpaint.send"
    bl_label = "Send to iPad"
    bl_description = "Send the active mesh and the active Image Texture node to the iPad"

    def execute(self, context):
        if not send_current(force=True):
            self.report({'WARNING'}, S.status)
        return {'FINISHED'}


class BLENDPAINT_OT_send_scene(bpy.types.Operator):
    bl_idname = "blendpaint.send_scene"
    bl_label = "Send Scene to iPad"
    bl_description = "Send all meshes (see Scene setting) so you can tap parts on the iPad"

    def execute(self, context):
        if not send_scene():
            self.report({'WARNING'}, "Nothing sent (iPad not connected or no meshes)")
        return {'FINISHED'}


class BLENDPAINT_OT_debug_material(bpy.types.Operator):
    bl_idname = "blendpaint.debug_material"
    bl_label = "Copy Material Debug"
    bl_description = ("Copy the active material's node tree (all groups, links and values) plus the "
                      "translated iPad shader to the clipboard, to report preview differences")

    @classmethod
    def poll(cls, context):
        o = context.active_object
        return o is not None and o.active_material is not None

    def execute(self, context):
        obj = context.active_object
        mat = obj.active_material
        text = shadergen.debug_dump(mat, obj)
        context.window_manager.clipboard = text
        t = bpy.data.texts.get("BlendPaint_debug") or bpy.data.texts.new("BlendPaint_debug")
        t.clear()
        t.write(text)
        self.report({'INFO'}, "Material debug copied to clipboard (%d KB)" % (len(text) // 1024 + 1))
        return {'FINISHED'}


class BLENDPAINT_OT_new_texture(bpy.types.Operator):
    bl_idname = "blendpaint.new_texture"
    bl_label = "New Paint Texture"
    bl_description = "Create an image + Image Texture node in the active material, ready to paint"
    bl_options = {'REGISTER', 'UNDO'}

    size: bpy.props.EnumProperty(name="Size", default="2048", items=[
        ("1024", "1024", ""), ("2048", "2048", ""), ("4096", "4096", ""), ("8192", "8192", "")])
    name: bpy.props.StringProperty(name="Name", default="Paint")
    color: bpy.props.FloatVectorProperty(name="Fill", subtype='COLOR', size=4, min=0, max=1,
                                         default=(0.8, 0.8, 0.8, 1.0))
    connect: bpy.props.BoolProperty(name="Connect to Base Color", default=True)

    @classmethod
    def poll(cls, context):
        o = context.active_object
        return o is not None and o.type == 'MESH'

    def invoke(self, context, event):
        return context.window_manager.invoke_props_dialog(self)

    def execute(self, context):
        obj = context.active_object
        mat = obj.active_material
        if mat is None:
            mat = bpy.data.materials.new(obj.name + "_Mat")
            mat.use_nodes = True
            if obj.material_slots:
                obj.material_slots[obj.active_material_index].material = mat
            else:
                obj.data.materials.append(mat)
        mat.use_nodes = True
        s = int(self.size)
        img = bpy.data.images.new(self.name, s, s, alpha=True)
        img.generated_color = self.color
        nt = mat.node_tree
        node = nt.nodes.new('ShaderNodeTexImage')
        node.image = img
        node.location = (-450, 300)
        if self.connect:
            bsdf = next((n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED'), None)
            if bsdf and not bsdf.inputs["Base Color"].is_linked:
                nt.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
        for n in nt.nodes:
            n.select = False
        node.select = True
        nt.nodes.active = node
        send_current(force=True)
        return {'FINISHED'}


def _draw_panel(layout, context):
    props = context.window_manager.blendpaint
    col = layout.column(align=True)
    running = S.server is not None and S.server.running
    if running:
        col.operator("blendpaint.server", text="Stop server", icon='PAUSE').action = "STOP"
    else:
        col.operator("blendpaint.server", text="Start server", icon='PLAY').action = "START"
    box = layout.box()
    if running:
        p = _prefs()
        port = p.port if p else DEFAULT_PORT
        for ip in local_ips() or ["?"]:
            box.label(text=f"{ip} : {port}", icon='URL')
        if S.server.connected:
            box.label(text=f"Connected: {S.server.client.addr[0]}", icon='CHECKMARK')
        else:
            box.label(text="Waiting for iPad…", icon='TIME')
    else:
        box.label(text="Server stopped", icon='X')
    if S.status:
        box.label(text=S.status)

    layout.prop(props, "follow_selection")
    t = export.current_target()
    sub = layout.box()
    if t:
        obj, mat, node = t
        sub.label(text=obj.name, icon='MESH_DATA')
        sub.label(text=mat.name, icon='MATERIAL')
        sub.label(text=f"{node.image.name} ({node.image.size[0]}×{node.image.size[1]})", icon='IMAGE_DATA')
    else:
        sub.label(text="Select a mesh + Image Texture node", icon='INFO')
    row = layout.row(align=True)
    row.scale_y = 1.4
    row.enabled = running
    row.operator("blendpaint.send", icon='EXPORT')
    col2 = layout.column(align=True)
    col2.enabled = running
    col2.prop(props, "scene_source", text="")
    col2.operator("blendpaint.send_scene", icon='SCENE_DATA')
    layout.operator("blendpaint.new_texture", icon='ADD')
    layout.operator("blendpaint.debug_material", icon='COPYDOWN')


class BLENDPAINT_PT_node(bpy.types.Panel):
    bl_label = "BlendPaint (iPad)"
    bl_space_type = 'NODE_EDITOR'
    bl_region_type = 'UI'
    bl_category = "BlendPaint"

    @classmethod
    def poll(cls, context):
        return context.space_data and context.space_data.tree_type == 'ShaderNodeTree'

    def draw(self, context):
        _draw_panel(self.layout, context)


class BLENDPAINT_PT_view3d(bpy.types.Panel):
    bl_label = "BlendPaint (iPad)"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "BlendPaint"

    def draw(self, context):
        _draw_panel(self.layout, context)


classes = (BLENDPAINT_Props, BLENDPAINT_Prefs, BLENDPAINT_OT_server, BLENDPAINT_OT_send, BLENDPAINT_OT_send_scene, BLENDPAINT_OT_debug_material,
           BLENDPAINT_OT_new_texture, BLENDPAINT_PT_node, BLENDPAINT_PT_view3d)


def _deferred_start():
    p = _prefs()
    if p is None or p.auto_start:
        start_server()
    return None


def register():
    for c in classes:
        bpy.utils.register_class(c)
    bpy.types.WindowManager.blendpaint = bpy.props.PointerProperty(type=BLENDPAINT_Props)
    bpy.app.handlers.depsgraph_update_post.append(_on_depsgraph)
    bpy.app.handlers.load_post.append(_on_load)
    bpy.app.timers.register(_pump, first_interval=0.5, persistent=True)
    bpy.app.timers.register(_deferred_start, first_interval=1.0)


def unregister():
    stop_server()
    if bpy.app.timers.is_registered(_pump):
        bpy.app.timers.unregister(_pump)
    if _on_depsgraph in bpy.app.handlers.depsgraph_update_post:
        bpy.app.handlers.depsgraph_update_post.remove(_on_depsgraph)
    if _on_load in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(_on_load)
    del bpy.types.WindowManager.blendpaint
    for c in reversed(classes):
        bpy.utils.unregister_class(c)

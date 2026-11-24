"""Headless test of the Blender add-on: pip install bpy, then python3 tools/test_addon_bpy.py
Acts like the iPad: hello -> session -> tiles -> material update."""
import sys, socket, struct, json, time, zlib
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "blender_addon"))
import bpy, numpy as np
import blendpaint_bridge as bp
bp.register()
bpy.ops.mesh.primitive_monkey_add()
obj = bpy.context.active_object
obj.data.uv_layers.new(name="UVMap")
obj.data.uv_layers.new(name="Second")
mat = bpy.data.materials.new("M"); mat.use_nodes=True; obj.data.materials.append(mat)
img = bpy.data.images.new("Paint", 256, 128, alpha=True)
nt = mat.node_tree
n = nt.nodes.new("ShaderNodeTexImage"); n.image = img
bsdf = nt.nodes["Principled BSDF"]
nt.links.new(n.outputs["Color"], bsdf.inputs["Base Color"])
uvn = nt.nodes.new("ShaderNodeUVMap"); uvn.uv_map="Second"; nt.links.new(uvn.outputs[0], n.inputs["Vector"])
img2 = bpy.data.images.new("Rough", 2048, 2048)
n2 = nt.nodes.new("ShaderNodeTexImage"); n2.image = img2
sep = nt.nodes.new("ShaderNodeSeparateColor"); nt.links.new(n2.outputs[0], sep.inputs[0]); nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
nm = nt.nodes.new("ShaderNodeNormalMap"); nt.links.new(n2.outputs[0], nm.inputs["Color"]); nt.links.new(nm.outputs[0], bsdf.inputs["Normal"])
nt.nodes.active = n
assert bp.start_server(), bp.S.status
s = socket.create_connection(("127.0.0.1", 47800))
def send(h, p=b""):
    hb=json.dumps(h).encode(); s.sendall(struct.pack(">II",len(hb),len(p))+hb+p)
def recv():
    def ex(k):
        b=b""
        while len(b)<k: b+=s.recv(k-len(b))
        return b
    hl,pl=struct.unpack(">II",ex(8)); h=json.loads(ex(hl)); return h, ex(pl) if pl else b""
probe = socket.create_connection(("127.0.0.1", 47800)); probe.close()
send({"type":"hello","client":"test"})
print(recv()[0])
time.sleep(0.2); bp._pump(); time.sleep(0.3)
h,p = recv()
print(h["type"], h["image"], h["mesh"], h["paintUV"])
print(json.dumps(h["materialDesc"], indent=0)[:600])
print([ (b["id"],b["length"]) for b in h["blobs"]], len(p))
sid=h["sessionId"]
# send red tile at top-left 16x8
tile = np.zeros((8,16,4),np.uint8); tile[...,0]=255; tile[...,3]=255
c=zlib.compressobj(1,zlib.DEFLATED,-15); d=c.compress(tile.tobytes())+c.flush()
send({"type":"tiles","sessionId":sid,"rects":[{"x":0,"y":0,"w":16,"h":8,"offset":0,"length":len(d)}]}, d)
time.sleep(0.3); bp._flush(force=True)
px=np.empty(256*128*4,np.float32); img.pixels.foreach_get(px); px=px.reshape(128,256,4)
print("top-left pixel (blender row 127):", px[127,0], "bottom:", px[0,0])
bsdf.inputs["Metallic"].default_value=0.7
bp.S.material_dirty_at = time.time()-1; bp._pump(); time.sleep(0.2)
h,p=recv(); print(h["type"], h["materialDesc"]["slots"]["metallic"])
bp.stop_server()

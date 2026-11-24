"""Converts Blender's bundled studio HDRIs (CC0, Poly Haven) into raw RGBA16F blobs for the app.
    python3 tools/convert_hdri.py   (needs `pip install bpy`)"""
import os, struct
import bpy, numpy as np
src = os.path.join(os.path.dirname(bpy.__file__), "..", "..", "..", "datafiles", "studiolights", "world")
src = os.path.normpath(src)
if not os.path.isdir(src):
    import glob
    src = glob.glob("/usr/local/lib/python3*/*-packages/bpy/*/datafiles/studiolights/world")[0]
out = os.path.join(os.path.dirname(__file__), "..", "ios", "BlendPaint", "Resources", "HDRI")
W, H = 512, 256
for f in sorted(os.listdir(src)):
    if not f.endswith(".exr"):
        continue
    img = bpy.data.images.load(os.path.join(src, f))
    w, h = img.size
    px = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(px)
    a = px.reshape(h, w, 4)[::-1]                       # top row first
    sy, sx = h // H, w // W
    a = a[:H * sy, :W * sx].reshape(H, sy, W, sx, 4).mean(axis=(1, 3))
    a[..., 3] = 1.0
    a = np.clip(a, 0, 60000).astype(np.float16)
    name = os.path.splitext(f)[0]
    with open(os.path.join(out, name + ".hdr16"), "wb") as fo:
        fo.write(b"BPH1" + struct.pack("<II", W, H) + a.tobytes())
    print(name, w, h, "->", W, H, float(a[..., :3].astype(np.float32).mean()))

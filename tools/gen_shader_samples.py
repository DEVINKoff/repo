"""Builds test materials in Blender (pip install bpy) and writes the translated MSL as full shader
files to ios/ShaderSamples/. CI compiles them with `xcrun metal` to validate the translator.

    python3 tools/gen_shader_samples.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "blender_addon"))

import bpy  # noqa: E402
from blendpaint_bridge import shadergen, export  # noqa: E402

TEMPLATE = open(os.path.join(ROOT, "ios", "BlendPaint", "Resources", "MaterialTemplate.txt")).read()
OUT = os.path.join(ROOT, "ios", "ShaderSamples")
os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    os.remove(os.path.join(OUT, f))

bpy.ops.mesh.primitive_cube_add()
obj = bpy.context.active_object
me = obj.data
me.uv_layers.new(name="UVMap")
me.uv_layers.new(name="Decal")
me.color_attributes.new("Col", 'BYTE_COLOR', 'CORNER')
UVS = [l.name for l in me.uv_layers]
COLS = [c.name for c in me.color_attributes]


def new_mat(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    return m, m.node_tree, m.node_tree.nodes["Principled BSDF"], m.node_tree.nodes["Material Output"]


def img(name, srgb=True):
    i = bpy.data.images.new(name, 16, 16, alpha=True)
    if not srgb:
        i.colorspace_settings.name = "Non-Color"
    return i


samples = []

# 1. Mecabricks-like: nested groups, purple base + decal mixed by alpha, roughness from group input
m, nt, bsdf, out = new_mat("mecabricks")
g = bpy.data.node_groups.new("mb:Shader", "ShaderNodeTree")
g.interface.new_socket("Shader", in_out='OUTPUT', socket_type='NodeSocketShader')
g.interface.new_socket("Color", in_out='INPUT', socket_type='NodeSocketColor')
g.interface.new_socket("Roughness", in_out='INPUT', socket_type='NodeSocketFloat')
gi, go = g.nodes.new("NodeGroupInput"), g.nodes.new("NodeGroupOutput")
gb = g.nodes.new("ShaderNodeBsdfPrincipled")
dec = bpy.data.node_groups.new("mb:Decal", "ShaderNodeTree")
dec.interface.new_socket("Color", in_out='OUTPUT', socket_type='NodeSocketColor')
dec.interface.new_socket("Alpha", in_out='OUTPUT', socket_type='NodeSocketFloat')
do = dec.nodes.new("NodeGroupOutput")
t = dec.nodes.new("ShaderNodeTexImage"); t.image = img("decal")
uvn = dec.nodes.new("ShaderNodeUVMap"); uvn.uv_map = "Decal"
dec.links.new(uvn.outputs[0], t.inputs["Vector"])
dec.links.new(t.outputs["Color"], do.inputs[0])
dec.links.new(t.outputs["Alpha"], do.inputs[1])
dn = g.nodes.new("ShaderNodeGroup"); dn.node_tree = dec
mix = g.nodes.new("ShaderNodeMix"); mix.data_type = 'RGBA'
g.links.new(dn.outputs[1], mix.inputs["Factor"])
g.links.new(gi.outputs[0], mix.inputs[6])
g.links.new(dn.outputs[0], mix.inputs[7])
g.links.new(mix.outputs[2], gb.inputs["Base Color"])
g.links.new(gi.outputs[1], gb.inputs["Roughness"])
noise = g.nodes.new("ShaderNodeTexNoise")
bump = g.nodes.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.1
g.links.new(noise.outputs["Fac"], bump.inputs["Height"])
g.links.new(bump.outputs[0], gb.inputs["Normal"])
gb.inputs["Coat Weight"].default_value = 0.5
g.links.new(gb.outputs[0], go.inputs[0])
gn = nt.nodes.new("ShaderNodeGroup"); gn.node_tree = g
gn.inputs[0].default_value = (0.35, 0.05, 0.6, 1)
gn.inputs[1].default_value = 0.2
nt.links.new(gn.outputs[0], out.inputs["Surface"])
samples.append((m, "decal"))

# 2. PBR set: ORM via Separate Color, normal map, emission, alpha, mapping
m, nt, bsdf, out = new_mat("pbr")
tc = nt.nodes.new("ShaderNodeTexCoord")
mp = nt.nodes.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = (2, 2, 2)
nt.links.new(tc.outputs["UV"], mp.inputs["Vector"])
base = nt.nodes.new("ShaderNodeTexImage"); base.image = img("albedo")
nt.links.new(mp.outputs[0], base.inputs["Vector"])
orm = nt.nodes.new("ShaderNodeTexImage"); orm.image = img("orm", False)
sep = nt.nodes.new("ShaderNodeSeparateColor")
nt.links.new(orm.outputs[0], sep.inputs[0])
nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
nrm = nt.nodes.new("ShaderNodeTexImage"); nrm.image = img("normal", False)
nm = nt.nodes.new("ShaderNodeNormalMap")
nt.links.new(nrm.outputs[0], nm.inputs["Color"])
nt.links.new(nm.outputs[0], bsdf.inputs["Normal"])
nt.links.new(base.outputs["Color"], bsdf.inputs["Base Color"])
nt.links.new(base.outputs["Alpha"], bsdf.inputs["Alpha"])
nt.links.new(base.outputs["Color"], bsdf.inputs["Emission Color"])
samples.append((m, "albedo"))

# 3. Utility nodes: math, ramp, curves, hsv, map range, mix modes, layer weight, vertex colors, mix shader
m, nt, bsdf, out = new_mat("utility")
vc = nt.nodes.new("ShaderNodeVertexColor"); vc.layer_name = "Col"
lw = nt.nodes.new("ShaderNodeLayerWeight")
ramp = nt.nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements.new(0.5).color = (1, 0, 0, 1)
nt.links.new(lw.outputs["Facing"], ramp.inputs["Fac"])
curve = nt.nodes.new("ShaderNodeRGBCurve")
nt.links.new(ramp.outputs["Color"], curve.inputs["Color"])
hs = nt.nodes.new("ShaderNodeHueSaturation")
nt.links.new(curve.outputs[0], hs.inputs["Color"])
mrgb = nt.nodes.new("ShaderNodeMixRGB"); mrgb.blend_type = 'OVERLAY'
nt.links.new(hs.outputs[0], mrgb.inputs[1])
nt.links.new(vc.outputs[0], mrgb.inputs[2])
math = nt.nodes.new("ShaderNodeMath"); math.operation = 'POWER'
nt.links.new(vc.outputs["Alpha"], math.inputs[0])
mr = nt.nodes.new("ShaderNodeMapRange"); mr.interpolation_type = 'SMOOTHSTEP'
nt.links.new(math.outputs[0], mr.inputs["Value"])
nt.links.new(mr.outputs[0], bsdf.inputs["Roughness"])
fc = nt.nodes.new("ShaderNodeFloatCurve")
nt.links.new(mr.outputs[0], fc.inputs["Value"])
nt.links.new(fc.outputs[0], bsdf.inputs["Metallic"])
nt.links.new(mrgb.outputs[0], bsdf.inputs["Base Color"])
vm = nt.nodes.new("ShaderNodeVectorMath"); vm.operation = 'DOT_PRODUCT'
geo = nt.nodes.new("ShaderNodeNewGeometry")
nt.links.new(geo.outputs["Normal"], vm.inputs[0])
nt.links.new(geo.outputs["Incoming"], vm.inputs[1])
glass = nt.nodes.new("ShaderNodeBsdfGlass")
ms = nt.nodes.new("ShaderNodeMixShader")
nt.links.new(vm.outputs["Value"], ms.inputs["Fac"])
nt.links.new(bsdf.outputs[0], ms.inputs[1])
nt.links.new(glass.outputs[0], ms.inputs[2])
nt.links.new(ms.outputs[0], out.inputs["Surface"])
chk = nt.nodes.new("ShaderNodeTexChecker")
grad = nt.nodes.new("ShaderNodeTexGradient")
comb = nt.nodes.new("ShaderNodeCombineColor"); comb.mode = 'HSV'
nt.links.new(chk.outputs["Fac"], comb.inputs[0])
nt.links.new(grad.outputs["Fac"], comb.inputs[1])
add = nt.nodes.new("ShaderNodeAddShader")
em = nt.nodes.new("ShaderNodeEmission")
nt.links.new(comb.outputs[0], em.inputs["Color"])
samples.append((m, ""))

# 4. Emission / transparent / color → shader conversion
m, nt, bsdf, out = new_mat("emissive")
tr = nt.nodes.new("ShaderNodeBsdfTransparent")
em = nt.nodes.new("ShaderNodeEmission")
ms = nt.nodes.new("ShaderNodeMixShader")
vor = nt.nodes.new("ShaderNodeTexVoronoi")
nt.links.new(vor.outputs["Distance"], ms.inputs["Fac"])
nt.links.new(tr.outputs[0], ms.inputs[1])
nt.links.new(em.outputs[0], ms.inputs[2])
nt.links.new(ms.outputs[0], out.inputs["Surface"])
samples.append((m, ""))

for mat, paint in samples:
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    prog = shadergen.compile_material(mat, obj, paint, UVS, "UVMap", COLS, "Col")
    code = TEMPLATE.replace("//@@MATERIAL@@", prog["code"])
    with open(os.path.join(OUT, mat.name + ".metal"), "w") as f:
        f.write(code)
    print("%-12s textures=%s uv=%s col=%s unsupported=%s lines=%d" % (
        mat.name, [t["image"] for t in prog["textures"]], prog["uvSlots"], prog["colorSlots"],
        prog["unsupported"], prog["code"].count("\n") + 1))
    if mat.name == "mecabricks":
        print(prog["code"])

# the selection logic must still find the decal inside nested groups
obj.data.materials.clear()
obj.data.materials.append(bpy.data.materials["mecabricks"])
print("paint target:", export.find_paint_node(bpy.data.materials["mecabricks"]).image.name)

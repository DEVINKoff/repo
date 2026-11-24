"""Self-update from GitHub Releases (CI publishes blendpaint-<build> with blendpaint_bridge.zip)."""
import io
import json
import os
import shutil
import threading
import urllib.request
import zipfile

REPO = "DEVINKoff/repo"
API = "https://api.github.com/repos/%s/releases/latest" % REPO
HERE = os.path.dirname(os.path.abspath(__file__))


class State:
    checking = False
    latest = 0
    message = ""
    updated_to = 0


def current_build():
    try:
        with open(os.path.join(HERE, "build.txt")) as f:
            return int(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def _get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "BlendPaint-Bridge",
                                               "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def check_and_install(install=True, done=None):
    """Runs in a background thread. Never touches bpy."""
    if State.checking:
        return
    State.checking = True

    def run():
        try:
            rel = json.loads(_get(API))
            tag = rel.get("tag_name", "")
            if not tag.startswith("blendpaint-"):
                State.message = "No BlendPaint release found"
                return
            n = int(tag.split("-", 1)[1])
            State.latest = n
            cur = current_build()
            if n <= cur:
                State.message = "Up to date (build %d)" % cur
                return
            if not install:
                State.message = "Build %d available (you have %d)" % (n, cur)
                return
            asset = next((a for a in rel.get("assets", []) if a.get("name") == "blendpaint_bridge.zip"), None)
            if not asset:
                State.message = "Release %d has no add-on zip" % n
                return
            data = _get(asset["browser_download_url"], timeout=60)
            zf = zipfile.ZipFile(io.BytesIO(data))
            tmp = HERE + "_update_tmp"
            shutil.rmtree(tmp, ignore_errors=True)
            zf.extractall(tmp)
            src = os.path.join(tmp, "blendpaint_bridge")
            if not os.path.isdir(src):
                State.message = "Bad update archive"
                return
            for name in os.listdir(src):
                s = os.path.join(src, name)
                d = os.path.join(HERE, name)
                if os.path.isdir(s):
                    shutil.rmtree(d, ignore_errors=True)
                    shutil.copytree(s, d)
                else:
                    shutil.copy2(s, d)
            shutil.rmtree(tmp, ignore_errors=True)
            State.updated_to = n
            State.message = "Updated to build %d — press Reload Add-on (or restart Blender)" % n
        except Exception as e:  # noqa
            State.message = "Update check failed: %s" % e
        finally:
            State.checking = False
            if done:
                done()

    threading.Thread(target=run, daemon=True, name="BlendPaintUpdate").start()


def template_text():
    """Material template shipped with this add-on build (sent to the iPad so shader fixes
    arrive without reinstalling the app)."""
    p = os.path.join(HERE, "material_template.txt")
    try:
        with open(p, encoding="utf-8") as f:
            t = f.read()
    except OSError:
        return None, 0
    abi = 0
    first = t.split("\n", 1)[0]
    if "BP_TEMPLATE_ABI" in first:
        try:
            abi = int(first.split()[-1])
        except ValueError:
            pass
    return t, abi

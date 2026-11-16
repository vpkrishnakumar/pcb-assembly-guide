"""Builds the KiCad plugin package:  python3 kicad-plugin/package.py

Writes build/pcb-assembly-guide-kicad-plugin-<version>.zip, which installs with KiCad's
Plugin and Content Manager (Install from File...). Also prints the download_* values the
official KiCad repository asks for.
"""
import hashlib
import json
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
WEB = ("guide.html", "three.min.js", "GLTFLoader.js", "OrbitControls.js", "THREE-LICENSE.txt")


def files():
    """(path inside the archive, source file) for everything in the package."""
    yield "metadata.json", HERE / "metadata.json"
    yield "resources/icon.png", HERE / "icon-64.png"
    for name in ("__init__.py", "assembly_guide_action.py", "icon.png"):
        yield "plugins/" + name, HERE / name
    yield "plugins/pcb_assembly_guide.py", ROOT / "cli" / "pcb_assembly_guide.py"
    yield "plugins/LICENSE", ROOT / "LICENSE"
    for name in WEB:
        yield "plugins/web/" + name, ROOT / "Resources" / "web" / name


def main():
    metadata = json.loads((HERE / "metadata.json").read_text(encoding="utf-8"))
    version = metadata["versions"][0]["version"]
    output = ROOT / "build" / ("pcb-assembly-guide-kicad-plugin-%s.zip" % version)
    output.parent.mkdir(exist_ok=True)
    installed = 0
    with zipfile.ZipFile(str(output), "w", zipfile.ZIP_DEFLATED) as archive:
        for name, source in files():
            data = source.read_bytes()
            installed += len(data)
            # A fixed timestamp keeps the archive, and so its hash, the same from build to build.
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)
    packed = output.read_bytes()
    print("Wrote %s" % output)
    print(json.dumps({"download_sha256": hashlib.sha256(packed).hexdigest(), "download_size": len(packed),
                      "install_size": installed}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

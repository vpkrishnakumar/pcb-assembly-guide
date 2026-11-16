"""Loads the unpacked KiCad plugin the way KiCad does and builds a guide with it.

    python3 tests/load_plugin.py <plugins folder> <plugin folder name> board.kicad_pcb out.html

Needs KiCad's Python (the one that can import pcbnew). There is no KiCad window, so the toolbar
registration is skipped; everything else is the code the button runs.
"""
import importlib
import sys
from pathlib import Path

import pcbnew

folder, name, board, output = sys.argv[1], sys.argv[2], Path(sys.argv[3]).resolve(), Path(sys.argv[4])
pcbnew.ActionPlugin.register = lambda self: None
sys.path.insert(0, folder)
action = importlib.import_module(name + ".assembly_guide_action")
plugin = action.AssemblyGuidePlugin()
plugin.defaults()
assert Path(plugin.icon_file_name).is_file(), "toolbar icon is missing"
print("KiCad %s, kicad-cli: %s" % (pcbnew.Version(), action.kicad_cli_beside_kicad()))
parts, steps, warning = action.build_guide(board, output, dict(action.DEFAULTS), print)
print("%d parts, %d steps, warning: %s" % (parts, steps, warning))
sys.exit(1 if warning else 0)

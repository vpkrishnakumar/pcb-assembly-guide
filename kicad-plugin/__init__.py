"""PCB Assembly Guide: a KiCad PCB editor plugin.

Adds a toolbar button that writes a step-by-step hand-assembly guide for the open board as a single
web page. See https://github.com/vpkrishnakumar/pcb-assembly-guide
"""
try:
    from .assembly_guide_action import AssemblyGuidePlugin
    AssemblyGuidePlugin().register()
except Exception:  # A broken plugin must never stop KiCad starting; KiCad lists the traceback itself.
    import traceback
    traceback.print_exc()
    raise

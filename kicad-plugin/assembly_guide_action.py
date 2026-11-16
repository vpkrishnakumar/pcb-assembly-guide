"""The toolbar action: asks a few options, builds the guide in the background and opens it."""
import json
import os
import sys
import threading
import webbrowser
from pathlib import Path

import pcbnew
import wx

try:
    from . import pcb_assembly_guide as guide  # packaged plugin: the tool sits beside this file
except ImportError:  # running from a checkout of the repository
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cli"))
    import pcb_assembly_guide as guide

TITLE = "PCB Assembly Guide"
ORDERS = [
    ("smd-first", "Surface-mount on both sides, then through-hole"),
    ("top-first", "Whole top side, then the bottom"),
    ("bottom-first", "Whole bottom side, then the top"),
    ("smallest-first", "Smallest parts first"),
]
DEFAULTS = {"order": "smd-first", "use_3d": True, "fill": True, "open": True}


def kicad_cli_beside_kicad():
    """The kicad-cli that belongs to the running KiCad, as an argument list, or None to search for one."""
    name = "kicad-cli.exe" if os.name == "nt" else "kicad-cli"
    candidates = [Path(sys.executable).parent / name]
    for start in (Path(pcbnew.__file__).resolve(), Path(sys.executable).resolve()):
        for folder in start.parents:
            if folder.suffix == ".app":  # macOS: KiCad.app/Contents/MacOS/kicad-cli
                candidates.append(folder / "Contents" / "MacOS" / name)
            candidates.append(folder / "bin" / name)  # Windows and Linux: <prefix>/bin
    for path in candidates:
        if path.is_file() and os.access(str(path), os.X_OK):
            return [str(path)]
    return None


def settings_file():
    return guide.cache_directory() / "plugin-settings.json"


def load_settings():
    settings = dict(DEFAULTS)
    try:
        saved = json.loads(settings_file().read_text(encoding="utf-8"))
        settings.update({key: saved[key] for key in DEFAULTS if type(saved.get(key)) is type(DEFAULTS[key])})
    except (OSError, ValueError):
        pass
    if settings["order"] not in dict(ORDERS):
        settings["order"] = DEFAULTS["order"]
    return settings


def save_settings(settings):
    try:
        settings_file().parent.mkdir(parents=True, exist_ok=True)
        settings_file().write_text(json.dumps(settings), encoding="utf-8")
    except OSError:
        pass


def build_guide(board, output, settings, say=lambda text: None):
    """Writes the guide. Returns (number of parts, number of steps, warning or None)."""
    components, glb, filled, warning = guide.load_board(
        board, settings["fill"], settings["use_3d"], say, kicad_cli_beside_kicad())
    data = guide.guide_data(board.stem, components, glb, filled, settings["order"])
    guide.write_guide(data, glb, output)
    return len(components), len(data["steps"]), warning


class OptionsDialog(wx.Dialog):
    def __init__(self, parent, board, settings, unsaved):
        super().__init__(parent, title=TITLE, style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        outer = wx.BoxSizer(wx.VERTICAL)
        intro = wx.StaticText(self, label="Write a step-by-step assembly guide for %s as one web page.\n"
                                          "It opens in any browser, with nothing to install." % board.name)
        outer.Add(intro, 0, wx.ALL, 12)
        if unsaved:
            note = wx.StaticText(self, label="This board has unsaved changes. The guide is made from the last "
                                             "saved version.")
            note.SetForegroundColour(wx.Colour(190, 90, 0))
            outer.Add(note, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)

        grid = wx.FlexGridSizer(cols=2, vgap=8, hgap=8)
        grid.AddGrowableCol(1, 1)
        grid.Add(wx.StaticText(self, label="Soldering order:"), 0, wx.ALIGN_CENTER_VERTICAL)
        self.order = wx.Choice(self, choices=[label for _, label in ORDERS])
        self.order.SetSelection([key for key, _ in ORDERS].index(settings["order"]))
        grid.Add(self.order, 1, wx.EXPAND)
        grid.Add(wx.StaticText(self, label="Save as:"), 0, wx.ALIGN_CENTER_VERTICAL)
        self.output = wx.FilePickerCtrl(
            self, path=str(board.parent / (board.stem + "-assembly-guide.html")),
            message="Save the assembly guide", wildcard="Web page (*.html)|*.html",
            style=wx.FLP_SAVE | wx.FLP_USE_TEXTCTRL | wx.FLP_OVERWRITE_PROMPT)
        self.output.SetMinSize((460, -1))
        grid.Add(self.output, 1, wx.EXPAND)
        outer.Add(grid, 0, wx.EXPAND | wx.LEFT | wx.RIGHT, 12)

        self.use_3d = wx.CheckBox(self, label="Show the board in 3D, using KiCad's 3D models")
        self.fill = wx.CheckBox(self, label="Borrow library models for chip parts that have none")
        self.open = wx.CheckBox(self, label="Open the guide in the browser when it is ready")
        for box, key in ((self.use_3d, "use_3d"), (self.fill, "fill"), (self.open, "open")):
            box.SetValue(settings[key])
            outer.Add(box, 0, wx.LEFT | wx.RIGHT | wx.TOP, 12)
        self.use_3d.Bind(wx.EVT_CHECKBOX, lambda event: self.fill.Enable(self.use_3d.GetValue()))
        self.fill.Enable(settings["use_3d"])

        buttons = wx.StdDialogButtonSizer()
        create = wx.Button(self, wx.ID_OK, "Create Guide")
        create.SetDefault()
        buttons.AddButton(create)
        buttons.AddButton(wx.Button(self, wx.ID_CANCEL))
        buttons.Realize()
        outer.Add(buttons, 0, wx.EXPAND | wx.ALL, 12)
        self.SetSizerAndFit(outer)
        self.CentreOnParent()

    def settings(self):
        return {"order": ORDERS[self.order.GetSelection()][0], "use_3d": self.use_3d.GetValue(),
                "fill": self.fill.GetValue(), "open": self.open.GetValue()}

    def output_path(self):
        text = self.output.GetPath().strip()
        if not text:
            return None
        path = Path(text).expanduser()
        return path if path.suffix.lower() in (".html", ".htm") else path.with_name(path.name + ".html")


class AssemblyGuidePlugin(pcbnew.ActionPlugin):
    def defaults(self):
        self.name = "Assembly Guide"
        self.category = "Fabrication"
        self.description = "Write a step-by-step hand-assembly guide for this board as a single web page"
        self.show_toolbar_button = True
        here = Path(__file__).resolve().parent
        self.icon_file_name = str(here / "icon.png")
        self.dark_icon_file_name = str(here / "icon.png")

    def Run(self):
        parent = wx.GetActiveWindow() or (wx.GetTopLevelWindows() or [None])[0]
        pcb = pcbnew.GetBoard()
        name = pcb.GetFileName() if pcb else ""
        if not name or not os.path.isfile(name):
            wx.MessageBox("Save the board first. The guide is made from the saved .kicad_pcb file.",
                          TITLE, wx.OK | wx.ICON_INFORMATION, parent)
            return
        board = Path(name).resolve()
        try:
            unsaved = bool(pcb.IsModified())
        except Exception:
            unsaved = False

        dialog = OptionsDialog(parent, board, load_settings(), unsaved)
        try:
            if dialog.ShowModal() != wx.ID_OK:
                return
            settings, output = dialog.settings(), dialog.output_path()
        finally:
            dialog.Destroy()
        if output is None:
            wx.MessageBox("Choose where to save the guide.", TITLE, wx.OK | wx.ICON_INFORMATION, parent)
            return
        save_settings(settings)

        result = {}
        status = ["Reading the board..."]

        def work():
            try:
                result["done"] = build_guide(board, output, settings, lambda text: status.__setitem__(0, text))
            except Exception as error:  # shown to the user below
                result["error"] = str(error) or error.__class__.__name__

        worker = threading.Thread(target=work, daemon=True)
        progress = wx.ProgressDialog(TITLE, status[0] + " " * 40, parent=parent, style=wx.PD_APP_MODAL)
        worker.start()
        try:
            while worker.is_alive():
                progress.Pulse(status[0])
                wx.MilliSleep(60)
        finally:
            progress.Destroy()
        worker.join()

        if "error" in result:
            wx.MessageBox("The guide could not be created.\n\n" + result["error"], TITLE,
                          wx.OK | wx.ICON_ERROR, parent)
            return
        parts, steps, warning = result["done"]
        if settings["open"]:
            webbrowser.open(output.resolve().as_uri())
        if warning or not settings["open"]:
            message = "Saved a guide with %d parts in %d steps to:\n%s" % (parts, steps, output)
            if warning:
                message += "\n\n" + warning
            wx.MessageBox(message, TITLE, wx.OK | (wx.ICON_WARNING if warning else wx.ICON_INFORMATION), parent)

"""Checks the KiCad plugin package against the rules of KiCad's Plugin and Content Manager."""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "kicad-plugin"))
import package  # noqa: E402


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.metadata = json.loads((ROOT / "kicad-plugin" / "metadata.json").read_text(encoding="utf-8"))
        cls.files = dict(package.files())

    def test_every_packaged_file_exists(self):
        for name, source in self.files.items():
            self.assertTrue(source.is_file(), name)

    def test_layout_is_what_kicad_expects(self):
        self.assertIn("metadata.json", self.files)
        self.assertIn("plugins/__init__.py", self.files)
        self.assertIn("resources/icon.png", self.files)
        for name in self.files:
            self.assertTrue(name == "metadata.json" or name.startswith(("plugins/", "resources/")), name)
        # The tool looks for the page template in a "web" folder beside itself.
        self.assertIn("plugins/pcb_assembly_guide.py", self.files)
        self.assertIn("plugins/web/guide.html", self.files)

    def test_metadata_follows_the_rules(self):
        m = self.metadata
        self.assertEqual(m["type"], "plugin")
        self.assertLessEqual(len(m["description"]), 150)
        self.assertLessEqual(len(m["description_full"]), 1000)
        self.assertRegex(m["identifier"], r"^[a-zA-Z][-a-zA-Z0-9.]{0,48}[a-zA-Z0-9]$")
        for version in m["versions"]:
            self.assertRegex(version["version"], r"^\d{1,4}(\.\d{1,4}(\.\d{1,6})?)?$")
            # The copy inside the archive must not carry the download details.
            self.assertFalse([key for key in version if key.startswith("download_")])
        self.assertNotIn("@", json.dumps(m))  # no email addresses

    def test_plugin_sources_compile(self):
        for name in ("__init__.py", "assembly_guide_action.py", "package.py"):
            source = (ROOT / "kicad-plugin" / name).read_text(encoding="utf-8")
            compile(source, name, "exec")


if __name__ == "__main__":
    unittest.main()

"""Regression checks for the loader-to-core bootstrap contract."""

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent


class LoaderBootstrapTests(unittest.TestCase):
    def test_loader_executes_the_core_export_before_passing_dependencies(self):
        for relative in ("loader.lua", "tools/loader.template.lua"):
            source = (REPO_ROOT / relative).read_text(encoding="utf-8")
            self.assertIn("local exported = chunk()", source, relative)
            self.assertIn("type(exported) ~= 'function'", source, relative)
            self.assertIn("return exported", source, relative)
            self.assertIn(
                "local runOk, result = pcall(coreChunk, factory, Library, Common)",
                source,
                relative,
            )

    def test_loader_and_template_share_the_same_core_bootstrap(self):
        loader = (REPO_ROOT / "loader.lua").read_text(encoding="utf-8")
        template = (REPO_ROOT / "tools/loader.template.lua").read_text(
            encoding="utf-8"
        )

        def bootstrap(source):
            start = source.index("local function fetchChunk")
            end = source.index("local Library =", start)
            return source[start:end]

        self.assertEqual(bootstrap(loader), bootstrap(template))

    def test_loader_does_not_create_a_second_floating_toggle(self):
        for relative in ("loader.lua", "tools/loader.template.lua"):
            source = (REPO_ROOT / relative).read_text(encoding="utf-8")
            self.assertNotIn("local toggleGui = Instance.new", source, relative)
            self.assertNotIn("button.Text = 'IG'", source, relative)
            self.assertIn("remove that exact legacy GUI once", source, relative)


if __name__ == "__main__":
    unittest.main()

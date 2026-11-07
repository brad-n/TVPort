"""Every Apple TV game app answers switchtv-<title ID>://play, so the SwitchTV launcher (tvport/switchtv) can open it."""
import re
import unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]


class TvUrlSchemeTests(unittest.TestCase):
    def test_tv_project_declares_the_scheme(self):
        source = (IOS / "project_tv.yml").read_text()
        self.assertRegex(source, r"CFBundleURLTypes:[^\n]*\n\s+- CFBundleURLName: \$\{DM_BUNDLE_ID\}\n\s+CFBundleURLSchemes:\n\s+- \$\{DM_URL_SCHEME\}")

    def test_phone_project_has_no_scheme(self):
        self.assertNotIn("CFBundleURLTypes", (IOS / "project.yml").read_text())

    def test_build_script_derives_the_scheme_from_the_title_id(self):
        line = next(l for l in (IOS / "tools/build_ipa.sh").read_text().splitlines() if l.startswith("export DM_URL_SCHEME="))
        self.assertIn("switchtv-$(echo \"$GAME\" | tr A-Z a-z)", line)

    def test_host_ignores_the_link(self):
        self.assertRegex((IOS / "Sources/main.m").read_text(), r"scene:\(UIScene \*\)scene openURLContexts:[^\n]*\{\}")


if __name__ == "__main__":
    unittest.main()

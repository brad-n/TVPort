# The Mac host step (build_mac_host) takes dmhost's compile line from `make -n` but builds the static libraries that line links itself, beforehand.
# A library added to the Makefile's dmhost rule and not to HOST_LIBS fails every game that needs a Mac host build ("no such file or directory: gen/astc/libastcenc.a", 2026-11-07).
import importlib.util
from pathlib import Path
import shlex
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
assert spec and spec.loader
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)


class HostLibraries(unittest.TestCase):
    def test_every_library_dmhost_links_is_built_first(self):
        dry = subprocess.run(['make', '-n', '-B', 'GAME=010015100B514000', 'dmhost'], cwd=REPO / 'dm/host', capture_output=True, text=True)
        line = next((l for l in dry.stdout.splitlines() if ' -o dmhost ' in l), None)
        self.assertIsNotNone(line, dry.stderr[-500:])
        linked = {t for t in shlex.split(line) if t.startswith('gen/') and t.endswith('.a')}
        self.assertTrue(linked, 'no gen/*.a library in the dmhost compile line')
        self.assertLessEqual(linked, set(nsp.HOST_LIBS))


if __name__ == '__main__':
    unittest.main()

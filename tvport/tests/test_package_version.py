"""The packaged TVPort says which build it is: the version from project.yml and a build number that counts up with every commit."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('package_tvport', REPO / 'scripts/package_tvport.py')
package_tvport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_tvport)


class PackageVersion(unittest.TestCase):
    def test_build_number_counts_commits(self):
        with tempfile.TemporaryDirectory() as tmp:
            git = lambda *a: subprocess.run(['git', '-C', tmp, *a], check=True, capture_output=True)
            git('init', '-q'); git('config', 'user.email', 't@example.com'); git('config', 'user.name', 't')
            git('commit', '-q', '--allow-empty', '-m', 'one')
            self.assertEqual(package_tvport.build_number(Path(tmp)), '1')
            git('commit', '-q', '--allow-empty', '-m', 'two')
            self.assertEqual(package_tvport.build_number(Path(tmp)), '2')

    def test_stamp_sets_the_build_and_keeps_the_version(self):
        values = {'CFBundleShortVersionString': '1.3.0', 'CFBundleVersion': '44'}
        package_tvport.stamp_version(values, '3412')
        self.assertEqual(values, {'CFBundleShortVersionString': '1.3.0', 'CFBundleVersion': '3412'})

    def test_this_fork_is_past_the_upstream_release(self):
        # brad-n/TVPort carries texture once, compression and Switch 2 support on top of TVPort 1.2.3 (44)
        # project.yml is the source; tvport/app/Info.plist is generated from it (and ignored by git)
        self.assertNotIn('1.2.3', (REPO / 'tvport/app/project.yml').read_text())


    def test_every_tvport_module_the_backend_imports_is_packaged(self):
        # TVPort.app runs backend.py from Contents/Resources: a sibling module left out breaks it at that import (nintendo_store.py, 2026-11-08)
        import re
        here = {p.stem for p in (REPO / 'tvport').glob('*.py')}
        used = set()
        for name in ('backend.py', 'save_import.py'):
            used |= {m for m in re.findall(r'^\s*(?:import|from)\s+(\w+)', (REPO / 'tvport' / name).read_text(), re.M) if m in here}
        packaged = {Path(n).stem for n in package_tvport.TVPORT_FILES}
        self.assertFalse(used - packaged, f'modules backend.py needs but the package leaves out: {sorted(used - packaged)}')

    def test_the_switchtv_submodule_goes_into_the_engine_by_its_own_files(self):
        # git ls-files names a submodule as one entry, not a file: the packaging reads the submodule's own file list, and its tests and screenshots stay out
        files = package_tvport.engine_files()
        self.assertIn('tvport/switchtv/switchtv.py', files)
        self.assertIn('tvport/switchtv/project.yml', files)
        self.assertIn('tvport/switchtv/tools/tv_icon.swift', files)
        self.assertFalse([f for f in files if f.startswith(('tvport/switchtv/tests/', 'tvport/switchtv/docs/'))])

    def test_a_submodule_that_is_not_checked_out_stops_the_packaging_loudly(self):
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as empty:
            (Path(empty) / 'tvport/switchtv').mkdir(parents=True)
            with patch.object(package_tvport, 'REPO', Path(empty)), self.assertRaisesRegex(package_tvport.Stop, 'git submodule update --init'):
                package_tvport.submodule_files("tvport/switchtv")


if __name__ == '__main__':
    unittest.main()

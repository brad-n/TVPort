"""Attached packages outside the base folder are identified from metadata."""
from test_nsp_external_drive import ExternalDrive, APP, pfs0, nsp


def contents(extra, content):   # package_reader's contents: the base folder's game is a base game, the attached file has the content metas given
    return lambda paths: {p: content if p == extra else [('Application', APP, 0)] for p in paths}


class ExtraPackages(ExternalDrive):
    def test_external_update_and_dlc_use_metadata_versions(self):
        self.tmp = self.tmp.resolve()
        base_dir = self.tmp / 'base'; base_dir.mkdir()
        base = base_dir / f'Base [{APP:016X}].nsp'; pfs0(base, [])
        extra = self.tmp / 'Unrelated name [v0].nsp'; pfs0(extra, [])
        _, family = nsp.scan_nsps(base_dir, contents_of=contents(extra, [('Patch', APP + 0x800, 65536), ('AddOnContent', APP + 0x1001, 7)]), want=APP, extra_packages=[extra, extra])
        self.assertEqual(family['updates'], [(65536, extra)])
        self.assertEqual(family['dlc'], [(APP + 0x1001, 7, extra)])
        for content in ([], [('Application', APP, 0)], [('AddOnContent', APP + 0x3001, 0)]):
            with self.assertRaises(nsp.BuildError):
                nsp.scan_nsps(base_dir, contents_of=contents(extra, content), want=APP, extra_packages=[extra])
        extra.unlink()
        with self.assertRaises(nsp.BuildError):
            nsp.scan_nsps(base_dir, contents(extra, []), want=APP, extra_packages=[extra])

"""scripts/tv_prewarm.py (TVPort's Apple TV build): the prewarm list's pipelines made by this Mac's host as the prebuild tool, with no pair base, and compiled by metal-tt for the TV's GPU
as tvOS archives (other_gpu_prewarm's tvos form); only the TV's files and the stamp go into the app's pso folder, beside the pair archive; made again only when the inputs change; a failure
leaves the app without them"""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('tv_prewarm', REPO / 'scripts/tv_prewarm.py')
tv = importlib.util.module_from_spec(spec); spec.loader.exec_module(tv)
bn = tv.bn
CHAIN = '0123456789ab'


class TvPrewarm(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t)
        self.work, self.msl, self.gen, self.bundle = self.t / 'build', self.t / 'msl', self.t / 'Gen/dm', self.t / 'pso'
        lib = self.msl / f'b-{CHAIN}'; lib.mkdir(parents=True); (lib / 'k_b.metallib').write_bytes(b'LIB'); (lib / 'inputs.tsv').write_text('inputs\tA\n')
        self.gen.mkdir(parents=True); (self.gen / 'shader_map.tsv').write_text('package\tindex\tstage\tdm_ctl_sha16\tsource\n')
        (self.gen / 'pso_manifest.tsv').write_text('# list\nS\tk_b\t0\nR\tk\tf\t0\nC\tc\n')
        self.bundle.mkdir(); (self.bundle / 'applegpu_g14p.mtl4a').write_bytes(b'pairs')
        (self.bundle / 'applegpu_g14p-prewarm-07.mtl4a').write_bytes(b'old'); (self.bundle / 'applegpu_g14p-prewarm-07.keys').write_bytes(b'old')   # an earlier build's
        self.ran, self.tools, self.fail = [], [], {}

    def fake_run(self, cmd, log, env=None, cwd=None, on_line=None, fatal=True):
        cmd = [str(c) for c in cmd]; self.ran.append(cmd); self.assertFalse(fatal)
        if len(cmd) == 1:   # this Mac's host as the prebuild tool, bundle form
            self.tools.append(env)
            if self.fail.get('tool'): return 1
            o = Path(env['DM_PSO_PREBUILD_OUT']); o.mkdir(parents=True, exist_ok=True)
            for i in range(2):
                (o / f'applegpu_g14s-prewarm-{i:02d}.mtl4a').write_bytes(b'mac%d' % i); (o / f'applegpu_g14s-prewarm-{i:02d}.keys').write_bytes(b'DMPSOIX1')
                (o / f'prewarm-{i:02d}.mtl4-json').write_text(json.dumps({'libraries': [], 'function_descriptors': {}}))
            (o / 'prewarm.tsv').write_text('chain\tx\n'); return 0
        if cmd[3] == 'metal-tt':
            if self.fail.get('metal_tt'): return 1
            Path(cmd[-1]).write_bytes(b'tv ' + cmd[5].encode()); return 0
        raise AssertionError(cmd)

    def main(self, gpu='g14p'):
        said, host = [], self.t / 'dmhost'
        if not host.exists(): host.write_bytes(b'host')
        g = types.SimpleNamespace(id='0100000000001000', get={'depth_mode': 'zero'}.get)
        real = subprocess.run
        def sdk(cmd, *a, **k):
            if '--show-sdk-version' in cmd: return subprocess.CompletedProcess(cmd, 0, '27.2\n', '')   # pso_offline.os_min_default('tvos'): the SDK's major version
            if cmd[:2] == ['sysctl', '-n']: return subprocess.CompletedProcess(cmd, 0, '25C56\n', '')
            return real(cmd, *a, **k)
        with mock.patch.object(bn, 'run', self.fake_run), mock.patch.object(bn, 'say', said.append), mock.patch.object(bn, 'chain_of', lambda repo: CHAIN), \
             mock.patch.object(bn, 'mac_gpu_arch', lambda *a: 'applegpu_g14s'), mock.patch.object(bn, 'build_mac_host', lambda *a: host), \
             mock.patch.object(tv.gamemod, 'load', lambda gid: g), mock.patch.object(subprocess, 'run', sdk):
            self.assertEqual(tv.main(['--game', g.id, '--work', str(self.work), '--msl', str(self.msl), '--manifest', str(self.gen / 'pso_manifest.tsv'),
                                      '--shader-map', str(self.gen / 'shader_map.tsv'), '--bundle', str(self.bundle), '--gpu', gpu]), 0)
        return said

    def test_the_tool_makes_the_lists_pipelines_and_metal_tt_builds_them_for_the_tv(self):
        said = self.main()
        env = self.tools[0]
        self.assertEqual({k: env.get(k) for k in ('DM_PSO_PREBUILD', 'DM_PSO_PREBUILD_PAIRS', 'DM_PSO_BUNDLE', 'DM_PSO_MANIFEST', 'DM_MSL_DIR', 'DM_NVN_SHMAP', 'DM_PSO_PREBUILD_DEPTH')},
                         {'DM_PSO_PREBUILD': 'tool', 'DM_PSO_PREBUILD_PAIRS': '0', 'DM_PSO_BUNDLE': 'off', 'DM_PSO_MANIFEST': str(self.gen / 'pso_manifest.tsv'),
                          'DM_MSL_DIR': str(self.msl), 'DM_NVN_SHMAP': str(self.gen / 'shader_map.tsv'), 'DM_PSO_PREBUILD_DEPTH': 'zero'})
        tt = [c for c in self.ran if len(c) > 3 and c[3] == 'metal-tt']
        self.assertEqual([c[:8] for c in tt], [['xcrun', '-sdk', 'appletvos', 'metal-tt', '-arch', 'applegpu_g14p', '-tvos-version-min', '27.0']] * 2)
        self.assertEqual(sorted(f.name for f in self.bundle.iterdir()),
                         ['applegpu_g14p-prewarm-00.keys', 'applegpu_g14p-prewarm-00.mtl4a', 'applegpu_g14p-prewarm-01.keys', 'applegpu_g14p-prewarm-01.mtl4a', 'applegpu_g14p.mtl4a', 'prewarm.tsv'])
        self.assertEqual((self.bundle / 'applegpu_g14p.mtl4a').read_bytes(), b'pairs')   # the pair archive build_ipa.sh made is left as it is
        self.assertEqual((self.bundle / 'applegpu_g14p-prewarm-01.mtl4a').read_bytes(), b'tv applegpu_g14p')
        self.assertEqual((self.bundle / 'applegpu_g14p-prewarm-01.keys').read_bytes(), b'DMPSOIX1')   # this Mac's index of the same period
        self.assertTrue(any('prewarm pipelines in the app: 2 files' in s for s in said))

    def test_made_again_only_when_the_inputs_change(self):
        self.main(); self.main()
        self.assertEqual(len(self.tools), 1)
        self.assertTrue((self.bundle / 'applegpu_g14p-prewarm-00.mtl4a').is_file())   # linked again from the work folder
        (self.gen / 'pso_manifest.tsv').write_text('R\tk\tf\t1\n')   # the Apple TV recorded more
        self.main()
        self.assertEqual(len(self.tools), 2)

    def test_nothing_without_an_archive_for_the_tv(self):
        self.main(gpu='none')
        (self.bundle / 'applegpu_g14p.mtl4a').unlink(); said = self.main()
        self.assertEqual(self.ran, []); self.assertIn('none (no pipeline archive', said[-1])

    def test_a_failed_tool_leaves_the_app_without_them(self):
        self.fail['tool'] = True
        said = self.main()
        self.assertFalse(list(self.bundle.glob('*-prewarm-*'))); self.assertFalse((self.bundle / 'prewarm.tsv').exists())
        self.assertTrue(any(s.startswith('[RED] prewarm pipelines: the host') for s in said))

    def test_a_failed_metal_tt_is_tried_again_at_the_next_build(self):
        self.fail['metal_tt'] = True
        said = self.main()
        self.assertFalse(list(self.bundle.glob('*-prewarm-*.mtl4a'))); self.assertTrue(any('[RED]' in s for s in said))
        self.fail.clear(); self.main()
        self.assertEqual(len(self.tools), 1)   # this Mac's files were kept; only metal-tt runs again
        self.assertEqual(len(list(self.bundle.glob('applegpu_g14p-prewarm-*.mtl4a'))), 2)


if __name__ == '__main__':
    unittest.main()

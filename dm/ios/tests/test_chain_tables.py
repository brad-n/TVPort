"""build_ipa.sh's check of the profile tables a full shader build makes (check_chain_tables): c1_full.tsv must name the libraries' chain and inputs, a cb_extent.tsv that is there
must too, and an Apple TV build (DM_TVOS=1) needs both. The host ignores a table that names other libraries: without c1_full.tsv every shader's c1 takes 64 KiB (468 MB in Ocarina of
Time's first house on a partial library), which an Apple TV, ending the app near 2 GB, cannot afford. Runs the script's own function against fixture tables, without Xcode or game files."""
import os, re, subprocess, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
V, IN = 'b0c0ffee1234', '4bd48f723876'


def functions():
    out = []
    for name in ('chain_table_ok', 'check_chain_tables'):
        m = re.search(r'^' + name + r'\(\) \{.*?^\}$' if name == 'check_chain_tables' else r'^' + name + r'\(\) \{.*?\}$', SCRIPT, re.M | re.S)
        assert m, f'{name} not found in build_ipa.sh'
        out.append(m.group(0))
    return '\n'.join(out)


class ChainTableTests(unittest.TestCase):
    def run_check(self, tables, tvos):
        with tempfile.TemporaryDirectory() as t:
            gd = Path(t)
            for name, head in tables.items():
                if head is not None: (gd / name).write_text(head + '\nrow\n')
            env = dict(os.environ, GD=str(gd), V=V, IN=IN, DM_TVOS='1' if tvos else '0')
            r = subprocess.run(['/bin/bash', '-c', 'set -u\ndie() { echo "$*" >&2; exit 1; }\n' + functions() + '\ncheck_chain_tables\necho passed'],
                               env=env, capture_output=True, text=True)
            return r.returncode == 0 and 'passed' in r.stdout, r.stderr

    def test_tables(self):
        good, other = f'# chain b-{V} inputs {IN} 2026-11-09T00:53:29-05:00', f'# chain b-{V} inputs 000000000000 2026-11-01T00:00:00-05:00'
        old_chain = f'# chain b-f702a67c2abe inputs {IN} 2026-11-01T00:00:00-05:00'
        cases = [   # (c1_full.tsv, cb_extent.tsv, Apple TV, passes)
            (good, good, True, True), (good, good, False, True),
            (None, good, True, False), (None, good, False, False),            # c1_full.tsv missing: every c1 its own 64 KiB
            (other, good, True, False), (old_chain, good, False, False),     # c1_full.tsv of other inputs or another chain version
            (good, other, True, False), (good, other, False, False),         # a stale cb_extent.tsv stops any build
            (good, None, True, False), (good, None, False, True),            # a missing one stops an Apple TV build only
            (good, '', True, False),                                          # an empty file names nothing
        ]
        for c1, cb, tvos, passes in cases:
            with self.subTest(c1=c1 and c1.split()[2:5], cb=cb and cb.split()[2:5], tvos=tvos):
                ok, err = self.run_check({'c1_full.tsv': c1, 'cb_extent.tsv': cb}, tvos)
                self.assertEqual(ok, passes, err)
                if not passes: self.assertRegex(err, r'(c1_full|cb_extent)\.tsv is missing or not made from these libraries')

    def test_the_program_check_runs_it(self):
        check = SCRIPT[SCRIPT.index('check_program() {'):]
        check = check[:check.index('\n}\n')]
        self.assertIn('check_chain_tables; fi', check)


if __name__ == '__main__':
    unittest.main()

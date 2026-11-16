"""Settings presets (dm/games/presets.tsv through dm/games/settings.py): the table's format, every value a value its setting takes, every device class covered, each value's
source a real document, and the presets written into launcher.json for a device class. How a front end tells a preset from Custom is run natively (dm/ios/tests/launcher_storage_check.swift)."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('launcher_settings_presets', ROOT / 'dm/games/settings.py')
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)
from test_launcher_settings import conforms

OCARINA, STAR_FOX, MARIO_KART = '0400486024DEC000', '0400E88025B1A000', '0100152000022000'
OOT_KEYS = ('FOLIAGE', 'GROUND_MIST', 'MODEL_LOD', 'REFLECTION_INTERVAL', 'SHADOW_CASCADES')
TABLE = settings.preset_rows


def table():
    return [{'line': n, 'device': d, 'preset': p, 'game': g, 'var': v, 'value': val} for n, d, p, g, v, val in TABLE()]


def tsv_rows():
    return {c[0]: c for _, c in settings.rows()}


def build(gid, device, fixups=(), extra=None):
    """The game's launcher list for a device class, with the rewriter keys named (key value) in its fixups table"""
    env = {'GFXAPI': 'nvn', 'SETTINGS_DEVICE': device, 'SETTINGS_PLATFORM': 'mac' if device == 'mac' else 'ios', **(extra or {})}
    with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, env):
        (Path(tmp) / 'main.fixups.tsv').write_text(''.join(f'# {k}\t{v}\n' for k, v in fixups))
        return settings.build(gid, tmp, Path(tmp) / 'control.nacp')


def oot(device):
    return build(OCARINA, device, [(k, '1') for k in OOT_KEYS])


def by_name(listed):
    return {p['name']: p['values'] for p in listed.get('presets', [])}


class PresetDataTests(unittest.TestCase):
    def test_every_device_class_has_presets_and_every_row_belongs_to_one(self):
        rows = table()
        self.assertTrue(rows)
        for device in settings.DEVICES:
            with self.subTest(device=device):
                self.assertIn('Performance', {r['preset'] for r in rows if r['device'] == device})
        self.assertEqual({r['device'] for r in rows}, set(settings.DEVICES))
        for device in ('tv', 'mac'):
            self.assertIn('Quality', {r['preset'] for r in rows if r['device'] == device})

    def test_a_value_is_named_once_per_preset_device_and_game(self):
        keys = [(r['device'], r['preset'], r['game'], r['var']) for r in table()]
        self.assertEqual(len(keys), len(set(keys)))

    def test_every_value_is_a_value_of_its_setting(self):
        """A value for every game ('*') is held to settings.tsv's own domain; one for a single game to that game's row (a render scale raised by its stub)"""
        listed = tsv_rows()
        for r in table():
            with self.subTest(line=r['line'], var=r['var'], value=r['value']):
                self.assertIn(r['var'], listed, 'a setting of settings.tsv')
                _, kind, values = listed[r['var']][:3]
                if r['game'] != '*':
                    row = {s['env']: s for s in build(r['game'], r['device'], [('RENDER_SCALE', '2')] + [(k, '1') for k in OOT_KEYS],
                                                      {'SETTINGS_MSL': ''})['settings']}.get(r['var'])
                    if row is not None: self.assertTrue(settings.accepts(row, r['value']), f'{r["var"]}={r["value"]} in {r["game"]}')
                    self.assertTrue(len(r['game']) == 16 and (ROOT / 'dm/games' / r['game']).is_dir(), 'a game of dm/games')
                elif kind == 'choice':
                    self.assertIn(r['value'], {v.split('?', 1)[0].split('=', 1)[0] for v in values.split(',')})
                elif kind == 'toggle':
                    self.assertIn(r['value'], {'1', '0'} if values == '-' else set(values.split('/')))
                else:
                    lo, hi, _ = (float(x) for x in values.split(':'))
                    self.assertTrue(lo <= float(r['value']) <= hi)

    def test_presets_name_only_the_games_own_settings_not_diagnostic_switches(self):
        """The allowlist: a preset can only set a row of settings.tsv, which holds no diagnostic switch"""
        self.assertTrue({r['var'] for r in table()} <= set(tsv_rows()))

    def test_every_value_cites_a_document_that_exists(self):
        for line in (ROOT / 'dm/games/presets.tsv').read_text(encoding='utf-8').splitlines():
            if not line.strip() or line.startswith('#'): continue
            source = line.split('\t')[5]
            with self.subTest(source=source[:60]):
                self.assertTrue((ROOT / source.split(' ', 1)[0]).is_file(), 'the source starts with the path of the document that has the measurement')
                self.assertGreater(len(source.split(' ', 1)[1]), 20)

    def test_a_bad_table_is_refused(self):
        for bad, why in [('tv\tFast\t*\tDM_ANISO\t16\tx', 'unknown preset'), ('car\tQuality\t*\tDM_ANISO\t16\tx', 'unknown device'), ('tv\tQuality\t*\tDM_ANISO\t16', '6 columns')]:
            with self.subTest(why=why), tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / 'presets.tsv').write_text(bad + '\n')
                with patch.object(settings, 'HERE', Path(tmp)), self.assertRaises(SystemExit) as e: list(settings.preset_rows())
                self.assertIn(why, str(e.exception))

    def test_a_value_its_row_does_not_take_fails_the_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'presets.tsv').write_text('tv\tQuality\t*\tDM_ANISO\t32\tdm/games/settings.tsv a value no row offers\n')
            with patch.object(settings, 'HERE', Path(tmp)), self.assertRaises(SystemExit) as e: settings.presets('tv', OCARINA, [{'env': 'DM_ANISO', 'kind': 'choice', 'default': '0', 'options': [['0', 'Auto']]}])
            self.assertIn('DM_ANISO=32', str(e.exception))


class WrittenPresetTests(unittest.TestCase):
    def test_tv_presets_for_ocarina(self):
        p = by_name(oot('tv'))
        self.assertEqual(list(p), ['Performance', 'Balanced', 'Quality'])
        self.assertEqual(p['Performance'], {'DM_FOLIAGE': 'off', 'DM_GROUND_MIST': 'off', 'DM_REFLECTION_INTERVAL': '8', 'DM_MODEL_LOD': '4', 'DM_SHADOW_CASCADES': '1'})
        self.assertEqual(p['Quality']['DM_ANISO'], '16')
        rows = {s['env']: s for s in oot('tv')['settings']}
        self.assertTrue(all(settings.same(rows[k], v, rows[k]['default']) for k, v in p['Quality'].items() if k != 'DM_ANISO'), 'everything else on (its default)')
        self.assertNotIn('DM_RES_SCALE', p['Quality'], 'no resolution scale above 100% on the TV')

    def test_every_preset_value_is_a_value_the_games_row_takes(self):
        for device in settings.DEVICES:
            listed = oot(device)
            rows = {s['env']: s for s in listed['settings']}
            for name, values in by_name(listed).items():
                for var, value in values.items():
                    with self.subTest(device=device, preset=name, var=var):
                        self.assertTrue(settings.accepts(rows[var], value))
            self.assertEqual(conforms(listed, json.loads((ROOT / 'docs/launcher.schema.json').read_text()), json.loads((ROOT / 'docs/launcher.schema.json').read_text())), [])

    def test_a_preset_names_only_what_is_measured(self):
        """Performance does not name the anisotropic filtering, Quality none of the effects: each of those keeps its default"""
        p = by_name(oot('tv'))
        self.assertNotIn('DM_ANISO', p['Performance'])
        self.assertEqual(set(p['Quality']), {'DM_ANISO'})

    def test_the_default_is_balanced_only_where_balanced_names_nothing(self):
        for device in ('phone', 'mac'):   # nothing measured for a Balanced here: Balanced is the defaults
            listed = oot(device)
            rows = {s['env']: s for s in listed['settings']}
            self.assertTrue(all(settings.same(rows[k], v, rows[k]['default']) for k, v in by_name(listed)['Balanced'].items()), device)
        listed = oot('tv')   # on the TV Balanced is the recommended mist-off set, so the defaults are not a preset: a front end shows Default
        rows = {s['env']: s for s in listed['settings']}
        self.assertFalse(all(settings.same(rows[k], v, rows[k]['default']) for k, v in by_name(listed)['Balanced'].items()))

    def test_phone_without_a_measured_quality_has_none(self):
        self.assertNotIn('Quality', by_name(oot('phone')))

    def test_mac_quality_raises_scales_only_where_measured(self):
        self.assertEqual(by_name(build(STAR_FOX, 'mac', [('RENDER_SCALE', '2')])).get('Quality', {}).get('DM_RENDER_SCALE'), '2.0')
        self.assertNotIn('DM_RENDER_SCALE', by_name(oot('mac')).get('Quality', {}))
        self.assertNotIn('DM_RES_SCALE', by_name(oot('mac')).get('Quality', {}), 'Ocarina of Time at 1.5x has an open picture bug')
        mk = by_name(build(MARIO_KART, 'mac', extra={'SETTINGS_MSL': ''})).get('Quality', {})
        self.assertTrue(mk.get('DM_ANISO') == '16' and mk.get('DM_RES_SCALE') in ('1.5', None))

    def test_the_defaults_are_untouched(self):
        """Presets are extra: the settings list and its defaults are what they were without the table"""
        with_presets = oot('tv')
        with patch.object(settings, 'presets', return_value=[]):
            without = oot('tv')
        self.assertEqual(with_presets['settings'], without['settings'])
        self.assertNotIn('presets', without)

    def test_a_game_with_no_setting_a_preset_names_has_none(self):
        self.assertEqual(settings.presets('tv', OCARINA, []), [])


if __name__ == '__main__':
    unittest.main()

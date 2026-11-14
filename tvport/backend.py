#!/usr/bin/env python3
"""TVPort backend: builds a Switch game you own into an Apple TV app, installs it, and reads back how it ran.

The Mac app drives this; it also runs on its own. Commands print JSON: `devices`, `inspect` and `diagnose` one object, `build`
a stream of one object per line, {"event": "stage" | "log" | "progress" | "error" | "done", ...}.

The game goes through nxnative as usual (scripts/build_ipa_from_nsp.py makes <title ID>_build: rewritten modules and shaders), then
build_ipa.sh with DM_TVOS=1 makes a separate tvOS project beside them. A build folder from an earlier run is reused, so only the first build of a game takes long.

In a checkout this file runs the engine around it. In TVPort.app (scripts/package_tvport.py) the engine comes as an archive beside this file, with engine.json, and `setup`
unpacks it into TVPort's own folder and makes the Python it needs there.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, Optional

HERE = Path(__file__).resolve().parent
BUNDLED = (HERE / 'engine.json').is_file()
REPO = HERE.parent   # the engine: this checkout, or for the app the copy it unpacked (main)
TITLE_RE = re.compile(r'^([0-9A-Fa-f]{16})_build$')
SOURCE_SUFFIXES = {'.nsp', '.xci', '.nsz', '.xcz', '.nup'}   # .nup: a Switch 2 game in one NUP container (scripts/pack_nup.py), which needs no prod.keys
ENGINE_PACKAGES = ('fontTools', 'capstone', 'lz4')
SUPPORT = Path.home() / 'Library/Application Support'
DATA = Path(os.environ.get('TVPORT_DATA') or SUPPORT / 'TVPort')   # the app's library, the build lock, and the app's engine and Python; TVPORT_DATA moves it, for a test run
PYTHON_VERSION = '3.14'
REQUIREMENTS = HERE / 'requirements.txt'
TOOL_PATHS = ['/opt/homebrew/bin', '/usr/local/bin']   # where the NSP script looks too (no .NET folders since upstream 641636e2)
TEXTURE_CAPS = (0, 1024, 512, 256)
UPSCALER_ENV = {'game': None, 'metalfx': 'metalfx', 'off': 'bilinear'}   # --upscaler to DM_UPSCALER; the game's own leaves it unset


def res_scale_arg(text: str) -> float:
    """0.5 to 2.0, the range the engine-wide resolution scale accepts (DM_RES_SCALE)"""
    value = float(text)
    if not 0.5 <= value <= 2.0:
        raise argparse.ArgumentTypeError('the resolution scale is 0.5 to 2.0')
    return value


def render_scale_arg(text: str) -> float:
    """0.5 to 1.0, the range the loader accepts (DM_RENDER_SCALE)"""
    value = float(text)
    if not 0.5 <= value <= 1.0:
        raise argparse.ArgumentTypeError('the render scale is 0.5 to 1.0')
    return value
CACHES = 'Library/Caches'
SHADER_LIST = 'tvport-shaders.tsv'
SAVE_BACKUPS = 'save-backups'
KEEP_BACKUPS = 20   # the newest backups, whatever their age,
KEEP_DAYS = 30      # and the newest of each day for this many days: a backup every few minutes would otherwise reach back barely an hour
BACKUP_NAME = re.compile(r'^\d{4}-\d{2}-\d{2}')   # a backup folder: the local time it was made, so names sort by age
MANIFEST = 'tvport-manifest.json'   # the TV's listing a backup was copied from
ICLOUD = Path.home() / 'Library/Mobile Documents/com~apple~CloudDocs'
ICLOUD_SAVES = 'TVPort Saves'
TV_TIMEOUT_S = 60
LAUNCH_SETTLE_S = 3
SAVE_FILE = re.compile(r'^save(\.p-[a-z0-9-]+)?(_device)?/.')   # each player's committed save; save.work, save.new and the like are working copies


REASON = re.compile(r' error: |\[RED\]|FAIL: ')   # lines that say why a tool stopped; xcodebuild's own last lines only say that it did


class Failure(Exception):
    """A problem the person can act on; its text is shown as it is."""


def emit(event: str, **fields) -> None:
    print(json.dumps({'event': event, **fields}), flush=True)


def stage(name: str) -> None:
    emit('stage', name=name)


def run(argv: Iterable, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run([str(a) for a in argv], text=True, capture_output=True, **kwargs)


def stream(argv: Iterable, *, env=None, cwd=None, on_line=None, log_filter=None) -> None:
    """Run a command, passing its output on as log events; stop with its last lines when it fails."""
    process = subprocess.Popen([str(a) for a in argv], env=env, cwd=cwd, text=True, errors='replace', stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    tail: list = []
    reasons: list = []
    for raw in process.stdout:
        line = raw.rstrip('\n')
        tail = (tail + [line])[-25:]
        if REASON.search(line):
            reasons = (reasons + [line.strip()])[-12:]
        if on_line:
            on_line(line)
        if log_filter is None or log_filter(line):
            emit('log', line=line[:400])
    if process.wait():
        raise Failure('\n'.join(reasons or tail[-6:])[-1500:])


def python_stamp() -> str:
    """What TVPort's own environment was made from: a new release that changes it makes it again."""
    return f'python {PYTHON_VERSION}\n' + REQUIREMENTS.read_text()


def venv_ready() -> bool:
    stamp = DATA / 'venv/tvport-requirements.txt'
    return (DATA / 'venv/bin/python3').exists() and stamp.is_file() and stamp.read_text() == python_stamp()


def borrowed_python() -> Optional[str]:
    """An interpreter with the engine's packages, 3.12 or newer (the NSP script's minimum): TVPort's own environment, then the one NX Play installed, then Homebrew's or the system's."""
    candidates = ([DATA / 'venv/bin/python3'] if venv_ready() else []) + [SUPPORT / 'NX Play/venv/bin/python3', Path('/opt/homebrew/bin/python3'), Path(shutil.which('python3') or 'python3')]
    probe = 'import sys; assert sys.version_info >= (3, 12); ' + '; '.join(f'import {p}' for p in ENGINE_PACKAGES)
    for python in candidates:
        if python.exists() and run([python, '-c', probe]).returncode == 0:
            return str(python)
    return None


def engine_python() -> str:
    python = borrowed_python()
    if python:
        return python
    if uv_tool():
        return set_up_python()
    raise Failure(f'No Python {PYTHON_VERSION} with the engine\'s packages, and no uv to make one. In Terminal: brew install uv, then press Set Up in TVPort.')


def uv_tool() -> Optional[str]:
    """uv makes TVPort's Python: the app carries one (Contents/Helpers), a checkout takes Homebrew's."""
    carried = HERE.parent / 'Helpers/uv'
    return str(carried) if carried.is_file() else shutil.which('uv', path=os.pathsep.join(TOOL_PATHS + [os.environ.get('PATH', '')]))


def set_up_python() -> str:
    """TVPort's own Python and the engine's packages at the versions requirements.txt names, all inside TVPort's folder: uv puts nothing in ~/.local or a cache outside it.
    The download needs the internet, once per release that changes them."""
    uv, venv = uv_tool(), DATA / 'venv'
    if not uv:
        raise Failure('uv is missing, so TVPort cannot make its Python. In Terminal: brew install uv')
    DATA.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, UV_PYTHON_INSTALL_DIR=str(DATA / 'python'), UV_NO_CONFIG='1', UV_NO_CACHE='1', UV_NO_PROJECT='1', UV_PYTHON_PREFERENCE='only-managed')
    env.pop('VIRTUAL_ENV', None)
    try:
        stage(f'Downloading Python {PYTHON_VERSION} for the engine')
        stream([uv, 'python', 'install', PYTHON_VERSION, '--no-bin'], env=env, cwd=DATA)
        stage('Installing the engine\'s Python packages')
        stream([uv, 'venv', '--clear', '--python', PYTHON_VERSION, venv], env=env, cwd=DATA)
        stream([uv, 'pip', 'install', '--python', venv / 'bin/python3', '-r', REQUIREMENTS], env=env, cwd=DATA)
    except Failure as failure:
        raise Failure(f'TVPort could not set up its Python. It needs the internet the first time.\n{failure}') from failure
    (venv / 'tvport-requirements.txt').write_text(python_stamp())
    return str(venv / 'bin/python3')


def unpack_engine(bundle: Path, data: Path) -> Path:
    """The engine the app carries, unpacked once per release into TVPort's folder: its tools write beside themselves (a profile's shader tables, the extractor's build files), which a
    signed app must not do to itself. Another command of the app may be unpacking it at the same moment, so the second waits for the first."""
    engine_id = json.loads((bundle / 'engine.json').read_text())['id']
    root = data / 'engine'
    target = root / engine_id
    if target.is_dir():
        return target
    root.mkdir(parents=True, exist_ok=True)
    with (root / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.is_dir():
            return target
        partial = root / f'.{engine_id}.partial'
        shutil.rmtree(partial, ignore_errors=True)
        partial.mkdir()
        result = run(['/usr/bin/tar', '-xf', bundle / 'engine.tar.xz', '-C', partial])
        if result.returncode:
            shutil.rmtree(partial, ignore_errors=True)
            raise Failure(f'The engine TVPort carries could not be unpacked into {root}: {result.stderr.strip()[-500:]}')
        shutil.copy2(bundle / 'engine.json', partial / 'engine.json')
        partial.rename(target)
    return target


def prune_engines(keep: Path) -> None:
    """Earlier releases' engines. Called while holding the build lock, so no build is using one."""
    for old in keep.parent.iterdir():
        if old.is_dir() and old != keep:
            shutil.rmtree(old, ignore_errors=True)


def chain() -> str:
    match = re.search(r'#define DMSH_CHAIN "(.*)"', (REPO / 'dm/gfx/nvn/dmsh_chain.h').read_text())
    if not match:
        raise Failure('The engine has no shader chain version (dm/gfx/nvn/dmsh_chain.h)')
    return match.group(1)


def nacp_text(path: Path, flag: Optional[str] = None) -> str:
    result = run([sys.executable, '-I', REPO / 'dm/tools/nacp.py'] + ([flag] if flag else []) + [path])
    return result.stdout.strip() if result.returncode == 0 else ''


class Game:
    """One game folder and what earlier builds left in it."""

    def __init__(self, folder: Path):
        self.folder = folder.expanduser().resolve()
        if not self.folder.is_dir():
            raise Failure(f'No such folder: {self.folder}')
        self.title_id = ''
        self.build = None
        saved = {}
        try:
            library = json.loads((DATA / 'library.json').read_text())
            saved = next((item for item in library if isinstance(item, dict) and Path(item.get('folder', '')).expanduser().resolve() == self.folder), {})
        except (OSError, ValueError, TypeError):
            pass
        self.addons = saved.get('addons') or []
        chosen = saved.get('buildFolder') or os.environ.get('TVPORT_DEFAULT_BUILD_FOLDER')
        if saved.get('buildNextToOriginal') is not None:
            chosen = None if saved['buildNextToOriginal'] else os.environ.get('TVPORT_DEFAULT_BUILD_FOLDER')
        self.storage_root = Path(chosen).expanduser().resolve() if chosen else self.folder
        # A stable per-source subfolder keeps two editions or source folders from sharing caches.
        leaf = re.sub(r'[^\w .()-]', '_', self.folder.name)[:80] + '-' + hashlib.sha256(str(self.folder).encode()).hexdigest()[:8]
        self.build_parent = self.storage_root / leaf if chosen else self.folder
        builds = sorted(p for p in self.build_parent.iterdir() if p.is_dir() and TITLE_RE.match(p.name)) if self.build_parent.is_dir() else []
        previous = Path(saved['lastBuildPath']) if saved.get('lastBuildPath') else None
        if not builds and previous and previous.is_dir() and TITLE_RE.fullmatch(previous.name):
            builds = [previous]
        if not builds and self.build_parent != self.folder:
            builds = sorted(p for p in self.folder.iterdir() if p.is_dir() and TITLE_RE.match(p.name))
        if builds:
            self.build = builds[0]
            self.title_id = TITLE_RE.match(self.build.name).group(1)

    @property
    def artwork_title_id(self) -> str:
        if self.title_id:
            return self.title_id.upper()
        # Filename lookup is only a hint for artwork, never an identity used for building.
        ids = {match.upper() for name in self.sources for match in re.findall(r'(?<![0-9A-Fa-f])([0-9A-Fa-f]{16})(?![0-9A-Fa-f])', name)
               if match.upper().startswith(('0100', '0400')) and match.endswith('000')}   # 0100…: Switch 1, 0400…: Switch 2
        return next(iter(ids)) if len(ids) == 1 else ''

    @property
    def sources(self) -> list:
        return sorted(p.name for p in self.folder.iterdir() if p.suffix.lower() in SOURCE_SUFFIXES)

    @property
    def keyless(self) -> bool:
        """Whether the game is only NUP containers: they carry their files unencrypted, so no prod.keys is needed (a Switch 2 game; the NSP script takes no -k for it)"""
        names = self.sources
        return bool(names) and all(name.lower().endswith('.nup') for name in names)

    def nup_info(self) -> dict:
        """What the folder's NUP says about the game, read from the container itself (title ID from its code's NPDM, newest update version, name from its control data), else from the
        `[title ID][v<version>]` of its file name. {} when the folder holds no NUP. Never raises: a damaged or unreadable NUP reports `error` and the file name's hints."""
        names = [name for name in self.sources if name.lower().endswith('.nup')]
        if not names:
            return {}
        path = self.folder / names[0]
        hint_id = re.search(r'\[([0-9A-Fa-f]{16})\]', path.name)
        hint_version = re.search(r'\[v(\d+)\]', path.name)
        info = {'file': path.name, 'title_id': hint_id.group(1).upper() if hint_id else '', 'version': int(hint_version.group(1)) if hint_version else None, 'name': '', 'icon': None, 'from_container': False}
        if len(names) > 1:
            info['error'] = f'More than one NUP in this folder ({", ".join(names)}): keep one game per folder.'
        try:
            sys.path.insert(0, str(REPO / 'scripts'))
            import pack_nup
            container = pack_nup.Nup(path)
            try:
                app, base, updates, dlc = pack_nup.scan(container)
                info.update(title_id=f'{app:016X}', from_container=True, updates=sorted(updates), dlc=len(dlc))
                if updates and info['version'] is None:
                    info['version'] = max(updates)
                meta = pack_nup.app_package(container).meta()
                nacp = meta.get(pack_nup.T_NACP)
                if nacp:
                    with tempfile.TemporaryDirectory() as folder:
                        (Path(folder) / 'control.nacp').write_bytes(nacp)
                        info['name'] = nacp_text(Path(folder) / 'control.nacp')
                info['icon'] = bool(meta.get(pack_nup.T_ICON) or meta.get(pack_nup.T_LICONS))
            finally:
                container.close()
        except Exception as error:   # a NUP that cannot be read still builds or fails in the engine with its own message; here it only costs the details
            info.setdefault('error', f'Could not read the NUP: {error}')
        return info

    @property
    def package(self) -> Optional[str]:
        content = self.prepared_content()
        selected = content.get('package')
        if selected and re.fullmatch(r'v\d+', selected) and (self.build / f'patched_{selected}').is_dir():
            return selected
        patched = sorted(self.build.glob('patched_*')) if self.build else []
        patched = [p for p in patched if p.is_dir()]
        return max(patched, key=lambda p: int(p.name.removeprefix('patched_v')) if p.name.removeprefix('patched_v').isdigit() else -1).name[len('patched_'):] if patched else None

    def prepared_content(self) -> dict:
        path = self.build / 'prepared-content.json' if self.build else None
        return json.loads(path.read_text()) if path and path.is_file() else {}

    def input_signature(self) -> str:
        paths = {p.resolve() for p in self.folder.iterdir() if p.is_file() and p.suffix.lower() in SOURCE_SUFFIXES and not p.name.startswith('._')}
        paths.update(Path(item['path']).expanduser().resolve() for item in self.addons)
        records = []
        for path in sorted(paths):
            if not path.is_file():
                raise Failure(f'Update or DLC is unavailable: {path}. Reconnect its drive or remove it from this game.')
            stat = path.stat()
            records.append((str(path), stat.st_size, stat.st_mtime_ns))
        return hashlib.sha256(json.dumps(records).encode()).hexdigest()

    def fixup_declared(self, key: str) -> bool:
        """Whether the rewritten main's fixups declare `# <key>`, as the iPhone launcher's fixups: conditions read them (dm/games/settings.tsv)"""
        fixups = self.build / f'patched_{self.package}/main.fixups.tsv' if self.build and self.package else None
        return bool(fixups and fixups.is_file() and any(line.startswith(f'# {key}\t') or line == f'# {key}' for line in fixups.read_text(errors='replace').splitlines()))

    def res_scale_supported(self) -> bool:
        """The game's built shader library carries the resolution-scaling code, which DM_RES_SCALE needs: dm/tools/shader_lib.py rescale_code (a shader built with the code binds
        the support buffer, one built without it never does), whatever the profile says now, since the app gets the library that was built. No library yet: not offered. The answer is kept in
        the state file for the library file it read (a library without the code is read whole, about a second)"""
        if not self.title_id or not self.shaders:
            return False
        lib = self.shaders / f'b-{chain()}'
        img = lib.with_name(lib.name + '.img')
        probe = img if img.is_file() else lib / 'inputs.tsv'
        try:
            st = probe.stat()
        except OSError:
            return False
        sig = f'{probe}:{st.st_size}:{st.st_mtime_ns}'
        kept = self.state().get('rescale_code')
        if isinstance(kept, dict) and kept.get('library') == sig:
            return bool(kept.get('value'))
        sys.path.insert(0, str(REPO / 'dm/tools'))
        import shader_lib
        value = bool(shader_lib.rescale_code(lib))
        self.save_state(rescale_code={'library': sig, 'value': value})
        return value

    def render_scale_supported(self) -> bool:
        """A render-scale stub in the rewritten main (Tears of the Kingdom 1.4.2 / 1.4.3, Breath of the Wild 1.9.0)"""
        return self.fixup_declared('RENDER_SCALE')

    def profile_value(self, key: str) -> str:
        """A key of the game's profile: the derived one the NSP script wrote for a version it was not brought up on, else the repository's (dm/games/<title ID>/game.tsv)"""
        for tsv in ((self.profile_root / self.title_id / 'game.tsv') if self.build else None, REPO / 'dm/games' / self.title_id / 'game.tsv'):
            if tsv and tsv.is_file():
                for line in tsv.read_text(errors='replace').splitlines():
                    fields = line.split('\t')
                    if len(fields) >= 2 and fields[0] == key:
                        return fields[1].strip()
        return ''

    @property
    def profile_root(self) -> Path:
        # Relative to the build folder so moving a build keeps its active profile.
        return self.build / self.state().get('profile_root', 'profile')

    def frame_step_supported(self) -> bool:
        """A frame step in the rewritten main (its state page, FPS_STATE_OFF): the host decides each frame's step and holds 30 fps while the device is thermally serious (hle_nvn.c thermal_capped)"""
        return self.fixup_declared('FPS_STATE_OFF')

    @property
    def extract(self) -> Optional[Path]:
        return self.build / 'extract' / self.package if self.package else None

    @property
    def romfs(self) -> Optional[Path]:
        if not self.extract:
            return None
        image = self.extract / 'RomFS.img'
        return image if image.is_file() else None

    @property
    def shaders(self) -> Optional[Path]:
        if not self.build:
            return None
        folder = self.build / 'shader/ios'
        library = folder / f'b-{chain()}'
        # A finished library is either the folder with its stamp or, since upstream's dm/tools/shader_lib.py, one packed file b-<chain>.img
        # (dmsh_build.py writes the image and removes the folder); build_ipa.sh reads either through MSL_IOS=<this folder>.
        packed = library.with_name(library.name + '.img')
        return folder if (library / 'inputs.tsv').is_file() or packed.is_file() else None

    @property
    def prepared(self) -> bool:
        return bool(self.package and self.romfs and self.shaders)

    @property
    def state_file(self) -> Optional[Path]:
        return self.build / 'tvport.json' if self.build else None

    def state(self) -> dict:
        if self.state_file and self.state_file.is_file():
            return json.loads(self.state_file.read_text())
        return {}

    def save_state(self, **fields) -> None:
        self.state_file.write_text(json.dumps({**self.state(), **fields}, indent=1))

    @property
    def icon(self) -> Optional[Path]:
        icon = self.extract / 'icon.jpg' if self.extract else None
        return icon if icon and icon.is_file() else None

    @property
    def app(self) -> Optional[Path]:
        return self.build / 'tvport-derived/Build/Products/Release-appletvos/DmIOS.app' if self.build else None

    def earlier_app(self) -> Optional[Path]:
        """The app of a build made before this project: its bundle ID keeps the game data already on the TV."""
        for app in (self.app, self.build / 'xcode-derived-data/Build/Products/Release-appletvos/DmIOS.app' if self.build else None):
            if app and (app / 'Info.plist').is_file():
                return app
        return None

    def bundle_id(self, team: str) -> str:
        saved = self.state().get('bundle_id')
        if saved:
            return saved
        app = self.earlier_app()
        if app:
            return plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
        return f'dev.tvport.{team.lower()}.g{self.title_id.lower()}'

    def name(self) -> str:
        control = self.extract / 'control.nacp' if self.extract else None
        return (nacp_text(control) if control and control.is_file() else '') or self.folder.name

    def version(self) -> str:
        control = self.extract / 'control.nacp' if self.extract else None
        return nacp_text(control, '--version') if control and control.is_file() else ''


def provisioning(app: Optional[Path]) -> dict:
    """What a signed app's profile says: its team, and when tvOS stops opening it."""
    profile = app / 'embedded.mobileprovision' if app else None
    if not profile or not profile.is_file():
        return {}
    decoded = run(['security', 'cms', '-D', '-i', profile])
    if decoded.returncode:
        return {}
    data = plistlib.loads(decoded.stdout.encode())
    expires = data['ExpirationDate'].replace(tzinfo=timezone.utc)
    return {'team': data['TeamIdentifier'][0], 'expires': expires.isoformat(), 'days_left': (expires - datetime.now(timezone.utc)).days,
            'free_team': bool(data.get('LocalProvision')) or (expires - data['CreationDate'].replace(tzinfo=timezone.utc)).days <= 7}


def xcode_teams(prefs: dict) -> list:
    """The teams of the Apple IDs signed in to Xcode (Settings > Accounts), personal teams first: a free Apple ID that has never built anything has no profile yet, only this."""
    teams = [team for account in prefs.get('IDEProvisioningTeamByIdentifier', {}).values() for team in account if team.get('teamID')]
    return [team['teamID'] for team in sorted(teams, key=lambda team: not team.get('isFreeProvisioningTeam'))]


def known_team() -> str:
    folders = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles', Path.home() / 'Library/MobileDevice/Provisioning Profiles']
    for folder in folders:
        for profile in sorted(folder.glob('*.mobileprovision'), key=lambda p: p.stat().st_mtime, reverse=True) if folder.is_dir() else []:
            decoded = run(['security', 'cms', '-D', '-i', profile])
            if decoded.returncode == 0:
                return plistlib.loads(decoded.stdout.encode())['TeamIdentifier'][0]
    exported = run(['defaults', 'export', 'com.apple.dt.Xcode', '-'])
    try:
        teams = xcode_teams(plistlib.loads(exported.stdout.encode())) if exported.returncode == 0 else []
    except plistlib.InvalidFileException:
        teams = []
    return teams[0] if teams else ''


def devicectl_json(*args, timeout: Optional[float] = None) -> dict:
    with tempfile.TemporaryDirectory() as folder:
        out = Path(folder) / 'out.json'
        try:
            result = run(['xcrun', 'devicectl', *args, '--quiet', '--json-output', out], timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failure('The Apple TV did not answer.') from None
        if not out.is_file():
            raise Failure(result.stderr.strip() or 'devicectl gave no answer. Is Xcode installed?')
        return json.loads(out.read_text())


def apple_tvs(listing: dict) -> list:
    tvs = []
    for device in listing.get('result', {}).get('devices', []):
        hardware = device.get('hardwareProperties', {})
        if hardware.get('deviceType') != 'appleTV' or hardware.get('reality') != 'physical':
            continue
        properties, connection = device.get('deviceProperties', {}), device.get('connectionProperties', {})
        tvs.append({'id': hardware.get('udid'), 'name': properties.get('name'), 'model': hardware.get('marketingName'), 'os': properties.get('osVersionNumber'),
                    'connected': connection.get('tunnelState') == 'connected', 'developer_mode': properties.get('developerModeStatus') == 'enabled'})
    return tvs


def installed_files(device: str, bundle: str) -> dict:
    try:
        data = devicectl_json('device', 'info', 'files', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--subdirectory', CACHES)
    except (Failure, json.JSONDecodeError):
        return {}
    return {f.get('relativePath'): f.get('metadata', {}).get('size') for f in data.get('result', {}).get('files', [])}


def cmd_devices(_) -> None:
    print(json.dumps({'devices': apple_tvs(devicectl_json('list', 'devices'))}))


def tool_path() -> str:
    return os.pathsep.join(TOOL_PATHS + [os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')])


def first_line(result: subprocess.CompletedProcess) -> str:
    return (result.stdout.strip() or result.stderr.strip()).split('\n')[0]


def checks() -> list:
    """What a build needs that the app cannot carry, each with what to do about it. The NSP script checks the same things (check_prereqs) once a build starts."""
    out = []

    def check(name: str, ok, detail: str, fix: str = '', command: str = '') -> bool:
        out.append({'name': name, 'ok': bool(ok), 'detail': detail, 'fix': '' if ok else fix, 'command': '' if ok else command})
        return bool(ok)

    developer = run(['xcode-select', '-p']).stdout.strip()
    xcode = run(['xcodebuild', '-version']) if developer and 'CommandLineTools' not in developer else None
    if check('Xcode', xcode and xcode.returncode == 0, ' '.join(xcode.stdout.split('\n')[0:1]) if xcode else 'Not installed, or not the selected developer folder',
             'Install Xcode from the App Store and open it once. If it is installed, select it:', 'sudo xcode-select -s /Applications/Xcode.app'):
        for sdk, platform in (('appletvos', 'tvOS'), ('iphoneos', 'iOS')):   # the shaders are iOS Metal libraries, so a tvOS build needs the iOS platform too
            version = run(['xcrun', '--sdk', sdk, '--show-sdk-version'])
            check(f'{platform} platform', version.returncode == 0, f'SDK {version.stdout.strip()}' if version.returncode == 0 else 'Not installed',
                  'Xcode > Settings > Components, or in Terminal:', f'xcodebuild -downloadPlatform {platform}')
        metal = run(['xcrun', '-sdk', 'iphoneos', 'metal', '--version'])
        check('Metal toolchain', metal.returncode == 0, first_line(metal) if metal.returncode == 0 else 'Not installed', 'In Terminal:', 'xcodebuild -downloadComponent MetalToolchain')
    team = known_team()
    check('Apple ID', team, f'Signing team {team}', 'Open Xcode, then Settings > Accounts, and add your Apple ID. A free one works: its installs open for 7 days.')
    path = tool_path()
    missing = [formula for tool, formula in (('xcodegen', 'xcodegen'), ('zstd', 'zstd'), ('glslangValidator', 'glslang')) if not shutil.which(tool, path=path)]
    brew = shutil.which('brew', path=path)
    check('Build tools', not missing, 'xcodegen, zstd and glslang' if not missing else 'Missing: ' + ', '.join(missing),
          'In Terminal:' if brew else 'Install Homebrew from brew.sh, then in Terminal:', 'brew install ' + ' '.join(missing))
    python = venv_ready() and str(DATA / 'venv/bin/python3') or borrowed_python()
    check('Python', python, f'Python {PYTHON_VERSION} in TVPort\'s folder' if venv_ready() else f'Borrowing {python}' if python else 'Not set up yet',
          'Press Set Up: TVPort downloads its own Python once.' if uv_tool() else 'TVPort makes its own Python with uv. In Terminal:', '' if uv_tool() else 'brew install uv')
    return out


def engine_info() -> dict:
    info = json.loads((REPO / 'engine.json').read_text()) if (REPO / 'engine.json').is_file() else {}
    return {'bundled': BUNDLED, 'folder': str(REPO), 'commit': info.get('commit', ''), 'chain': chain()}


def cmd_doctor(_) -> None:
    found = checks()
    own = not venv_ready() and bool(uv_tool()) and (BUNDLED or not borrowed_python())   # the app makes its own, rather than lean on another's that may change
    print(json.dumps({'checks': found, 'ready': all(c['ok'] for c in found), 'needs_setup': own,
                      'can_set_up': bool(uv_tool()), 'engine': engine_info()}))


def cmd_setup(_) -> None:
    """The app's first run, and the first run of each release: unpack its engine (main) and make its Python. Holds the build lock, as a build uses both."""
    lock = one_build_at_a_time()   # noqa: F841 held until this process exits
    if BUNDLED:
        prune_engines(REPO)
    if not venv_ready():
        set_up_python()
    emit('done', engine=engine_info())


def cmd_inspect(args) -> None:
    game = Game(args.folder)
    app = game.earlier_app() if game.build else None
    profile = provisioning(app)
    team = profile.get('team') or known_team()
    nup = game.nup_info()
    print(json.dumps({'folder': str(game.folder), 'title_id': game.title_id, 'keyless': game.keyless, 'nup': nup or None, 'artwork_title_id': game.artwork_title_id or nup.get('title_id', ''), 'name': game.name() if game.build else nup.get('name') or game.folder.name, 'version': game.version() if game.build else '',
                      'build_folder': str(game.build_parent), 'build_path': str(game.build) if game.build else None, 'built': app is not None,
                      'sources': game.sources, 'prepared': game.prepared, 'render_scale': game.render_scale_supported() if game.build else False, 'res_scale': game.res_scale_supported(), 'frame_step': game.frame_step_supported() if game.build else False, 'fps_target': int(game.profile_value('fps_target') or 0) if game.title_id else 0, 'icon': str(game.icon) if game.icon else None, 'team': team,
                      'bundle_id': game.bundle_id(team) if game.build and team else None, 'signing': profile, 'saved': game.state(), 'upscaler': game.state().get('upscaler', 'game'),
                      'keys': str(find_keys(game) or '') or None, **backup_info(latest_backup(game))}))


def check_addons(game: Game, sources, keys=None, python=None) -> dict:
    if game.keyless:   # a NUP holds its updates and DLC itself, and the keys check reads NSP / XCI metadata
        emit('log', line='This game is a NUP container: its updates and DLC are inside it, so there is nothing to verify.')
        return {'title_id': game.nup_info().get('title_id', ''), 'addons': []}
    keys = keys if keys and keys.is_file() else find_keys(game)
    if not keys:
        raise Failure('Choose your prod.keys file in this game’s settings first, so TVPort can verify the update or DLC.')
    command = [python or engine_python(), REPO / 'scripts/inspect_game_addons.py', game.folder, '--keys', keys]
    if game.title_id:
        command += ['--expected', game.title_id]
    for path in dict.fromkeys(map(str, sources)):
        command += ['--source', path]
    result = run(command)
    try:
        answer = json.loads(result.stdout)
    except ValueError:
        raise Failure('Could not inspect the update or DLC. Check your keys, file access and .NET setup.') from None
    if result.returncode or answer.get('error'):
        raise Failure(answer.get('error') or 'Could not verify the update or DLC.')
    return answer


def cmd_check_addons(args) -> None:
    print(json.dumps(check_addons(Game(args.folder), args.source, args.keys)))


def artwork_env(args) -> dict:
    """Shared crop configuration for previews and the generated Apple TV assets."""
    env = {'DM_ICON_CROP_SCALE': str(args.art_scale), 'DM_ICON_CROP_X': str(args.art_x), 'DM_ICON_CROP_Y': str(args.art_y)}
    if hasattr(args, 'shelf_scale'):
        env.update(DM_SHELF_CROP_SCALE=str(args.shelf_scale), DM_SHELF_CROP_X=str(args.shelf_x), DM_SHELF_CROP_Y=str(args.shelf_y))
    if getattr(args, 'shelf_art', None):
        env['DM_TOP_SHELF_ART'] = str(args.shelf_art)
    elif hasattr(args, 'shelf_art'):
        env['DM_TOP_SHELF_ART'] = ''
    return env


def art_scale_arg(text: str) -> float:
    value = float(text)
    if value != 0 and not 1 <= value <= 3:
        raise argparse.ArgumentTypeError('art scale must be 0 (automatic) or 1 to 3')
    return value


def art_position_arg(text: str) -> float:
    value = float(text)
    if not -1 <= value <= 1:
        raise argparse.ArgumentTypeError('art position must be -1 to 1')
    return value


def cmd_preview(args) -> None:
    result = run(['xcrun', 'swift', REPO / 'dm/ios/tools/tv_icon.swift', args.art, '--shelf-preview' if args.top_shelf else '--preview', args.out], env={**os.environ, **artwork_env(args)})
    if result.returncode:
        raise Failure(result.stderr.strip() or 'The artwork could not be read')
    print(json.dumps({'preview': str(args.out)}))


def find_keys(game: Game) -> Optional[Path]:
    """prod.keys in the usual places, so one copy serves every game."""
    for folder in (game.folder, game.folder.parent, Path.home() / 'Games', Path.home() / '.switch', Path.home() / 'Downloads', Path.home() / 'Desktop'):
        keys = folder / 'prod.keys'
        if keys.is_file():
            return keys
    return None


def save_listing(device: str, bundle: str) -> Optional[dict]:
    """The committed saves on the TV, as {path under Library/Caches: [size, last change]}, from one listing: empty for a game that is not installed, None for a TV that did not answer."""
    try:
        data = devicectl_json('device', 'info', 'files', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--subdirectory', CACHES, timeout=TV_TIMEOUT_S)
    except (Failure, json.JSONDecodeError):
        return None
    if 'error' in data:
        return {} if data['error'].get('domain') == 'CoreDevice.ActionError' else None   # ActionError: the TV answered, and has no such app or folder
    return {f['relativePath']: [f.get('metadata', {}).get('size'), f.get('metadata', {}).get('lastModDate')] for f in data.get('result', {}).get('files', [])
            if SAVE_FILE.match(f.get('relativePath', '')) and not f.get('resources', {}).get('isDirectory')}


def save_files(device: str, bundle: str) -> list:
    """The committed saves on the TV, as paths under Library/Caches. An app that is not installed has none."""
    return sorted(save_listing(device, bundle) or {})


def backup_places(game: Game) -> list:
    """Where a game's backups are: beside the game, and in iCloud Drive when it is on (TVPort Saves/<title ID>)."""
    places = [game.build / SAVE_BACKUPS] if game.build else []
    if game.title_id and ICLOUD.is_dir():
        places.append(ICLOUD / ICLOUD_SAVES / game.title_id)
    return places


def newest_backup(places: Iterable[Path]) -> Optional[Path]:
    """The newest backup in any of these places: by name, which is the time it was made."""
    found = [p for place in places if place.is_dir() for p in place.iterdir() if p.is_dir() and BACKUP_NAME.match(p.name)]
    return max(found, key=lambda p: p.name, default=None)


def latest_backup(game: Game) -> Optional[Path]:
    return newest_backup(backup_places(game))


def backup_time(backup: Optional[Path]) -> Optional[float]:
    try:
        return datetime.strptime(backup.name[:17], '%Y-%m-%d-%H%M%S').timestamp() if backup else None
    except ValueError:
        return None


def read_manifest(backup: Path) -> Optional[dict]:
    try:
        return json.loads((backup / MANIFEST).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def same_files(one: Path, other: Path) -> bool:
    names = lambda root: sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and SAVE_FILE.match(str(p.relative_to(root))))
    return names(one) == names(other) and all((one / n).read_bytes() == (other / n).read_bytes() for n in names(one))


def kept_backups(names: Iterable[str], today) -> set:
    """Of a place's backup folders, those to keep: the newest KEEP_BACKUPS, and the newest of each of the last KEEP_DAYS days (today the newest)."""
    names = sorted(n for n in names if BACKUP_NAME.match(n))
    newest_of_day = {name[:10]: name for name in names}   # sorted, so each day ends on its newest
    first_day = (today - timedelta(days=KEEP_DAYS - 1)).isoformat()
    return set(names[-KEEP_BACKUPS:]) | {name for day, name in newest_of_day.items() if day >= first_day}


def prune_backups(place: Path) -> None:
    folders = [p for p in place.iterdir() if p.is_dir() and BACKUP_NAME.match(p.name)]
    keep = kept_backups([p.name for p in folders], datetime.now().date())
    for old in folders:
        if old.name not in keep:
            shutil.rmtree(old)


def backup_info(backup: Optional[Path]) -> dict:
    return {'last_backup': backup.name if backup else None, 'last_backup_time': backup_time(backup), 'last_backup_place': None if not backup else 'icloud' if ICLOUD in backup.parents else 'mac'}


def backup_saves(game: Game, device: str, bundle: str, icloud: bool = False, attempts: int = 3) -> dict:
    """Copies the TV's saves to the Mac, which survives what the TV's storage may not: an app deleted on the TV takes its preferences with it. With icloud, and iCloud Drive on,
    the copy goes to iCloud Drive instead. Only reads the TV: it lists files and copies them from it.
    The newest backup keeps the TV's listing it came from, and the same listing again copies nothing. A copy is kept only when a second listing after it matches the first: the
    game commits a save by swapping save.work into save, and a copy across that swap could mix old and new files. Identical saves make no new backup."""
    lock = (game.build / '.save-backup.lock').open('w')   # the app's rounds and a build's backup can meet
    fcntl.flock(lock, fcntl.LOCK_EX)
    newest, listing = latest_backup(game), None
    for _ in range(attempts):
        listing = save_listing(device, bundle)
        if not listing:
            return {'files': 0, 'folder': None, 'changed': False, 'state': 'unavailable' if listing is None else 'none'}
        if newest and read_manifest(newest) == listing:
            return {'files': len(listing), 'folder': str(newest), 'changed': False, 'state': 'unchanged'}
        incoming = Path(tempfile.mkdtemp(prefix='.save-backup-incoming-', dir=game.build))   # outside the backups, so a copy that fails partway is never taken for one
        try:
            for name in listing:
                (incoming / name).parent.mkdir(parents=True, exist_ok=True)
                run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', f'{CACHES}/{name}', '--destination', incoming / name])
                if not (incoming / name).is_file():
                    raise Failure(f'Could not copy {name} from the Apple TV. Nothing was changed.')
            if save_listing(device, bundle) != listing:
                continue   # the game saved during the copy
            if newest and same_files(incoming, newest):
                (newest / MANIFEST).write_text(json.dumps(listing))   # the same saves, written again: the next round needs no copy
                return {'files': len(listing), 'folder': str(newest), 'changed': False, 'state': 'unchanged'}
            (incoming / MANIFEST).write_text(json.dumps(listing))
            place = backup_places(game)[-1] if icloud else game.build / SAVE_BACKUPS
            stamp, n = datetime.now().strftime('%Y-%m-%d-%H%M%S'), 1
            target = place / stamp
            while target.exists() or target.parent.joinpath(f'.{target.name}.partial').exists():
                n += 1
                target = place / f'{stamp}-{n}'
            partial = place / f'.{target.name}.partial'   # in the same place, so the backup appears whole
            partial.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(incoming, partial)
            partial.rename(target)
            prune_backups(place)
            return {'files': len(listing), 'folder': str(target), 'changed': True, 'state': 'backed-up'}
        finally:
            shutil.rmtree(incoming, ignore_errors=True)
    return {'files': len(listing or {}), 'folder': str(newest) if newest else None, 'changed': False, 'state': 'busy'}


def restore_saves(game: Game, device: str, bundle: str) -> int:
    """Puts the newest backup back on a TV that has lost its saves. It never replaces a save that is there."""
    backup = latest_backup(game)
    from save_import import SaveImporter, SLOT
    importer = SaveImporter(sys.modules[__name__])
    sources = {p.relative_to(backup).as_posix(): p for p in backup.rglob('*')
               if p.is_file() and SAVE_FILE.match(str(p.relative_to(backup)))} if backup else {}
    # Prefer newer automatic managed copies, without promoting imported saves or
    # safety backups into the game's active progress. Legacy backups remain usable.
    seen = set()
    for record in importer.history(device, bundle):
        slot = record['slot']
        if record['status'] != 'automatic-backup' or slot in seen or not SLOT.fullmatch(slot):
            continue
        seen.add(slot)
        if record['date'] < (backup_time(backup) or 0):
            continue
        folder = Path(record['folder'])
        files = {slot + '/' + p.relative_to(folder).as_posix(): p
                 for p in folder.rglob('*') if p.is_file() and not p.is_symlink()}
        if files:
            sources = {name: path for name, path in sources.items() if not name.startswith(slot + '/')}
            sources.update(files)
    if not sources:
        return 0
    try:
        listing = importer.listing(device, bundle)
        if any(SAVE_FILE.match(name.removeprefix('Caches/')) for name in listing if name.startswith('Caches/')):
            return 0
        # tvOS may purge Caches while the real save still exists in Preferences.
        if any(name.startswith('Preferences/tv-saves/') and name.endswith('.dmsync') for name in listing):
            return 0
        with tempfile.TemporaryDirectory() as folder:
            prefs = importer.preferences(device, bundle, listing, Path(folder))
        if any(key.startswith('dmsave:') for key in prefs):
            return 0
    except (Failure, OSError, ValueError):
        emit('log', line='Automatic save recovery skipped: existing saves could not be verified. No saves were replaced.')
        return 0
    for name, path in sources.items():
        result = run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', path, '--destination', f'{CACHES}/{name}'])
        if result.returncode:
            raise Failure(f'Could not put {path.name} back on the Apple TV: {result.stderr.strip()[-300:]}')
    return len(sources)


def write_env(game: Game, mode: str, texture_cap: int, players: str = '', render_scale: float = 1.0, thermal_cap: bool = True, fps_target: int = 0, swap_ab_xy: bool = False, swap_ab: Optional[bool] = None, swap_xy: Optional[bool] = None, pso_mtl4: bool = False, extra_env: Optional[list] = None, guest_file: Optional[str] = None, astc_block: Optional[int] = None, bc1_block: Optional[int] = None, upscaler: str = 'game', res_scale: float = 1.0) -> Path:
    """The switches the app reads at launch (main.m, dm/env.txt)."""
    path = game.build / 'tvport-env.txt'
    lines = ['# Written by TVPort', f'DM_OPMODE={0 if mode == "handheld" else 1}', f'DM_BC_MAX_DIM={texture_cap}']
    if render_scale != 1.0:   # the 3D views at that fraction of the game's size (loader.c dm_fps_state_apply); a game without the stub ignores it
        lines.append(f'DM_RENDER_SCALE={render_scale:g}')
    if res_scale != 1.0:   # every scaled render target at that many times the game's size (nvn_rscale.inc); a game whose shaders lack the rescale code logs [res-scale] off
        lines.append(f'DM_RES_SCALE={res_scale:g}')
    if UPSCALER_ENV.get(upscaler):   # the game's upscaler network drawn with MetalFX, or off for plain bilinear scaling (DM_UPSCALER); unset is the game's own
        lines.append(f'DM_UPSCALER={UPSCALER_ENV[upscaler]}')
    if fps_target:   # the profile's fps_target replaced (30 or 60): the frame step's cap, or the engine limit the host sets (hle_fpslock.c)
        lines.append(f'DM_FPS_TARGET={fps_target}')
    if not thermal_cap:   # the frame step keeps its cap when the TV is hot; tvOS lowers the clocks then all the same (docs/reference/frame-rate.md)
        lines.append('DM_THERMAL_CAP=0')
    if swap_ab_xy and swap_ab is None and swap_xy is None:  # Older callers still swap both pairs.
        lines.append('DM_PAD_SWAP_AB_XY=1')
    else:
        if swap_ab if swap_ab is not None else swap_ab_xy:
            lines.append('DM_PAD_SWAP_AB=1')
        if swap_xy if swap_xy is not None else swap_ab_xy:
            lines.append('DM_PAD_SWAP_XY=1')
    if players.strip():
        lines.append('DM_TV_PLAYERS=' + ' '.join(players.split()))
    if pso_mtl4:   # the Metal 4 pipelines; the build keeps the pulling libraries they need (IOS_PULL, generate_project)
        lines.append('DM_PSO_MTL4=1')
    if guest_file in ('on', 'off'):   # Game memory paging (hle_svc.c guest_file_wanted); unset leaves the engine's per-target default
        lines.append(f'DM_GUEST_FILE={1 if guest_file == "on" else 0}')
    if astc_block is not None:   # Compressed textures: BC1/2/3/7 stored as ASTC from the prebuilt pack (dm/gfx/tex/README.md); 0 = off
        lines.append(f'DM_NVN_BC_ASTC={astc_block}')
        if astc_block and bc1_block:   # BC1 at its own block (the engine's astc_block_for); unset it is the same block as the others
            lines.append(f'DM_NVN_BC1_ASTC={bc1_block}')
    pairs = extra_env_pairs(extra_env or [])
    if pairs:   # the player's own switches: they win over a line above with the same key
        keys = {key for key, _ in pairs}
        lines = [line for line in lines if line.startswith('#') or line.split('=', 1)[0] not in keys] + [f'{key}={value}' for key, value in pairs]
    path.write_text('\n'.join(lines) + '\n')
    return path


ENV_KEY = re.compile(r'[A-Z0-9_]+')


def extra_env_pairs(items: Iterable) -> list:
    """KEY=VALUE switches (a block of lines is fine) as (key, value) pairs: blank and # lines are skipped, a key outside [A-Z0-9_]+ or a line without = stops the build."""
    pairs: dict = {}
    for item in items:
        for line in str(item).splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            key, equals, value = line.partition('=')
            key = key.strip()
            if not equals or not ENV_KEY.fullmatch(key):
                raise Failure(f'Extra environment switch "{line[:80]}" is not KEY=VALUE with a key of capital letters, digits and underscores')
            pairs[key] = value.strip()
    return list(pairs.items())


def profile_env(game: Game) -> dict:
    env = dict(os.environ)
    derived = game.profile_root
    if (derived / game.title_id / 'game.tsv').is_file():
        env.update(DM_GAMES_DIR=str(derived), DM_GAMES_FIRST='1')
    return env


def restore_tables(game: Game) -> None:
    """c1_full.tsv and cb_extent.tsv are outputs of the shader build, kept in the profile, and a new checkout has none: take them from the game's last project."""
    profile = game.profile_root / game.title_id
    if not profile.is_dir():
        profile = REPO / 'dm/games' / game.title_id
    for name in ('c1_full.tsv', 'cb_extent.tsv'):
        for origin in (game.build / 'tvport-xcode/Gen/dm' / name, game.build / 'xcode/Gen/dm' / name):
            if not (profile / name).is_file() and origin.is_file():
                shutil.copy2(origin, profile / name)


GPU_LIST = re.compile(r'(applegpu_)?g\w+(,(applegpu_)?g\w+)*')


def pipeline_gpu(args) -> str:
    """--gpu of the build script: none (no pipeline archive, as always) unless the game page names GPU architectures."""
    gpu = (getattr(args, 'gpu', '') or '').strip().replace(' ', '')
    if gpu and gpu != 'none' and not GPU_LIST.fullmatch(gpu):
        raise Failure(f'Pipeline archive GPU "{gpu}" is not a GPU architecture such as g18p (or several, separated by commas)')
    return gpu or 'none'


def extractor_options(args) -> list:
    """The build script's options for a damaged manual and nx_extract's extra arguments (option-like values need the = form)."""
    out = ['--allow-damaged-manual'] if getattr(args, 'allow_damaged_manual', False) else []
    for item in getattr(args, 'nx_extract_arg', None) or []:
        out.append(f'--nx-extract-arg={item}')
    return out


def profile_signature(game: Game) -> str:
    """The game's own profile in the engine (dm/games/<title id>/game.tsv and pso_manifest.tsv): what the rewriter and the shader step read besides the code patches."""
    title_id = getattr(game, 'title_id', '')
    folder = REPO / 'dm/games' / title_id
    parts = {name: hashlib.sha256((folder / name).read_bytes()).hexdigest() for name in ('game.tsv', 'pso_manifest.tsv') if title_id and (folder / name).is_file()}
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()


def engine_change(game: Game) -> Optional[str]:
    """Why a prepared game's rewritten code is out of date with this engine, or None. The rewriter (dm/tools/patch_nso.py) writes build_src.sha256 into patched_<version>/:
    the sha256 and the path (from dm/tools) of itself and every patch file it read. Entries for other games' patches.py are ignored; this game's own, the shared ones and
    a missing record all count. A changed game.tsv / pso_manifest.tsv counts when the last prepare recorded them (a game prepared before that has nothing to compare)."""
    package = getattr(game, 'package', None)
    if not game.build or not package:
        return None
    record = game.build / f'patched_{package}' / 'build_src.sha256'
    try:
        lines = record.read_text(encoding='utf-8').splitlines()
    except OSError:
        return 'the record of what its code was rewritten from is missing'
    tools = REPO / 'dm/tools'
    own = f'../games/{getattr(game, "title_id", "")}/'
    for line in lines:
        digest, _, relative = line.partition('  ')
        if not digest or not relative:
            continue
        if relative.startswith('../games/') and not relative.startswith(own):
            continue
        try:
            current = hashlib.sha256((tools / relative).read_bytes()).hexdigest()
        except OSError:
            return f'{relative} is gone from the engine'
        if current != digest:
            return f'{Path(relative).name} changed' if not relative.startswith('..') else f'{relative.removeprefix("../")} changed'
    recorded = game.state().get('profile_signature')
    if recorded and recorded != profile_signature(game):
        return "the game's profile (game.tsv or pso_manifest.tsv) changed"
    return None


def prepare_game(game: Game, keys: Optional[Path], team: str, python: str, args=None) -> Game:
    stage('Extracting the game, rewriting its code and building shaders')
    emit('log', line='This can take 30 to 60 minutes the first time, and again when the game version changes.')
    keys = None if game.keyless else keys if keys and keys.is_file() else find_keys(game)
    if game.keyless:
        emit('log', line='NUP container (Switch 2): no prod.keys needed. TVPort reads the game as it is; this is not a Switch 1 build, so expect it to stop where the engine lacks Switch 2 support.')
    elif not keys:
        raise Failure('This game has not been built yet, so it needs your prod.keys file. (A Switch 2 game packed as a .nup needs none: its files are not encrypted. A Switch 1 game, or a Switch 2 game as an .nsp or .xci, needs keys from your own Switch.)')
    signature = game.input_signature()
    state = game.state()
    profiles = dict(state.get('profiles_by_source') or {})
    previous_signature = state.get('source_signature')
    if previous_signature:
        profiles.setdefault(previous_signature, state.get('profile_root', 'profile'))
    # A provisional survey contains build-specific addresses and memory settings.
    # Different inputs must not reuse it; keep each survey so switching back is safe.
    profile = profiles.get(signature, f'profiles/{signature}') if game.build else None
    command = [python, REPO / 'scripts/build_ipa_from_nsp.py', game.folder, *(['-k', keys] if keys else []), '--prepare-xcode', '--keep-extracted', '--gpu', pipeline_gpu(args), '--romfs', 'separate', '--allow-other-metal', '--progress', 'lines']
    command += extractor_options(args)
    if game.title_id:
        command += ['--title-id', game.title_id]
    if profile:
        command += ['--profile-out', game.build_parent / game.build.name / profile]
        if signature not in profiles:
            emit('log', line='Game files changed: creating a separate game profile. Earlier profiles are kept.')
    for path in dict.fromkeys(item['path'] for item in game.addons):
        command += ['--extra-package', path]
    if game.build_parent != game.folder:
        command += ['--build-root', game.build_parent]
    if team:
        command += ['--team-id', team]
    stream(command, cwd=REPO)
    game = Game(game.folder)
    if not game.prepared:
        raise Failure('The engine finished without shaders or game files for this game. See the log above.')
    profile = profile or 'profile'
    profiles[signature] = profile
    game.save_state(source_signature=signature, profile_root=profile, profiles_by_source=profiles, profile_signature=profile_signature(game))
    return game


def store_artwork(game: Game) -> Optional[Path]:
    """The Nintendo store's art for a game that has none else (a Switch 2 game: no icon in its NUP, no entry in titledb), kept in the artwork cache. None offline."""
    import nintendo_store
    try:
        return nintendo_store.fallback_artwork(DATA, switchtv_cache(), game.artwork_title_id, log=lambda line: emit('log', line=line))
    except Exception as error:   # the fallback must never fail a build
        emit('log', line=f'Nintendo store artwork skipped ({error})')
        return None


def generate_project(game: Game, args, team: str, bundle: str, python: str, romfs: Optional[Path] = None) -> Path:
    """romfs: the image the app is built against when it is not game.romfs (the sparse image of Store textures once)"""
    stage('Generating the Apple TV project')
    restore_tables(game)
    pso_mtl4 = bool(getattr(args, 'pso_mtl4', False))
    env = profile_env(game)
    aoc = game.build / 'aoc'
    env.update(GAME=game.title_id, W=str(game.build), PATCHED=str(game.build / f'patched_{game.package}'), ROMFS=str(romfs or game.romfs), MSL_IOS=str(game.shaders), AOC=str(aoc) if aoc.is_dir() and game.prepared_content().get('dlc', True) else '',
               DM_TVOS='1', DM_COPY_ROMFS='NO', DM_SHOW_FPS='1' if args.fps else '0', DM_ENV_FILE=str(write_env(game, args.mode, args.texture_cap, args.players, args.render_scale, not args.no_thermal_cap, args.fps_target, args.swap_ab_xy, args.swap_ab, args.swap_xy, pso_mtl4, getattr(args, 'extra_env', None), getattr(args, 'guest_file', None), astc_block(args), astc_blocks(args)[1], getattr(args, 'upscaler', 'game'), getattr(args, 'res_scale', 1.0))), DM_BUNDLE_ID=bundle, DM_TEAM_ID=team,
               DM_XCODE_PROJECT_DIR=str(game.build / 'tvport-xcode'), DM_XCODE_DERIVED_DATA=str(game.build / 'tvport-derived'), FONT_PY=python)
    env.update(artwork_env(args))
    control = game.extract / 'control.nacp' if game.extract else None
    if not (control and control.is_file() and nacp_text(control)):
        env['DM_DISPLAY_NAME'] = game.name()   # a Switch 2 NUP has no control data; build_ipa.sh needs a name
    if pso_mtl4:
        env['IOS_PULL'] = '1'   # keep the pulling vertex libraries (_bp) the Metal 4 pipelines read; without it DM_PSO_MTL4=1 cannot fully enable them
    art = args.art or game.icon or args.shelf_art or store_artwork(game)
    if art:
        env['DM_ICON'] = str(art)
    stream(['bash', REPO / 'dm/ios/tools/build_ipa.sh', '--prepare-xcode'], env=env, cwd=REPO)
    return game.build / 'tvport-xcode'


def merged_rows(*texts: str) -> list:
    """Shader list rows from every source, each once, in the order first seen."""
    rows = dict.fromkeys(line for text in texts for line in text.splitlines() if line.strip() and not line.startswith('#'))
    return list(rows)


def remember_shaders(game: Game, device: str, bundle: str) -> None:
    """The game records each shader and pipeline it meets on the TV, in Library/Caches, and warms them at launch. That file goes when the app or the cache goes, and the game then stalls on
    each one again, so a copy stays beside the game. A game that has not run yet has nothing to copy."""
    saved = game.build / SHADER_LIST
    with tempfile.TemporaryDirectory() as folder:
        copy = Path(folder) / 'pso_user.tsv'
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', f'{CACHES}/pso_user.tsv', '--destination', copy])
        if copy.is_file():
            rows = merged_rows(saved.read_text() if saved.is_file() else '', copy.read_text())
            saved.write_text('\n'.join(rows) + '\n')


def bundle_shaders(game: Game, project: Path) -> None:
    """Puts the saved list into the app's own prewarm list, which the app reads next to the one on the TV."""
    saved, manifest = game.build / SHADER_LIST, project / 'Gen/dm/pso_manifest.tsv'
    if saved.is_file() and manifest.is_file():
        known = manifest.read_text()
        rows = merged_rows(saved.read_text())
        manifest.write_text(known.rstrip('\n') + '\n' + '\n'.join(row for row in rows if row not in set(merged_rows(known))) + '\n')
        emit('log', line=f'{len(rows)} known shaders and pipelines go into the app.')


def compile_app(game: Game, project: Path, device: Optional[str]) -> None:
    stage('Compiling and signing')
    schemes = sorted(p.stem for p in (project / 'DmIOS.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
    if not schemes:
        raise Failure('The generated project has no scheme')
    total = max(len(list((project / 'Gen/src').iterdir())), 1) + 12
    done = [0]

    def on_line(line: str) -> None:
        if line.startswith('CompileC ') or line.startswith('CompileAssetCatalog') or line.startswith('Ld '):
            done[0] += 1
            emit('progress', value=min(done[0] / total, 0.99))

    command = ['xcodebuild', '-project', project / 'DmIOS.xcodeproj', '-scheme', schemes[0], '-configuration', 'Release', '-destination', f'platform=tvOS,id={device}' if device else 'generic/platform=tvOS',
               '-derivedDataPath', game.build / 'tvport-derived', '-allowProvisioningUpdates', 'build']
    stream(command, on_line=on_line, log_filter=lambda x: bool(REASON.search(x)) or x.startswith(('CodeSign', '** ', 'Copy game resources')))
    emit('progress', value=1.0)


ASTC_CHOICES = ('auto', 'on', 'off')


ASTC_BLOCK_CHOICES = ('matched', '4', '6')   # Block size: matched to the original (BC1 6x6, the rest 4x4), or one block for every format


def astc_blocks(args) -> tuple:
    """(block, bc1_block) for DM_NVN_BC_ASTC and DM_NVN_BC1_ASTC; (0, 0) when Compressed textures is Off. Matched keeps each texture about its Switch size: BC1 is 4 bits a texel (ASTC 6x6 is 3.56, 4x4 would be 8), BC2/3/7 are 8 bits (ASTC 4x4). No choice, or an unknown one, is Matched. Automatic is On for the Apple TV (an A15 GPU has no BC formats, so every BC texture would be stored as RGBA8: 4 to 8 times the size)."""
    if (getattr(args, 'astc', None) or 'auto') == 'off':
        return (0, 0)
    choice = str(getattr(args, 'astc_block', None) or 'matched')
    if choice == '6':
        return (6, 6)
    if choice == '4':
        return (4, 4)
    return (4, 6)


def astc_block(args) -> int:
    """The ASTC block size for DM_NVN_BC_ASTC (every format but BC1): 0 when Compressed textures is Off, else 4 or 6"""
    return astc_blocks(args)[0]


TARGET_BC_FORMATS = False   # whether the GPU TVPort builds for reads BC textures: no Apple TV's does (A8 to A15). One that does (a Mac's) draws the game's own BC textures while it encodes them


def pack_required(block: int, bc_formats: Optional[bool] = None) -> bool:
    """Whether a texture pack that could not be prepared stops the build: on a GPU without BC formats with Compressed textures on (block > 0), which Store textures once needs too.
    Without the pack every BC texture is held decoded until the game has encoded it in the background, several times its ASTC size (Ocarina of Time on the Apple TV, run 17:
    600 more textures decoded, 455 MB against 188, and the app ran out of memory). A GPU with BC formats (bc_formats, by default TARGET_BC_FORMATS) goes on without it, as before."""
    return block > 0 and not (TARGET_BC_FORMATS if bc_formats is None else bc_formats)


def pack_stopped(reason: str) -> Failure:
    """The error that ends a build whose required pack could not be prepared (pack_required), in the words the app shows"""
    return Failure(f"Build stopped: the compressed textures could not be prepared ({reason}). The Apple TV cannot read the game's own compressed textures, so without them "
                   'the game would hold its textures uncompressed, several times the memory, and a large game runs out of it. Nothing was sent to the Apple TV. '
                   'Build & Install again once the reason is fixed, or set Compressed textures to Off for this game to build without them.')


def prebuild_astc(game: Game, block: int, python: str, texture_cap: int, bc1_block: Optional[int] = None, required: bool = False) -> Optional[Path]:
    """Run the engine's prebuild (dm/gfx/tools/bntx_astc.py) over the extracted game: every BC1/2/3/7 texture encoded to ASTC on this Mac and packed into one astc-ro.pack. The game's texture cap (DM_BC_MAX_DIM in the app's env, 0 = none) goes along: only the mip levels the app keeps under it are packed. It is incremental: with the same game files, engine, block size and cap it
    returns the pack it made before at once. A failure stops the build when the pack is required (pack_required: the Apple TV); otherwise it is not fatal: the game then encodes textures while it runs (slower the first time, and the textures stay uncompressed until it has)."""
    stage('Preparing compressed textures')
    out = game.build / 'tvport-astc'
    pack = out / 'astc-ro.pack'
    try:
        stream([python, '-I', REPO / 'dm/gfx/tools/bntx_astc.py', game.romfs, '--out', out, '--block', str(block), '--bc1-block', str(bc1_block or block), '--max-dim', str(texture_cap), '--drop-cache'], cwd=REPO, log_filter=lambda line: line.startswith('astc'))
    except Failure as failure:
        reason = str(failure).splitlines()[-1][:300] if str(failure).strip() else 'no reason given'
        if required:
            raise pack_stopped(reason) from None
        # The build goes on without a pack, and so without Store textures once: until the game has encoded a texture in the background it holds it decoded, several times its ASTC size.
        # The engine's log says so too ([RED] ASTC: no prebuilt texture pack)
        emit('log', line=f'Compressed textures could not be prepared ({reason}). The game prepares them while it runs instead; '
                         'until it has, its textures take several times the memory, which a large game may not have on the Apple TV. Build & Install again once the reason is fixed.')
        return None
    if pack.is_file():
        return pack
    if required:
        raise pack_stopped('the tool finished without a pack')
    return None


TEXTURE_ONCE_CHOICES = ('auto', 'on', 'off')
BESIDE_ROMFS = ('control.nacp', 'icon.jpg', 'html', 'jit')   # what build_ipa.sh / stage_resources.sh look for next to the RomFS image they are given


def texture_once_enabled(args, block: int) -> bool:
    """Store textures once (docs/texture_once.md): Automatic is On whenever Compressed textures resolves to on (block > 0). The stripped image carries the ASTC pack, so with ASTC off there is nothing to strip against and even On does nothing."""
    return block > 0 and (getattr(args, 'texture_once', None) or 'auto') != 'off'


COMPRESS_CHOICES = ('auto', 'on', 'off')


def compress_enabled(args) -> bool:
    """Compress game data (docs/texture_once.md 7c): Automatic is On. Off keeps today's behaviour: the plain RomFS.img (or the uncompressed stripped image) and astc-ro.pack."""
    return (getattr(args, 'compress_data', None) or 'auto') != 'off'


def link_beside(game: Game, out: Path) -> None:
    for name in BESIDE_ROMFS:   # the build script finds control.nacp, the icon, html and jit beside the image it is given
        source, link = game.romfs.parent / name, out / name
        if source.exists() and not link.exists() and not link.is_symlink():
            link.symlink_to(source)


def embeds_pack(image: Path) -> bool:
    """Whether a DMSPARS1 image carries the ASTC pack (header: pack size at byte 48); a plain image or an unreadable file does not"""
    try:
        with image.open('rb') as file:
            head = file.read(64)
    except OSError:
        return False
    return len(head) == 64 and head[:8] == b'DMSPARS1' and int.from_bytes(head[48:56], 'little') != 0


def compress_game_data(game: Game, python: str) -> Optional[Path]:
    """Run tex_once.py --no-pack over RomFS.img: a lossless zstd-compressed DMSPARS1 v2 image of the game with nothing stripped. Returns that romfs.img, or None with one warning line: the game then installs as before."""
    stage('Compressing game data')
    tool = REPO / 'dm/gfx/tools/tex_once.py'
    out = game.build / 'tvport-compress'
    image = out / 'romfs.img'
    if not game.romfs:
        emit('log', line='Game data is stored uncompressed: there is no RomFS image.')
        return None
    if not tool.is_file():
        emit('log', line='Game data is stored uncompressed: this engine has no tex_once.py.')
        return None
    try:
        stream([python, '-I', tool, game.romfs, '--no-pack', '--out', out, '--compress', 'on'], cwd=REPO)
    except Failure as failure:
        emit('log', line=f'Game data is stored uncompressed: it could not be compressed ({str(failure).splitlines()[-1][:300] if str(failure) else "no reason given"}).')
        return None
    if not image.is_file():
        emit('log', line='Game data is stored uncompressed: the tool finished without an image.')
        return None
    link_beside(game, out)
    return image


def store_textures_once(game: Game, pack: Optional[Path], block: int, python: str, texture_cap: int, bc1_block: Optional[int] = None, compress: bool = False) -> Optional[Path]:
    """Run the engine's tex_once.py over RomFS.img and the ASTC pack: every plane the pack covers is zeroed in the game files (the pack holds it) and the result is one sparse image with the pack embedded. Returns that romfs.img, or None when it cannot be made, with one warning line: the feature never fails a build, and the game then goes as before with the plain RomFS.img and astc-ro.pack."""
    stage('Storing textures once')
    tool = REPO / 'dm/gfx/tools/tex_once.py'
    out = game.build / 'tvport-once'
    image = out / 'romfs.img'
    if not (game.romfs and pack and pack.is_file()):
        emit('log', line='Textures are stored twice: there is no compressed texture pack to store them once against.')
        return None
    if not tool.is_file():
        emit('log', line='Textures are stored twice: this engine has no tex_once.py.')
        return None
    try:
        stream([python, '-I', tool, game.romfs, '--pack', pack, '--out', out, '--max-dim', str(texture_cap), '--block', str(block), '--bc1-block', str(bc1_block or block), '--compress', 'on' if compress else 'off'], cwd=REPO)   # tex_once.py must take --bc1-block, as bntx_astc.py does; --compress is Compress game data (docs/texture_once.md 7c)
    except Failure as failure:
        emit('log', line=f'Textures are stored twice: they could not be stored once ({str(failure).splitlines()[-1][:300] if str(failure) else "no reason given"}).')
        return None
    if not image.is_file():
        emit('log', line='Textures are stored twice: the tool finished without an image.')
        return None
    link_beside(game, out)
    return image


def pack_fingerprint(pack: Path) -> str:
    """The input fingerprint in an astc-ro.pack's header (dm/gfx/tex/nvn_astc_cache.m): which game files, engine and block size made it; '' for a file that is not a pack"""
    with pack.open('rb') as file:
        head = file.read(80)
    return head[40:72].hex() if len(head) == 80 and head[:8] == b'NXASTCPK' else ''


TRANSIENT = re.compile(r'3002|coordinat|locate|time[ds]? ?out|connection|network|unreachable|tunnel|IXErrorDomain', re.I)   # what devicectl says when the network under it hiccups
ATTEMPTS = 3
RETRY_DELAYS = (5, 15)   # seconds before the 2nd and 3rd attempt


def with_retries(what: str, attempt):
    """attempt() returns None when it worked, or the reason it failed. A reason that looks transient (TRANSIENT) is tried again, up to ATTEMPTS times in all; any other stops at once."""
    for number in range(1, ATTEMPTS + 1):
        reason = attempt()
        if reason is None:
            return
        if number == ATTEMPTS or not TRANSIENT.search(reason):
            raise Failure(reason or f'{what} failed')
        delay = RETRY_DELAYS[min(number - 1, len(RETRY_DELAYS) - 1)]
        emit('log', line=f'{what} failed (attempt {number} of {ATTEMPTS}): {reason.strip().splitlines()[-1][:200] if reason.strip() else "no reason given"}. Trying again in {delay} s.')
        time.sleep(delay)


def send_file(what: str, source: Path, name: str, device: str, bundle: str) -> None:
    """Copy one file into the app's Library/Caches, trying again when the network hiccups"""
    def attempt():
        try:
            stream(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', source, '--destination', f'{CACHES}/{name}'])
        except Failure as failure:
            return str(failure)
        return None

    with_retries(f'Sending {what}', attempt)


def install(game: Game, device: str, bundle: str, astc_pack: Optional[Path] = None, once: Optional[Path] = None) -> None:
    """once: the sparse image of Store textures once, or the compressed image of Compress game data. It goes as romfs.img. When it carries the ASTC pack, astc_pack is not sent and a stale astc-ro.pack is emptied; a compressed image without a pack (embeds_pack) goes with astc_pack beside it, as before."""
    stage('Installing on the Apple TV')
    if not game.app or not (game.app / 'embedded.mobileprovision').is_file():
        raise Failure('Build the app first: there is no signed app to install')

    def install_app():
        result = run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, game.app])
        return None if not result.returncode else (result.stderr.strip() or result.stdout.strip())[-900:] or 'The install failed'

    with_retries('The install', install_app)
    stage('Checking the game files on the Apple TV')
    image = once or game.romfs
    size = image.stat().st_size
    files = installed_files(device, bundle)
    # A stripped image of the same size can hold other textures (another cap or block size), so its size alone is not enough: the stamp names the file that last arrived whole.
    stamp = image.with_name(image.name + '.sent') if once else None
    mine = f'{device} {bundle} {size} {image.stat().st_mtime_ns}'
    if files.get('romfs.img') == size and (not stamp or (stamp.is_file() and stamp.read_text() == mine)):
        emit('log', line='The game files are already on the Apple TV.')
    else:
        if stamp:
            stamp.unlink(missing_ok=True)
        emit('log', line=f'Sending the game files ({size / 2**30:.1f} GB). This takes a few minutes over the network.')
        send_file('the game files', image, 'romfs.img', device, bundle)
        there = installed_files(device, bundle).get('romfs.img')
        if there != size:
            raise Failure(f'The game files did not arrive whole: the Apple TV has {there if there is not None else "no"} bytes of romfs.img, this Mac has {size}. Build & Install again to resend them.')
        if stamp:
            stamp.write_text(mine)
        emit('log', line='The game files on the Apple TV match this Mac.')
    if once and embeds_pack(once):
        empty_stale_pack(once, device, bundle, files.get('astc-ro.pack'))
    elif astc_pack:
        install_astc_pack(astc_pack, device, bundle, files.get('astc-ro.pack'))


def empty_stale_pack(once: Path, device: str, bundle: str, there: Optional[int]) -> None:
    """The sparse image embeds the pack, so an astc-ro.pack from an earlier build is dead weight (several GB). devicectl (Xcode 26: device copy to/from, device info files, no delete or move for a file in an app container) cannot remove it, so it is overwritten with an empty file: the engine's pack reader (dm/gfx/tex/nvn_astc_cache.m pack_open) ignores a file shorter than its 80-byte header, and the embedded pack takes precedence over it anyway. Never fatal: a leftover costs only space."""
    if not there:   # absent, or already emptied
        return
    empty = once.with_name('astc-ro.pack.empty')
    empty.write_bytes(b'')
    emit('log', line=f'Emptying the old compressed textures on the Apple TV ({there / 2**30:.1f} GB): the game files carry them now.')
    try:
        send_file('the empty file', empty, 'astc-ro.pack', device, bundle)
    except Failure as failure:
        emit('log', line=f'The old compressed textures could not be emptied ({str(failure).splitlines()[-1][:200] if str(failure) else "no reason given"}); they only take space. Build & Install again to retry.')
        return
    left = installed_files(device, bundle).get('astc-ro.pack')
    if left:
        emit('log', line=f'The old compressed textures are still on the Apple TV ({left} bytes); they only take space.')
    else:
        emit('log', line='The old compressed textures are gone from the Apple TV.')   # (a later build without Store textures once sees size 0 there and resends the pack)


def install_astc_pack(pack: Path, device: str, bundle: str, there: Optional[int]) -> None:
    """Send astc-ro.pack beside romfs.img (one file: tens of thousands of small ones would take far longer). The size alone does not say it is this pack, so the fingerprint of the last pack that arrived whole is kept beside it."""
    size = pack.stat().st_size
    stamp = pack.with_name(pack.name + '.sent')
    mine = f'{device} {bundle} {size} {pack_fingerprint(pack)}'
    if there == size and stamp.is_file() and stamp.read_text() == mine:
        emit('log', line='The compressed textures are already on the Apple TV.')
        return
    emit('log', line=f'Sending the compressed textures ({size / 2**30:.1f} GB).')
    stamp.unlink(missing_ok=True)
    send_file('the compressed textures', pack, 'astc-ro.pack', device, bundle)
    arrived = installed_files(device, bundle).get('astc-ro.pack')
    if arrived != size:
        raise Failure(f'The compressed textures did not arrive whole: the Apple TV has {arrived if arrived is not None else "no"} bytes of astc-ro.pack, this Mac has {size}. Build & Install again to resend them.')
    stamp.write_text(mine)
    emit('log', line='The compressed textures on the Apple TV match this Mac.')


def one_build_at_a_time():
    """Two builds would write the same project and race each other's install on the TV. The system drops this lock when the process ends, however it ends."""
    path = DATA / 'build.lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Failure('Another TVPort build is already running. Wait for it to finish.')
    return lock


def relocate_build(game: Game) -> Game:
    """Copy an existing build to its chosen location without deleting the original."""
    if not game.storage_root.is_dir():
        raise Failure('The selected build folder is unavailable. Connect its drive or choose another folder in settings.')
    if not game.build or game.build.parent == game.build_parent:
        return game
    destination = game.build_parent / game.build.name
    if destination.exists():
        raise Failure('The destination already contains a build. Choose another build folder before continuing.')
    stage('Copying the existing build to its new folder')
    game.build_parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.tvport-copy-', dir=game.build_parent))
    try:
        shutil.copytree(game.build, staging, symlinks=True, dirs_exist_ok=True)
        staging.rename(destination)
    except OSError as error:
        raise Failure(f'The build could not be copied. The original is unchanged: {error}') from error
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    emit('log', line=f'Build copied to {destination}. Original kept at {game.build}.')
    return Game(game.folder)


def cmd_build(args) -> None:
    extra_env_pairs(getattr(args, 'extra_env', None) or [])   # a bad switch stops the build before anything slow
    lock = one_build_at_a_time()   # held until this process exits
    game = Game(args.folder)
    team = args.team or known_team()
    if not team:
        raise Failure('No Apple signing team found. Open Xcode, sign in under Settings > Accounts, and build any app for the Apple TV once.')
    game = relocate_build(game)
    if BUNDLED:
        prune_engines(REPO)
    python = engine_python()
    os.environ['PATH'] = os.pathsep.join([str(Path(python).parent), os.environ.get('PATH', '')])   # the engine's own `python3` calls (build_ipa.sh) take this one, not the system's 3.9
    signature = game.input_signature()
    if game.addons:
        stage('Checking updates and DLC')
        check_addons(game, [item['path'] for item in game.addons], args.keys, python)
    previous_signature = game.state().get('source_signature')
    if not game.prepared or ((previous_signature or game.addons) and previous_signature != signature):
        game = prepare_game(game, args.keys, team, python, args)
    else:
        why = engine_change(game)
        if why:
            # build_ipa_from_nsp.py reuses the extract, the shaders and every rewritten module whose inputs are unchanged, so this redoes only the rewrite
            if getattr(game, 'keyless', False) or (args.keys and Path(args.keys).is_file()) or find_keys(game):
                emit('log', line=f"The engine's patches for this game changed ({why}): rewriting the game's code again.")
                game = prepare_game(game, args.keys, team, python, args)
            else:
                emit('log', line=f"The engine's patches for this game changed ({why}), but prod.keys was not found, so the game's code is not rewritten again this time.")
    bundle = game.bundle_id(team)
    block, bc1_block = astc_blocks(args)
    pack = prebuild_astc(game, block, python, args.texture_cap, bc1_block, pack_required(block)) if block else None   # the game's files are extracted: encode its BC textures once, here; without them an Apple TV build stops here, before anything is sent
    if args.device:
        remember_shaders(game, args.device, bundle)
        stage('Backing up saves to this Mac')
        backup = backup_saves(game, args.device, bundle, icloud=args.icloud)
        emit('log', line={'backed-up': f'{backup["files"]} save files backed up.', 'unchanged': 'The saves on this Mac are already up to date.', 'none': 'No saves on the Apple TV yet.',
                          'unavailable': 'The saves on the Apple TV could not be read, so this build goes ahead without a new backup.',
                          'busy': 'The game kept saving during each copy, so this build goes ahead without a new backup.'}[backup['state']])
    compress = compress_enabled(args)
    once = store_textures_once(game, pack, block, python, args.texture_cap, bc1_block, compress) if pack and texture_once_enabled(args, block) else None
    if once is None and compress:
        once = compress_game_data(game, python)   # no stripped image: the compressed whole RomFS.img (install sends the ASTC pack beside it when it does not carry one)
    # The Xcode project reads the PLAIN RomFS.img (resources it copies, romfs.id identity): its build-phase scripts run on the system
    # Python (3.9, no zstd module), which cannot read a compressed DMSPARS1 v2 image. Stripping and compressing never change the
    # logical index or size, so the identity is the same and the app accepts the stripped/compressed image install() sends.
    project = generate_project(game, args, team, bundle, python, None)
    bundle_shaders(game, project)
    compile_app(game, project, args.device)
    game.save_state(bundle_id=bundle, art=str(args.art) if args.art else None, mode=args.mode, texture_cap=args.texture_cap, render_scale=args.render_scale, res_scale=getattr(args, 'res_scale', 1.0), upscaler=getattr(args, 'upscaler', 'game'), source_signature=signature, profile_signature=profile_signature(game))
    if args.device:
        install(game, args.device, bundle, pack, once)
        restored = restore_saves(game, args.device, bundle)
        if restored:
            emit('log', line=f'The Apple TV had lost its saves: {restored} files put back from this Mac.')
    emit('done', bundle_id=bundle, app=str(game.app), signing=provisioning(game.app))


def cmd_backup(args) -> None:
    game = Game(args.folder)
    if not game.build:
        raise Failure('This game has not been built yet, so it has no saves.')
    print(json.dumps(backup_saves(game, args.device, args.bundle, icloud=args.icloud)))


def build_running() -> bool:
    try:
        lock = one_build_at_a_time()
    except Failure:
        return True
    lock.close()
    return False


def cmd_autobackup(args) -> None:
    """Read all supported installed games, including games built on another Mac.
    Managed backups cover every player, including persistent-only saves, and
    are available in Manage Saves even when there is no local build folder.
    """
    from save_import import SaveImporter
    out = {'state': 'done', 'games': {}, 'icloud': ICLOUD.is_dir()}
    try:
        lock = one_build_at_a_time()
    except Failure:
        out['state'] = 'building'
        print(json.dumps(out))
        return
    with lock:
        importer = SaveImporter(sys.modules[__name__], icloud=args.icloud)
        try:
            apps = [app for app in importer.apps(args.device) if app['compatible']]
        except (Failure, OSError, ValueError) as failure:
            out.update(state='unreachable', message=str(failure))
            print(json.dumps(out))
            return
        local = {}
        for folder in args.folder:
            try:
                game = Game(Path(folder)) if Path(folder).is_dir() else None
                app = game.earlier_app() if game and game.build else None
                bundle = game and game.build and (game.state().get('bundle_id') or app and plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'])
                if bundle:
                    local[bundle] = (folder, game)
            except (Failure, OSError, ValueError, KeyError):
                continue
        for app in apps:
            bundle = app['id']
            folder, game = local.get(bundle, (bundle, None))
            try:
                status = importer.automatic_backup(args.device, bundle)
            except (Failure, OSError, ValueError) as failure:
                status = {'state': 'failed', 'checked': None, 'message': str(failure)}
            out['games'][folder] = status
            if status['state'] == 'failed':
                out['state'] = 'partial'
            # A single inaccessible app must not prevent the other games being checked.
    print(json.dumps(out))


def running_pids(listing: dict, executable: str = 'DmIOS') -> list:
    return [p.get('processIdentifier') for p in listing.get('result', {}).get('runningProcesses', []) if f'/{executable}.app/' in str(p.get('executable', ''))]


def cmd_launch(args) -> None:
    # devicectl's --terminate-existing launches at once, and the Home screen coming back can then land on top of the new launch: tvOS suspends it during startup, which looks like a hang.
    # So the old instance goes first, and the Home screen gets a moment to settle.
    pids = running_pids(devicectl_json('device', 'info', 'processes', '--device', args.device))
    for pid in pids:
        run(['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', args.device, '--pid', pid])
    if pids:
        time.sleep(LAUNCH_SETTLE_S)
    result = run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device, args.bundle])
    if result.returncode:
        message = result.stdout + result.stderr
        raise Failure('The Apple TV is asleep. Wake it with the remote, then try again.' if 'asleep' in message else message.strip()[-700:])
    print(json.dumps({'launched': args.bundle}))


NUMBER = r'(-?[\d.]+)'
MEMORY_LINE = re.compile(rf'memory up to frame (\d+): resident {NUMBER} MB, GPU allocated {NUMBER} MB')
HEADROOM = re.compile(rf'headroom to the system memory limit {NUMBER} MB')
LONG_FRAME = re.compile(rf'\[longframe\] frame (\d+) \({NUMBER} s\) whole frame {NUMBER} ms, submit\+present {NUMBER} ms, GPU {NUMBER} ms; new pipelines (\d+) \+ shader libraries (\d+), {NUMBER} ms in all; '
                        rf'texture uploads (\d+) first \+ (\d+) re-uploads, {NUMBER} MB / {NUMBER} ms')
ON_SCREEN = re.compile(rf'on-screen up to frame (\d+): (\d+) frames, dropped (\d+).*?footprint (\d+) MiB')
HITCH_MS = 33.4   # a frame that misses two refreshes at 60 Hz


def read_log(text: str) -> dict:
    """What one run's log.txt says about memory and long frames."""
    memory = [(int(m[1]), float(m[2]), float(m[3])) for m in MEMORY_LINE.finditer(text)]
    headroom = [float(x) for x in HEADROOM.findall(text)]
    footprints = [int(m[4]) for m in ON_SCREEN.finditer(text)]
    frames = [{'frame': int(m[1]), 'ms': float(m[3]), 'gpu': float(m[5]), 'pipelines': float(m[8]), 'textures': float(m[12]), 'uploads': int(m[9])} for m in LONG_FRAME.finditer(text)]
    hitches = [f for f in frames if f['ms'] >= HITCH_MS]
    last_frame = max([m[0] for m in memory] + [int(m[1]) for m in ON_SCREEN.finditer(text)], default=0)
    return {'last_frame': last_frame, 'peak_mb': max([m[1] for m in memory] + footprints, default=0), 'gpu_mb': max((m[2] for m in memory), default=0), 'min_headroom_mb': min(headroom, default=None),
            'hitches': len(hitches), 'worst_ms': max((f['ms'] for f in frames), default=0), 'texture_ms': round(sum(f['textures'] for f in hitches), 1), 'pipeline_ms': round(sum(f['pipelines'] for f in hitches), 1),
            'gpu_slow_frames': len([f for f in frames if f['gpu'] > 16.7]), 'ended_on_precompile': text.rstrip().split('\n')[-1:] and 'parallel precompile' in text.rstrip().split('\n')[-1]}


def read_jetsam(folder: Path, process: str = 'DmIOS') -> list:
    """Times tvOS ended this app for memory; an out-of-memory kill leaves only these reports, no crash report."""
    kills = []
    for path in sorted(folder.rglob('JetsamEvent-*.ips')):
        lines = path.read_text(errors='replace').split('\n', 1)
        if len(lines) < 2:
            continue
        try:
            report = json.loads(lines[1])
        except json.JSONDecodeError:
            continue
        page = report.get('memoryStatus', {}).get('pageSize', 16384)
        for entry in report.get('processes', []):
            if entry.get('name') == process and entry.get('reason'):
                kills.append({'time': report.get('date', path.stem), 'reason': entry['reason'], 'mb': entry.get('rpages', 0) * page >> 20})
    return sorted(kills, key=lambda kill: kill['time'])   # oldest first by the report's own date: the newest can sit beside older ones in Retired/, whose path sorts after it


def verdicts(run_log: dict, kills: list) -> list:
    """Plain sentences for the person, each from a number above."""
    out = []
    if kills:
        last = kills[-1]
        out.append(f'tvOS ended the game for using too much memory ({last["mb"]:,} MB, {last["reason"]}) at {last["time"][:19]}. Most of that is the game itself, so Texture Detail helps only a little.')
    headroom = run_log['min_headroom_mb']
    if headroom is not None and headroom < 200:
        out.append(f'Memory is tight: {headroom:.0f} MB from the limit at its lowest. A scene load can end the game.')
    if run_log['hitches']:
        if run_log['texture_ms'] > run_log['pipeline_ms'] * 2:
            out.append(f'{run_log["hitches"]} long frames, mostly texture loading ({run_log["texture_ms"]:.0f} ms against {run_log["pipeline_ms"]:.0f} ms of shaders). Lower Texture Detail.')
        elif run_log['pipeline_ms'] > run_log['texture_ms'] * 2:
            out.append(f'{run_log["hitches"]} long frames, mostly first-use shaders ({run_log["pipeline_ms"]:.0f} ms). They fade as the game sees each scene once.')
        else:
            out.append(f'{run_log["hitches"]} long frames: {run_log["texture_ms"]:.0f} ms of texture loading, {run_log["pipeline_ms"]:.0f} ms of shaders.')
    if run_log['gpu_slow_frames']:
        out.append(f'{run_log["gpu_slow_frames"]} slow frames took the GPU over 16.7 ms. Handheld mode lowers its load.')
    if not out and run_log['last_frame']:
        out.append(f'Nothing unusual up to frame {run_log["last_frame"]:,}, with memory at {run_log["peak_mb"]:,.0f} MB. If the game closed by itself, tvOS most likely ended it for memory: a sudden spike can miss these readings, and tvOS does not always file a report.')
    return out


def cmd_diagnose(args) -> None:
    with tempfile.TemporaryDirectory() as folder:
        folder = Path(folder)
        try:
            copied = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle, '--source', f'{CACHES}/log.txt', '--destination', folder / 'log.txt'], timeout=30)
        except subprocess.TimeoutExpired as error:
            raise Failure('The Apple TV did not respond. Wake it and check the connection, then press Refresh.') from error
        if copied.returncode or not (folder / 'log.txt').is_file():
            raise Failure('Could not read the game log. Check that the Apple TV is awake and connected and the game has been played, then press Refresh.')
        # System reports are optional; an unavailable report must not hide the game log.
        try:
            run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'systemCrashLogs', '--source', '.', '--destination', folder / 'reports'], timeout=10)
        except subprocess.TimeoutExpired:
            pass
        log = (folder / 'log.txt').read_text(errors='replace')
        run_log, kills = read_log(log), read_jetsam(folder / 'reports')
        print(json.dumps({'run': run_log, 'kills': kills[-5:], 'verdicts': verdicts(run_log, kills[-1:]), 'log': log}))


def cmd_save_import(args) -> None:
    from save_import import SaveImporter
    importer = SaveImporter(sys.modules[__name__], icloud=getattr(args, 'icloud', False))
    try:
        if args.command == 'installed-games':
            answer = {'apps': importer.apps(args.device)}
        elif args.command == 'saved-games':
            answer = importer.saved_games(args.device)
        elif args.command == 'save-targets':
            answer = {'slots': importer.targets(args.device, args.bundle), 'backups': importer.history(args.device, args.bundle)}
        elif args.command == 'save-source':
            answer = importer.source(args.folder)
        elif args.command == 'save-history':
            answer = {'backups': importer.history(args.device, args.bundle)}
        else:
            with one_build_at_a_time():
                if args.command == 'store-save':
                    answer = importer.store_import(args.device, args.bundle, args.slot, args.folder, args.name, args.version, args.title_id)
                elif args.command == 'restore-save':
                    answer = importer.restore(args.device, args.bundle, args.backup, args.slot)
                elif args.command == 'export-save':
                    answer = importer.export(args.device, args.bundle, args.slot)
                elif args.command == 'export-all-saves':
                    answer = importer.export_all(args.device)
                else:
                    answer = importer.transfer(args.device, args.bundle, args.slot, args.folder)
        answer['icloud_available'] = importer.icloud_available
        print(json.dumps(answer))
    except (OSError, ValueError) as error:
        raise Failure(f'The save operation could not complete: {error}') from error


# ---- SwitchTV: the launcher app on the Apple TV. It is its own project (github.com/brad-n/SwitchTV, the submodule tvport/switchtv) with its own build tool, tvport/switchtv/switchtv.py;
# what is TVPort's own is here: its library as the tool's games file, its cache folder, its signing team, and when to refresh the app on the Apple TV ----


def switchtv_cache() -> Path:
    """Where the title database, banners and the build of SwitchTV live: TVPORT_SWITCHTV_CACHE, else inside TVPort's own data folder."""
    return Path(os.environ.get('TVPORT_SWITCHTV_CACHE') or DATA / 'switchtv-cache')


def read_library() -> list:
    try:
        library = json.loads((DATA / 'library.json').read_text())
    except (OSError, ValueError):
        return []
    return library if isinstance(library, list) else []


def switchtv_state_file() -> Path:
    return switchtv_cache() / 'installed.json'


def switchtv_state() -> dict:
    try:
        return json.loads(switchtv_state_file().read_text())
    except (OSError, ValueError):
        return {}


def game_bundle_id(item: dict, team: str) -> str:
    """The game's app bundle ID from its saved build state; the standard one when the build folder is not at hand."""
    try:
        return Game(Path(item['folder'])).bundle_id(team)
    except (Failure, OSError, KeyError, ValueError):
        return f'dev.tvport.{team.lower()}.g{item["titleID"].lower()}'


SWITCHTV_JSON = re.compile(r'^\{"switchtv": true')   # the last line `switchtv.py ... --json` prints


def switchtv_tool() -> Path:
    tool = REPO / 'tvport/switchtv/switchtv.py'
    if not tool.is_file():
        raise Failure('The SwitchTV project is not checked out (tvport/switchtv is empty). Run: git submodule update --init')
    return tool


def switchtv_games(library: list, team: str, data: Optional[Path] = None) -> list:
    """The library's built games as SwitchTV's games file (switchtv.py: README, "The games file"): title ID, name, the game app's bundle ID, the artwork TVPort has for it and the shop banner that artwork came from."""
    data = data or DATA
    try:
        sources = json.loads((data / 'artwork/sources.json').read_text())
    except (OSError, ValueError):
        sources = {}
    games = []
    for item in library:
        if not (isinstance(item, dict) and item.get('built') and re.match(r'^[0-9A-Fa-f]{16}$', item.get('titleID') or '')):
            continue
        title_id = item['titleID'].upper()
        game = {'titleID': title_id, 'name': item.get('name') or title_id, 'bundleID': game_bundle_id(item, team)}
        if (data / 'artwork' / f'{title_id}.jpg').is_file():
            game['artwork'] = str(data / 'artwork' / f'{title_id}.jpg')
        if sources.get(title_id):
            game['artworkSource'] = sources[title_id]
        games.append(game)
    return games


def run_switchtv_tool(arguments: list) -> dict:
    """Runs switchtv.py with `arguments`, its output as log events; returns the summary it prints last (--json)."""
    summary: dict = {}

    def on_line(line: str) -> None:
        if SWITCHTV_JSON.match(line):
            summary.update(json.loads(line))

    stream([sys.executable, switchtv_tool(), *arguments, '--json'], env={**os.environ, 'PATH': os.pathsep.join(TOOL_PATHS + [os.environ.get('PATH', '')])}, on_line=on_line,
           log_filter=lambda line: not SWITCHTV_JSON.match(line))
    return summary


def prepare_switchtv(team: str) -> tuple:
    """SwitchTV's catalogue of the library, made into the cache folder; returns (catalogue folder, catalogue, fingerprint). Nothing is built yet."""
    cache = switchtv_cache()
    stage('Making the SwitchTV catalogue')
    cache.mkdir(parents=True, exist_ok=True)
    games_file, catalog_out = cache / 'games.json', cache / 'catalog'
    games_file.write_text(json.dumps({'games': switchtv_games(read_library(), team)}, indent=1))
    summary = run_switchtv_tool(['catalog', '--games', games_file, '--out', catalog_out, '--cache', cache])
    if not summary.get('fingerprint'):
        raise Failure('The SwitchTV catalogue could not be made')
    catalog = json.loads((catalog_out / 'catalog.json').read_text())
    return catalog_out, catalog, summary['fingerprint']


def compile_switchtv(work: Path, device: Optional[str], team: str, simulator: bool = False) -> Path:
    """Builds SwitchTV from the catalogue folder `work` (what prepare_switchtv made); returns the .app."""
    stage('Building SwitchTV')
    arguments = ['build', '--out', work, '--cache', switchtv_cache()]
    arguments += ['--simulator'] if simulator else ['--team', team] + (['--device', device] if device else [])
    summary = run_switchtv_tool(arguments)
    app = Path(summary.get('app') or '')
    if not app.is_dir():
        raise Failure('SwitchTV was built but its app is missing')
    return app


def install_switchtv(app: Path, device: str) -> None:
    stage('Installing SwitchTV on the Apple TV')

    def install_app():
        result = run([sys.executable, switchtv_tool(), 'install', '--app', app, '--device', device])
        return None if not result.returncode else (result.stderr.strip() or result.stdout.strip())[-900:] or 'The install failed'

    with_retries('The SwitchTV install', install_app)


def sync_switchtv(device: str, team: str, *, force: bool = False, prepare=None, compile_app=None, install_app=None) -> str:
    """Make the SwitchTV on `device` match the library: 'unchanged' when its fingerprint is the one last installed there, else it is built and installed ('installed').
    Cheap when nothing changed: only the catalogue is made (no Xcode)."""
    prepare, compile_app, install_app = prepare or prepare_switchtv, compile_app or compile_switchtv, install_app or install_switchtv
    work, catalog, fingerprint = prepare(team)
    state = switchtv_state()
    if not force and state.get(device) == fingerprint:
        emit('log', line='SwitchTV on the Apple TV already lists these games.')
        return 'unchanged'
    app = compile_app(work, device, team)
    install_app(app, device)
    state[device] = fingerprint
    switchtv_state_file().write_text(json.dumps(state, indent=1))
    emit('log', line=f'SwitchTV installed with {len(catalog["games"])} games.')
    return 'installed'


def cmd_switchtv(args) -> None:
    lock = one_build_at_a_time()   # SwitchTV's project is shared like a game's
    team = args.team or known_team()
    if not team and not (args.action == 'build' and args.simulator):
        raise Failure('No Apple signing team found. Open Xcode, sign in under Settings > Accounts, and build any app for the Apple TV once.')
    if args.action == 'catalog':
        work, catalog, fingerprint = prepare_switchtv(team or '')
        emit('done', games=len(catalog['games']), fingerprint=fingerprint, project=str(work))
        return
    if args.action == 'build':
        work, catalog, fingerprint = prepare_switchtv(team or '')
        app = compile_switchtv(work, args.device, team or '', simulator=args.simulator)
        emit('done', app=str(app), games=len(catalog['games']), fingerprint=fingerprint)
        return
    if not args.device:
        raise Failure('Choose an Apple TV first')
    result = sync_switchtv(args.device, team, force=args.action == 'install' or args.force)
    emit('done', result=result)


def main() -> int:
    global REPO
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('devices')
    installed = commands.add_parser('installed-games')
    installed.add_argument('--device', required=True)
    saved = commands.add_parser('saved-games')
    saved.add_argument('--device', default='')
    targets = commands.add_parser('save-targets')
    targets.add_argument('--device', required=True)
    targets.add_argument('--bundle', required=True)
    source = commands.add_parser('save-source')
    source.add_argument('folder', type=Path)
    importing = commands.add_parser('import-save')
    importing.add_argument('folder', type=Path)
    importing.add_argument('--device', required=True)
    importing.add_argument('--bundle', required=True)
    importing.add_argument('--slot', required=True)
    storing = commands.add_parser('store-save')
    storing.add_argument('folder', type=Path)
    storing.add_argument('--device', required=True)
    storing.add_argument('--bundle', required=True)
    storing.add_argument('--slot', default='save')
    storing.add_argument('--name', default='')
    storing.add_argument('--version', default='')
    storing.add_argument('--title-id', default='')
    storing.add_argument('--icloud', action='store_true')
    restoring = commands.add_parser('restore-save')
    restoring.add_argument('--device', required=True)
    restoring.add_argument('--bundle', required=True)
    restoring.add_argument('--backup', required=True)
    restoring.add_argument('--slot')
    history = commands.add_parser('save-history')
    history.add_argument('--device', required=True)
    history.add_argument('--bundle', required=True)
    exporting = commands.add_parser('export-save')
    exporting.add_argument('--device', required=True)
    exporting.add_argument('--bundle', required=True)
    exporting.add_argument('--slot', required=True)
    export_all = commands.add_parser('export-all-saves')
    export_all.add_argument('--device', required=True)
    for command in (importing, restoring, exporting, export_all):
        command.add_argument('--icloud', action='store_true')
    inspect = commands.add_parser('inspect')
    inspect.add_argument('folder', type=Path)
    addons = commands.add_parser('check-addons')
    addons.add_argument('folder', type=Path)
    addons.add_argument('--source', action='append', required=True)
    addons.add_argument('--keys', type=Path)
    preview = commands.add_parser('preview')
    preview.add_argument('--art', type=Path, required=True)
    preview.add_argument('--out', type=Path, required=True)
    preview.add_argument('--top-shelf', action='store_true')
    build = commands.add_parser('build')
    build.add_argument('folder', type=Path)
    build.add_argument('--keys', type=Path)
    build.add_argument('--team')
    build.add_argument('--device')
    build.add_argument('--art', type=Path)
    build.add_argument('--mode', choices=('handheld', 'docked'), default='handheld')
    build.add_argument('--texture-cap', type=int, choices=TEXTURE_CAPS, default=512)
    build.add_argument('--render-scale', type=render_scale_arg, default=1.0)
    build.add_argument('--res-scale', type=res_scale_arg, default=1.0)   # DM_RES_SCALE: the engine-wide resolution scale, for a game whose shaders have the rescale code
    build.add_argument('--no-thermal-cap', action='store_true')
    build.add_argument('--upscaler', choices=tuple(UPSCALER_ENV), default='game')   # game: the game's own; metalfx: MetalFX spatial scaler; off: bilinear, the most GPU headroom
    build.add_argument('--fps-target', type=int, choices=(0, 30, 60), default=0)   # 0: the profile's
    build.add_argument('--swap-ab-xy', action='store_true')
    build.add_argument('--swap-ab', action='store_true', default=None)
    build.add_argument('--swap-xy', action='store_true', default=None)
    build.add_argument('--fps', action='store_true')
    build.add_argument('--allow-damaged-manual', action='store_true')
    build.add_argument('--nx-extract-arg', action='append', default=[])
    build.add_argument('--pso-mtl4', action='store_true')
    build.add_argument('--guest-file', choices=('on', 'off'))   # unset: the engine's default for the target
    build.add_argument('--astc', choices=ASTC_CHOICES, default='auto')   # Compressed textures: auto is on for the Apple TV
    build.add_argument('--compress-data', choices=COMPRESS_CHOICES, default='auto')   # Compress game data: auto is on
    build.add_argument('--texture-once', choices=TEXTURE_ONCE_CHOICES, default='auto')   # Store textures once: auto is on whenever Compressed textures is
    build.add_argument('--astc-block', choices=ASTC_BLOCK_CHOICES, default='matched')   # matched to the original (BC1 6x6, the rest 4x4), or 4x4 / 6x6 for every format
    build.add_argument('--gpu', default='')
    build.add_argument('--extra-env', action='append', default=[])   # KEY=VALUE
    build.add_argument('--players', default='')
    build.add_argument('--icloud', action='store_true')
    for command in (preview, build):
        command.add_argument('--shelf-art', type=Path)
        command.add_argument('--shelf-scale', type=art_scale_arg, default=0.0)
        command.add_argument('--shelf-x', type=art_position_arg, default=0.0)
        command.add_argument('--shelf-y', type=art_position_arg, default=0.0)
        command.add_argument('--art-scale', type=art_scale_arg, default=0.0)
        command.add_argument('--art-x', type=art_position_arg, default=0.0)
        command.add_argument('--art-y', type=art_position_arg, default=0.0)
    backup = commands.add_parser('backup')
    backup.add_argument('folder', type=Path)
    backup.add_argument('--device', required=True)
    backup.add_argument('--bundle', required=True)
    backup.add_argument('--icloud', action='store_true', help='new backups go to iCloud Drive (TVPort Saves) when it is on')
    autobackup = commands.add_parser('autobackup')
    autobackup.add_argument('--device', required=True)
    autobackup.add_argument('--folder', action='append', default=[])
    autobackup.add_argument('--icloud', action='store_true')
    launch = commands.add_parser('launch')
    launch.add_argument('--device', required=True)
    launch.add_argument('--bundle', required=True)
    diagnose = commands.add_parser('diagnose')
    diagnose.add_argument('--device', required=True)
    diagnose.add_argument('--bundle', required=True)
    switchtv = commands.add_parser('switchtv', help='the SwitchTV launcher app: catalog | build | install (always) | sync (only when the library changed)')
    switchtv.add_argument('action', choices=('catalog', 'build', 'install', 'sync'))
    switchtv.add_argument('--device')
    switchtv.add_argument('--team')
    switchtv.add_argument('--force', action='store_true', help='sync: install even when the installed SwitchTV already lists these games')
    switchtv.add_argument('--simulator', action='store_true', help='build: for the tvOS Simulator (unsigned, nothing installed)')
    commands.add_parser('doctor')
    commands.add_parser('setup')
    args = parser.parse_args()
    streamed = args.command in ('build', 'setup', 'switchtv')
    try:
        if BUNDLED:
            if args.command == 'setup':
                stage('Unpacking the engine')
            REPO = unpack_engine(HERE, DATA)
        {'devices': cmd_devices, 'inspect': cmd_inspect, 'check-addons': cmd_check_addons, 'preview': cmd_preview, 'build': cmd_build, 'backup': cmd_backup, 'launch': cmd_launch, 'diagnose': cmd_diagnose,
         'doctor': cmd_doctor, 'setup': cmd_setup, 'switchtv': cmd_switchtv, 'autobackup': cmd_autobackup,
         **{name: cmd_save_import for name in ('installed-games', 'saved-games', 'save-targets', 'save-source', 'save-history', 'store-save', 'import-save', 'export-save', 'export-all-saves', 'restore-save')}}[args.command](args)
    except Failure as failure:
        if streamed:
            emit('error', message=str(failure))
        else:
            print(json.dumps({'error': str(failure)}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

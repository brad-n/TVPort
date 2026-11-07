"""The SwitchTV catalogue: what the launcher app lists, made from TVPort's library, its artwork cache and blawar/titledb's US list.

`backend.py switchtv ...` calls this. Pure functions where it can be (a fixture library and a titledb snippet are enough to test them); the network and
`sips` are passed in, so a test needs neither.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Callable, Optional

TITLEDB_URL = 'https://raw.githubusercontent.com/blawar/titledb/master/US.en.json'
TITLEDB_MAX_AGE_S = 24 * 3600   # a list that lacks a library game is fetched again after this
NOT_GENRES = {'Other', 'Multiplayer'}   # titledb's `category` mixes genres with these two
CARD_PX, BANNER_PX = 800, 1920
SCHEME_PREFIX = 'switchtv-'
TITLE_ID = re.compile(r'^[0-9A-Fa-f]{16}$')


def scheme(title_id: str) -> str:
    """The URL scheme a game's Apple TV app answers (dm/ios/tools/build_ipa.sh DM_URL_SCHEME)."""
    return SCHEME_PREFIX + title_id.lower()


def library_games(library: list) -> list:
    """The library entries SwitchTV lists: games with a valid title ID that TVPort built."""
    return [item for item in library if isinstance(item, dict) and item.get('built') and TITLE_ID.match(item.get('titleID') or '')]


def release_date(value) -> Optional[str]:
    text = str(value or '')
    return f'{text[:4]}-{text[4:6]}-{text[6:8]}' if re.fullmatch(r'\d{8}', text) else None


def pick_entry(titledb: dict, title_id: str, banner_url: str = '') -> dict:
    """The shop product that is the game itself. The list can hold several under one title ID (the game, its Switch 2 Edition, a bundle): the one whose banner TVPort's artwork came from
    (artwork/sources.json) wins, then a non-demo product with a banner, then any."""
    candidates = [entry for entry in titledb.values() if isinstance(entry, dict) and (entry.get('id') or '').upper() == title_id.upper()]
    for entry in candidates:
        if banner_url and entry.get('bannerUrl') == banner_url:
            return entry
    return next((e for e in candidates if e.get('bannerUrl') and not e.get('isDemo')), candidates[0] if candidates else {})


def game_record(item: dict, entry: dict, bundle_id: str, card: str, banner: str) -> dict:
    """One game of catalog.json. Fields the list lacks are null / empty, and the app leaves them out."""
    title_id = item['titleID'].upper()
    players = entry.get('numberOfPlayers')
    return {
        'titleID': title_id,
        'name': item.get('name') or entry.get('name') or title_id,
        'publisher': entry.get('publisher') or None,
        'releaseDate': release_date(entry.get('releaseDate')),
        'numberOfPlayers': players if isinstance(players, int) else None,
        'genres': [g for g in entry.get('category') or [] if g not in NOT_GENRES],
        'description': entry.get('description') or None,
        'intro': entry.get('intro') or None,
        'bundleID': bundle_id,
        'scheme': scheme(title_id),
        'card': card,
        'banner': banner,
        'screenshots': [s for s in entry.get('screenshots') or [] if isinstance(s, str) and s.startswith('https://')],
    }


def sips_scale(source: Path, destination: Path, longest: int) -> None:
    """A JPEG no larger than `longest` pixels on its long side (the app bundles these, so they are kept small)."""
    result = subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '80', '-Z', str(longest), str(source), '--out', str(destination)], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'sips failed')


def download(url: str, destination: Path, timeout: float = 60) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + '.part')
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'TVPort'}), timeout=timeout) as response, partial.open('wb') as out:
        shutil.copyfileobj(response, out)
    partial.replace(destination)


def load_titledb(cache: Path, wanted: set, fetch: Callable[[str, Path], None] = download, now: Callable[[], float] = time.time, log: Callable[[str], None] = lambda _: None) -> dict:
    """titledb's US list from the cache folder, fetched once (about 90 MB) and again only when a wanted game is missing from it and it is a day old. A failed fetch keeps the old list, or none:
    the games are then listed with their library name and artwork only."""
    path = cache / 'US.en.json'
    titledb: dict = {}
    if path.is_file():
        try:
            titledb = json.loads(path.read_text())
        except ValueError:
            titledb = {}
    have = {(e.get('id') or '').upper() for e in titledb.values() if isinstance(e, dict)}
    stale = not path.is_file() or (wanted - have and now() - path.stat().st_mtime > TITLEDB_MAX_AGE_S)
    if stale:
        try:
            log('Fetching the title database (about 90 MB, once)')
            cache.mkdir(parents=True, exist_ok=True)
            fetch(TITLEDB_URL, path)
            titledb = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            log(f'The title database could not be fetched ({error}); games are listed with what the library has')
    return titledb


def build_catalog(library: list, data: Path, cache: Path, out: Path, bundle_for: Callable[[dict], str], *, fetch: Callable[[str, Path], None] = download,
                  scale: Callable[[Path, Path, int], None] = sips_scale, now: Callable[[], float] = time.time, log: Callable[[str], None] = lambda _: None) -> dict:
    """Write out/catalog.json and out/images/ for the library's built games; return the catalogue (also a summary of which fields each game has: 'fields')."""
    games = library_games(library)
    ids = {g['titleID'].upper() for g in games}
    titledb = load_titledb(cache, ids, fetch, now, log)
    try:
        sources = json.loads((data / 'artwork/sources.json').read_text())
    except (OSError, ValueError):
        sources = {}
    shutil.rmtree(out, ignore_errors=True)
    (out / 'images').mkdir(parents=True)
    records = []
    for item in sorted(games, key=lambda g: g['titleID'].upper()):
        title_id = item['titleID'].upper()
        entry = pick_entry(titledb, title_id, sources.get(title_id, ''))
        art = data / 'artwork' / f'{title_id}.jpg'
        if not art.is_file() and entry.get('bannerUrl'):
            art = cache / 'banners' / f'{title_id}.jpg'
            try:
                if not art.is_file():
                    fetch(entry['bannerUrl'], art)
            except OSError as error:
                log(f'{title_id}: the banner could not be fetched ({error})')
        card = banner = ''
        if art.is_file():
            try:
                scale(art, out / 'images' / f'{title_id}-banner.jpg', BANNER_PX)
                scale(art, out / 'images' / f'{title_id}-card.jpg', CARD_PX)
                card, banner = f'images/{title_id}-card.jpg', f'images/{title_id}-banner.jpg'
            except (OSError, RuntimeError) as error:
                log(f'{title_id}: the artwork could not be read ({error})')
        records.append(game_record(item, entry, bundle_for(item), card, banner))
    catalog = {'generated': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now())), 'games': records}
    (out / 'catalog.json').write_text(json.dumps(catalog, indent=1, ensure_ascii=False))
    return catalog


FIELDS = ('publisher', 'releaseDate', 'numberOfPlayers', 'genres', 'description', 'screenshots', 'banner')


def field_report(catalog: dict) -> dict:
    """Per game, the fields that came out empty."""
    return {g['name']: [f for f in FIELDS if not g.get(f)] for g in catalog['games']}


def fingerprint(out: Path, extra: str = '') -> str:
    """What the installed SwitchTV was made from: the catalogue (without its timestamp), its images, and `extra` (the app's sources and branding). Same fingerprint, same app."""
    catalog = json.loads((out / 'catalog.json').read_text())
    catalog.pop('generated', None)
    h = hashlib.sha256(json.dumps(catalog, sort_keys=True).encode())
    for path in sorted((out / 'images').glob('*')):
        h.update(path.name.encode())
        h.update(hashlib.sha256(path.read_bytes()).digest())
    h.update(extra.encode())
    return h.hexdigest()[:16]


def sources_digest(root: Path) -> str:
    """A digest of the SwitchTV app's own files (sources, project, branding source), so a new release of the app is installed even when the catalogue did not change."""
    h = hashlib.sha256()
    for path in sorted(p for p in root.rglob('*') if p.is_file() and 'Generated' not in p.parts and p.name != '.DS_Store'):
        h.update(str(path.relative_to(root)).encode())
        h.update(hashlib.sha256(path.read_bytes()).digest())
    return h.hexdigest()[:16]

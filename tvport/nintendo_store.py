"""Game artwork and info from Nintendo's own store, for titles blawar/titledb does not list (every Nintendo Switch 2 game).

title ID -> ec.nintendo.com/apps/<ID>/US answers a redirect whose address ends in the shop's nsuId -> the US store product page, whose embedded Next.js
data (`__NEXT_DATA__`, the Apollo state of the Product) holds the name, description, publisher, release date, genres and the images. The result is shaped like
a titledb entry so the SwitchTV catalogue reads both the same way. Python 3.9, standard library only; the network is passed in, so a test needs none.

Only a fallback: callers ask it when titledb has no entry (or no banner), and it never replaces artwork the user already has.
"""
from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from html import unescape
from pathlib import Path
from typing import Callable, Optional

APPS_URL = 'https://ec.nintendo.com/apps/{title_id}/US'
IMAGE_HOST = 'https://assets.nintendo.com/image/upload/'
USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15'
STORE_MAX_AGE_S = 24 * 3600   # a cached store answer is asked for again after this, no sooner
TITLE_ID = re.compile(r'^[0-9A-Fa-f]{16}$')
NSU_ID = re.compile(r'/pos-redirect/(\d{10,16})')
NEXT_DATA = re.compile(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', re.S)
WIDE_PX = 1920
SQUARE_PX = 1024


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class _Follow(urllib.request.HTTPRedirectHandler):
    """Python 3.9's urllib does not follow 308; the store's pages redirect with it."""
    def http_error_308(self, req, fp, code, msg, headers):
        return self.http_error_302(req, fp, code, msg, headers)

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, 302 if code == 308 else code, msg, headers, newurl)


def _open(url: str, opener, timeout: float):
    return opener.open(urllib.request.Request(url, headers={'User-Agent': USER_AGENT}), timeout=timeout)


def fetch_location(url: str, timeout: float = 20) -> str:
    """The address `url` redirects to ('' when it does not redirect)."""
    try:
        with _open(url, urllib.request.build_opener(_NoRedirect), timeout) as response:
            return response.headers.get('Location') or ''
    except urllib.error.HTTPError as error:
        if 300 <= error.code < 400:
            return error.headers.get('Location') or ''
        raise


def fetch_text(url: str, timeout: float = 30) -> str:
    with _open(url, urllib.request.build_opener(_Follow), timeout) as response:
        return response.read().decode('utf-8', 'replace')


def fetch_file(url: str, destination: Path, timeout: float = 60) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + '.part')
    with _open(url, urllib.request.build_opener(_Follow), timeout) as response:
        partial.write_bytes(response.read())
    partial.replace(destination)


def parse_redirect(location: str) -> Optional[str]:
    """The nsuId in the store redirect (.../pos-redirect/70010000130792?l=en&c=US), or None."""
    match = NSU_ID.search(location or '')
    return match.group(1) if match else None


def _plain(text: str) -> str:
    return unescape(re.sub(r'<[^>]+>', '', re.sub(r'<br\s*/?>', '\n', text or ''))).strip()


def _image_urls(public_id: str, square_url: str) -> tuple:
    """(square, wide) JPEG addresses on Nintendo's image host: the wide one is 16:9 (padded white when the art is not), the square one the store's square cut."""
    wide = f'{IMAGE_HOST}ar_16:9,c_lpad,w_{WIDE_PX}/b_white/f_jpg/q_auto/{public_id}' if public_id else ''
    square = ''
    if square_url.startswith(IMAGE_HOST):
        square = f'{IMAGE_HOST}f_jpg,q_auto,w_{SQUARE_PX}/' + square_url[len(IMAGE_HOST):].replace('q_auto/f_auto/', '', 1)
    return square, wide


def parse_product(page: str, title_id: str = '') -> Optional[dict]:
    """The product of a store page, or None when the page has none (or it is another game's). Keys: nsuId, name, description, publisher, releaseDate (YYYYMMDD int),
    genres, squareUrl, wideUrl."""
    found = NEXT_DATA.search(page or '')
    if not found:
        return None
    try:
        state = json.loads(found.group(1))['props']['pageProps']['initialApolloState']
        nsu = str(json.loads(found.group(1))['props']['pageProps']['analytics']['product']['nsuid'])
    except (ValueError, KeyError, TypeError):
        return None
    product = next((v for k, v in state.items() if k.startswith('Product:') and isinstance(v, dict) and str(v.get('nsuid')) == nsu), None)
    if not product or not product.get('name'):
        return None
    if title_id and str(product.get('applicationId') or '').upper() not in ('', title_id.upper()):
        return None   # a different title's page
    image = product.get('productImage') or {}
    square = (product.get('productImage({"shape":"square"})') or {}).get('url') or ''
    square_url, wide_url = _image_urls(image.get('publicId') or '', square)
    date = re.match(r'(\d{4})-(\d{2})-(\d{2})', str(product.get('releaseDate') or ''))
    tags = product.get('tags') if isinstance(product.get('tags'), dict) else {}
    return {
        'nsuId': nsu,
        'name': _plain(product['name']),
        'description': product.get('description') or _plain(product.get('description({"html":true})')) or None,
        'publisher': product.get('softwarePublisher') or None,
        'releaseDate': int(''.join(date.groups())) if date else None,
        'genres': [t['label'] for t in tags.get('genres') or [] if isinstance(t, dict) and t.get('label')],
        'squareUrl': square_url,
        'wideUrl': wide_url,
    }


def resolve(title_id: str, fetch_loc: Callable[[str], str] = fetch_location, fetch_page: Callable[[str], str] = fetch_text) -> Optional[dict]:
    """The store's product for a title ID, or None when the store does not know it. Network errors are raised (OSError)."""
    location = fetch_loc(APPS_URL.format(title_id=title_id.upper()))
    nsu = parse_redirect(location)
    if not nsu:
        return None
    page_url = location if location.startswith('http') else 'https://www.nintendo.com' + location
    product = parse_product(fetch_page(page_url), title_id)
    if product:
        product['nsuId'] = nsu
    return product


def cache_file(cache: Path, title_id: str) -> Path:
    return cache / 'store' / f'{title_id.upper()}.json'


def load_product(cache: Path, title_id: str, *, fetch_loc: Callable[[str], str] = fetch_location, fetch_page: Callable[[str], str] = fetch_text,
                 now: Callable[[], float] = time.time, log: Callable[[str], None] = lambda _: None) -> Optional[dict]:
    """The store product from the cache folder (cache/store/<TITLEID>.json), asked for again only when the file is over a day old. A failed fetch keeps the old data; with none,
    the answer is None and nothing is written (the next run tries again). A title the store does not know is remembered for the day too. Never raises."""
    if not TITLE_ID.match(title_id or ''):
        return None
    path = cache_file(cache, title_id)
    old: Optional[dict] = None
    try:
        old = json.loads(path.read_text())
        if not isinstance(old, dict):
            old = None
    except (OSError, ValueError):
        old = None
    if old is not None and now() - path.stat().st_mtime < STORE_MAX_AGE_S:
        return old.get('product')
    try:
        product = resolve(title_id, fetch_loc, fetch_page)
    except (OSError, ValueError) as error:   # urllib's errors are OSErrors
        log(f'{title_id}: the Nintendo store could not be reached ({error})')
        return old.get('product') if old else None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_suffix('.json.part')
        partial.write_text(json.dumps({'titleID': title_id.upper(), 'fetched': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now())), 'product': product}, indent=1, ensure_ascii=False))
        partial.replace(path)
    except OSError as error:
        log(f'{title_id}: the store answer could not be saved ({error})')
    return product


def catalog_entry(product: dict) -> dict:
    """The product as a titledb entry (what SwitchTV catalog.game_record reads)."""
    return {'id': None, 'name': product.get('name'), 'publisher': product.get('publisher'), 'releaseDate': product.get('releaseDate'), 'category': product.get('genres') or [],
            'description': product.get('description'), 'bannerUrl': product.get('wideUrl') or None, 'screenshots': []}


def merge_entry(entry: dict, product: Optional[dict]) -> dict:
    """titledb's entry when it has a banner; the store's when titledb has none; a titledb entry without a banner keeps its own fields and gains the store's banner (and any field it lacks)."""
    if not product:
        return entry
    store = catalog_entry(product)
    if not entry:
        return store
    if entry.get('bannerUrl'):
        return entry
    return {**{k: v for k, v in store.items() if v not in (None, '', [])}, **{k: v for k, v in entry.items() if v not in (None, '', [])}, 'bannerUrl': store['bannerUrl']}


def titledb_has_banner(titledb_path: Path, title_id: str) -> bool:
    """Whether the cached titledb list holds a product with a banner for the title. An unreadable or missing list says no."""
    try:
        titledb = json.loads(titledb_path.read_text())
    except (OSError, ValueError):
        return False
    wanted = title_id.upper()
    return any(isinstance(e, dict) and (e.get('id') or '').upper() == wanted and e.get('bannerUrl') for e in titledb.values())


def fallback_artwork(data: Path, cache: Path, title_id: str, *, fetch_file_fn: Callable[[str, Path], None] = fetch_file, log: Callable[[str], None] = lambda _: None, **load) -> Optional[Path]:
    """artwork/<TITLEID>.jpg for a title titledb has no banner for, from the store, with its address in artwork/sources.json. An image already there (the user's own, or titledb's) is
    returned untouched. None when there is no art and none could be fetched. Never raises."""
    if not TITLE_ID.match(title_id or ''):
        return None
    title_id = title_id.upper()
    target = data / 'artwork' / f'{title_id}.jpg'
    if target.is_file():
        return target
    if titledb_has_banner(cache / 'US.en.json', title_id):
        return None
    product = load_product(cache, title_id, log=log, **load)
    if not product or not product.get('wideUrl'):
        return None
    try:
        fetch_file_fn(product['wideUrl'], target)
    except OSError as error:
        log(f'{title_id}: the store image could not be fetched ({error})')
        return None
    try:
        sources_file = data / 'artwork' / 'sources.json'
        try:
            sources = json.loads(sources_file.read_text())
        except (OSError, ValueError):
            sources = {}
        sources[title_id] = product['wideUrl']
        partial = sources_file.with_suffix('.json.part')
        partial.write_text(json.dumps(sources))
        partial.replace(sources_file)
    except OSError as error:
        log(f'{title_id}: the artwork source could not be recorded ({error})')
    return target

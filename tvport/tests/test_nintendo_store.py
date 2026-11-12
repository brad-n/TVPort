"""The Nintendo store fallback for Switch 2 games: every network answer is a fixture (tests/fixtures/ocarina_product.html is a trimmed copy of the live store page, 2026-11-08)."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import nintendo_store as ns  # noqa: E402

OCARINA = '0400486024DEC000'
PAGE = (Path(__file__).resolve().parent / 'fixtures/ocarina_product.html').read_text()
REDIRECT = 'https://www.nintendo.com/pos-redirect/70010000130792?l=en&c=US'
PAGE_URL = 'https://www.nintendo.com/us/store/products/the-legend-of-zelda-ocarina-of-time-switch-2/'
WIDE = 'https://assets.nintendo.com/image/upload/ar_16:9,c_lpad,w_1920/b_white/f_jpg/q_auto/store/software/switch2/70010000130792/21d17919819cffebda2817f9b0110116c28568e0b6fa30a9778f1679271be809'
KART = '0100152000022000'


class Network:
    """Scripted answers; counts calls; `offline` makes every call fail."""
    def __init__(self, location=REDIRECT, page=PAGE, offline=False):
        self.location, self.page, self.offline, self.calls, self.files = location, page, offline, [], []

    def loc(self, url):
        self.calls.append(url)
        if self.offline:
            raise OSError('offline')
        return self.location

    def text(self, url):
        self.calls.append(url)
        if self.offline:
            raise OSError('offline')
        return self.page

    def file(self, url, destination):
        self.files.append(url)
        if self.offline:
            raise OSError('offline')
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b'jpeg-from-store')

    @property
    def kwargs(self):
        return {'fetch_loc': self.loc, 'fetch_page': self.text}


class ParseTests(unittest.TestCase):
    def test_redirect_parse(self):
        self.assertEqual(ns.parse_redirect(REDIRECT), '70010000130792')
        self.assertEqual(ns.parse_redirect('/pos-redirect/70010000130792/?c=US&l=en'), '70010000130792')
        for bad in ('', None, 'https://www.nintendo.com/us/', 'https://www.nintendo.com/pos-redirect/abc'):
            self.assertIsNone(ns.parse_redirect(bad))

    def test_product_parse(self):
        product = ns.parse_product(PAGE, OCARINA)
        self.assertEqual(product['nsuId'], '70010000130792')
        self.assertEqual(product['name'], 'The Legend of Zelda™: Ocarina of Time')
        self.assertEqual(product['publisher'], 'Nintendo')
        self.assertEqual(product['releaseDate'], 20261105)
        self.assertEqual(product['genres'], ['Action', 'Adventure'])
        self.assertTrue(product['description'].startswith('Take up your sword'))
        self.assertNotIn('<', product['description'])
        self.assertEqual(product['wideUrl'], WIDE)
        self.assertTrue(product['squareUrl'].startswith(ns.IMAGE_HOST + 'f_jpg,q_auto,w_1024/store/software/switch2/70010000130792/'))
        self.assertNotIn('f_auto', product['squareUrl'])

    def test_pages_without_a_product_parse_to_none(self):
        for page in ('', '<html></html>', '<script id="__NEXT_DATA__">not json</script>', '<script id="__NEXT_DATA__">{"props":{}}</script>'):
            self.assertIsNone(ns.parse_product(page))

    def test_another_titles_page_is_refused(self):
        self.assertIsNone(ns.parse_product(PAGE, '0100152000022000'))

    def test_resolve_follows_the_redirect_to_the_page(self):
        net = Network()
        product = ns.resolve(OCARINA.lower(), net.loc, net.text)
        self.assertEqual(net.calls, ['https://ec.nintendo.com/apps/0400486024DEC000/US', REDIRECT])
        self.assertEqual(product['nsuId'], '70010000130792')

    def test_a_title_the_store_does_not_know(self):
        net = Network(location='')
        self.assertIsNone(ns.resolve(OCARINA, net.loc, net.text))
        self.assertEqual(len(net.calls), 1)

    def test_merge_entry_rules(self):
        product = ns.parse_product(PAGE, OCARINA)
        titledb = {'id': KART, 'name': 'Kart', 'bannerUrl': 'https://img-eshop.cdn.nintendo.net/i/k.jpg', 'publisher': 'Nintendo'}
        self.assertIs(ns.merge_entry(titledb, product), titledb)   # a titledb entry with a banner is never touched
        self.assertEqual(ns.merge_entry({}, product)['bannerUrl'], WIDE)
        self.assertEqual(ns.merge_entry({}, None), {})
        half = ns.merge_entry({'id': KART, 'name': 'Own name', 'publisher': 'Own'}, product)   # no banner: the banner is added, titledb's fields stay
        self.assertEqual((half['name'], half['publisher'], half['bannerUrl']), ('Own name', 'Own', WIDE))
        self.assertEqual(half['category'], ['Action', 'Adventure'])


class RedirectTests(unittest.TestCase):
    def test_308_is_followed_because_python_3_9_does_not(self):
        import urllib.request
        handler = ns._Follow()
        request = urllib.request.Request('https://www.nintendo.com/a')
        new = handler.redirect_request(request, None, 308, 'Permanent Redirect', {}, 'https://www.nintendo.com/b')
        self.assertEqual(new.full_url, 'https://www.nintendo.com/b')
        self.assertTrue(hasattr(handler, 'http_error_308'))


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.cache = Path(self.temp.name) / 'cache'
        self.now = 1_800_000_000.0

    def tearDown(self):
        self.temp.cleanup()

    def load(self, net, at=None):
        return ns.load_product(self.cache, OCARINA, now=lambda: self.now if at is None else at, **net.kwargs)

    def test_first_load_fetches_and_writes_the_cache_file_keyed_by_title_id(self):
        net = Network()
        self.assertEqual(self.load(net)['name'], 'The Legend of Zelda™: Ocarina of Time')
        saved = json.loads((self.cache / 'store' / f'{OCARINA}.json').read_text())
        self.assertEqual((saved['titleID'], saved['product']['nsuId']), (OCARINA, '70010000130792'))

    def test_a_fresh_cache_is_not_fetched_again(self):
        self.load(Network())
        os.utime(self.cache / 'store' / f'{OCARINA}.json', (self.now, self.now))
        net = Network()
        self.assertEqual(self.load(net, at=self.now + 23 * 3600)['nsuId'], '70010000130792')
        self.assertEqual(net.calls, [])

    def test_a_day_old_cache_is_refreshed(self):
        self.load(Network())
        os.utime(self.cache / 'store' / f'{OCARINA}.json', (self.now, self.now))
        net = Network(page=PAGE.replace('"softwarePublisher": "Nintendo"', '"softwarePublisher": "Nintendo EPD"'))
        self.assertEqual(self.load(net, at=self.now + 25 * 3600)['publisher'], 'Nintendo EPD')
        self.assertEqual(len(net.calls), 2)

    def test_a_failed_refresh_keeps_the_old_data(self):
        self.load(Network())
        os.utime(self.cache / 'store' / f'{OCARINA}.json', (self.now, self.now))
        before = (self.cache / 'store' / f'{OCARINA}.json').read_text()
        self.assertEqual(self.load(Network(offline=True), at=self.now + 48 * 3600)['name'], 'The Legend of Zelda™: Ocarina of Time')
        self.assertEqual((self.cache / 'store' / f'{OCARINA}.json').read_text(), before)

    def test_offline_with_no_cache_is_none_and_writes_nothing(self):
        self.assertIsNone(self.load(Network(offline=True)))
        self.assertFalse((self.cache / 'store').exists())

    def test_an_unknown_title_is_remembered_for_the_day(self):
        self.assertIsNone(self.load(Network(location='')))
        os.utime(self.cache / 'store' / f'{OCARINA}.json', (self.now, self.now))
        net = Network()
        self.assertIsNone(self.load(net, at=self.now + 3600))
        self.assertEqual(net.calls, [])

    def test_a_broken_cache_file_is_fetched_again(self):
        (self.cache / 'store').mkdir(parents=True)
        (self.cache / 'store' / f'{OCARINA}.json').write_text('{oops')
        self.assertEqual(self.load(Network())['nsuId'], '70010000130792')

    def test_a_bad_title_id_is_none_without_a_request(self):
        net = Network()
        self.assertIsNone(ns.load_product(self.cache, 'nope', **net.kwargs))
        self.assertEqual(net.calls, [])


class ArtworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.data, self.cache = root / 'data', root / 'cache'
        (self.data / 'artwork').mkdir(parents=True)
        self.cache.mkdir()
        self.net = Network()

    def tearDown(self):
        self.temp.cleanup()

    def run_fallback(self, title=OCARINA, net=None):
        net = net or self.net
        return ns.fallback_artwork(self.data, self.cache, title, fetch_file_fn=net.file, **net.kwargs)

    def titledb(self, entries):
        (self.cache / 'US.en.json').write_text(json.dumps(entries))

    def test_art_lands_in_the_artwork_cache_with_its_source_recorded(self):
        self.titledb({'1': {'id': KART, 'bannerUrl': 'https://img-eshop.cdn.nintendo.net/i/k.jpg'}})
        (self.data / 'artwork/sources.json').write_text(json.dumps({KART: 'https://img-eshop.cdn.nintendo.net/i/k.jpg'}))
        art = self.run_fallback()
        self.assertEqual(art, self.data / 'artwork' / f'{OCARINA}.jpg')
        self.assertEqual(art.read_bytes(), b'jpeg-from-store')
        self.assertEqual(self.net.files, [WIDE])
        sources = json.loads((self.data / 'artwork/sources.json').read_text())
        self.assertEqual(sources[OCARINA], WIDE)
        self.assertEqual(sources[KART], 'https://img-eshop.cdn.nintendo.net/i/k.jpg')   # the others stay

    def test_works_without_a_cached_titledb(self):
        self.assertIsNotNone(self.run_fallback())

    def test_a_titledb_banner_means_no_store_request(self):
        self.titledb({'1': {'id': OCARINA, 'bannerUrl': 'https://img-eshop.cdn.nintendo.net/i/o.jpg'}})
        self.assertIsNone(self.run_fallback())
        self.assertEqual((self.net.calls, self.net.files), ([], []))

    def test_a_titledb_entry_without_a_banner_does_not_stop_it(self):
        self.titledb({'1': {'id': OCARINA, 'name': 'x'}})
        self.assertIsNotNone(self.run_fallback())

    def test_existing_artwork_is_never_replaced(self):
        mine = self.data / 'artwork' / f'{OCARINA}.jpg'
        mine.write_bytes(b'my own art')
        self.assertEqual(self.run_fallback(), mine)
        self.assertEqual(mine.read_bytes(), b'my own art')
        self.assertEqual((self.net.calls, self.net.files), ([], []))
        self.assertFalse((self.data / 'artwork/sources.json').exists())

    def test_offline_gives_no_art_and_no_error(self):
        net = Network(offline=True)
        self.assertIsNone(self.run_fallback(net=net))
        self.assertEqual(list((self.data / 'artwork').iterdir()), [])

    def test_a_failed_image_download_leaves_nothing_behind(self):
        net = Network()
        net.file = lambda url, destination: (_ for _ in ()).throw(OSError('reset'))
        self.assertIsNone(self.run_fallback(net=net))
        self.assertEqual(list((self.data / 'artwork').iterdir()), [])


if __name__ == '__main__':
    unittest.main()

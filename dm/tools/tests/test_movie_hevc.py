"""dm/tools/movie_hevc.py: the HEVC sidecars of a game's AV1 movies for the Apple TV (docs/reference/movies.md, "AV1 movies as HEVC sidecars on the Apple TV").
The WebM reader, the unit keys the host matches (temporal delimiters left out), the Annex B access units and the pack, on hand-made bytes; then the transcode itself on a short
SVT-AV1 clip, when this Mac has ffmpeg with libsvtav1, libdav1d and hevc_videotoolbox (Homebrew's): one HEVC picture per AV1 unit, an IDR at each AV1 key frame, a RomFS image
as input, a movie that is not AV1 left as it is, and --reuse. No game files."""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import movie_hevc as mh
import romfs_image


def el(eid, payload=b'', unknown=False):
    """One EBML element: its ID as written, an 8-byte size (or the unknown size)"""
    size = b'\x01\xff\xff\xff\xff\xff\xff\xff' if unknown else b'\x01' + len(payload).to_bytes(7, 'big')
    return eid.to_bytes((eid.bit_length() + 7) // 8, 'big') + size + payload


def block(track, data, flags=0x80):
    return bytes([0x80 | track]) + b'\x00\x00' + bytes([flags]) + data


def webm(units, codec=b'V_AV1', laced=False, encodings=False, audio=True):
    """A WebM as a demuxer meets it: EBML header, a Segment and a Cluster of unknown size, a video track 1 and an audio track 2 whose blocks sit between the video's,
    one video unit in a BlockGroup"""
    video = el(mh.TRACK_NUMBER, b'\x01') + el(mh.TRACK_TYPE, b'\x01') + el(mh.CODEC_ID, codec) + el(mh.EBML_VIDEO, el(mh.PIXEL_W, b'\x00\x60') + el(mh.PIXEL_H, b'\x40'))
    if encodings:
        video += el(mh.CONTENT_ENCODINGS, el(0x6240, b''))
    tracks = el(mh.EBML_TRACK, video) + (el(mh.EBML_TRACK, el(mh.TRACK_NUMBER, b'\x02') + el(mh.TRACK_TYPE, b'\x02') + el(mh.CODEC_ID, b'A_OPUS')) if audio else b'')
    cluster = el(0xE7, b'\x00')
    for k, u in enumerate(units):
        if k == 1:
            cluster += el(mh.EBML_GROUP, el(mh.BLOCK, block(1, u, 0)) + el(0xFB, b'\x01'))
        else:
            cluster += el(mh.SIMPLE_BLOCK, block(1, u, 0x82 if laced else 0x80))
        if audio:
            cluster += el(mh.SIMPLE_BLOCK, block(2, b'opus%d' % k))
    return el(0x1A45DFA3, el(0x4282, b'webm')) + el(mh.EBML_SEGMENT, el(0x1549A966, el(0x2AD7B1, b'\x0f\x42\x40')) + el(mh.EBML_TRACKS, tracks) + el(mh.EBML_CLUSTER, cluster, True), True)


def nal(t, body=b'\x01\x02'):
    return bytes([t << 1, 1]) + body


class Units(unittest.TestCase):
    def test_keys_leave_out_leading_temporal_delimiters(self):
        frame = b'\x32\x03abc'   # a frame OBU with its size field
        key, size = mh.unit_key(frame)
        self.assertEqual((key, size), (int.from_bytes(hashlib.sha256(frame).digest()[:8], 'little'), 5))
        self.assertEqual(mh.unit_key(b'\x12\x00' + frame), (key, 5))
        self.assertEqual(mh.unit_key(b'\x12\x00\x12\x00' + frame), (key, 5))
        self.assertEqual(mh.strip_delimiters(b'\x12\x00'), b'')
        self.assertEqual(mh.strip_delimiters(b'\x12\x05ab'), b'\x12\x05ab')   # a delimiter that runs past the end is not one: kept
        self.assertEqual(mh.strip_delimiters(frame + b'\x12\x00'), frame + b'\x12\x00')   # only leading ones

    def test_webm_units_in_file_order_of_the_av1_track_only(self):
        units = [b'\x0a\x01\x00key', b'\x32\x01x', b'\x32\x01y']
        w, h, got = mh.webm_units(memoryview(webm(units)))
        self.assertEqual((w, h, got), (96, 64, units))

    def test_webm_that_is_not_plain_av1_is_refused(self):
        for kw, why in (({'codec': b'V_VP9'}, 'not AV1'), ({'laced': True}, 'laced'), ({'encodings': True}, 'content encodings')):
            with self.assertRaisesRegex(mh.Unsupported, why):
                mh.webm_units(webm([b'\x0a\x01\x00', b'\x32\x01x'], **kw))
        with self.assertRaisesRegex(mh.Unsupported, 'no AV1 blocks'):
            mh.webm_units(webm([], audio=False))
        with self.assertRaisesRegex(mh.Unsupported, 'past the end'):
            mh.webm_units(webm([b'\x0a\x01\x00', b'\x32\x01x'])[:-3])


class AnnexB(unittest.TestCase):
    def test_access_units_split_at_delimiters(self):
        params = [nal(32, b'\x0c\x01'), nal(33, b'\x01\x01'), nal(34, b'\xc1')]
        idr, trail, sei = nal(19, b'\x80\x01'), nal(1, b'\x80\x00\x00\x03'), nal(39, b'\x05')
        stream = b'\x00\x00\x00\x01' + nal(35, b'\x50') + b''.join(b'\x00\x00\x01' + n for n in params + [sei, idr]) + b'\x00\x00'   # trailing zero bytes
        stream += b'\x00\x00\x00\x01' + nal(35, b'\x50') + b'\x00\x00\x01' + trail
        aus = mh.access_units(stream)
        self.assertEqual(aus, [(params, [sei, idr], True), ([], [trail], False)])
        self.assertEqual(mh.sample([sei, idr]), struct.pack('>I', len(sei)) + sei + struct.pack('>I', len(idr)) + idr)

    def test_a_stream_without_delimiters_or_pictures_is_refused(self):
        with self.assertRaisesRegex(mh.Unsupported, 'delimiter'):
            mh.access_units(b'\x00\x00\x01' + nal(19))
        with self.assertRaisesRegex(mh.Unsupported, 'without a picture'):
            mh.access_units(b'\x00\x00\x01' + nal(35) + b'\x00\x00\x01' + nal(39))

    def test_the_encode_keeps_every_picture_without_reordering(self):
        argv = mh.encode_argv('ffmpeg', 'in.webm', 'out.hevc', 65, 120)
        for words in (['-c:v', 'libdav1d', '-i'], ['-c:v', 'hevc_videotoolbox'], ['-q:v', '65'], ['-bf', '0'], ['-g', '120'], ['-force_key_frames', 'source'],
                      ['-fps_mode', 'passthrough'], ['-bsf:v', 'hevc_metadata=aud=insert'], ['-f', 'hevc']):
            self.assertIn(words, [argv[i:i + len(words)] for i in range(len(argv))], words)


class NoMovies(unittest.TestCase):
    def test_a_game_without_movies_needs_no_ffmpeg_and_gets_an_empty_pack(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'romfs/Data').mkdir(parents=True)
            (Path(d) / 'romfs/Data/a.bin').write_bytes(b'x')
            with mock.patch.object(mh, 'find_ffmpeg', return_value=None), contextlib.redirect_stdout(io.StringIO()):
                report = mh.build(Path(d) / 'romfs', Path(d) / 'out')
            self.assertEqual((report['converted'], report['movies']), (0, []))
            header, movies, entries = mh.read_pack(Path(d) / 'out' / mh.PACK)
            self.assertEqual((movies, entries), ([], []))

    def test_no_ffmpeg_is_an_error_when_there_are_movies(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'romfs').mkdir()
            (Path(d) / 'romfs/m.webm').write_bytes(webm([b'\x0a\x01\x00']))
            with mock.patch.object(mh, 'find_ffmpeg', return_value=None), self.assertRaisesRegex(RuntimeError, 'ffmpeg was not found'):
                mh.build(Path(d) / 'romfs', Path(d) / 'out')

    def test_arguments(self):
        for argv in (['r', '--out', 'o', '--quality', '0'], ['r', '--out', 'o', '--gop', '0']):
            with mock.patch.object(sys, 'argv', ['movie_hevc.py'] + argv), self.assertRaises(SystemExit) as e, contextlib.redirect_stderr(io.StringIO()):
                mh.main()
            self.assertEqual(e.exception.code, 2)


def encoders_here():
    ffmpeg = mh.find_ffmpeg()
    if not ffmpeg:
        return None
    enc = subprocess.run([ffmpeg, '-hide_banner', '-encoders'], capture_output=True, text=True).stdout
    return ffmpeg if ' libsvtav1 ' in enc and not mh.ffmpeg_ready(ffmpeg)[1] else None


@unittest.skipUnless(encoders_here(), "needs ffmpeg with libsvtav1, libdav1d and hevc_videotoolbox (Homebrew's)")
class Transcode(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.romfs = cls.root / 'romfs'
        (cls.romfs / 'Movie').mkdir(parents=True)
        ff = encoders_here()
        # 30 pictures, a key frame every 10 (SVT-AV1 with its hierarchical structure: units that only show a frame decoded earlier), and a VP9 movie the pack leaves alone
        subprocess.run([ff, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=128x72:rate=60', '-frames:v', '30', '-pix_fmt', 'yuv420p', '-c:v', 'libsvtav1', '-preset', '10',
                        '-crf', '45', '-g', '10', '-svtav1-params', 'keyint=10:scd=0', str(cls.romfs / 'Movie/a.webm')], check=True, stderr=subprocess.DEVNULL)
        subprocess.run([ff, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=64x64:rate=30', '-frames:v', '4', '-c:v', 'libvpx-vp9', str(cls.romfs / 'Movie/b.webm')], check=True)
        cls.image = cls.root / 'RomFS.img'
        romfs_image.pack(cls.romfs, cls.image)
        with contextlib.redirect_stdout(io.StringIO()):
            cls.report = mh.build(cls.image, cls.root / 'out', quality=50, workers=2)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_one_picture_per_unit_keyed_as_the_host_keys_it(self):
        r = self.report
        self.assertEqual((r['converted'], r['skipped'], r['pictures']), (1, 1, 30))
        self.assertIn('not AV1', [m for m in r['movies'] if m['path'] == 'Movie/b.webm'][0]['skipped'])
        header, movies, entries = mh.read_pack(self.root / 'out' / mh.PACK)
        self.assertEqual(header['quality'], 50)
        self.assertEqual(len(movies), 1)
        m = movies[0]
        self.assertEqual((m['name'], m['first'], m['count'], m['pictures'], m['width'], m['height']), ('Movie/a.webm', 0, 30, 30, 128, 72))
        self.assertEqual([n[0] >> 1 & 63 for n in m['params']], [32, 33, 34])
        _, _, units = mh.webm_units(memoryview((self.romfs / 'Movie/a.webm').read_bytes()))
        self.assertEqual([(e[0], e[3]) for e in entries], [mh.unit_key(u) for u in units])
        keys = [k for k, u in enumerate(units) if u[0] >> 3 & 15 == 1]   # units that open with a sequence header: the key frames
        self.assertEqual(keys, [0, 10, 20])
        self.assertTrue(all(entries[k][5] & mh.F_SYNC for k in keys))   # an IDR at each, where a stream can start
        self.assertTrue(len({e[0] for e in entries}) < len(entries))   # alike units (a shown frame decoded earlier)
        data = (self.root / 'out' / mh.PACK).read_bytes()
        for key, off, size, av1, movie, flags in entries:   # each sample is whole NAL units with 4-byte lengths, a picture's
            at, types = off, []
            while at < off + size:
                n = int.from_bytes(data[at:at + 4], 'big'); types.append(data[at + 4] >> 1 & 63); at += 4 + n
            self.assertEqual(at, off + size)
            self.assertTrue(any(t < 32 for t in types) and not any(t in (32, 33, 34, 35) for t in types))

    def test_the_pack_decodes_to_the_movie(self):
        header, movies, entries = mh.read_pack(self.root / 'out' / mh.PACK)
        data = (self.root / 'out' / mh.PACK).read_bytes()
        stream = b''.join(b'\x00\x00\x00\x01' + p for p in movies[0]['params'])
        for _, off, size, _, _, _ in entries:
            at = off
            while at < off + size:
                n = int.from_bytes(data[at:at + 4], 'big'); stream += b'\x00\x00\x00\x01' + data[at + 4:at + 4 + n]; at += 4 + n
        hevc = self.root / 'back.hevc'
        hevc.write_bytes(stream)
        out = subprocess.run([encoders_here(), '-v', 'error', '-i', str(hevc), '-f', 'framemd5', '-'], capture_output=True, text=True, check=True).stdout
        self.assertEqual(sum(1 for line in out.splitlines() if line and not line.startswith('#')), 30)

    def test_reuse_keeps_the_pack_for_the_same_inputs(self):
        pack = self.root / 'out' / mh.PACK
        before = pack.stat().st_mtime_ns
        with contextlib.redirect_stdout(io.StringIO()) as out:
            again = mh.build(self.image, self.root / 'out', quality=50, reuse=True)
        self.assertIn('up to date', out.getvalue())
        self.assertEqual((pack.stat().st_mtime_ns, again['fingerprint']), (before, self.report['fingerprint']))
        self.assertNotEqual(mh.fingerprint(mh.movies(self.image), 51, mh.GOP, again['ffmpeg']), self.report['fingerprint'])   # another quality is another pack

    def test_a_folder_gives_the_same_pack_as_its_image(self):
        with contextlib.redirect_stdout(io.StringIO()):
            mh.build(self.romfs, self.root / 'out-folder', quality=50, workers=1)
        keyed = lambda d: [(e[0], e[3], e[4]) for e in mh.read_pack(self.root / d / mh.PACK)[2]]   # the samples are the encoder's: compared by what keys them
        self.assertEqual(keyed('out-folder'), keyed('out'))


if __name__ == '__main__':
    unittest.main()

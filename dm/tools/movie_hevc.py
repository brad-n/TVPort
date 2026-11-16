#!/usr/bin/env python3
"""HEVC sidecars of a game's AV1 movies, for the Apple TV (docs/reference/movies.md, "AV1 movies as HEVC sidecars on the Apple TV").

The Apple TV 4K's A15 has no AV1 decoder in hardware: dav1d decodes the Switch 2's AV1 movies on its CPU (hle_movie_av1.c), and a 1080p 60 fps movie falls behind its sound. The A15
decodes HEVC in hardware. This tool transcodes every AV1 movie of a game with VideoToolbox (ffmpeg's hevc_videotoolbox) at the movie's size and rate, one HEVC picture per AV1
temporal unit, and writes them all as ONE pack the host reads beside the game files (hle_movie_hevc.c). The game keeps its WebM: its own demuxer reads it and submits each temporal unit
to nn::codec (hle_codec_video.c), which never sees a file name, so the host knows a unit by its bytes (the key: the first 8 bytes of its SHA-256, leading temporal delimiters left out)
and decodes the HEVC picture made from it instead. A unit the pack does not hold goes to the AV1 decoder, as before.

Usage: movie_hevc.py <RomFS.img | RomFS folder> --out DIR [--quality Q] [--gop N] [--workers N] [--ffmpeg PATH] [--only PATH ...] [--reuse] [--json]
Output DIR: movies-hevc.pack, report.json (each movie: pictures, AV1 and HEVC bytes, or why it stays AV1; the inputs' fingerprint, which --reuse compares). Exit 0 with a pack (it may
hold no movie: a game without AV1 movies), 1 when it cannot be made (no ffmpeg with libdav1d and hevc_videotoolbox), 2 for bad arguments.

Pack layout (little-endian). The header is written last, so a pack cut off partway has no magic and the host ignores it:
  header   64 bytes: magic "DMHEVC01", u32 version (1), u32 movies, u32 entries, u32 quality, u64 movie table offset, u64 entry table offset, u64 file size, 16 bytes of the fingerprint
  samples  each HEVC access unit: its NAL units with 4-byte big-endian lengths (hvcC with lengthSizeMinusOne 3), without the parameter sets and access unit delimiters
  per movie: its parameter sets (u32 count, then u32 length + NAL unit each: VPS, SPS, PPS as the encoder wrote them) and its name (the RomFS path, UTF-8)
  movies   48 bytes each: u32 first entry, u32 entries, u32 width, u32 height, u64 parameter sets offset, u32 their size, u32 pictures, u64 name offset, u32 name length, u32 0
  entries  32 bytes each, one per AV1 temporal unit in file order: u64 key, u64 sample offset, u32 sample size, u32 AV1 size (the unit as keyed), u32 movie, u32 flags
           (1: an intra random access picture, where decoding can start; 2: a unit without a picture of its own, no sample)
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import mmap
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romfs_image

PACK = 'movies-hevc.pack'
MAGIC = b'DMHEVC01'
VERSION = 1
ENCODE = 'hevc_videotoolbox-1'   # bump when the encode changes in a way the fingerprint must see (options, mapping)
HEADER = struct.Struct('<8sIIIIQQQ16s')
MOVIE = struct.Struct('<IIIIQIIQII')
ENTRY = struct.Struct('<QQIIII')
F_SYNC, F_NOPIC = 1, 2
QUALITY = 65   # hevc_videotoolbox -q:v: on Ocarina of Time's title and cutscene movies 41.8-44.3 dB PSNR against the AV1 decode, 0.57-1.0 times the AV1 bytes (docs/reference/movies.md)
GOP = 120      # an IDR at least every 2 s of a 60 fps movie (a jump decodes from the one before its unit), and at every AV1 key frame (-force_key_frames source)
SUFFIXES = ('.webm', '.mkv')
assert HEADER.size == 64 and MOVIE.size == 48 and ENTRY.size == 32


class Unsupported(Exception):
    """A movie this tool leaves to the AV1 decoder, with the reason"""


def log(msg):
    print(f'movie_hevc: {msg}', flush=True)


# ---- AV1 temporal units ----
def leb128(b, i):
    """(value, bytes read) of the leb128 at b[i:]; (0, 0) when it runs past the end"""
    v = 0
    for k in range(8):
        if i + k >= len(b):
            return 0, 0
        v |= (b[i + k] & 0x7f) << (7 * k)
        if not b[i + k] & 0x80:
            return v, k + 1
    return 0, 0


def strip_delimiters(tu):
    """The unit without its leading temporal delimiter OBUs (type 2): WebM leaves them out (the AV1 Matroska binding), a demuxer may put one back; the host keys the unit the same way"""
    i = 0
    while i < len(tu):
        h = tu[i]
        if (h >> 3) & 15 != 2 or not h & 2:
            break
        at = i + (2 if h & 4 else 1)
        size, n = leb128(tu, at)
        if not n or at + n + size > len(tu):
            break
        i = at + n + size
    return tu[i:]


def unit_key(tu):
    """(key, size) the host looks a temporal unit up by"""
    body = strip_delimiters(tu)
    return int.from_bytes(hashlib.sha256(body).digest()[:8], 'little'), len(body)


# ---- WebM (Matroska) ----
EBML_SEGMENT, EBML_CLUSTER, EBML_TRACKS, EBML_TRACK, EBML_VIDEO, EBML_GROUP = 0x18538067, 0x1F43B675, 0x1654AE6B, 0xAE, 0xE0, 0xA0
MASTERS = {EBML_SEGMENT, EBML_CLUSTER, EBML_TRACKS, EBML_TRACK, EBML_VIDEO, EBML_GROUP}   # entered whatever their size says (a live WebM leaves Segment and Cluster sizes unknown)
TRACK_NUMBER, TRACK_TYPE, CODEC_ID, PIXEL_W, PIXEL_H, CONTENT_ENCODINGS, SIMPLE_BLOCK, BLOCK = 0xD7, 0x83, 0x86, 0xB0, 0xBA, 0x6D80, 0xA3, 0xA1


def vint(b, i, keep_marker):
    """(value, length) of the EBML variable-length integer at b[i]; value None for an unknown size (all ones)"""
    first = b[i]
    n = 1
    while n <= 8 and not first & (0x80 >> (n - 1)):
        n += 1
    if n > 8 or i + n > len(b):
        raise Unsupported(f'a damaged EBML number at byte {i}')
    v = first if keep_marker else first & (0xff >> n)
    for k in range(1, n):
        v = v << 8 | b[i + k]
    if not keep_marker and v == (1 << (7 * n)) - 1:
        return None, n
    return v, n


def webm_units(b):
    """(width, height, [temporal unit, ...]) of the first AV1 video track of a WebM, in file order (the order the guest's demuxer submits them in)"""
    tracks, track, units, i = {}, None, [], 0
    av1 = None
    while i < len(b):
        eid, n = vint(b, i, True)
        size, m = vint(b, i + n, False)
        i += n + m
        if eid in MASTERS:
            if eid == EBML_TRACK:
                track = tracks.setdefault(len(tracks), {})
            continue   # its children follow
        if size is None or i + size > len(b):
            raise Unsupported(f'element {eid:#x} runs past the end of the file')
        body = b[i:i + size]
        i += size
        if track is not None and eid in (TRACK_NUMBER, TRACK_TYPE, PIXEL_W, PIXEL_H):
            track[eid] = int.from_bytes(body, 'big')
        elif track is not None and eid == CODEC_ID:
            track[eid] = bytes(body).rstrip(b'\0').decode('ascii', 'replace')
        elif track is not None and eid == CONTENT_ENCODINGS:
            track[eid] = True
        elif eid in (SIMPLE_BLOCK, BLOCK):
            if av1 is None:
                video = [t for t in tracks.values() if t.get(TRACK_TYPE) == 1]
                if not video or video[0].get(CODEC_ID) != 'V_AV1':
                    raise Unsupported(f'not AV1 ({video[0].get(CODEC_ID) if video else "no video track"})')
                if video[0].get(CONTENT_ENCODINGS):
                    raise Unsupported('its AV1 track has content encodings (compression or header stripping)')
                av1 = video[0]
            num, k = vint(body, 0, False)
            if num != av1.get(TRACK_NUMBER):
                continue
            if body[k + 2] & 0x06:
                raise Unsupported('laced AV1 blocks')
            units.append(bytes(body[k + 3:]))
    if av1 is None:
        raise Unsupported('no AV1 blocks')
    return av1.get(PIXEL_W, 0), av1.get(PIXEL_H, 0), units


# ---- HEVC Annex B ----
def nal_units(data):
    """The NAL units of an Annex B stream, without start codes or trailing zero bytes (a NAL unit never ends in 0x00, H.265 7.4.2)"""
    starts, i = [], data.find(b'\x00\x00\x01')
    while i >= 0:
        starts.append(i + 3)
        i = data.find(b'\x00\x00\x01', i + 3)
    for k, s in enumerate(starts):
        nal = data[s:starts[k + 1] - 3 if k + 1 < len(starts) else len(data)].rstrip(b'\x00')
        if nal:
            yield nal


def nal_type(nal):
    return (nal[0] >> 1) & 63


def access_units(data):
    """[(parameter sets, [other NAL units], is a random access picture)] of an Annex B stream with an access unit delimiter before every access unit (hevc_metadata=aud=insert)"""
    aus, cur = [], None
    for nal in nal_units(data):
        t = nal_type(nal)
        if t == 35:
            cur = ([], [], False)
            aus.append(cur)
            continue
        if cur is None:
            raise Unsupported('the HEVC stream does not start with an access unit delimiter')
        if t in (32, 33, 34):
            cur[0].append(nal)
        else:
            cur[1].append(nal)
    out = []
    for ps, rest, _ in aus:
        if not any(nal_type(n) < 32 for n in rest):
            raise Unsupported('an HEVC access unit without a picture')
        out.append((ps, rest, any(16 <= nal_type(n) <= 21 for n in rest)))
    return out


def sample(nals):
    return b''.join(len(n).to_bytes(4, 'big') + n for n in nals)


# ---- ffmpeg ----
def find_ffmpeg(given=None):
    if given:
        return given if os.access(given, os.X_OK) else None
    path = os.pathsep.join([os.environ.get('PATH', ''), '/opt/homebrew/bin', '/usr/local/bin'])
    return shutil.which('ffmpeg', path=path)


def ffmpeg_ready(ffmpeg):
    """(version line, '') when ffmpeg has libdav1d and hevc_videotoolbox, else ('', why)"""
    try:
        version = subprocess.run([ffmpeg, '-hide_banner', '-version'], capture_output=True, text=True, timeout=60).stdout.split('\n')[0].strip()
        enc = subprocess.run([ffmpeg, '-hide_banner', '-encoders'], capture_output=True, text=True, timeout=60).stdout
        dec = subprocess.run([ffmpeg, '-hide_banner', '-decoders'], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError) as e:
        return '', f'ffmpeg does not run ({e})'
    if ' hevc_videotoolbox ' not in enc:
        return '', 'this ffmpeg has no hevc_videotoolbox encoder'
    if ' libdav1d ' not in dec:
        return '', 'this ffmpeg has no libdav1d decoder'
    return version, ''


def encode_argv(ffmpeg, source, out, quality, gop):
    """One movie's AV1 track to an Annex B HEVC stream: a picture for every decoded one, none dropped or repeated (passthrough), no reordering (no B frames: a unit's picture
    comes out of the decoder when its sample goes in), an IDR at every AV1 key frame and at least every gop pictures, and an access unit delimiter before each access unit"""
    return [ffmpeg, '-nostdin', '-hide_banner', '-v', 'error', '-y', '-c:v', 'libdav1d', '-i', source, '-map', '0:v:0', '-an', '-sn', '-dn',
            '-c:v', 'hevc_videotoolbox', '-q:v', str(quality), '-bf', '0', '-g', str(gop), '-force_key_frames', 'source', '-profile:v', 'main', '-pix_fmt', 'nv12',
            '-fps_mode', 'passthrough', '-bsf:v', 'hevc_metadata=aud=insert', '-f', 'hevc', out]


# ---- the game's movies ----
def movies(romfs, only=None):
    """[(RomFS path, (image, offset, size) or file path)] of the movie files, sorted by path"""
    found = []
    if os.path.isdir(romfs):
        for root, _, files in os.walk(romfs):
            for f in files:
                if f.lower().endswith(SUFFIXES):
                    full = os.path.join(root, f)
                    found.append((os.path.relpath(full, romfs).replace(os.sep, '/'), full))
    else:
        with open(romfs, 'rb') as f:
            if f.read(8) != romfs_image.MAGIC:
                raise SystemExit(f'{romfs}: not a plain RomFS image (DMROMFS1) or folder')
        for path, (is_dir, off, size) in romfs_image.read_index(romfs).items():
            if not is_dir and path.lower().endswith(SUFFIXES):
                found.append((path, (romfs, off, size)))
    found.sort()
    return [m for m in found if not only or m[0] in only]


class Source:
    """A movie's bytes (mapped, not read) and the URL ffmpeg reads it by"""
    def __init__(self, where):
        if isinstance(where, tuple):
            image, self.off, self.size = where
            self.url = f'subfile,,start,{self.off},end,{self.off + self.size},,:{image}'
        else:
            image, self.off, self.size = where, 0, os.path.getsize(where)
            self.url = where
        self.file = open(image, 'rb')
        self.map = mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ) if self.size else None

    def bytes(self):
        return memoryview(self.map)[self.off:self.off + self.size] if self.map else memoryview(b'')

    def close(self):
        if self.map:
            try:
                self.map.close()
            except BufferError:   # a view of it still alive: closed when that goes
                pass
        self.file.close()


def fingerprint(found, quality, gop, version):
    h = hashlib.sha256(json.dumps([VERSION, ENCODE, quality, gop, version]).encode())
    for path, where in found:
        src = Source(where)
        try:
            h.update(path.encode() + b'\0' + str(src.size).encode() + b'\0')
            h.update(hashlib.sha256(src.bytes()).digest())
        finally:
            src.close()
    return h.hexdigest()


def encode_one(ffmpeg, path, where, work, quality, gop):
    """Runs on a worker: (path, [(key, size)] of the units, AV1 bytes, width, height, access units, seconds) or (path, Unsupported)"""
    t0 = time.monotonic()
    src = Source(where)
    try:
        w, h, units = webm_units(src.bytes())
        fd, out = tempfile.mkstemp(suffix='.hevc', dir=work)
        os.close(fd)
        try:
            r = subprocess.run(encode_argv(ffmpeg, src.url, out, quality, gop), capture_output=True, text=True)
            if r.returncode:
                raise Unsupported(f'ffmpeg failed ({(r.stderr.strip().splitlines() or ["no message"])[-1][:300]})')
            with open(out, 'rb') as f:
                aus = access_units(f.read())
        finally:
            os.unlink(out)
        if len(aus) != len(units):
            raise Unsupported(f'{len(units)} temporal units decoded to {len(aus)} pictures (a unit without a shown frame, which this pack cannot map)')
        return path, [unit_key(u) for u in units], sum(len(u) for u in units), w, h, aus, time.monotonic() - t0
    except Unsupported as e:
        return path, e
    finally:
        src.close()


def build(romfs, out_dir, quality=QUALITY, gop=GOP, workers=2, ffmpeg=None, only=None, reuse=False):
    """Writes out_dir/movies-hevc.pack and report.json; returns the report. A game without movie files gets a pack with none, and needs no ffmpeg"""
    found = movies(romfs, only)
    version = ''
    if found:
        ffmpeg = find_ffmpeg(ffmpeg)
        if not ffmpeg:
            raise RuntimeError('ffmpeg was not found (Homebrew: brew install ffmpeg)')
        version, why = ffmpeg_ready(ffmpeg)
        if why:
            raise RuntimeError(why)
    os.makedirs(out_dir, exist_ok=True)
    pack, report_path = os.path.join(out_dir, PACK), os.path.join(out_dir, 'report.json')
    fp = fingerprint(found, quality, gop, version)
    if reuse and os.path.isfile(pack) and os.path.isfile(report_path):
        try:
            with open(report_path) as f:
                old = json.load(f)
        except ValueError:
            old = {}
        if old.get('fingerprint') == fp and old.get('pack_bytes') == os.path.getsize(pack):
            log(f'{PACK} is up to date for these inputs ({old.get("converted", 0)} movies, {os.path.getsize(pack) / 1e9:.2f} GB)')
            return old
    log(f'{len(found)} movie files; HEVC quality {quality}, an IDR at least every {gop} pictures, {workers} at a time ({version})')
    work = tempfile.mkdtemp(prefix='movie_hevc.', dir=out_dir)
    part = pack + '.part'
    report = {'version': VERSION, 'encode': ENCODE, 'fingerprint': fp, 'quality': quality, 'gop': gop, 'ffmpeg': version, 'movies': []}
    movie_rows, entry_rows = [], []
    try:
        with open(part, 'wb') as f, cf.ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
            f.write(b'\0' * HEADER.size)
            jobs = [pool.submit(encode_one, ffmpeg, path, where, work, quality, gop) for path, where in found]
            for k, job in enumerate(jobs):   # in path order, whatever order they finish in: the same inputs give the same pack
                res = job.result()
                path = res[0]
                if isinstance(res[1], Unsupported):
                    log(f'{k + 1}/{len(found)} {path}: left as it is: {res[1]}')
                    report['movies'].append({'path': path, 'skipped': str(res[1]), 'av1_bytes': (found[k][1][2] if isinstance(found[k][1], tuple) else os.path.getsize(found[k][1]))})
                    continue
                _, keys, av1, w, h, aus, secs = res
                params = aus[0][0]
                if [n for n in params if nal_type(n) not in (32, 33, 34)] or sorted({nal_type(n) for n in params}) != [32, 33, 34]:
                    log(f'{k + 1}/{len(found)} {path}: left as it is: the first HEVC access unit lacks its parameter sets')
                    report['movies'].append({'path': path, 'skipped': 'no parameter sets', 'av1_bytes': av1})
                    continue
                if any(ps and ps != params for ps, _, _ in aus):
                    log(f'{k + 1}/{len(found)} {path}: left as it is: the encoder changed its parameter sets within the movie')
                    report['movies'].append({'path': path, 'skipped': 'parameter sets change', 'av1_bytes': av1})
                    continue
                first, hevc = len(entry_rows), 0
                for (key, size), (_, nals, sync) in zip(keys, aus):
                    data = sample(nals)
                    entry_rows.append((key, f.tell(), len(data), size, len(movie_rows), F_SYNC if sync else 0))
                    f.write(data)
                    hevc += len(data)
                if not entry_rows[first][5] & F_SYNC:
                    raise RuntimeError(f'{path}: the first HEVC picture is not a random access picture')
                ps_off = f.tell()
                f.write(struct.pack('<I', len(params)) + b''.join(struct.pack('<I', len(n)) + n for n in params))
                ps_size = f.tell() - ps_off
                name = path.encode()
                name_off = f.tell()
                f.write(name)
                f.write(b'\0' * (-f.tell() % 8))
                movie_rows.append((first, len(keys), w, h, ps_off, ps_size, len(aus), name_off, len(name), 0))
                report['movies'].append({'path': path, 'pictures': len(aus), 'width': w, 'height': h, 'av1_bytes': av1, 'hevc_bytes': hevc,
                                         'idr': sum(1 for a in aus if a[2]), 'seconds': round(secs, 1)})
                log(f'{k + 1}/{len(found)} {path}: {len(aus)} pictures {w}x{h}, {av1 / 1e6:.1f} MB AV1 -> {hevc / 1e6:.1f} MB HEVC ({secs:.0f} s)')
            movies_off = f.tell()
            for row in movie_rows:
                f.write(MOVIE.pack(*row))
            entries_off = f.tell()
            for row in entry_rows:
                f.write(ENTRY.pack(*row))
            size = f.tell()
            f.seek(0)
            f.write(HEADER.pack(MAGIC, VERSION, len(movie_rows), len(entry_rows), quality, movies_off, entries_off, size, bytes.fromhex(fp)[:16]))
        os.replace(part, pack)
    finally:
        shutil.rmtree(work, ignore_errors=True)
        if os.path.exists(part):
            os.unlink(part)
    done = [m for m in report['movies'] if 'pictures' in m]
    report.update(converted=len(done), skipped=len(report['movies']) - len(done), pictures=sum(m['pictures'] for m in done),
                  av1_bytes=sum(m['av1_bytes'] for m in done), hevc_bytes=sum(m['hevc_bytes'] for m in done), pack_bytes=os.path.getsize(pack))
    with open(report_path + '.part', 'w') as f:
        json.dump(report, f, indent=1)
    os.replace(report_path + '.part', report_path)
    log(f'{PACK}: {len(done)} movies ({report["pictures"]:,} pictures), {report["av1_bytes"] / 1e9:.2f} GB of AV1 as {report["hevc_bytes"] / 1e9:.2f} GB of HEVC; '
        f'{report["skipped"]} left as they are')
    return report


def read_pack(path):
    """For tests and checks: (header fields, [movie dict], [entry tuple]) of a pack"""
    with open(path, 'rb') as f:
        data = f.read()
    magic, version, nm, ne, quality, moff, eoff, size, fp = HEADER.unpack_from(data, 0)
    if magic != MAGIC or version != VERSION or size != len(data):
        raise ValueError(f'{path}: not a complete version {VERSION} pack')
    mv = []
    for k in range(nm):
        first, count, w, h, ps_off, ps_size, pics, name_off, name_len, _ = MOVIE.unpack_from(data, moff + k * MOVIE.size)
        n, = struct.unpack_from('<I', data, ps_off)
        ps, at = [], ps_off + 4
        for _ in range(n):
            ln, = struct.unpack_from('<I', data, at)
            ps.append(data[at + 4:at + 4 + ln])
            at += 4 + ln
        mv.append({'first': first, 'count': count, 'width': w, 'height': h, 'params': ps, 'pictures': pics, 'name': data[name_off:name_off + name_len].decode()})
    entries = [ENTRY.unpack_from(data, eoff + k * ENTRY.size) for k in range(ne)]
    return {'quality': quality, 'fingerprint': fp.hex(), 'size': size}, mv, entries


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('romfs', help='the game files: a plain RomFS image (DMROMFS1) or an extracted RomFS folder')
    ap.add_argument('--out', required=True, help='output folder: movies-hevc.pack, report.json')
    ap.add_argument('--quality', type=int, default=QUALITY, help=f'hevc_videotoolbox constant quality, 1-100 (default {QUALITY})')
    ap.add_argument('--gop', type=int, default=GOP, help=f'the longest run of pictures between two IDRs (default {GOP})')
    ap.add_argument('--workers', type=int, default=2, help='movies encoded at once (default 2)')
    ap.add_argument('--ffmpeg', help='the ffmpeg to run (default: PATH, then /opt/homebrew/bin and /usr/local/bin)')
    ap.add_argument('--only', nargs='*', help='only these RomFS paths (checks)')
    ap.add_argument('--reuse', action='store_true', help='keep the pack when the movies, the settings and ffmpeg are unchanged')
    ap.add_argument('--json', action='store_true', help='print the report as JSON at the end')
    a = ap.parse_args()
    if not 1 <= a.quality <= 100 or a.gop < 1:
        ap.error('--quality takes 1-100 and --gop a positive count')
    try:
        report = build(a.romfs, a.out, a.quality, a.gop, a.workers, a.ffmpeg, a.only, a.reuse)
    except RuntimeError as e:
        print(f'movie_hevc: {e}', file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps(report))
    return 0


if __name__ == '__main__':
    sys.exit(main())

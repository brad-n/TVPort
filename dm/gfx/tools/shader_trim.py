#!/usr/bin/env python3
# Shader trimming (docs/reference/tv-size.md, "Cut 2 as built: shader trimming"): an app's shader library with the shaders the game has used as they are, and every other vertex and pixel
# shader packed as one zstd frame of its own build output (its libraries and reflection, byte for byte as dmsh_build.py made them), which the host inflates into a cache folder the first time
# something loads it (dm/gfx/nvn/nvn_shader_trim.inc). Nothing is compiled on the device: a packed library is the build's AIR, so a shader read from its frame is the shader the full
# library holds (the same -O1, -fwrapv, bracket depth, MSL version and compiler), and its pipelines are built as for any library the device meets for the first time.
# The image keeps the format of every library (dm/tools/shader_lib.py, read in place by msl_image.h), with three more kinds of entry:
#   <key>.trim   one zstd frame (dictionary trim.dict, content checksum) of b'DMT1', u32 file count, then per file u16 name length, u32 size, the name, the bytes: every file
#                <key>_b*.metallib / .json of one shader
#   trim.dict    the zstd dictionary the frames are compressed with, trained on this library's own packed shaders (absent when too few to train on: plain frames)
#   trim.tsv     "# shader_trim 1<TAB><id>", then key<TAB>stage<TAB>its file names without the key, comma separated, for every packed shader. <id> names this packing (a digest of the
#                dictionary and the index), and the host's cache folder for it
# What stays as it is: every shader the used lists name (S and C rows, the vertex and fragment keys of R rows, the task and mesh keys of M rows, and the first column of key-only lists such
# as shader_seen.tsv), every shader of another stage (compute, geometry, tessellation, task, mesh: few, and loaded by their own paths), the pair libraries (<vertex>_<geometry>_m3) and every
# file that is not a shader's (inputs.tsv, the markers). The shader map is not changed: the image says which shaders it packed.
# Usage: shader_trim.py split --lib <b-chain[.img]> --map <shader_map.tsv> --used <list>... --out <dir> [--level 19] [--jobs N] [--dict-kb 1024]
#        shader_trim.py check <dir or image>   every packed shader's frame inflates to the files its index line names, and none of them is also a plain entry
#        shader_trim.py count --used <list>...   the number of shaders the lists name
import argparse, collections, concurrent.futures as cf, hashlib, json, os, random, re, struct, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools'))
import romfs, shader_lib

try: from compression import zstd   # Python 3.14
except ImportError:
    try: from backports import zstd   # the same API before it
    except ImportError: zstd = None

INDEX, DICT, SUFFIX = 'trim.tsv', 'trim.dict', '.trim'
INDEX_HEAD = '# shader_trim 1'
MAGIC = b'DMT1'
FILE_OF = re.compile(r'([0-9a-f]{16})(_b[a-z0-9]*\.(?:metallib|json))')   # a shader's own files: <key>_b.metallib, _b.json, _bx, _bf, _bp, _bv ... (not <vertex>_<geometry>_m3)
TRIM_STAGES = ('vertex', 'pixel')
TRAIN_KEYS, TRAIN_BYTES = 3000, 192 << 20


def need_zstd():
    if zstd is None: raise SystemExit('[RED] shader_trim.py needs Python 3.14 (compression.zstd) or backports.zstd')


# ---------------------------------------------------------------- the used lists
def key_of(text):
    m = re.fullmatch(r'([0-9a-f]{16})(_b)?', text.strip())
    return m.group(1) if m else None


def skey_keys(hexs):
    """The vertex and fragment keys of a pso_skey in hex (nvn_pso_skey.h: char vs[24], fs[24] first)"""
    try: raw = bytes.fromhex(hexs[:96])
    except ValueError: return []
    return [key_of(raw[o:o + 24].split(b'\0', 1)[0].decode('ascii', 'replace')) for o in (0, 24)]


def read_used(paths):
    """The keys the lists name → (set, Counter of the rows that named them). A prewarm list's S, C, R and M rows (docs/development.md, Prewarm lists); any other line whose first column is a key
    (shader_seen.tsv, partial-keys.txt). A missing list names nothing"""
    keys, rows = set(), collections.Counter()
    for p in paths:
        try: f = open(p, 'r', errors='replace')
        except OSError: continue
        with f:
            for ln in f:
                if ln.startswith('#') or not ln.strip(): continue
                c = ln.rstrip('\n').split('\t')
                if c[0] in ('S', 'C') and len(c) > 1: got = [key_of(c[1])]
                elif c[0] == 'R' and len(c) > 1: got = skey_keys(c[1])
                elif c[0] == 'M' and len(c) > 2: got = [key_of(c[1])] + skey_keys(c[2])
                else: got = [key_of(c[0])]
                for k in got:
                    if k: keys.add(k); rows[c[0] if c[0] in 'SCRM' and len(c[0]) == 1 else 'key'] += 1
    return keys, rows


def read_stages(map_path):
    """{key: stage} of a shader map (column 4 the key, column 3 the stage)"""
    out = {}
    with open(map_path, 'r', errors='replace') as f:
        for ln in f:
            c = ln.rstrip('\n').split('\t')
            if len(c) > 3 and not ln.startswith('#') and c[0] != 'package': out[c[3]] = c[2]
    return out


# ---------------------------------------------------------------- frames
def payload(files):
    """[(name, bytes)] → the bytes a frame holds"""
    out = [MAGIC, struct.pack('<I', len(files))]
    for name, data in files:
        n = name.encode(); out += [struct.pack('<HI', len(n), len(data)), n, data]
    return b''.join(out)


def unpack(raw):
    """A frame's bytes → [(name, bytes)]; ValueError when they are not a frame's"""
    if raw[:4] != MAGIC: raise ValueError('not a shader_trim frame')
    (n,), at, out = struct.unpack_from('<I', raw, 4), 8, []
    for _ in range(n):
        ln, size = struct.unpack_from('<HI', raw, at); at += 6
        name = raw[at:at + ln].decode(); at += ln
        if at + size > len(raw): raise ValueError(f'{name}: the frame ends inside it')
        out.append((name, raw[at:at + size])); at += size
    if at != len(raw): raise ValueError('bytes after the last file')
    return out


DICT_MAGIC = b'\x37\xa4\x30\xec'


def zdict(d):   # a trained dictionary, or raw content (a library with too few shaders to train on), as zstd's decoder tells them apart
    return zstd.ZstdDict(d, is_raw=not d.startswith(DICT_MAGIC)) if d else None


def compress(raw, d, level):
    opts = {zstd.CompressionParameter.compression_level: level, zstd.CompressionParameter.checksum_flag: 1}
    return zstd.compress(raw, options=opts, zstd_dict=d) if d else zstd.compress(raw, options=opts)


def inflate(frame, d): return zstd.decompress(frame, zstd_dict=d) if d else zstd.decompress(frame)


# ---------------------------------------------------------------- the split
def split(lib, map_path, used_paths, out_dir, level=19, jobs=None, dict_kb=1024, say=lambda *a: print(*a, flush=True)):
    """Writes out_dir/<b-chain>.img, the library with the shaders the lists do not name packed, and out_dir/trim_report.json. → the report"""
    need_zstd()
    t0 = time.time(); jobs = jobs or max(1, (os.cpu_count() or 4) - 2)
    src = shader_lib.view(lib)
    sizes = {p.name: p.stat().st_size for p in src.iterdir()}
    if not any(n.endswith('_b.metallib') for n in sizes): raise ValueError(f'no shader libraries at {lib}')
    used, rows = read_used(used_paths)
    stage = read_stages(map_path)
    by_key = collections.defaultdict(list)
    for n in sizes:
        m = FILE_OF.fullmatch(n)
        if m: by_key[m.group(1)].append(n)
    packed = sorted(k for k, names in by_key.items() if k not in used and stage.get(k) in TRIM_STAGES and f'{k}_b.metallib' in names)
    say(f'{len(by_key):,} shaders in {lib}, {len(used & set(by_key)):,} named by the lists ({", ".join(f"{v:,} {k}" for k, v in sorted(rows.items()))}): {len(packed):,} vertex and pixel shaders to pack')

    def files_of(k): return [(n, (src / n).read_bytes()) for n in sorted(by_key[k])]
    rnd = random.Random(0x7a5e); sample, got = [], 0
    for k in rnd.sample(packed, min(len(packed), TRAIN_KEYS)):
        b = payload(files_of(k))
        if got + len(b) > TRAIN_BYTES: break
        sample.append(b); got += len(b)
    d_bytes = b''
    if len(sample) >= 32:
        try: d_bytes = zstd.train_dict(sample, dict_kb << 10).dict_content
        except zstd.ZstdError as e: say(f'no trained dictionary ({e})')
    if not d_bytes and sample: d_bytes = b''.join(sample)[-(dict_kb << 10):]   # too few to train on: the shaders themselves, as a raw content dictionary
    d = zdict(d_bytes); del sample
    say(f'dictionary: {len(d_bytes):,} bytes from {got >> 20} MB of the packed shaders ({time.time() - t0:.0f} s)')

    os.makedirs(out_dir, exist_ok=True)
    blob_path = os.path.join(out_dir, '.trim-frames.part')
    spans, raw_total, lock = {}, [0, 0], threading.Lock()
    with open(blob_path, 'wb') as blob:
        def one(k):
            raw = payload(files_of(k))
            return k, len(raw), compress(raw, d, level)
        with cf.ThreadPoolExecutor(jobs) as ex:
            for i, (k, n, fr) in enumerate(ex.map(one, packed)):
                with lock: spans[k] = (blob.tell(), len(fr)); blob.write(fr); raw_total[0] += n; raw_total[1] += len(fr)
                if i and i % 4000 == 0: say(f'  {i:,} of {len(packed):,} packed ({time.time() - t0:.0f} s)')
    index = ''.join(f'{k}\t{stage[k]}\t{",".join(n[16:] for n in sorted(by_key[k]))}\n' for k in packed)
    tid = hashlib.sha256(d_bytes + b'\0' + index.encode()).hexdigest()[:16]
    gone = {n for k in packed for n in by_key[k]}
    files = {n: str(src / n) for n in sizes if n not in gone}
    bf = open(blob_path, 'rb')
    def span(k):
        a, n = spans[k]; bf.seek(a); return bf.read(n)
    for k in packed: files[k + SUFFIX] = (lambda k=k: span(k))
    if d_bytes: files[DICT] = d_bytes
    if packed: files[INDEX] = f'{INDEX_HEAD}\t{tid}\n# key, stage, its files packed in <key>{SUFFIX} (dm/gfx/tools/shader_trim.py)\n{index}'.encode()   # nothing packed: the library as it was
    img = os.path.join(out_dir, shader_lib.name_of(lib) + '.img')
    try: shader_lib.write(files, img)
    finally: bf.close(); os.unlink(blob_path)
    before, after = sum(sizes.values()), os.path.getsize(img)
    kept_bytes = sum(sizes[n] for n in sizes if n not in gone)
    rep = {'lib': os.fspath(lib), 'id': tid, 'shaders': len(by_key), 'used_named': len(used & set(by_key)), 'packed': len(packed), 'packed_files': len(gone),
           'library_bytes': before, 'image_bytes': after, 'kept_bytes': kept_bytes, 'packed_raw_bytes': raw_total[0], 'packed_frame_bytes': raw_total[1], 'dict_bytes': len(d_bytes),
           'level': level, 'seconds': round(time.time() - t0), 'lists': [os.fspath(p) for p in used_paths]}
    with open(os.path.join(out_dir, 'trim_report.json'), 'w') as f: json.dump(rep, f, indent=1)
    say(f'trimmed library {after / 1e9:.3f} GB from {before / 1e9:.3f} GB: {kept_bytes / 1e9:.3f} GB kept as it is, {len(packed):,} shaders packed from {raw_total[0] / 1e9:.3f} GB into '
        f'{raw_total[1] / 1e9:.3f} GB ({raw_total[0] / max(raw_total[1], 1):.2f}x), {time.time() - t0:.0f} s')
    return rep


# ---------------------------------------------------------------- reading a trimmed image
def read_index(img):
    """(id, {key: (stage, [file names])}) of a trimmed image; (None, {}) for a library that packs nothing"""
    p = romfs.Path(img) / INDEX
    if not p.is_file(): return None, {}
    lines = p.read_text().splitlines()
    if not lines or not lines[0].startswith(INDEX_HEAD + '\t'): raise ValueError(f'{img}: {INDEX} has no "{INDEX_HEAD}" head')
    out = {}
    for ln in lines[1:]:
        if ln.startswith('#') or not ln.strip(): continue
        k, st, names = ln.split('\t')
        out[k] = (st, [k + n for n in names.split(',')])
    return lines[0].split('\t')[1], out


def extract(img, key):
    """[(name, bytes)] of a packed shader"""
    need_zstd()
    im = romfs.Path(img); dp = im / DICT
    return unpack(inflate((im / (key + SUFFIX)).read_bytes(), zdict(dp.read_bytes() if dp.is_file() else b'')))


def check(path, say=print):
    """Every packed shader of the image (or of the only .img in a folder): its frame inflates (zstd checks its checksum) to exactly the files its index line names, none of which is a plain
    entry too. → the problems"""
    need_zstd()
    img = path if path.endswith('.img') else os.path.join(path, next(n for n in sorted(os.listdir(path)) if n.endswith('.img')))
    _, idx = read_index(img)
    im = romfs.Path(img); names = {p.name for p in im.iterdir()}; dp = im / DICT
    d = zdict(dp.read_bytes() if dp.is_file() else b''); bad = []
    for k, (_, want) in idx.items():
        if k + SUFFIX not in names: bad.append(f'{k}: no {k}{SUFFIX}'); continue
        try: got = [n for n, _ in unpack(inflate((im / (k + SUFFIX)).read_bytes(), d))]
        except (zstd.ZstdError, ValueError, struct.error) as e: bad.append(f'{k}: {e}'); continue
        if got != want: bad.append(f'{k}: the frame holds {got}, the index names {want}')
        bad += [f'{n}: both packed and a plain entry' for n in want if n in names]
    extra = sorted(n for n in names if n.endswith(SUFFIX) and n[:-len(SUFFIX)] not in idx)
    bad += [f'{n}: a frame the index does not name' for n in extra]
    say(f'{len(idx):,} packed shaders checked, {len(bad)} problems')
    return bad


def main():
    ap = argparse.ArgumentParser(description='Shader trimming: pack the shaders a game has not used into zstd frames of its library')
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('split')
    s.add_argument('--lib', required=True, help='the library, b-<chain> or b-<chain>.img'); s.add_argument('--map', required=True)
    s.add_argument('--used', action='append', default=[]); s.add_argument('--out', required=True)
    s.add_argument('--level', type=int, default=19); s.add_argument('--jobs', type=int); s.add_argument('--dict-kb', type=int, default=1024)
    c = sub.add_parser('check'); c.add_argument('path')
    n = sub.add_parser('count'); n.add_argument('--used', action='append', default=[])
    a = ap.parse_args()
    if a.cmd == 'check': return 1 if check(a.path) else 0
    if a.cmd == 'count': print(len(read_used(a.used)[0])); return 0
    split(a.lib, a.map, a.used, a.out, a.level, a.jobs, a.dict_kb)
    return 0


if __name__ == '__main__': sys.exit(main())

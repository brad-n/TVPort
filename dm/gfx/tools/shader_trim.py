#!/usr/bin/env python3
# Shader trimming (docs/shader_trimming.md): the app image carries the shaders a game uses as compiled Metal libraries and every other vertex / pixel shader as zstd-compressed Metal source,
# which the device compiles the first time a draw needs it (dm/gfx/nvn/nvn_shader_trim.m). One image, the same romfs format as before (dm/tools/shader_lib.py), with new entry kinds:
#   <key>_b.msl  <key>_bp.msl  <key>_bv.msl  <key>_bu.msl   the source of the library <key>_b / _bp / _bv (the base, the pulling and the shadow-input vertex libraries), and of <key>_bu: the compile
#                                                           unit that <key>_bx (alpha test, logic operation) and <key>_bf (readable tile) are cut from at build time; the device uses its one
#                                                           library for both names. zstd frames compressed with the dictionary trim.dict
#   <key>_b.jsonz                                           the reflection json of the shader, zstd with trim_json.dict (the host reads it where it reads <key>_b.json)
#   trim.dict, trim_json.dict                               the dictionaries (trained on this game's own sources)
#   trim.tsv                                                what the image was made of: "# shader_trim 1", then key<TAB>stage<TAB>variants for every shader in source form
# The shader map says which form each key has: shader_map.tsv gets a sixth column, lib (compiled in the image, as before) or src (the entries above). A map without the column is all lib.
# Compiled: every key in the used list (the TV-recorded list tvport-shaders.tsv plus the profile's prewarm list pso_manifest.tsv: S / C rows and the vertex and fragment keys of R rows), every
# compute / geometry / tessellation shader, and the files that are not a shader's (inputs.tsv, the geometry kernels). The libraries of a key in source form are those a full build made,
# regenerated from the same MSL by the same functions dmsh_build.py calls (dmsh_pull.variant, dmsh_vin.variant, dmsh_side.unit, dmsh_fetch.fold), kept only where the shader's reflection says
# the build made them.
# Usage: shader_trim.py split --compiled <ios b-chain.img> --sources <mac cache b-chain.img> --map <shader_map.tsv> --used <list.tsv>... --out <dir> [--level 19] [--jobs 4]
#        shader_trim.py count --used <list.tsv>...  the number of shaders the lists name
#        shader_trim.py check <out dir>             the trimmed image against its map: every key has the form the map says, and every source entry inflates
import argparse, collections, concurrent.futures as cf, ctypes, ctypes.util, json, os, random, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools'))
import romfs, shader_lib

MSL, JSONZ = '.msl', '.jsonz'
DICT_MSL, DICT_JSON, INDEX = 'trim.dict', 'trim_json.dict', 'trim.tsv'
INDEX_HEAD = '# shader_trim 1'
KEY = re.compile(r'([0-9a-f]{16})(_b[a-z0-9]*)\.(metallib|json)')
TRIM_STAGES = ('vertex', 'pixel')   # the stages a source form is made for: the others are few, and have stubs and kernels the loader treats on their own
DICT_BYTES, TRAIN_SAMPLES, TRAIN_BYTES = 112640, 4000, 64 << 20


# ---------------------------------------------------------------- zstd (the system's libzstd, through ctypes)
class Zstd:
    def __init__(self):
        found = [p for p in (os.environ.get('DM_ZSTD_LIB'), ctypes.util.find_library('zstd'), '/opt/homebrew/lib/libzstd.dylib', '/usr/local/lib/libzstd.dylib') if p]
        for p in found:
            try: L = ctypes.CDLL(p); break
            except OSError: continue
        else: raise RuntimeError('libzstd not found (brew install zstd, or DM_ZSTD_LIB=<path to libzstd.dylib>)')
        vp, sz, ui, i = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint, ctypes.c_int
        for name, res, args in (('ZSTD_createCCtx', vp, []), ('ZSTD_freeCCtx', sz, [vp]), ('ZSTD_createDCtx', vp, []), ('ZSTD_freeDCtx', sz, [vp]),
                                ('ZSTD_createCDict', vp, [vp, sz, i]), ('ZSTD_createDDict', vp, [vp, sz]), ('ZSTD_compressBound', sz, [sz]),
                                ('ZSTD_compress_usingCDict', sz, [vp, vp, sz, vp, sz, vp]), ('ZSTD_decompress_usingDDict', sz, [vp, vp, sz, vp, sz, vp]),
                                ('ZSTD_getFrameContentSize', ctypes.c_ulonglong, [vp, sz]), ('ZSTD_isError', ui, [sz]), ('ZSTD_getErrorName', ctypes.c_char_p, [sz]),
                                ('ZDICT_trainFromBuffer', sz, [vp, sz, vp, vp, ui]), ('ZDICT_isError', ui, [sz]), ('ZSTD_compress', sz, [vp, sz, vp, sz, i])):
            f = getattr(L, name); f.restype = res; f.argtypes = args
        self.L = L

    def err(self, r, what):
        if self.L.ZSTD_isError(r): raise RuntimeError(f'zstd {what}: {self.L.ZSTD_getErrorName(r).decode()}')
        return r

    def train(self, samples, size=DICT_BYTES):
        """A dictionary of size bytes from the sample byte strings"""
        buf = b''.join(samples); sizes = (ctypes.c_size_t * len(samples))(*map(len, samples)); out = ctypes.create_string_buffer(size)
        n = self.L.ZDICT_trainFromBuffer(out, size, buf, sizes, len(samples))
        if self.L.ZDICT_isError(n): raise RuntimeError(f'zstd dictionary training: {self.L.ZSTD_getErrorName(n).decode()}')
        return out.raw[:n]

    def cdict(self, d, level): return self.L.ZSTD_createCDict(d, len(d), level)
    def ddict(self, d): return self.L.ZSTD_createDDict(d, len(d))

    def compress(self, data, cd, cctx):
        out = ctypes.create_string_buffer(self.L.ZSTD_compressBound(len(data)))
        n = self.err(self.L.ZSTD_compress_usingCDict(cctx, out, len(out), data, len(data), cd), 'compress')
        return out.raw[:n]

    def decompress(self, frame, dd, dctx):
        size = self.L.ZSTD_getFrameContentSize(frame, len(frame))
        if size >= (1 << 63): raise ValueError('zstd frame without a content size')
        out = ctypes.create_string_buffer(size)
        self.err(self.L.ZSTD_decompress_usingDDict(dctx, out, size, frame, len(frame), dd), 'decompress')
        return out.raw


def make_dict(z, samples, size):
    """A trained dictionary, or for a game with few shaders (the trainer needs many samples) the samples themselves as a raw-content dictionary"""
    if len(samples) >= 64:
        try: return z.train(samples, size)
        except RuntimeError: pass
    return b''.join(samples)[-size:] or b'shader_trim'


# ---------------------------------------------------------------- the used list
def key_of(text):
    """A shader key (16 hex digits) from a list's S / C row field (<key>_b), or None"""
    m = re.fullmatch(r'([0-9a-f]{16})(_b)?', text.strip())
    return m.group(1) if m else None


def read_used(paths):
    """The set of keys the lists name: S and C rows (<key>_b), and the vertex and fragment keys of R rows (pso_skey_hex: vs[24], fs[24] as text, in hex)"""
    keys, rows = set(), collections.Counter()
    for p in paths:
        with open(p, 'r', errors='replace') as f:
            for ln in f:
                c = ln.rstrip('\n').split('\t')
                if len(c) < 2 or ln.startswith('#'): continue
                if c[0] in ('S', 'C'): k = key_of(c[1]); got = [k] if k else []
                elif c[0] == 'R':
                    try: raw = bytes.fromhex(c[1][:96])
                    except ValueError: continue
                    got = [key_of(raw[o:o + 24].split(b'\0', 1)[0].decode('ascii', 'replace')) for o in (0, 24)]
                else: continue
                for k in got:
                    if k: keys.add(k); rows[c[0]] += 1
    return keys, rows


# ---------------------------------------------------------------- the source variants
def variants(key, msl, refl, bf_want=frozenset()):
    """{suffix: MSL text} of the libraries a full build made for this shader beyond its plain source: the pulling and shadow-input libraries of a vertex shader, the unit of a pixel shader's side and
    readable-tile entry points. Only what the reflection says exist; a variant the functions no longer produce is left out (the host draws without it, as for a build that failed to make it)"""
    import dmsh_pull, dmsh_vin, dmsh_side, dmsh_fetch
    out = {'_b': msl}
    if refl.get('stage') == 'vs':
        if refl.get('pull'):
            v, _ = dmsh_pull.variant(msl)
            if v: out['_bp'] = v
        if refl.get('vin'):
            v, _ = dmsh_vin.variant(msl)
            if v: out['_bv'] = v
    elif refl.get('stage') == 'ps' and (refl.get('alpha') or refl.get('logic') or refl.get('fetch')):
        unit, _ = dmsh_side.unit(msl)
        if refl.get('fetch'):
            folded, _ = dmsh_fetch.fold(unit or msl, refl.get('bindings') or [], om_only_ok=key in bf_want)
            unit = folded or unit
        if unit: out['_bu'] = unit
    return out


# ---------------------------------------------------------------- the split
def entries_of(path):
    """{name: size} of an image's files"""
    return {e.name: e.stat().st_size for e in romfs.Path(path).iterdir()}


def split(compiled, sources, map_path, used_paths, out_dir, level=19, jobs=4, say=print, limit=None, bf_want=frozenset()):
    """Writes out_dir/b-<chain>.img (trimmed), out_dir/shader_map.tsv and out_dir/trim_report.json. → the report dict"""
    t0 = time.time(); z = Zstd()
    used, rows = read_used(used_paths)
    cimg, simg = romfs.Path(compiled), romfs.Path(sources)
    cnames = {e.name for e in cimg.iterdir()}
    with open(map_path, 'r', errors='replace') as f: lines = f.read().split('\n')
    stage_of = {}
    for ln in lines:
        c = ln.split('\t')
        if len(c) > 3 and not ln.startswith('#') and c[0] != 'package': stage_of[c[3]] = c[2]
    keys = sorted({m.group(1) for n in cnames if (m := KEY.fullmatch(n))})
    snames = {e.name for e in simg.iterdir()}
    trim = [k for k in keys if k not in used and stage_of.get(k) in TRIM_STAGES and f'{k}_b.metallib' in cnames and f'{k}_b.json' in cnames and f'{k}_b.metal' in snames]
    if limit: trim = trim[:limit]
    say(f'{len(keys)} shaders in the image, {len(used)} named by the lists ({dict(rows)}), {len(trim)} go to source form')
    rnd = random.Random(0x7a5e)
    # dictionaries from the shaders' own sources: a random sample, as it comes from the cache image
    pick = rnd.sample(trim, min(len(trim), TRAIN_SAMPLES)) if trim else []
    samples, jsamples, total = [], [], 0
    for k in pick:
        try: s = (simg / f'{k}_b.metal').read_bytes()
        except OSError: continue
        if total + len(s) > TRAIN_BYTES: break
        samples.append(s); total += len(s); jsamples.append((cimg / f'{k}_b.json').read_bytes())
    d_msl, d_json = make_dict(z, samples, DICT_BYTES), make_dict(z, jsamples, 32768)
    say(f'dictionaries: msl {len(d_msl)} bytes from {len(samples)} sources ({total >> 20} MB), json {len(d_json)} bytes ({time.time() - t0:.0f} s)')
    import threading
    local = threading.local()
    cds = (z.cdict(d_msl, level), z.cdict(d_json, level))

    def cctx():
        if not hasattr(local, 'c'): local.c = z.L.ZSTD_createCCtx()
        return local.c

    def one(k):
        try: msl = (simg / f'{k}_b.metal').read_bytes().decode()
        except OSError: return k, None, 'no source in the cache image'
        refl = json.loads((cimg / f'{k}_b.json').read_bytes())
        vs = variants(k, msl, refl, bf_want)
        blobs = {f'{k}{suf}{MSL}': z.compress(text.encode(), cds[0], cctx()) for suf, text in vs.items()}
        blobs[f'{k}_b{JSONZ}'] = z.compress((cimg / f'{k}_b.json').read_bytes(), cds[1], cctx())
        return k, blobs, sorted(vs)

    files, src_keys, skipped, raw_msl, nblob = {}, {}, [], 0, 0
    with cf.ThreadPoolExecutor(jobs) as ex:
        for i, (k, blobs, info) in enumerate(ex.map(one, trim)):
            if blobs is None: skipped.append((k, info)); continue
            files.update(blobs); src_keys[k] = info
            if i % 2000 == 0: say(f'  {i}/{len(trim)} sources compressed ({time.time() - t0:.0f} s)')
    gone = set()
    for k in src_keys:
        gone.update(n for n in cnames if n.startswith(k + '_b') and KEY.fullmatch(n))
    for n in cnames:
        if n not in gone: files[n] = str(cimg / n)
    files[DICT_MSL], files[DICT_JSON] = d_msl, d_json
    files[INDEX] = (INDEX_HEAD + '\n' + ''.join(f'{k}\t{stage_of[k]}\t{",".join(v)}\n' for k, v in sorted(src_keys.items()))).encode()
    os.makedirs(out_dir, exist_ok=True)
    img = os.path.join(out_dir, os.path.basename(compiled))
    shader_lib.write(files, img)
    outmap = []
    for ln in lines:
        c = ln.split('\t')
        if not ln.strip() or ln.startswith('#'): outmap.append(ln)
        elif c[0] == 'package': outmap.append('\t'.join(c[:5] + ['form']))
        elif len(c) > 3: outmap.append('\t'.join(c[:5] + [''] * (5 - len(c[:5])) + ['src' if c[3] in src_keys else 'lib']))
        else: outmap.append(ln)
    outmap.insert(1, '# form (column 6): lib = a compiled library in the image, src = zstd MSL source the device compiles at first use (dm/gfx/tools/shader_trim.py)')
    with open(os.path.join(out_dir, 'shader_map.tsv'), 'w') as f: f.write('\n'.join(outmap))
    csize = os.path.getsize(compiled); isize = os.path.getsize(img)
    rep = {'keys': len(keys), 'used': len(used & set(keys)), 'source_keys': len(src_keys), 'no_source': len(skipped), 'compiled_image_bytes': csize, 'trimmed_image_bytes': isize,
           'dict_bytes': [len(d_msl), len(d_json)], 'msl_entries': sum(1 for n in files if n.endswith(MSL)), 'seconds': round(time.time() - t0)}
    with open(os.path.join(out_dir, 'trim_report.json'), 'w') as f: json.dump(rep, f, indent=1)
    say(f'trimmed image {isize >> 20} MB from {csize >> 20} MB, {len(src_keys)} shaders in source form ({len(skipped)} without a source stay compiled... see report)')
    return rep



def check(out_dir, say=print):
    """The image in out_dir against its shader_map.tsv: a src key has its _b.msl and _b.jsonz and no compiled _b files, a lib key has its _b.metallib, every source entry inflates. → the list of problems"""
    z = Zstd(); bad = []
    img = next(p for p in sorted(os.listdir(out_dir)) if p.endswith('.img'))
    im = romfs.Path(os.path.join(out_dir, img)); names = {e.name for e in im.iterdir()}
    dd, dj, dctx = z.ddict((im / DICT_MSL).read_bytes()), z.ddict((im / DICT_JSON).read_bytes()), z.L.ZSTD_createDCtx()
    nsrc = nlib = 0
    with open(os.path.join(out_dir, 'shader_map.tsv')) as f: map_lines = f.read().split('\n')
    for ln in map_lines:
        c = ln.split('\t')
        if ln.startswith('#') or c[0] == 'package' or len(c) < 6: continue
        k, form = c[3], c[5]
        if form == 'src':
            nsrc += 1
            for n in (f'{k}_b{MSL}', f'{k}_b{JSONZ}'):
                if n not in names: bad.append(f'{k}: {n} is not in the image')
            if f'{k}_b.metallib' in names or f'{k}_b.json' in names: bad.append(f'{k}: both forms are in the image')
            for n in (x for x in names if x.startswith(k) and x.endswith(MSL)):
                try: z.decompress((im / n).read_bytes(), dd, dctx)
                except (RuntimeError, ValueError, OSError) as e: bad.append(f'{n}: {e}')
            try: json.loads(z.decompress((im / f'{k}_b{JSONZ}').read_bytes(), dj, dctx))
            except (RuntimeError, ValueError, OSError, KeyError) as e: bad.append(f'{k}: json: {e}')
        elif f'{k}_b.metallib' in names: nlib += 1
    say(f'{nsrc} source, {nlib} compiled, {len(bad)} problems')
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0] if __doc__ else None)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('split')
    s.add_argument('--compiled', required=True); s.add_argument('--sources', required=True); s.add_argument('--map', required=True)
    s.add_argument('--used', action='append', default=[]); s.add_argument('--out', required=True)
    s.add_argument('--level', type=int, default=19); s.add_argument('--jobs', type=int, default=4); s.add_argument('--limit', type=int)
    s.add_argument('--bf-want')
    c = sub.add_parser('check'); c.add_argument('out')
    n = sub.add_parser('count'); n.add_argument('--used', action='append', default=[])   # the number of shaders the lists name (TVPort's Automatic)
    a = ap.parse_args()
    if a.cmd == 'check': return 1 if check(a.out) else 0
    if a.cmd == 'count': print(len(read_used(a.used)[0])); return 0
    bf = frozenset()
    if a.bf_want and os.path.exists(a.bf_want):
        with open(a.bf_want) as f: bf = frozenset(ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith('#'))
    split(a.compiled, a.sources, a.map, a.used, a.out, a.level, a.jobs, limit=a.limit, bf_want=bf)
    return 0


if __name__ == '__main__': sys.exit(main())

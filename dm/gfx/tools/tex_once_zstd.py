"""The zstd encoder tex_once re-packs frames with, and the check of what a frame is made of.

Smash's own zstd decoder (2018) hung at boot on frames with RLE blocks (Block_Type 1) and RLE literals, which stock libzstd emits for runs of one byte (the stripped textures are
mostly zero) and which no frame of Smash's data.arc contains. So the tool compresses with libzstd 1.5.7 patched not to emit either (tex_once_zstd_norle.patch, built by
tex_once_zstd_build.sh into a dylib cached in the tool's lib folder) and checks every frame it wrote with `frame_features`. Decompression stays with Python's zstd module."""
import ctypes
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ZSTD_MAGIC = b'\x28\xb5\x2f\xfd'
BLOCK_NAMES = {0: 'raw', 1: 'rle', 2: 'compressed'}
LITERAL_NAMES = {0: 'raw', 1: 'rle', 2: 'huffman', 3: 'treeless'}
ALLOWED_BLOCKS = frozenset({'raw', 'compressed'})
ALLOWED_LITERALS = frozenset({'raw', 'huffman', 'treeless'})

C_LEVEL, C_WINDOW_LOG, C_CONTENT_SIZE, C_CHECKSUM, C_DICT_ID = 100, 101, 200, 201, 202
E_CONTINUE, E_END = 0, 2

_work = None
_lib = None
_exact = None
_exact_cache = {}


def configure(work):
    """Where the dylib is built and cached (the tool's lib folder)"""
    global _work, _lib, _exact
    if work != _work: _lib = None; _exact = None
    _work = work


def _sources_hash():
    h = hashlib.sha256()
    for f in ('tex_once_zstd_norle.patch', 'tex_once_zstd_build.sh'):
        with open(os.path.join(HERE, f), 'rb') as fh: h.update(fh.read())
    return h.hexdigest()[:16]


def build(work):
    """libzstd without RLE blocks / RLE literals, cached in work by its patch's and script's hash. -> path"""
    lib = os.path.join(work, f'libzstd_norle-{_sources_hash()}.dylib')
    if os.path.exists(lib): return lib
    os.makedirs(work, exist_ok=True)
    import bntx_astc as B
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET=B.min_os())
    r = subprocess.run(['sh', os.path.join(HERE, 'tex_once_zstd_build.sh'), work, lib], capture_output=True, text=True, env=env)
    if r.returncode: raise RuntimeError(f'building the zstd encoder failed:\n{r.stderr[-2000:]}')
    return lib


def _open():
    global _lib
    if _lib is not None: return _lib
    work = _work or os.environ.get('TEX_ONCE_ZSTD_WORK') or os.path.join(tempfile.gettempdir(), f'tex_once_zstd-{os.getuid()}')
    L = ctypes.CDLL(build(work))
    vp, sz, ui, i = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint, ctypes.c_int
    L.ZSTD_createCCtx.restype = vp
    L.ZSTD_freeCCtx.argtypes = [vp]
    L.ZSTD_CCtx_reset.argtypes = [vp, i]; L.ZSTD_CCtx_reset.restype = sz
    L.ZSTD_CCtx_setParameter.argtypes = [vp, i, i]; L.ZSTD_CCtx_setParameter.restype = sz
    L.ZSTD_CCtx_setPledgedSrcSize.argtypes = [vp, ctypes.c_ulonglong]; L.ZSTD_CCtx_setPledgedSrcSize.restype = sz
    L.ZSTD_CCtx_loadDictionary.argtypes = [vp, vp, sz]; L.ZSTD_CCtx_loadDictionary.restype = sz
    L.ZSTD_compress2.argtypes = [vp, vp, sz, vp, sz]; L.ZSTD_compress2.restype = sz
    L.ZSTD_compressBound.argtypes = [sz]; L.ZSTD_compressBound.restype = sz
    L.ZSTD_isError.argtypes = [sz]; L.ZSTD_isError.restype = ui
    L.ZSTD_getErrorName.argtypes = [sz]; L.ZSTD_getErrorName.restype = ctypes.c_char_p
    class In(ctypes.Structure): _fields_ = [('src', vp), ('size', sz), ('pos', sz)]
    class Out(ctypes.Structure): _fields_ = [('dst', vp), ('size', sz), ('pos', sz)]
    L.In, L.Out = In, Out
    L.ZSTD_compressStream2.argtypes = [vp, ctypes.POINTER(Out), ctypes.POINTER(In), i]; L.ZSTD_compressStream2.restype = sz
    L.cctx = L.ZSTD_createCCtx()
    _lib = L
    return L


def _ok(L, r, what):
    if L.ZSTD_isError(r): raise RuntimeError(f'zstd {what}: {L.ZSTD_getErrorName(r).decode()}')
    return r


def frame_header(f):
    """The layout of a zstd frame's header: (frame header descriptor byte, window descriptor byte or None), or None for no frame"""
    if len(f) < 5 or f[:4] != ZSTD_MAGIC: return None
    return f[4], (None if (f[4] >> 5) & 1 else (f[5] if len(f) > 5 else None))


def params_like(like, level):
    """{zstd parameter: value} that give a frame the header layout of `like`, the original frame it replaces: its content size / checksum / dictionary ID flags and its window"""
    opts = {C_LEVEL: level}
    h = frame_header(like) if like else None
    if h is None: return opts
    fhd, wd = h
    opts[C_CHECKSUM] = (fhd >> 2) & 1
    opts[C_DICT_ID] = 1 if fhd & 3 else 0
    opts[C_CONTENT_SIZE] = 1 if (fhd >> 6) or ((fhd >> 5) & 1) else 0
    if wd is not None:
        opts[C_WINDOW_LOG] = max(10, 10 + (wd >> 3) + (1 if wd & 7 else 0))   # the power of two covering the original's window
    return opts


def compress(data, level, dict_content=None, like=None):
    """`data` as one zstd frame (no RLE blocks, no RLE literals) with the header layout of `like`; a frame without a content size is compressed as a stream of unknown size,
    so zstd keeps the window it is given (a one-shot compress knows the size and shrinks the window)"""
    L = _open()
    data = bytes(data)
    _ok(L, L.ZSTD_CCtx_reset(L.cctx, 3), 'reset')   # session and parameters
    for k, v in params_like(like, level).items(): _ok(L, L.ZSTD_CCtx_setParameter(L.cctx, k, v), 'parameter')
    if dict_content:
        dc = bytes(dict_content)
        _ok(L, L.ZSTD_CCtx_loadDictionary(L.cctx, dc, len(dc)), 'dictionary')
    cap = L.ZSTD_compressBound(len(data)) + 64
    out = ctypes.create_string_buffer(cap)
    src = ctypes.create_string_buffer(data, len(data)) if data else None
    h = frame_header(like) if like else None
    if h is not None and h[1] is not None and not (h[0] >> 6):
        i, o = L.In(ctypes.cast(src, ctypes.c_void_p), len(data), 0), L.Out(ctypes.cast(out, ctypes.c_void_p), cap, 0)
        while i.pos < i.size: _ok(L, L.ZSTD_compressStream2(L.cctx, ctypes.byref(o), ctypes.byref(i), E_CONTINUE), 'compress')
        while _ok(L, L.ZSTD_compressStream2(L.cctx, ctypes.byref(o), ctypes.byref(i), E_END), 'compress'): pass
        return out.raw[:o.pos]
    n = _ok(L, L.ZSTD_compress2(L.cctx, out, cap, src, len(data)), 'compress')
    return out.raw[:n]


def frame_features(buf, max_frames=1 << 20, zero_tail=False):
    """What a run of zstd frames is made of: {'frames', 'skippable', 'blocks': set of 'raw'/'rle'/'compressed', 'literals': set of 'raw'/'rle'/'huffman'/'treeless',
    'headers': [(descriptor, window descriptor)], 'tail': zero bytes after the last frame (only with zero_tail)}. Raises ValueError on bytes that are not a frame"""
    mv = memoryview(buf)
    p, n = 0, len(mv)
    res = dict(frames=0, skippable=0, blocks=set(), literals=set(), headers=[], tail=0)
    while p < n and res['frames'] + res['skippable'] < max_frames:
        if zero_tail and mv[p] == 0 and bytes(mv[p:]).count(0) == n - p: res['tail'] = n - p; return res
        if n - p < 8: raise ValueError('bytes after the last frame')
        magic = struct.unpack_from('<I', mv, p)[0]
        if 0x184d2a50 <= magic <= 0x184d2a5f:
            p += 8 + struct.unpack_from('<I', mv, p + 4)[0]; res['skippable'] += 1; continue
        if bytes(mv[p:p + 4]) != ZSTD_MAGIC: raise ValueError(f'not a zstd frame at {p}')
        fhd = mv[p + 4]
        res['headers'].append((fhd, None if (fhd >> 5) & 1 else mv[p + 5]))
        fcs = (0, 2, 4, 8)[fhd >> 6] if (fhd >> 6) else (1 if (fhd >> 5) & 1 else 0)
        q = p + 5 + (0 if (fhd >> 5) & 1 else 1) + (0, 1, 2, 4)[fhd & 3] + fcs
        while True:
            h = mv[q] | mv[q + 1] << 8 | mv[q + 2] << 16
            last, typ, size = h & 1, (h >> 1) & 3, h >> 3
            if typ == 3: raise ValueError('reserved block type')
            res['blocks'].add(BLOCK_NAMES[typ])
            if typ == 2 and size:
                res['literals'].add(LITERAL_NAMES[mv[q + 3] & 3])
            q += 3 + (1 if typ == 1 else size)
            if last: break
        if (fhd >> 2) & 1: q += 4
        p = q; res['frames'] += 1
    if p != n: raise ValueError('bytes after the last frame')
    return res


def forbidden(new, orig=None, skippable_ok=False):
    """Reasons a frame `new` uses a zstd feature that the archive's own frames (`orig`, when given) do not: block types outside raw/compressed, literal types outside raw/Huffman/treeless,
    a skippable frame where the original has none (unless skippable_ok). -> list of strings"""
    f = frame_features(new)
    bad = []
    if f['blocks'] - ALLOWED_BLOCKS: bad.append(f'block types {sorted(f["blocks"] - ALLOWED_BLOCKS)}')
    if f['literals'] - ALLOWED_LITERALS: bad.append(f'literal types {sorted(f["literals"] - ALLOWED_LITERALS)}')
    if f['skippable'] and not skippable_ok and (orig is None or not frame_features(orig)['skippable']): bad.append('a skippable frame')
    return bad


# ---- the exact encoder: zstd v1.3.5, streaming, unknown size -------------------------------------------------------------------------------------------------------------------------
# Super Smash Bros. Ultimate's data.arc frames (entries at level 9, window 2^21; the table at level 22) are what ZSTD_initCStream(level) + ZSTD_compressStream + ZSTD_endStream of v1.3.5 make of
# their content (no content size in the header). Re-packing with that encoder, at the level that reproduces each original frame, gives frames the game's own decoder reads.

def build_exact(work):
    """libzstd v1.3.5 (tex_once_zstd135_norlelit.patch), cached in work by its patch's and script's hash. -> path"""
    h = hashlib.sha256()
    for f in ('tex_once_zstd135_norlelit.patch', 'tex_once_zstd135_build.sh'):
        with open(os.path.join(HERE, f), 'rb') as fh: h.update(fh.read())
    lib = os.path.join(work, f'libzstd135-{h.hexdigest()[:16]}.dylib')
    if os.path.exists(lib): return lib
    os.makedirs(work, exist_ok=True)
    import bntx_astc as B
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET=B.min_os())
    r = subprocess.run(['sh', os.path.join(HERE, 'tex_once_zstd135_build.sh'), work, lib], capture_output=True, text=True, env=env)
    if r.returncode: raise RuntimeError(f'building the zstd v1.3.5 encoder failed:\n{r.stderr[-2000:]}')
    return lib


def _open_exact():
    global _exact
    if _exact is not None: return _exact
    work = _work or os.environ.get('TEX_ONCE_ZSTD_WORK') or os.path.join(tempfile.gettempdir(), f'tex_once_zstd-{os.getuid()}')
    L = ctypes.CDLL(build_exact(work))
    vp, sz, ui, i = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint, ctypes.c_int
    L.ZSTD_createCStream.restype = vp
    L.ZSTD_initCStream.argtypes = [vp, i]; L.ZSTD_initCStream.restype = sz
    L.ZSTD_compressBound.argtypes = [sz]; L.ZSTD_compressBound.restype = sz
    L.ZSTD_isError.argtypes = [sz]; L.ZSTD_isError.restype = ui
    L.ZSTD_getErrorName.argtypes = [sz]; L.ZSTD_getErrorName.restype = ctypes.c_char_p
    class In(ctypes.Structure): _fields_ = [('src', vp), ('size', sz), ('pos', sz)]
    class Out(ctypes.Structure): _fields_ = [('dst', vp), ('size', sz), ('pos', sz)]
    L.In, L.Out = In, Out
    L.ZSTD_compressStream.argtypes = [vp, ctypes.POINTER(Out), ctypes.POINTER(In)]; L.ZSTD_compressStream.restype = sz
    L.ZSTD_endStream.argtypes = [vp, ctypes.POINTER(Out)]; L.ZSTD_endStream.restype = sz
    L.zcs = L.ZSTD_createCStream()
    _exact = L
    return L


def exact_compress(data, level):
    """`data` as one zstd frame the way zstd v1.3.5 streams it with no pledged size: no content size in the header, the window of `level`, no checksum, no dictionary"""
    L = _open_exact()
    data = bytes(data)
    _ok(L, L.ZSTD_initCStream(L.zcs, level), 'init')
    cap = L.ZSTD_compressBound(len(data)) + 64
    out = ctypes.create_string_buffer(cap)
    src = ctypes.create_string_buffer(data, len(data)) if data else None
    i, o = L.In(ctypes.cast(src, ctypes.c_void_p), len(data), 0), L.Out(ctypes.cast(out, ctypes.c_void_p), cap, 0)
    while i.pos < i.size: _ok(L, L.ZSTD_compressStream(L.zcs, ctypes.byref(o), ctypes.byref(i)), 'compress')
    while _ok(L, L.ZSTD_endStream(L.zcs, ctypes.byref(o)), 'end'): pass
    return out.raw[:o.pos]


def level_window(level):
    """The window descriptor byte exact_compress gives frames of `level`"""
    if level not in _exact_cache: _exact_cache[level] = exact_compress(b'\0', level)[5]
    return _exact_cache[level]


def tail_ok(tail):
    """What may follow a frame in its slot: nothing, zeros, or skippable frame(s)"""
    if not tail or tail.count(0) == len(tail): return True
    try: f = frame_features(tail)
    except (ValueError, IndexError): return False
    return f['frames'] == 0


def match_level(orig, dec, big=8 << 20):
    """The level at which exact_compress(dec) reproduces the zstd frame at the start of `orig` byte for byte (the rest of `orig` being zeros or skippable frames), or None.
    Only levels with the frame's window descriptor are tried: the one that matched last for that window first, then 9, 22, then the rest (the rest only for content under `big` bytes; stronger levels are slow).
    A frame with a dictionary or a content size has no match"""
    orig = bytes(orig)
    h = frame_header(orig)
    if h is None or h[1] is None or h[0] != 0: return None
    cands = [lv for lv in range(1, 23) if level_window(lv) == h[1]]
    first = [lv for lv in (_exact_cache.get(('last', h[1])), 9, 22) if lv in cands]
    for lv in dict.fromkeys(first + (cands if len(dec) < big else [])):
        comp = exact_compress(dec, lv)
        if orig[:len(comp)] == comp and tail_ok(orig[len(comp):]):
            _exact_cache[('last', h[1])] = lv
            return lv
    return None

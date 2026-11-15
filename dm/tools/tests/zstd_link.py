"""The vendored zstd decoder for tests that compile C helpers including romfs_image.h (it includes romfs_sparse.h, which inflates DMSPARS1 v2 extents with zstd).
Same sources and flags as dm/host/Makefile (gen/zstd/libzstd.a) and dm/mac/pack_app.py; built once into a per-user cache and reused."""
import os
from pathlib import Path
import subprocess
import tempfile

ZSTD = Path(__file__).resolve().parents[2] / 'third_party/zstd'
FLAGS = ['-O1', '-DNDEBUG', '-DZSTD_DISABLE_ASM', '-DZSTD_MULTITHREAD=0']


def library():
    srcs = sorted(ZSTD.glob('common/*.c')) + sorted(ZSTD.glob('decompress/*.c'))
    stamp = max(int(p.stat().st_mtime) for p in srcs)
    cache = Path(tempfile.gettempdir()) / f'tvport-test-zstd-{os.getuid()}-{stamp}'
    lib = cache / 'libzstd.a'
    if lib.exists(): return lib
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache) as t:
        objs = []
        for i, s in enumerate(srcs):
            o = Path(t) / f'{i}_{s.stem}.o'
            subprocess.run(['cc', *FLAGS, '-I', str(ZSTD), '-c', '-o', str(o), str(s)], check=True)
            objs.append(str(o))
        tmp = Path(t) / 'libzstd.a'
        subprocess.run(['ar', 'rcs', str(tmp), *objs], check=True)
        os.replace(tmp, lib)
    return lib

#!/usr/bin/env python3
"""SHA-256 of an image's LOGICAL bytes through sparse_image.open_logical (the tool's reader): sparse_sha.py <image>"""
import hashlib, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import sparse_image as S

t0 = time.monotonic()
h = hashlib.sha256(); n = 0
with S.open_logical(sys.argv[1]) as f:
    while True:
        b = f.read(32 << 20)
        if not b: break
        h.update(b); n += len(b)
print(f'logical_size={n}\nsha256={h.hexdigest()}\nread_seconds={time.monotonic() - t0:.1f}')

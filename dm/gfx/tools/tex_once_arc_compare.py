#!/usr/bin/env python3
"""Compare every data.arc entry of a Smash RomFS image (plain or DMSPARS1) with the original image's.

Usage: tex_once_arc_compare.py ORIGINAL.img IMAGE.img [--workers N] [--json]
Per entry (unique offset in the file section, stored as the image's own table records it):
  identical               same stored size and the same stored bytes
  same_content_different  other stored bytes (re-packed) but the same inflated content
  content_changed         the inflated content differs
(an entry that cannot be inflated counts as undecodable). Also: whether the data.arc file-system table slot (16-byte header, frame, padding) is byte-identical and whether
the inflated table is equal.
"""
import argparse
import collections
import concurrent.futures as cf
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.join(HERE, '..', '..', 'tools')]
import romfs            # first: it makes the image paths readable by the plain open()
import smash_arc

CHUNK = 2000
_S = {}


def _open(path): return romfs.open(path + '/data.arc', 'rb')


def _inflate(d):
    if d[:4] == smash_arc.ZSTD_MAGIC: return smash_arc.zstd_mod().decompress(d)
    return d


def work(job):
    a_path, b_path, ents = job
    fa, fb = _open(a_path), _open(b_path)
    c = collections.Counter(); bad = []
    for off, sa, sb, size in ents:
        fa.seek(off); da = fa.read(sa); fb.seek(off); db = fb.read(sb)
        if sa == sb and da == db: c['identical'] += 1; continue
        try: ia, ib = _inflate(da), _inflate(db)
        except Exception as e: c['undecodable'] += 1; bad.append((off, str(e)[:80])); continue
        if ia[:size] == ib[:size] and len(ia) == len(ib): c['same_content_different_bytes'] += 1; bad.append((off, f'recompressed: stored {sa} -> {sb}, inflated {len(ia)}, header {da[4:6].hex()} -> {db[4:6].hex()}'))
        else: c['content_changed'] += 1; bad.append((off, 'content'))
        if sb < sa: c['stored_smaller'] += 1
        elif sb > sa: c['stored_larger'] += 1
    return dict(c), bad[:5]


def table_slot(path):
    T = smash_arc.table(path + '/data.arc')
    with _open(path) as f:
        f.seek(T['fs_off']); slot = f.read(16 + T['stored'])
    return T, slot


def compare(a_path, b_path, workers=4):
    ea = {e[1]: e for e in smash_arc.files(a_path + '/data.arc')}
    eb = {e[1]: e for e in smash_arc.files(b_path + '/data.arc')}
    res = collections.Counter(entries_original=len(ea), entries_image=len(eb))
    if set(ea) != set(eb): res['offset_sets_differ'] = len(set(ea) ^ set(eb))
    ents = [(o, ea[o][2], eb[o][2], ea[o][3]) for o in sorted(set(ea) & set(eb))]
    res['entries_compared'] = len(ents)
    jobs = [(a_path, b_path, ents[i:i + CHUNK]) for i in range(0, len(ents), CHUNK)]
    bad = []
    with cf.ProcessPoolExecutor(workers) as ex:
        for c, b in ex.map(work, jobs): res.update(c); bad += b
    Ta, sa = table_slot(a_path); Tb, sb = table_slot(b_path)
    out = {k: res.get(k, 0) for k in ('entries_original', 'entries_image', 'entries_compared', 'identical', 'same_content_different_bytes', 'content_changed', 'undecodable', 'stored_smaller', 'stored_larger')}
    if res.get('offset_sets_differ'): out['offset_sets_differ'] = res['offset_sets_differ']
    out['table_slot_bytes_identical'] = sa == sb
    out['table_inflated_identical'] = bytes(Ta['fs']) == bytes(Tb['fs'])
    out['table_stored_original_vs_image'] = [Ta['stored'], Tb['stored']]
    out['samples_of_trouble'] = bad[:8]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('original'); ap.add_argument('image')
    ap.add_argument('--workers', type=int, default=4); ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    r = compare(os.path.abspath(a.original), os.path.abspath(a.image), a.workers)
    if a.json: print(json.dumps(r, indent=1))
    else:
        for k, v in r.items(): print(f'{k:36} {v}')


if __name__ == '__main__':
    main()

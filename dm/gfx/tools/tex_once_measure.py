#!/usr/bin/env python3
"""Spike: how much of a game's RomFS.img would be zero/holes if every texture the ASTC pack covers were overwritten with a small tag (the 'texture once' design), and the resulting pack sizes.
Reuses bntx_astc.py's container walk (zstd, Yaz0, SARC, BNTX/BFRES, NUTEXB, Smash data.arc) and the engine's own layout/plane library. Read-only: streams the image, writes only a JSON report.

Per eligible texture (every instance, repeats included) the whole stored texture [start, start + layout size) becomes zero (a tag of 8 bytes at each plane start is below the noise).
Compressed containers: zstd is really recompressed after zeroing (level 3); Yaz0 has no encoder here, so the compressed bytes of the ops whose output lies in the zeroed ranges are summed from the
stream itself and replaced by the cost of a zero run (3.375 bytes per 273 zero bytes): an ESTIMATE. A frame's freed bytes = its stored size - its new size (the slot keeps its size, the tail is zero).

Usage: tex_once_measure.py <RomFS.img | build folder> --out report.json --attr-lib libyaz0_attr.dylib [--workers 4] [--limit N]
"""
import argparse, collections, concurrent.futures as cf, ctypes, json, os, struct, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bntx_astc as B

ZLEVEL = 3
YAZ0_ZERO = 3.375 / 273   # bytes of Yaz0 per zero byte in a long run (3-byte copy + flag bits)
_X = {}


def merge(rs):
    rs = sorted(r for r in rs if r[1] > r[0]); out = []
    for a, b in rs:
        if out and a <= out[-1][1]: out[-1][1] = max(out[-1][1], b)
        else: out.append([a, b])
    return out


def sarc_members_off(d):
    hl, bom, size, doff = struct.unpack_from('<HHII', d, 4)
    n = struct.unpack_from('<H', d, hl + 6)[0]
    names = hl + 12 + 16 * n + 8
    if not names <= doff <= len(d): raise ValueError('damaged SARC')
    for i in range(n):
        h, attr, s, e = struct.unpack_from('<IIII', d, hl + 12 + 16 * i)
        if not s <= e <= len(d) - doff: raise ValueError('SARC member outside the archive')
        if attr >> 24:
            o = names + (attr & 0xffffff) * 4; z = d.find(b'\0', o)
            nm = d[o:z if z >= 0 else len(d)].decode('utf-8', 'replace')
        else: nm = f'#{i}'
        yield nm, doff + s, doff + e


class MJob(B.Job):
    def __init__(self, lib, dicts, gob=0):
        super().__init__(lib, 4, None, False, dicts, 0, gob=gob)   # gob: the GOB order the runtime reads the game in (bntx_astc.gob_switch2)
        self.unique = {}          # key -> (w, h, in_cap512)
        self.alt = set()
        self.sigs = collections.Counter()      # chain -> texture bytes zeroed
        self.sigcount = collections.Counter()
        self.fmt_bytes = collections.Counter()
        self.cal = []             # (stored, recompressed original) samples of zstd frames
        self.fr = None; self.base = 0; self.chain = ()
        self.small_planes = 0; self.planes_total = 0; self.plane_bytes_total = 0
        self.skipped_cap_bytes = 0  # bytes of levels above the 512 cap (zeroed, not in the cap-512 pack)
        self.tex_bytes = 0
        self.fmtcov = collections.Counter()   # (group, comp|raw, all|cap512) -> stored bytes of covered planes

    # a texture: stats + zero range + plane keys (the pack model)
    def texture(self, d, t, name):
        c = self.c; L = self.L
        c['textures'] += 1
        if 'bad' in t: c['unparsed'] += 1; return
        fn = B.FORMAT_NAMES.get(t['fmt'], '%#x' % t['fmt'])
        self.formats[fn] += 1
        eligible = B.BC_ELIGIBLE.get(t['fmt'])
        if not eligible: self.fmt_bytes[fn] += t['size']; return
        tg = B.target_of(t)
        if tg is None or t['samples'] > 1 or t['dimension'] == 2: c['ineligible_shape'] += 1; self.fmt_bytes['shape:' + fn] += t['size']; return
        target, depth = tg
        if t['w'] == 0 or t['h'] == 0 or (not t['offs'] and not t.get('auto')) or t['w'] > 16384 or t['h'] > 16384: c['unparsed'] += 1; return
        c['eligible'] += 1
        nvn, alt = eligible
        pkg = 0 if t.get('auto') else (t['layout'] & 0xff) + 1
        start, size = t['start'], t['size']
        if start + size > t['end']: c['short'] += 1; return
        total = L.dm_texture_size(target, nvn, t['w'], t['h'], depth, t['mips'], pkg)
        if not total or total > size: c['layout_failed'] += 1; return
        layers = depth if target in (4, 8, 9) else 1
        ls = total // layers
        offs = [L.dm_level_offset(target, nvn, t['w'], t['h'], depth, t['mips'], pkg, i) for i in range(t['mips'])]
        skip = L.dm_skip_levels(target, nvn, t['w'], t['h'], depth, t['mips'], 512)
        # zero range: the whole texture, tag-sized planes excepted (counted)
        a = self.base + start
        self.fr['z'].append((a, a + total))
        self.tex_bytes += total
        self.sigs[self.chain + ('nutexb' if t.get('auto') else 'bntx',)] += total
        self.sigcount[self.chain + ('nutexb' if t.get('auto') else 'bntx',)] += 1
        grp = 'BC1' if t['fmt'] in (0x1a01, 0x1a06) else 'BC7' if t['fmt'] in (0x2001, 0x2006) else 'BC2/3'
        comp = 'comp' if ('zstd' in self.chain or 'yaz0' in self.chain) else 'raw'
        for i in range(t['mips']):
            span = (offs[i + 1] if i + 1 < t['mips'] else ls) - offs[i]
            self.planes_total += layers; self.plane_bytes_total += span * layers
            if span < 16: self.small_planes += layers
            if i < skip: self.skipped_cap_bytes += span * layers
            self.fmtcov[(grp, comp, 'all')] += span * layers
            if i >= skip: self.fmtcov[(grp, comp, 'cap512')] += span * layers
        import hashlib
        ident = hashlib.sha1(struct.pack('<7I', t['fmt'], t['w'], t['h'], depth, t['mips'], target, pkg) + d[start:start + size]).digest()
        if ident in self.seen: c['repeat'] += 1; return
        self.seen.add(ident)
        cap = t['mips'] * (depth + 1) + 8
        out = (B.Plane * cap)()
        n = L.dm_texture_planes(target, nvn, t['w'], t['h'], depth, t['mips'], pkg, B.addr(d) + start, size, 4, alt, None, 0, out, cap, 0)
        if n < 0: c['layout_failed2'] += 1; return
        c['converted'] += 1
        for i in range(n):
            p = out[i]; k = p.key.decode(); inc = p.level >= skip
            old = self.unique.get(k)
            self.unique[k] = (p.width, p.height, inc or (old[2] if old else False), grp)
            if alt: self.alt.add(p.key2.decode())

    def frame_after(self, kind, d, dec, cf_):
        z = merge(cf_['z'])
        if kind == 'zstd':
            buf = bytearray(dec)
            for a, b in z: buf[a:b] = bytes(b - a)
            z_ = B.zstd_module()
            new = len(z_.compress(bytes(buf), level=ZLEVEL))
            self.c['zstd_recompressed'] += 1
            if self.c['zstd_recompressed'] % 8 == 1: self.cal.append((len(d), len(z_.compress(dec, level=ZLEVEL)), new))
            return min(new + 16, len(d))   # +16: slack for the skippable-frame header / container bookkeeping
        # yaz0: estimate
        n = len(z)
        rs = (ctypes.c_uint64 * n)(*[a for a, _ in z]); re_ = (ctypes.c_uint64 * n)(*[b for _, b in z])
        attr = _X['attr'].dm_yaz0_attr(B.addr(d), len(d), rs, re_, n)
        zl = sum(b - a for a, b in z)
        if attr < 0: self.c['yaz0_attr_fail'] += 1; return len(d)
        self.c['yaz0_est'] += 1
        return int(max(16, len(d) - attr + zl * YAZ0_ZERO))

    def child(self, kind, d, dec, name, depth, hint, fr, base):
        cf_ = {'kind': kind, 'z': []}
        sf, sb, sc = self.fr, self.base, self.chain
        self.fr, self.base, self.chain = cf_, 0, sc + (kind,)
        try: self.blob(dec, name, depth + 1, hint)
        finally: self.fr, self.base, self.chain = sf, sb, sc
        if cf_['z']:
            after = self.frame_after(kind, d, dec, cf_)
            if after < len(d): fr['z'].append((base + after, base + len(d)))
            self.c['cframes_' + kind] += 1; self.c['cframe_stored_' + kind] += len(d); self.c['cframe_after_' + kind] += after
            self.c['cframe_zbytes_' + kind] += sum(b - a for a, b in merge(cf_['z']))

    def blob(self, d, name, depth=0, hint=''):
        c = self.c
        if depth > B.MAX_DEPTH: c['too_deep'] += 1; return
        m = d[:4]; fr, base = self.fr, self.base
        try:
            if m == b'\x28\xb5\x2f\xfd' or (len(m) == 4 and struct.unpack('<I', m)[0] in B.SKIPPABLE):
                c['zstd'] += 1
                return self.child('zstd', d, B.unzstd(d, self.dicts), name, depth, hint, fr, base)
            if m == b'Yaz0':
                c['yaz0'] += 1
                return self.child('yaz0', d, B.unyaz0(d, self.L), name, depth, hint, fr, base)
            if m == b'SARC':
                c['sarc'] += 1
                self.chain += ('sarc',)
                try:
                    for nm, s, e in sarc_members_off(d):
                        self.base = base + s
                        self.blob(d[s:e], name + '/' + nm, depth + 1, nm)
                finally: self.chain = self.chain[:-1]; self.base = base
                return
            if name.endswith('.nutexb'):
                c['nutexb'] += 1
                t = B.nutexb_texture(d)
                if t: self.texture(d, t, name)
                return
            if m in (b'BNTX', b'FRES', b'EFFN') or hint.endswith(('.bfres', '.bntx', '.bkres')) or name.endswith(('.bfres', '.bntx', '.bkres')):
                import re
                for mt in re.finditer(b'BNTX\0\0\0\0', d):
                    if B.bntx_ok(d, mt.start()):
                        c['bntx'] += 1
                        self.base = base
                        for t in B.bntx_textures(d, mt.start()):
                            self.base = base; self.texture(d, t, name)
                return
            c['other_files'] += 1; c['other_bytes'] += len(d)
        except (ValueError, struct.error, IndexError) as e:
            c['container_errors'] += 1
        except Exception as e:
            c['container_errors'] += 1; c.setdefault('x', 0)


def init(lib, romfs, attr):
    B.init_worker(lib, 4, None, False, romfs, {}, 0, gob=B.gob_switch2(romfs))
    _X['attr'] = ctypes.CDLL(attr); _X['attr'].dm_yaz0_attr.restype = ctypes.c_double
    _X['attr'].dm_yaz0_attr.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]


def work(batch):
    s = B._STATE
    job = MJob(s['lib'], {}, s.get('gob', 0))
    files = []   # per top-level file: (name, off, slot, dominant sig, tex bytes, freed, after_est)
    zr = []
    for name, off, size in batch:
        head = os.pread(s['fd'], 4, off)
        if head not in B.KNOWN_MAGIC and not (len(head) == 4 and head[1:4] == b'*M\x18' and 0x50 <= head[0] <= 0x5f) and not name.endswith(B.HINTS):
            job.c['other_files'] += 1; job.c['other_bytes'] += size
            continue
        d = os.pread(s['fd'], size, off)
        root = {'kind': 'raw', 'z': []}
        job.fr, job.base, job.chain = root, 0, ()
        sig0 = job.sigs.copy(); tb0 = job.tex_bytes
        job.blob(d, name)
        z = merge(root['z'])
        if not z: continue
        diff = {k: v - sig0.get(k, 0) for k, v in job.sigs.items() if v != sig0.get(k, 0)}
        dom = max(diff, key=diff.get) if diff else ('?',)
        freed = sum(b - a for a, b in z)
        files.append((dom, size, job.tex_bytes - tb0, freed))
        zr += [(off + a, off + b) for a, b in z]
    c = dict(job.c)
    return dict(c=c, files=files, zr=zr, unique=job.unique, alt=job.alt, sigs=dict(job.sigs), sigcount=dict(job.sigcount), fmt_bytes=dict(job.fmt_bytes), cal=job.cal,
                small=job.small_planes, planes=job.planes_total, plane_bytes=job.plane_bytes_total, skipped_cap=job.skipped_cap_bytes, tex_bytes=job.tex_bytes, fmtcov={'|'.join(k): v for k, v in job.fmtcov.items()})


def holes(z, bs):
    t = 0
    for a, b in z:
        lo = -(-a // bs) * bs; hi = b // bs * bs
        if hi > lo: t += hi - lo
    return t


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('input'); ap.add_argument('--out', required=True); ap.add_argument('--attr-lib', required=True)
    ap.add_argument('--workers', type=int, default=4); ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--lib', required=True, help='libastc_prebuild dylib (bntx_astc.build_library output)')
    a = ap.parse_args()
    romfs = B.find_romfs(a.input)
    files = B.image_files(romfs)
    total_files = sum(f[2] for f in files)
    files = B.smash_arc_files(romfs, files)
    if a.limit: files = files[:a.limit]
    t0 = time.monotonic()
    chunks = list(B.batches(files, 64 << 20 if len(files) > a.workers * 8 else 1))
    R = collections.Counter(); unique = {}; alt = set(); sigs = collections.Counter(); sigcount = collections.Counter(); fb = collections.Counter(); cal = []
    fmtcov = collections.Counter()
    classes = collections.defaultdict(lambda: [0, 0, 0, 0]); zr = []; small = planes = plane_bytes = skipped = tex = 0
    with cf.ProcessPoolExecutor(a.workers, initializer=init, initargs=(a.lib, romfs, a.attr_lib)) as ex:
        for i, r in enumerate(ex.map(work, chunks)):
            R.update(r['c']); alt |= r['alt']; sigs.update(r['sigs']); sigcount.update(r['sigcount']); fb.update(r['fmt_bytes']); cal += r['cal']; zr += r['zr']
            fmtcov.update(r['fmtcov']); small += r['small']; planes += r['planes']; plane_bytes += r['plane_bytes']; skipped += r['skipped_cap']; tex += r['tex_bytes']
            for k, (w, h, inc, g) in r['unique'].items():
                o = unique.get(k); unique[k] = (w, h, inc or (o[2] if o else False), g)
            for dom, slot, tb, freed in r['files']:
                cl = classes['/'.join(dom)]; cl[0] += 1; cl[1] += slot; cl[2] += tb; cl[3] += freed
            if i % 20 == 0: print(f'{i}/{len(chunks)} {time.monotonic() - t0:.0f}s', file=sys.stderr, flush=True)
    z = merge(zr)
    def pack(cap, block):   # block: int, or {group: block}
        pay = ent = 0
        for k, (w, h, inc, g) in unique.items():
            if cap and not inc: continue
            bk = block if isinstance(block, int) else block[g]
            n = 16 * -(-w // bk) * -(-h // bk)
            pay += (40 + n + 15) // 16 * 16; ent += 1
        return pay, ent
    out = dict(input=romfs, image_bytes=total_files, scanned_bytes=sum(f[2] for f in files), counters=dict(R), texture_bytes_zeroed=tex, plane_bytes=plane_bytes, planes=planes, small_planes_lt16=small,
               bytes_in_levels_above_cap512=skipped, zero_bytes_total=sum(b - a for a, b in z), intervals=len(z),
               holes={str(bs): holes(z, bs) for bs in (4096, 16384, 65536, 262144)},
               classes={k: dict(files=v[0], stored=v[1], texture_bytes=v[2], freed=v[3]) for k, v in sorted(classes.items(), key=lambda kv: -kv[1][3])},
               sigs={'/'.join(k): [sigcount[k], v] for k, v in sorted(sigs.items(), key=lambda kv: -kv[1])},
               uncovered_texture_bytes=dict(fb.most_common()), zstd_cal=cal[:200], unique_planes=len(unique), alt_keys=len(alt - set(unique)), pack={})
    out['fmtcov'] = dict(fmtcov)
    for cap in (0, 512):
        for block in (4, 6, 'bc1_6', 'bc1_5'):
            bm = block if isinstance(block, int) else {'BC1': int(block[-1]), 'BC2/3': 4, 'BC7': 4}
            pay, ent = pack(cap, bm); n_alias = len(alt - set(unique)) if cap == 0 else None
            out['pack'][f'cap{cap}_b{block}'] = dict(payload_bytes=pay, payloads=ent, entries_cap0_incl_alias=ent + len(alt - set(unique)), head_plus_index_cap0=80 + 48 * (ent + len(alt - set(unique))), total_cap0=pay + 80 + 48 * (ent + len(alt - set(unique))))
    out['seconds'] = round(time.monotonic() - t0)
    with open(a.out, 'w') as f: json.dump(out, f, indent=1)
    print('done', out['seconds'], 's', file=sys.stderr)


if __name__ == '__main__':
    main()

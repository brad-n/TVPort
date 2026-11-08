// DMSPARS1: a sparse wrapper around one DMROMFS1 image (docs/texture_once.md section 1), and the one read every RomFS image consumer goes through (romfs_image.h loader, hle_fs.c ReadFile, the
// identity in romfs_identity.h, iOS / Mac startup validation). A plain DMROMFS1 file is the same thing with no extents: romfs_src_open accepts both and reads them alike.
//
// Layout (little-endian). Header, 64 bytes at physical 0: "DMSPARS1", u32 version 1, u32 header size 64, u64 logical size (bytes of the DMROMFS1 image), u64 extent count, u64 extent table offset
// (16-byte aligned), u64 pack offset (16384-byte aligned, 0 = none), u64 pack size, u64 reserved 0. Extent table: {u64 logical offset, u64 length, u64 physical offset} x N, sorted by logical offset,
// non-overlapping, length > 0, inside the logical size; logical bytes no extent covers read as zero. Embedded pack: an NXASTCPK file at the pack offset. Trailer, 32 bytes, the last bytes of the file:
// "DMSPEND1", u64 total file size, u64 extent table offset, u64 0. A missing or disagreeing trailer is a cut-off copy and the file is rejected.
//
// Version 2 (docs/texture_once.md section 7a): header version 2 and 32-byte extents {u64 logical offset, u64 length, u64 physical offset, u32 stored length, u32 kind}; kind 0 = raw (stored == length),
// kind 1 = one zstd frame of exactly `stored` bytes that inflates to exactly `length` (at most 256 KiB). The pack stays raw. A zstd extent is inflated whole into a block cache that every reader of the
// same romfs_src shares (a mutex guards the table, a block being read is pinned; the inflate itself runs outside the lock): DM_ROMFS_ZCACHE_MB (default 16) bounds the bytes it keeps, least recently used out
// first. A frame that fails to inflate or does not give `length` bytes is a read error (errno EIO) with one [RED] line, never zeros. Version 1 files read exactly as before.
//
// A STRIPPED image (one whose textures were replaced by tags, tex_once.py) is recognised as a DMSPARS1 with an embedded pack (romfs_src.pack_size != 0): only a pack makes a tag resolvable, and the
// tool always embeds one. nvn_mtl.m refuses such an image where the GPU has native BC or the ASTC path is off (a tagged plane would draw from zeros).
#pragma once
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../third_party/zstd/zstd.h"   // decoder only

typedef struct { uint64_t lo, len, phys; uint32_t stored, kind; } romfs_ext;   // kind 0 raw / 1 zstd (version 2; v1 extents are raw with stored = len mod 2^32, unused)
#define ROMFS_ZBLOCK_MAX (256u << 10)   // the longest logical run a zstd extent may hold
typedef struct {
    int fd;
    int sparse;                 // 1: DMSPARS1; 0: a plain file read as it is
    uint64_t logical;           // size of the DMROMFS1 image (the file size when plain)
    uint64_t file_size;
    uint64_t n; romfs_ext *ext; // extents (sparse only)
    struct romfs_zcache *zc;    // the shared block cache of a version 2 image with zstd extents (NULL otherwise); freed by romfs_src_free
    uint64_t pack_off, pack_size;   // the embedded pack's place in the FILE (physical); 0 / 0 when there is none
} romfs_src;

#define ROMFS_SPARSE_HEAD 64u
#define ROMFS_SPARSE_TAIL 32u

static uint64_t romfs_src_le64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t romfs_src_le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

// ---- The shared decompressed-block cache (version 2). One per opened image, reached by every copy of the romfs_src through zc; blocks are keyed by extent index. ----
typedef struct romfs_zblk { struct romfs_zblk *prev, *next; uint64_t idx; size_t len; int refs; uint8_t *data; } romfs_zblk;
struct romfs_zcache {
    pthread_mutex_t mu;
    romfs_zblk **by_ext;          // extent index -> resident block (NULL if none); n entries
    romfs_zblk *head, *tail;      // most recently used first
    size_t cap, used;             // bytes kept (cap from DM_ROMFS_ZCACHE_MB), bytes held now
};
static size_t romfs_zcache_cap_bytes(void) {
    const char *e = getenv("DM_ROMFS_ZCACHE_MB"); double mb = 16;
    if (e && *e) { char *end; double v = strtod(e, &end); if (end != e && v >= 0 && v < 1048576) mb = v; }
    return (size_t)(mb * 1048576.0);
}
static void romfs_src_free(romfs_src *s) {
    if (!s) return;
    if (s->zc) {
        for (romfs_zblk *b = s->zc->head, *nx; b; b = nx) { nx = b->next; free(b->data); free(b); }
        pthread_mutex_destroy(&s->zc->mu); free(s->zc->by_ext); free(s->zc); s->zc = NULL;
    }
    free(s->ext); s->ext = NULL; s->n = 0;
}
static void romfs_zred(const romfs_src *s, uint64_t idx, const char *why) {
    fprintf(stderr, "[RED] RomFS image: compressed extent %llu (logical %llu, %u bytes stored, %llu inflated) is unreadable: %s\n", (unsigned long long)idx,
            (unsigned long long)s->ext[idx].lo, s->ext[idx].stored, (unsigned long long)s->ext[idx].len, why);
}
static void romfs_zunlink(struct romfs_zcache *c, romfs_zblk *b) {
    if (b->prev) b->prev->next = b->next; else c->head = b->next;
    if (b->next) b->next->prev = b->prev; else c->tail = b->prev;
    b->prev = b->next = NULL;
}
static void romfs_zpush(struct romfs_zcache *c, romfs_zblk *b) { b->prev = NULL; b->next = c->head; if (c->head) c->head->prev = b; c->head = b; if (!c->tail) c->tail = b; }

// pread until size bytes are read or the file ends; -1 on an error with nothing read (a partial count is returned as such)
static ssize_t romfs_src_raw(int fd, void *buf, size_t size, uint64_t off) {
    size_t got = 0;
    while (got < size) {
        ssize_t n = pread(fd, (char *)buf + got, size - got, (off_t)(off + got));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return got ? (ssize_t)got : -1;
        if (!n) break;
        got += (size_t)n;
    }
    return (ssize_t)got;
}
// The inflated bytes of zstd extent idx: from the cache (*pin set, the block is pinned until romfs_zrelease) or, when the cache cannot keep it, in a private buffer (*priv set, the caller frees it). NULL with errno EIO
// (and one [RED] line) when the frame cannot be read or inflated, or does not give exactly the extent's length
static const uint8_t *romfs_zblock(const romfs_src *s, uint64_t idx, romfs_zblk **pin, uint8_t **priv) {
    struct romfs_zcache *c = s->zc; const romfs_ext *x = &s->ext[idx];
    *pin = NULL; *priv = NULL;
    pthread_mutex_lock(&c->mu);
    romfs_zblk *b = c->by_ext[idx];
    if (b) { b->refs++; if (c->head != b) { romfs_zunlink(c, b); romfs_zpush(c, b); } pthread_mutex_unlock(&c->mu); *pin = b; return b->data; }
    pthread_mutex_unlock(&c->mu);
    uint8_t *in = malloc(x->stored), *out = malloc((size_t)x->len); const char *why = NULL;
    if (!in || !out) { free(in); free(out); errno = ENOMEM; return NULL; }
    ssize_t got = romfs_src_raw(s->fd, in, x->stored, x->phys);
    if (got < 0 || (size_t)got != x->stored) why = "the file ends inside the frame";
    else if (ZSTD_findFrameCompressedSize(in, x->stored) != x->stored) why = "not exactly one zstd frame";
    else { size_t r = ZSTD_decompress(out, (size_t)x->len, in, x->stored); if (ZSTD_isError(r)) why = ZSTD_getErrorName(r); else if (r != x->len) why = "the frame inflates to the wrong size"; }
    free(in);
    if (why) { romfs_zred(s, idx, why); free(out); errno = EIO; return NULL; }
    pthread_mutex_lock(&c->mu);
    if ((b = c->by_ext[idx])) {   // another reader got there first: use its block
        b->refs++; if (c->head != b) { romfs_zunlink(c, b); romfs_zpush(c, b); } pthread_mutex_unlock(&c->mu); free(out); *pin = b; return b->data;
    }
    size_t len = (size_t)x->len;
    for (romfs_zblk *v = c->tail, *pv; v && c->used + len > c->cap; v = pv) {   // make room: least recently used first, never a block a reader is copying from
        pv = v->prev;
        if (!v->refs) { romfs_zunlink(c, v); c->by_ext[v->idx] = NULL; c->used -= v->len; free(v->data); free(v); }
    }
    if (c->used + len <= c->cap && (b = malloc(sizeof *b))) {
        b->idx = idx; b->len = len; b->refs = 1; b->data = out; c->by_ext[idx] = b; c->used += len; romfs_zpush(c, b);
        pthread_mutex_unlock(&c->mu); *pin = b; return out;
    }
    pthread_mutex_unlock(&c->mu);
    *priv = out; return out;
}
static void romfs_zrelease(const romfs_src *s, romfs_zblk *b) { pthread_mutex_lock(&s->zc->mu); b->refs--; pthread_mutex_unlock(&s->zc->mu); }
// Whether fd is a DMSPARS1 file (1, s filled in), a plain file (1, s->sparse = 0) or neither (0, errno EINVAL for a damaged / cut-off one). The caller keeps the descriptor; romfs_src_free releases the table.
static int romfs_src_open(int fd, romfs_src *s) {
    struct stat st; uint8_t h[ROMFS_SPARSE_HEAD], t[ROMFS_SPARSE_TAIL];
    memset(s, 0, sizeof *s); s->fd = fd;
    if (fstat(fd, &st)) return 0;
    s->file_size = s->logical = (uint64_t)st.st_size;
    ssize_t r = romfs_src_raw(fd, h, 8, 0);
    if (r < 0) return 0;
    if (r < 8 || memcmp(h, "DMSPARS1", 8)) return 1;   // a plain file (the DMROMFS1 checks follow in the caller)
    uint64_t fsz = (uint64_t)st.st_size; errno = EINVAL;
    if (fsz < ROMFS_SPARSE_HEAD + ROMFS_SPARSE_TAIL || romfs_src_raw(fd, h, sizeof h, 0) != (ssize_t)sizeof h || romfs_src_raw(fd, t, sizeof t, fsz - ROMFS_SPARSE_TAIL) != (ssize_t)sizeof t) goto bad;
    uint64_t logical = romfs_src_le64(h + 16), n = romfs_src_le64(h + 24), toff = romfs_src_le64(h + 32), poff = romfs_src_le64(h + 40), psz = romfs_src_le64(h + 48);
    uint64_t body = fsz - ROMFS_SPARSE_TAIL;   // physical bytes before the trailer
    uint32_t ver = romfs_src_le32(h + 8); size_t esz = ver == 2 ? 32 : 24;
    if ((ver != 1 && ver != 2) || romfs_src_le32(h + 12) != ROMFS_SPARSE_HEAD || romfs_src_le64(h + 56)) goto bad;
    if (memcmp(t, "DMSPEND1", 8) || romfs_src_le64(t + 8) != fsz || romfs_src_le64(t + 16) != toff || romfs_src_le64(t + 24)) goto bad;
    if ((toff & 15) || toff < ROMFS_SPARSE_HEAD || toff > body || n > (body - toff) / esz || n > SIZE_MAX / sizeof(romfs_ext)) goto bad;
    if (!poff != !psz) goto bad;
    if (poff && ((poff & 16383) || poff < ROMFS_SPARSE_HEAD || poff > body || psz > body - poff || psz < 80)) goto bad;
    if (poff) {   // the pack's own header: magic, and the file size it records is the pack size
        uint8_t ph[80];
        if (romfs_src_raw(fd, ph, sizeof ph, poff) != (ssize_t)sizeof ph || memcmp(ph, "NXASTCPK", 8) || romfs_src_le64(ph + 32) != psz) goto bad;
    }
    uint8_t *raw = n ? malloc((size_t)n * esz) : NULL; romfs_ext *e = n ? malloc((size_t)n * sizeof *e) : NULL;
    if (n && (!raw || !e)) { free(raw); free(e); errno = ENOMEM; return 0; }
    if (n && romfs_src_raw(fd, raw, (size_t)n * esz, toff) != (ssize_t)(n * esz)) { free(raw); free(e); goto bad; }
    uint64_t prev_end = 0, nz = 0;
    for (uint64_t i = 0; i < n; i++) {
        const uint8_t *r = raw + i * esz;
        e[i].lo = romfs_src_le64(r); e[i].len = romfs_src_le64(r + 8); e[i].phys = romfs_src_le64(r + 16);
        if (ver == 2) { e[i].stored = romfs_src_le32(r + 24); e[i].kind = romfs_src_le32(r + 28); } else { e[i].kind = 0; e[i].stored = 0; }
        const romfs_ext *x = &e[i];
        uint64_t sl = ver == 2 ? x->stored : x->len;   // the bytes the extent occupies in the file
        int ok = x->len && x->lo >= prev_end && x->lo <= logical && x->len <= logical - x->lo                       // sorted, non-overlapping, inside the logical image
              && (ver == 1 || (x->kind == 0 && x->stored == x->len) || (x->kind == 1 && x->stored && x->len <= ROMFS_ZBLOCK_MAX))   // version 2: raw is stored whole, zstd holds at most 256 KiB
              && x->phys >= ROMFS_SPARSE_HEAD && x->phys <= body && sl <= body - x->phys                              // inside the file, clear of header and trailer
              && (x->phys + sl <= toff || x->phys >= toff + n * esz)                                                  // clear of the table
              && (!poff || x->phys + sl <= poff || x->phys >= poff + psz);                                            // clear of the pack
        if (!ok) { free(raw); free(e); goto bad; }
        prev_end = x->lo + x->len; nz += x->kind == 1;
    }
    free(raw);
    if (poff && ((poff < toff + n * esz && poff + psz > toff))) { free(e); goto bad; }   // the pack over the table
    if (nz) {   // the shared block cache
        struct romfs_zcache *c = calloc(1, sizeof *c);
        if (c) { c->by_ext = calloc((size_t)n, sizeof *c->by_ext); c->cap = romfs_zcache_cap_bytes(); if (c->by_ext) pthread_mutex_init(&c->mu, NULL); else { free(c); c = NULL; } }
        if (!c) { free(e); errno = ENOMEM; return 0; }
        s->zc = c;
    }
    s->sparse = 1; s->logical = logical; s->n = n; s->ext = e; s->pack_off = poff; s->pack_size = psz;
    return 1;
bad:
    errno = EINVAL; return 0;
}
// Reads logical [off, off + size): the bytes an extent holds come from the file, the others are zero. Returns the bytes read, short only at the logical end (like pread), or -1 with errno set when nothing could be
// read; a failure after some bytes returns the count so far (the caller's next call meets the error again)
static ssize_t romfs_src_pread(const romfs_src *s, void *buf, size_t size, uint64_t off) {
    if (!s->sparse) return romfs_src_raw(s->fd, buf, size, off);
    if (off >= s->logical) return 0;
    if (size > s->logical - off) size = (size_t)(s->logical - off);
    uint64_t lo = 0, hi = s->n;   // the first extent that ends after off
    while (lo < hi) { uint64_t mid = lo + (hi - lo) / 2; if (s->ext[mid].lo + s->ext[mid].len <= off) lo = mid + 1; else hi = mid; }
    size_t done = 0;
    while (done < size) {
        uint64_t at = off + done; size_t want = size - done;
        if (lo < s->n && s->ext[lo].lo <= at) {   // inside an extent
            const romfs_ext *x = &s->ext[lo]; uint64_t in = at - x->lo, left = x->len - in;
            size_t n = want < left ? want : (size_t)left;
            if (x->kind == 1) {   // a zstd extent: through the shared block cache
                romfs_zblk *pin; uint8_t *priv; const uint8_t *blk = romfs_zblock(s, lo, &pin, &priv);
                if (!blk) return done ? (ssize_t)done : -1;
                memcpy((char *)buf + done, blk + in, n);
                if (pin) romfs_zrelease(s, pin); else free(priv);
                done += n; if (n == left) lo++;
                continue;
            }
            ssize_t r = romfs_src_raw(s->fd, (char *)buf + done, n, x->phys + in);
            if (r < 0) return done ? (ssize_t)done : -1;
            if ((size_t)r < n) { errno = EIO; return done + (size_t)r ? (ssize_t)(done + (size_t)r) : -1; }   // the file is shorter than its table says
            done += n; if (n == left) lo++;
        } else {   // a hole up to the next extent
            size_t n = want; if (lo < s->n && s->ext[lo].lo - at < n) n = (size_t)(s->ext[lo].lo - at);
            memset((char *)buf + done, 0, n); done += n;
        }
    }
    return (ssize_t)done;
}
// The whole range or a failure (errno EINVAL for a short read)
static int romfs_src_read(const romfs_src *s, void *buf, size_t size, uint64_t off) {
    ssize_t r = romfs_src_pread(s, buf, size, off);
    if (r < 0) return 0;
    if ((size_t)r != size) { errno = EINVAL; return 0; }
    return 1;
}

// DMSPARS1 (dm/host/romfs_sparse.h, docs/texture_once.md section 1): reads across extent and hole boundaries, reads past the logical end, every kind of damaged file refused, a DMROMFS1 wrapped in a
// DMSPARS1 reading exactly like the plain image, and the RomFS identity of the wrapped image equal to the plain one's. Expected values come from the logical bytes the fixture was made from
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include "../romfs_image.h"
#include "../romfs_identity.h"
#include "romfs_sparse_fixture.h"

static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL (line %d): ", __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static char g_dir[1024];
static char *path(const char *name) { static char b[8][1200]; static int k; char *r = b[k++ & 7]; snprintf(r, 1200, "%s/%s", g_dir, name); return r; }
static void write_file(const char *p, const uint8_t *d, size_t n) { FILE *f = fopen(p, "wb"); assert(f && fwrite(d, 1, n, f) == n); fclose(f); }
static uint32_t g_rng = 12345;
static uint32_t rnd(void) { g_rng = g_rng * 1664525u + 1013904223u; return g_rng >> 8; }
static int opens(const uint8_t *f, size_t n, romfs_src *out) {   // the file's bytes through romfs_src_open
    write_file(path("t.bin"), f, n);
    int fd = open(path("t.bin"), O_RDONLY); romfs_src s; errno = 0; int ok = romfs_src_open(fd, &s);
    if (ok && out) *out = s; else if (ok) romfs_src_free(&s);
    if (!ok || !out) close(fd);
    return ok && s.sparse;
}

int main(void) {
    snprintf(g_dir, sizeof g_dir, "%s/t_romfs_sparse.%d", getenv("TMPDIR") && *getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid()); mkdir(g_dir, 0755);

    printf("reads across extents and holes\n");
    enum { N = 60000 };
    uint8_t *L = malloc(N);
    for (int i = 0; i < N; i++) L[i] = (uint8_t)(1 + rnd() % 255);
    memset(L + 5000, 0, 9000);                 // a hole (>= 4096)
    memset(L + 30000, 0, 4096);                // exactly 4096: a hole
    memset(L + 40000, 0, 4095);                // 4095: stays inside an extent (the contract's writer rule)
    memset(L + 50000, 0, N - 50000);           // a hole that ends the image
    uint8_t *pack; size_t pack_n = fx_pack(&pack, 0, NULL, 0, 0);
    uint8_t *file; size_t file_n; long ne = fx_write_sparse(NULL, L, N, 4096, 3000, pack, pack_n, &file, &file_n);
    CHECK(ne > 4, "the fixture has several extents (%ld)", ne);
    romfs_src s; CHECK(opens(file, file_n, &s), "a well-formed DMSPARS1 opens");
    CHECK(s.sparse && s.logical == N && s.n == (uint64_t)ne && s.pack_off && !(s.pack_off & 16383) && s.pack_size == pack_n, "header fields: logical %llu extents %llu pack %llu+%llu", (unsigned long long)s.logical, (unsigned long long)s.n, (unsigned long long)s.pack_off, (unsigned long long)s.pack_size);
    uint8_t *got = malloc(N + 100);
    CHECK(romfs_src_pread(&s, got, N, 0) == N && !memcmp(got, L, N), "the whole logical image reads back");
    int bad = 0;
    for (int k = 0; k < 20000; k++) {   // random windows, plus every edge of every extent
        uint64_t off = rnd() % (N + 50); size_t len = rnd() % 9000;
        if (k < 2 * (int)s.n * 3) { const romfs_ext *x = &s.ext[(k / 6) % s.n]; int64_t edge = (int64_t)((k & 1) ? x->lo + x->len : x->lo); off = (uint64_t)(edge + (int64_t)(k / 2 % 3) - 1); if ((int64_t)off < 0) off = 0; len = (size_t)(1 + (k % 5) * 7); }
        size_t want = off >= N ? 0 : (N - off < len ? N - off : len);
        memset(got, 0xAA, len + 1);
        ssize_t r = romfs_src_pread(&s, got, len, off);
        if (r != (ssize_t)want || (want && memcmp(got, L + off, want)) || (len > want && got[want] != 0xAA)) { if (bad++ < 3) fprintf(stderr, "window off %llu len %zu: got %zd want %zu\n", (unsigned long long)off, len, r, want); }
    }
    CHECK(!bad, "%d wrong windows of 20000", bad);
    CHECK(romfs_src_pread(&s, got, 10, N) == 0 && romfs_src_pread(&s, got, 10, N + 5) == 0 && romfs_src_pread(&s, got, 0, 3) == 0, "reads at and past the logical end are empty");
    CHECK(romfs_src_pread(&s, got, 100, N - 10) == 10 && !memcmp(got, L + N - 10, 10), "a read across the logical end is short");
    CHECK(!romfs_src_read(&s, got, 100, N - 10) && errno == EINVAL && romfs_src_read(&s, got, 10, N - 10), "the full-read wrapper fails on a short read");
    // the pack bytes are where the header says
    { uint8_t ph[80]; CHECK(pread(s.fd, ph, 80, (off_t)s.pack_off) == 80 && !memcmp(ph, "NXASTCPK", 8), "the embedded pack is at its offset"); }
    close(s.fd); romfs_src_free(&s);

    printf("a plain file reads as it is\n");
    { uint8_t plain[300]; for (int i = 0; i < 300; i++) plain[i] = (uint8_t)i; write_file(path("p.bin"), plain, 300);
      int fd = open(path("p.bin"), O_RDONLY); romfs_src p; CHECK(romfs_src_open(fd, &p) && !p.sparse && p.logical == 300 && !p.pack_size, "a plain file: not sparse, its own size");
      uint8_t b[400]; CHECK(romfs_src_pread(&p, b, 400, 250) == 50 && !memcmp(b, plain + 250, 50) && romfs_src_pread(&p, b, 5, 300) == 0, "plain reads, short at the end"); close(fd); }

    printf("damaged files are refused\n");
    CHECK(opens(file, file_n, NULL) == 1, "the pristine file opens");
    { uint8_t *f = malloc(file_n); memcpy(f, file, file_n); f[0] = 'X'; CHECK(!opens(f, file_n, NULL), "a file with another magic is not a DMSPARS1 (the DMROMFS1 loader refuses it)"); free(f); }
    for (size_t cut = 1; cut < file_n; cut += (cut < 200 ? 1 : cut < file_n - 200 ? 997 : 1)) {   // a cut-off copy: every length
        if (opens(file, cut, NULL)) { CHECK(0, "a file cut to %zu of %zu bytes opened", cut, file_n); break; }
    }
    CHECK(!opens(file, 0, NULL) || 1, "(an empty file is a plain file with nothing in it)");
    struct { const char *what; size_t at; uint64_t v; int bytes; } patches[] = {
        {"version 2", 8, 2, 4}, {"header size 65", 12, 65, 4}, {"reserved set", 56, 1, 8},
        {"logical size below the extents", 16, 100, 8}, {"extent count + 1", 24, (uint64_t)ne + 1, 8}, {"table offset unaligned", 32, 0, 0 /* patched below */, },
        {"pack offset unaligned", 40, 0, 0}, {"pack size 0 with an offset", 48, 0, 8}, {"pack size 79", 48, 79, 8},
        {"trailer magic", 0, 'X', 1}, {"trailer size", 0, 0, 8}, {"trailer table offset", 0, 0, 8}, {"trailer tail", 0, 1, 8},
    };
    uint64_t toff = romfs_src_le64(file + 32), poff = romfs_src_le64(file + 40);
    for (size_t k = 0; k < sizeof patches / sizeof *patches; k++) {
        uint8_t *f = malloc(file_n); memcpy(f, file, file_n); size_t at = patches[k].at; uint64_t v = patches[k].v; int nb = patches[k].bytes;
        if (!strcmp(patches[k].what, "table offset unaligned")) { v = toff + 8; nb = 8; }
        if (!strcmp(patches[k].what, "pack offset unaligned")) { v = poff + 16; nb = 8; }
        if (k >= 9) { size_t t = file_n - 32; at = t + (k == 9 ? 0 : k == 10 ? 8 : k == 11 ? 16 : 24); if (k == 10) v = file_n + 16; if (k == 11) v = toff + 16; }
        if (nb == 1) f[at] = (uint8_t)v; else if (nb == 4) fx_put32(f + at, (uint32_t)v); else fx_put64(f + at, v);
        CHECK(!opens(f, file_n, NULL) && errno == EINVAL, "refused: %s", patches[k].what); free(f);
    }
    // damaged extent tables
    struct { const char *what; int ext; int field; int64_t delta; } tab[] = {
        {"zero-length extent", 3, 1, -1000000}, {"extent past the logical end", 2, 1, 1000000}, {"extent overlapping the next", 0, 1, 1}, {"extent out of order", 2, 0, 0},
        {"extent inside the header", 1, 2, -1000000}, {"extent past the file", 2, 2, 1000000}, {"extent over the table", 1, 2, 0},
    };
    for (size_t k = 0; k < sizeof tab / sizeof *tab; k++) {
        uint8_t *f = malloc(file_n); memcpy(f, file, file_n); uint8_t *e = f + toff + (size_t)tab[k].ext * 24 + (size_t)tab[k].field * 8; uint64_t v = romfs_src_le64(e);
        if (!strcmp(tab[k].what, "zero-length extent")) v = 0; else if (!strcmp(tab[k].what, "extent inside the header")) v = 8; else if (!strcmp(tab[k].what, "extent over the table")) v = toff - 100; else if (!strcmp(tab[k].what, "extent out of order")) v = 1000;
        else v = (uint64_t)((int64_t)v + tab[k].delta);
        fx_put64(e, v);
        CHECK(!opens(f, file_n, NULL) && errno == EINVAL, "refused: %s", tab[k].what); free(f);
    }
    { uint8_t *f = malloc(file_n); memcpy(f, file, file_n); memcpy(f + poff, "NXASTCPX", 8); CHECK(!opens(f, file_n, NULL), "refused: the pack's magic is wrong"); free(f); }
    { uint8_t *f = malloc(file_n); memcpy(f, file, file_n); fx_put64(f + poff + 32, pack_n + 16); CHECK(!opens(f, file_n, NULL), "refused: the pack's recorded size is not the header's pack size"); free(f); }
    // a table that describes no data at all, for an image of zeros, is fine
    { uint8_t z[100] = {0}; uint8_t *f; size_t fn; fx_write_sparse(NULL, z, sizeof z, 16, 0, NULL, 0, &f, &fn); romfs_src zs; CHECK(opens(f, fn, &zs) && zs.n == 0 && zs.logical == 100 && !zs.pack_size, "an all-zero image: no extents");
      uint8_t b[10] = {1}; CHECK(romfs_src_pread(&zs, b, 10, 95) == 5 && !b[0] && !b[4], "reads zeros"); close(zs.fd); romfs_src_free(&zs); free(f); }
    free(file); free(pack);

    printf("a DMROMFS1 wrapped in a DMSPARS1\n");
    {   enum { K = 4 };
        size_t sz[K] = {20000, 7, 0, 9000}; uint8_t *d[K];
        for (int i = 0; i < K; i++) { d[i] = malloc(sz[i] + 1); for (size_t j = 0; j < sz[i]; j++) d[i][j] = (uint8_t)(1 + rnd() % 255); }
        memset(d[0] + 2000, 0, 15000); memset(d[3], 0, 8500);   // holes inside files, and one file that is nearly all hole
        uint8_t *img; size_t img_n = fx_romfs(&img, K, (const uint8_t *const *)d, sz);
        write_file(path("plain.img"), img, img_n);
        uint8_t *spf; size_t spn; uint8_t *pk; size_t pkn = fx_pack(&pk, 0, NULL, 0, 0);
        long e2 = fx_write_sparse(NULL, img, img_n, 256, 5000, pk, pkn, &spf, &spn); CHECK(e2 > 2, "wrapped image has extents (%ld)", e2);
        write_file(path("sparse.img"), spf, spn); CHECK(spn < img_n, "and is smaller than the plain image (%zu < %zu)", spn, img_n);
        romfs_img *a = romfs_image_open(path("plain.img")), *b = romfs_image_open(path("sparse.img"));
        CHECK(a && b, "both open (errno %d)", errno);
        if (a && b) {
            CHECK(a->n == b->n && a->damaged == b->damaged && !a->src.sparse && b->src.sparse && !a->src.pack_size && b->src.pack_size == pkn, "same index, the sparse one carries the pack");
            int same = 1;
            for (uint64_t k = 0; k < a->n; k++) {
                const img_ent *x = &a->e[k], *y = &b->e[k];
                if (memcmp(x, y, sizeof *x)) same = 0;
                if (!x->type) continue;
                uint8_t *ba = malloc(x->b + 1), *bb = malloc(x->b + 1);
                int ra = romfs_image_read(a, ba, x->b, x->a), rb = romfs_image_read(b, bb, x->b, y->a);
                if (!ra || !rb || memcmp(ba, bb, x->b)) same = 0;
                if (k >= 2 && memcmp(bb, d[k - 2], x->b)) same = 0;   // and both are the source bytes
                free(ba); free(bb);
            }
            CHECK(same, "every entry and every file reads identically from the plain and the wrapped image");
            romfs_image_close(a); romfs_image_close(b);
        }
        romfs_id ia, ib;
        CHECK(romfs_id_of_image(path("plain.img"), &ia) && romfs_id_of_image(path("sparse.img"), &ib) && romfs_id_same(&ia, &ib) && ia.size == img_n && ib.size == img_n, "the identity of the wrapped image is its logical image's (size %llu index %016llx)", (unsigned long long)ib.size, (unsigned long long)ib.index);
        // the identity file check the iOS startup does
        { char line[300]; romfs_id_text(&ia, line, sizeof line); strcat(line, "\n"); write_file(path("romfs.id"), (const uint8_t *)line, strlen(line));
          romfs_id w, g; CHECK(romfs_id_check(path("romfs.id"), path("sparse.img"), &w, &g) == ROMFS_ID_OK && romfs_id_check(path("romfs.id"), path("plain.img"), &w, &g) == ROMFS_ID_OK, "romfs.id accepts the wrapped image and the plain one"); }
        // an index that differs changes the identity
        { img[img_n - 3] ^= 1; write_file(path("other.img"), img, img_n); romfs_id ic; CHECK(romfs_id_of_image(path("other.img"), &ic) && !romfs_id_same(&ia, &ic), "a changed index changes the identity"); img[img_n - 3] ^= 1; }
        // a cut-off wrapped image has no identity and does not open
        { write_file(path("cut.img"), spf, spn - 1); romfs_id ic; CHECK(!romfs_id_of_image(path("cut.img"), &ic) && !romfs_image_open(path("cut.img")), "a cut-off wrapped image is refused by the identity and by the loader"); }
        // a wrapped image whose logical image is not DMROMFS1 (index not ending it) is refused as a plain one would be
        { uint8_t *w; size_t wn; fx_write_sparse(NULL, img, img_n - 5, 256, 0, NULL, 0, &w, &wn); write_file(path("badlogical.img"), w, wn); CHECK(!romfs_image_open(path("badlogical.img")), "a wrapped image whose index does not end it is refused"); free(w); }
        // the pack-less wrapper: no pack
        { uint8_t *w; size_t wn; fx_write_sparse(NULL, img, img_n, 256, 0, NULL, 0, &w, &wn); write_file(path("nopack.img"), w, wn); romfs_img *m = romfs_image_open(path("nopack.img")); CHECK(m && m->src.sparse && !m->src.pack_size, "a wrapper without a pack opens, with none"); romfs_image_close(m); free(w); }
        for (int i = 0; i < K; i++) free(d[i]);
        free(img); free(spf); free(pk);
    }
    free(L); free(got);
    char cmd[1300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", g_dir); if (system(cmd)) {}
    printf("%d checks, %d failed\n", checks, failed);
    return failed != 0;
}

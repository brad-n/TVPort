// tex_once_verify (1/2): the engine's sparse reader against a real stripped image (docs/texture_once.md section 1).
//   tex_once_verify_read <stripped romfs.img> [<original RomFS.img>]
// Streams the whole LOGICAL image through romfs_src_open / romfs_src_pread (dm/host/romfs_sparse.h) and prints its SHA-256 (tex_once_verify.sh compares it with sparse_image.py's); loads the index through
// the DMROMFS1 loader (romfs_image.h) and takes the identity (romfs_identity.h). With the original image: the file count and the identity must equal it. Exit 0 when every check passed.
#include <CommonCrypto/CommonDigest.h>
#include <inttypes.h>
#include <stdio.h>
#include <time.h>
#include "../../host/romfs_image.h"
#include "../../host/romfs_identity.h"

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec + (double)t.tv_nsec * 1e-9; }

static int sha_of(const char *path, char hex[65], uint64_t *logical, double *seconds, int *sparse, uint64_t *pack) {
    int fd = open(path, O_RDONLY); romfs_src s;
    if (fd < 0 || !romfs_src_open(fd, &s)) { fprintf(stderr, "cannot open %s as a DMSPARS1 / DMROMFS1 file (errno %d)\n", path, errno); return 0; }
    enum { CHUNK = 32 << 20 };
    uint8_t *buf = malloc(CHUNK); CC_SHA256_CTX c; CC_SHA256_Init(&c);
    double t0 = now();
    for (uint64_t at = 0; at < s.logical;) {
        size_t want = s.logical - at < CHUNK ? (size_t)(s.logical - at) : (size_t)CHUNK;
        ssize_t n = romfs_src_pread(&s, buf, want, at);
        if (n != (ssize_t)want) { fprintf(stderr, "short read at %" PRIu64 ": %zd of %zu (errno %d)\n", at, n, want, errno); free(buf); return 0; }
        CC_SHA256_Update(&c, buf, (CC_LONG)n); at += (uint64_t)n;
    }
    uint8_t d[32]; CC_SHA256_Final(d, &c);
    for (int i = 0; i < 32; i++) sprintf(hex + 2 * i, "%02x", d[i]);
    *logical = s.logical; *sparse = s.sparse; *pack = s.pack_size; *seconds = now() - t0;
    free(buf); romfs_src_free(&s); close(fd);
    return 1;
}

static int index_of(const char *label, const char *path, uint64_t *files, uint64_t *dirs, romfs_id *id) {
    double t0 = now();
    romfs_img *m = romfs_image_open(path);
    if (!m) { printf("%s: DMROMFS1 index does not load (errno %d)\n", label, errno); return 0; }
    *files = *dirs = 0;
    for (uint64_t k = 0; k < m->n; k++) { if (m->e[k].type) (*files)++; else (*dirs)++; }
    uint64_t damaged = m->damaged; romfs_image_close(m);
    if (!romfs_id_of_image(path, id)) { printf("%s: identity unreadable (errno %d)\n", label, errno); return 0; }
    printf("%s: index loads, %" PRIu64 " files, %" PRIu64 " directories, %" PRIu64 " damaged; identity size=%" PRIu64 " index=%016" PRIx64 " (%.1f s)\n", label, *files, *dirs, damaged, id->size, id->index, now() - t0);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <stripped romfs.img> [<original RomFS.img>]\n", argv[0]); return 2; }
    int ok = 1; char hex[65]; uint64_t logical, pack; double sec; int sparse;
    if (!sha_of(argv[1], hex, &logical, &sec, &sparse, &pack)) return 1;
    printf("logical_size=%" PRIu64 " sparse=%d embedded_pack_bytes=%" PRIu64 "\nsha256=%s\nread_seconds=%.1f (%.0f MB/s)\n", logical, sparse, pack, hex, sec, (double)logical / 1e6 / sec);
    uint64_t f1, d1, f2 = 0, d2 = 0; romfs_id i1, i2;
    if (!index_of("stripped", argv[1], &f1, &d1, &i1)) return 1;
    if (!sparse || !pack) { printf("FAIL: the image is not a DMSPARS1 with an embedded pack\n"); ok = 0; }
    if (argc > 2) {
        if (!index_of("original", argv[2], &f2, &d2, &i2)) return 1;
        int files = f1 == f2 && d1 == d2, id = romfs_id_same(&i1, &i2);
        printf("file count match: %s; identity match: %s\n", files ? "yes" : "NO", id ? "yes" : "NO");
        ok = ok && files && id;
    }
    printf(ok ? "read: PASS\n" : "read: FAIL\n");
    return ok ? 0 : 1;
}

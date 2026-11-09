// DMROMFS1's index loader, shared by the host mount and iOS startup. Startup must validate the same index before replacing a working folder.
#pragma once
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "romfs_sparse.h"

typedef struct { uint64_t a, b; uint32_t name; uint16_t nlen; uint8_t type, flags; } __attribute__((packed)) img_ent;   // directory: a = first child, b = children; file: a = offset, b = size
_Static_assert(sizeof(img_ent) == 24, "RomFS image entry layout");
#define IMG_ENT_DAMAGED 1    // in the image: this file failed the NCA's hash check and was written as read (nx_extract --allow-damaged)
#define IMG_ENT_REPORTED 2   // in memory only: the host has named this damaged file in its log
typedef struct { int fd; uint64_t n, damaged; img_ent *e; const char *names; romfs_src src; } romfs_img;   // src: the file as a plain DMROMFS1 or a DMSPARS1 (romfs_sparse.h); every read of its bytes goes through it

static void romfs_image_close(romfs_img *m) {
    if (m) { close(m->fd); romfs_src_free(&m->src); free(m->e); free(m); }
}
// Reads [off, off + size) of the image's LOGICAL bytes (a DMSPARS1's holes read as zero); 0 with errno set when the range cannot be read in full
static inline int romfs_image_read(const romfs_img *m, void *buf, size_t size, uint64_t off) { return romfs_src_read(&m->src, buf, size, off); }
// NULL for an incomplete or invalid image (errno EINVAL), an I/O error, or allocation failure. The caller owns the descriptor and index on success.
static romfs_img *romfs_image_open(const char *path) {
    int fd = open(path, O_RDONLY); uint8_t h[32]; romfs_img *m = NULL; uint64_t ioff, isz, n, size; romfs_src src;
    if (fd < 0) return NULL;
    if (!romfs_src_open(fd, &src)) goto bad;
    size = src.logical;   // the DMROMFS1 image: the file itself, or what a DMSPARS1 wraps
    if (!(m = calloc(1, sizeof *m))) { romfs_src_free(&src); goto bad; }
    m->fd = fd; m->src = src;
    if (size < sizeof h || !romfs_src_read(&m->src, h, sizeof h, 0)) goto bad;
    errno = EINVAL;
    if (memcmp(h, "DMROMFS1", 8)) goto bad;
    memcpy(&ioff, h + 8, 8); memcpy(&isz, h + 16, 8); memcpy(&n, h + 24, 8);
    if (!n || n > UINT32_MAX || ioff < sizeof h || ioff > size || isz != size - ioff || isz > SIZE_MAX || n > isz / sizeof(img_ent)) goto bad;
    if (!(m->e = malloc((size_t)isz)) || !romfs_src_read(&m->src, m->e, (size_t)isz, ioff)) goto bad;
    m->n = n; m->names = (const char *)m->e + n * sizeof(img_ent);
    uint64_t pool = isz - n * sizeof(img_ent), next_child = 1;
    errno = EINVAL;
    if (m->e[0].type || m->e[0].nlen) goto bad;
    for (uint64_t k = 0; k < n; k++) {
        const img_ent *x = &m->e[k];
        if ((uint64_t)x->name + x->nlen > pool || x->type > 1 || x->flags > (x->type ? IMG_ENT_DAMAGED : 0)) goto bad;
        m->damaged += x->flags;
        const char *name = m->names + x->name;
        if (k && (!x->nlen || x->nlen > 0x300 || memchr(name, 0, x->nlen) || memchr(name, '/', x->nlen) || (x->nlen == 1 && name[0] == '.') || (x->nlen == 2 && !memcmp(name, "..", 2)))) goto bad;
        if (x->type) { if (x->a < sizeof h || x->a > ioff || x->b > ioff - x->a) goto bad; }
        else {
            // Breadth-first child runs partition entries 1..n-1; reject cycles, aliases and unreachable entries.
            if (x->a != next_child || x->a <= k || x->a > n || x->b > n - x->a) goto bad;
            next_child += x->b;
        }
    }
    if (next_child != n) goto bad;
    for (uint64_t k = 0; k < n; k++) {
        const img_ent *d = &m->e[k]; if (d->type) continue;
        for (uint64_t j = 1; j < d->b; j++) {
            const img_ent *a = &m->e[d->a + j - 1], *b = a + 1;
            size_t len = a->nlen < b->nlen ? a->nlen : b->nlen;
            int c = memcmp(m->names + a->name, m->names + b->name, len);
            if (c > 0 || (!c && a->nlen >= b->nlen)) goto bad;
        }
    }
    return m;
bad: {
    int e = errno ? errno : EINVAL;
    if (m) romfs_image_close(m); else close(fd);
    errno = e; return NULL;
    }
}

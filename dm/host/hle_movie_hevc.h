// HEVC sidecars of AV1 movies (hle_movie_hevc.c, made by dm/tools/movie_hevc.py), for the nn::codec AV1 decoders (hle_movie_av1.c)
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "hle_movie_av1.h"

typedef struct mhevc mhevc;
// A decoder's reader of the pack DM_MOVIE_HEVC names (loaded once per process); NULL when there is none, it is off (0) or it cannot be read
mhevc *mhevc_new(void);
void mhevc_free(mhevc *h);
void mhevc_reset(mhevc *h);   // a new stream (Flush, a new movie): its next unit is looked up afresh
// One AV1 temporal unit and its time. 1 and *out: the HEVC picture made from that unit, NV12 in the decoder's memory until the next call, with the unit's time; 0: a unit with no
// picture of its own (only temporal delimiters, or one the pack holds without a picture); -1: a unit the pack does not hold, or its picture could not be decoded
int mhevc_decode(mhevc *h, const uint8_t *data, size_t n, int64_t ts, mav1_picture *out);
// Exposed for its test: the key the pack holds a unit under (the first 8 bytes of the SHA-256 of the unit without its leading temporal delimiters, little-endian) and that unit's size
uint64_t mhevc_key(const uint8_t *data, size_t n, size_t *size);

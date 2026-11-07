// Yaz0 cost attribution for the texture-once spike: decode the op structure of a Yaz0 stream (no output written) and add up the compressed bytes
// (1 or 2-3 bytes per op, plus 1/8 byte of the flag byte) of the ops whose output lies in [rs[i], re[i]) (sorted, disjoint). An op straddling a region edge is split in proportion.
#include <stdint.h>
#include <stddef.h>
double dm_yaz0_attr(const uint8_t *s, size_t n, const uint64_t *rs, const uint64_t *re, size_t nr) {
    if (n < 16) return -1;
    uint64_t out = (uint64_t)s[4] << 24 | (uint64_t)s[5] << 16 | (uint64_t)s[6] << 8 | s[7];
    size_t si = 16, r = 0; uint64_t di = 0; double acc = 0;
    while (di < out) {
        if (si >= n) return -1;
        unsigned h = s[si++];
        for (int i = 0; i < 8 && di < out; i++, h <<= 1) {
            uint64_t len; double cost;
            if (h & 0x80) { if (si >= n) return -1; si++; len = 1; cost = 1.125; }
            else {
                if (si + 1 >= n) return -1;
                unsigned b1 = s[si]; si += 2; cost = 2.125; len = b1 >> 4;
                if (len) len += 2; else { if (si >= n) return -1; len = (uint64_t)s[si++] + 0x12; cost = 3.125; }
                if (len > out - di) len = out - di;
            }
            uint64_t a = di, b = di + len;
            while (r < nr && re[r] <= a) r++;
            for (size_t k = r; k < nr && rs[k] < b; k++) {
                uint64_t lo = rs[k] > a ? rs[k] : a, hi = re[k] < b ? re[k] : b;
                if (hi > lo) acc += cost * (double)(hi - lo) / (double)len;
            }
            di = b;
        }
    }
    return acc;
}

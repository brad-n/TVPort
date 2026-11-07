// Greedy hash-chain Yaz0 encoder (validation of the cost-attribution estimate only; not Nintendo's encoder). Returns the stream size (16-byte header included).
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
size_t dm_yaz0_encode_size(const uint8_t *s, size_t n, int chain) {
    int *head = malloc(sizeof(int) * 65536), *prev = malloc(sizeof(int) * n);
    memset(head, 0xff, sizeof(int) * 65536);
    size_t out = 16, i = 0; size_t flagpos = 0; int bits = 0;
    #define H(p) (((s[p] << 8) ^ (s[(p) + 1] << 4) ^ s[(p) + 2]) & 0xffff)
    size_t ins = 0;
    while (i < n) {
        if (!bits) { flagpos = out++; bits = 8; }
        size_t bl = 0, bd = 0;
        if (i + 2 < n) {
            // insert pending positions up to i
            while (ins < i) { if (ins + 2 < n) { int h = H(ins); prev[ins] = head[h]; head[h] = (int)ins; } ins++; }
            int c = head[H(i)], k = 0;
            // special case: run of identical bytes (dist 1)
            while (c >= 0 && (i - (size_t)c) <= 4096 && k++ < chain) {
                size_t l = 0, mx = n - i < 273 ? n - i : 273;
                while (l < mx && s[c + l] == s[i + l]) l++;
                if (l > bl) { bl = l; bd = i - c; if (l == mx) break; }
                c = prev[c];
            }
        }
        if (bl >= 3) { out += bl > 17 ? 3 : 2; i += bl; }
        else { out += 1; i += 1; }
        bits--;
    }
    free(head); free(prev); return out;
}

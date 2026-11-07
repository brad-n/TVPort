// DM_MEMSTAT / DM_THRCPU path placement (diag_path.h). Compiled twice: as the Mac build and with DM_DIAG_ASSUME_IOS for the iOS/tvOS rules.
#include "../diag_path.h"
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
int main(void) {
    char o[64];
    CHECK(dm_diag_resolve("/tmp/m.tsv", "/data", o, sizeof o) && !strcmp(o, "/tmp/m.tsv"), "absolute name is used as is");
    CHECK(dm_diag_resolve("/tmp/t.tsv,5", NULL, o, sizeof o) && !strcmp(o, "/tmp/t.tsv,5"), "absolute name with interval, no data directory");
    CHECK(!dm_diag_resolve("", "/data", o, sizeof o) && !dm_diag_resolve(NULL, "/data", o, sizeof o), "empty spec is refused");
    CHECK(!dm_diag_resolve("/tmp/0123456789012345678901234567890123456789012345678901234567890123456789", "/d", o, sizeof o), "overlong absolute name is refused");
#ifdef DM_DIAG_ASSUME_IOS
    CHECK(dm_diag_resolve("m.tsv", "/data/Caches", o, sizeof o) && !strcmp(o, "/data/Caches/m.tsv"), "relative name goes under the data directory");
    CHECK(dm_diag_resolve("t.tsv,5", "/data/Caches", o, sizeof o) && !strcmp(o, "/data/Caches/t.tsv,5"), "interval rides along");
    CHECK(!dm_diag_resolve("m.tsv", NULL, o, sizeof o) && !dm_diag_resolve("m.tsv", "", o, sizeof o), "relative name waits for the data directory (constructor must not guess)");
    CHECK(!dm_diag_resolve("m.tsv", "/0123456789012345678901234567890123456789012345678901234567890123456789", o, sizeof o), "overlong relative result is refused");
#else
    CHECK(dm_diag_resolve("m.tsv", NULL, o, sizeof o) && !strcmp(o, "m.tsv"), "Mac: relative name stays relative to the working directory");
    CHECK(dm_diag_resolve("m.tsv", "/data", o, sizeof o) && !strcmp(o, "m.tsv"), "Mac: a data directory does not change it");
#endif
    if (fails) { fprintf(stderr, "t_diag_path: %d of %d failed\n", fails, checks); return 1; }
    printf("t_diag_path: %d checks passed\n", checks);
    return 0;
}

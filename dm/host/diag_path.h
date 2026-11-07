// Where the DM_MEMSTAT / DM_THRCPU diagnostics files go. Pure string logic (no Foundation), so a host test can run it.
//   An absolute spec is used as is. A relative name goes under the app data directory (the one dm/ios/Sources/main.m uses: Library/Caches on tvOS, Documents on iOS), which only the
//   iOS entry point knows; before it has handed that over (datadir == NULL) a relative name on iOS/tvOS cannot be placed, and the caller must wait for dm_diag_start (memstat.m).
//   On the Mac a relative name stays relative to the working directory, as before.
#pragma once
#include <stdio.h>
#include <string.h>
#include <TargetConditionals.h>

// Returns 1 and fills out[n] when the spec can be placed now, else 0 (relative name without a data directory yet, or it does not fit).
static inline int dm_diag_resolve(const char *spec, const char *datadir, char *out, size_t n) {
    if (!spec || !*spec) return 0;
#if TARGET_OS_IPHONE || defined(DM_DIAG_ASSUME_IOS)   // the host test forces the iOS branch on the Mac
    if (*spec != 0x2f) {
        if (!datadir || !*datadir) return 0;
        int w = snprintf(out, n, "%s/%s", datadir, spec);
        return w > 0 && (size_t)w < n;
    }
#else
    (void)datadir;
#endif
    int w = snprintf(out, n, "%s", spec);
    return w > 0 && (size_t)w < n;
}

// Called by the iOS/tvOS entry point once the env files are loaded (the constructors run earlier and cannot see them). Safe to call more than once; each diagnostic starts at most once.
void dm_diag_start(const char *datadir);

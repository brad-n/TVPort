// Shader trimming at run time (docs/shader_trimming.md, dm/gfx/tools/shader_trim.py): a vertex or pixel shader the map marks `src` has no compiled library in the app. Its Metal source is a
// zstd entry of the shader image (<key>_b.msl, and _bp / _bv / _bu for its other libraries), and this module inflates it and compiles it with newLibraryWithSource on a few background threads.
// The caller never waits for it on the draw path: trim_ensure(key, 0) starts the work and answers TRIM_PENDING until every library of the shader is ready, and the draw is skipped for those frames
// (nvn_mtl.m draw). The prewarm, which runs while the game loads, asks to wait (wait = 1). Metal keeps a compiled source on disk, so the same source costs ~0 on the next launch.
// Not a texture or shader translator: the source is final MSL, made at build time.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

typedef NSData *(^trim_read_fn)(NSString *entry);   // the bytes of a file of the shader image (a name such as <key>_b.msl), nil when it has none
typedef void (^trim_log_fn)(NSString *line);
enum { TRIM_READY = 0, TRIM_PENDING = 1, TRIM_FAILED = 2, TRIM_NONE = 3 };   // TRIM_NONE: not a source-form shader
typedef struct { uint64_t compiled, failed, compile_ns, libs, skipped_draws, skipped_shaders, inflated_bytes, source_keys; } trim_stats_t;

// dev: compiles; rd: reads the image; workers: compile threads (2 to 4). Safe to call again (the first call counts)
void trim_configure(id<MTLDevice> dev, trim_read_fn rd, trim_log_fn log, int workers);
void trim_add_source_key(NSString *key);   // a key the shader map marks `src` (16 hex digits)
int trim_active(void);                     // whether any key is in source form
int trim_is_source(NSString *key);
int trim_ensure(NSString *key, int wait);  // starts the compile of every library of the shader (once); wait = 1 blocks until it is done. → TRIM_*
int trim_state(NSString *key);             // as trim_ensure without starting anything
// The library named <key>_b / _bp / _bv / _bx / _bf (the last two are the unit's), nil when the shader has none or it is not ready. layer: whether its source uses render_target_array_index
id<MTLLibrary> trim_library(NSString *name, int *layer);
NSData *trim_json(NSString *key);          // the shader's reflection json, inflated; nil when the image has none
NSData *trim_inflate(NSData *frame, int json);   // a zstd entry with the msl (json = 0) or json dictionary
void trim_note_skip(NSString *key);        // a draw was skipped for this shader: counted, logged once per shader
trim_stats_t trim_stats(void);
// The options a source is compiled with, as close as MTLCompileOptions gets to the build's `metal -c -O1 -mios-version-min=18.0 -fmetal-math-mode=relaxed -fpreserve-invariance -fbracket-depth=1024`
MTLCompileOptions *trim_compile_options(void);

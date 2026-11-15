"""An Apple TV game app takes the settings SwitchTV's Options page saved for it (through the shared keychain group): SourcesTV/TVOptions.m is compiled for the Mac and run with blocks standing in
for the environment, on rows in launcher.json's shape; then with the env file reader main.m uses (Sources/env_file.h), in boot_env's order, on real files: the launch environment, the player's
env.txt, SwitchTV's choices, the bundle's dm/env.txt. main.m keeps that order, on tvOS only, before the host reads its environment."""
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]

DRIVER = r"""
#import <Foundation/Foundation.h>
typedef NSString *(^TVEnvGet)(NSString *key);
typedef void (^TVEnvSet)(NSString *key, NSString *value);
typedef void (^TVLog)(NSString *line);
NSString *tv_options_title_id(NSString *scheme);
BOOL tv_option_accepts(NSDictionary *row, NSString *value);
NSArray<NSString *> *tv_options_apply(NSData *saved, NSArray *rows, NSSet<NSString *> *fromLaunch, TVEnvGet get, TVEnvSet set, TVLog log);
NSArray<NSString *> *tv_apply_switchtv_options(NSSet<NSString *> *fromLaunch);
static NSData *json(id o) { return [NSJSONSerialization dataWithJSONObject:o options:0 error:nil]; }
int main(int argc, char **argv) {
    @autoreleasepool {
        NSArray *rows = @[   // launcher.json rows as dm/games/settings.py writes them (Ocarina of Time's, abridged)
            @{@"env": @"DM_RENDER_SCALE", @"kind": @"range", @"section": @"Game", @"label": @"Render scale", @"note": @"", @"default": @"1.0", @"min": @0.5, @"max": @1.0, @"step": @0.05},
            @{@"env": @"DM_ANISO", @"kind": @"choice", @"section": @"Game", @"label": @"Anisotropic filtering", @"note": @"", @"default": @"0", @"options": @[@[@"0", @"Auto"], @[@"4", @"4x"], @[@"16", @"16x"]]},
            @{@"env": @"DM_OPMODE", @"kind": @"choice", @"section": @"Game", @"label": @"Console mode", @"note": @"", @"default": @"1", @"options": @[@[@"1", @"Docked"], @[@"0", @"Handheld"]]},
            @{@"env": @"DM_FOLIAGE", @"kind": @"toggle", @"section": @"Game options", @"label": @"Grass and ground cover", @"note": @"", @"default": @"on", @"on": @"on", @"off": @"off"},
            @{@"env": @"DM_METAL_HUD", @"kind": @"toggle", @"section": @"Performance", @"label": @"Performance HUD", @"note": @"", @"default": @"0", @"on": @"1", @"off": @"0"},
        ];
        // the title ID comes from the app's switchtv-<title ID> scheme, in capitals; anything else is none
        if (![tv_options_title_id(@"switchtv-0400486024dec000") isEqualToString:@"0400486024DEC000"]) return 1;
        if (tv_options_title_id(@"switchtv-ci") || tv_options_title_id(@"other-0400486024dec000") || tv_options_title_id(@"switchtv-../../etc/passwd00")) return 2;
        // values: a row's own, as the iPhone launcher accepts a saved choice
        if (!tv_option_accepts(rows[0], @"0.75") || tv_option_accepts(rows[0], @"0.25") || tv_option_accepts(rows[0], @"0x1") || tv_option_accepts(rows[0], @"1.0abc") || tv_option_accepts(rows[0], @"nan")) return 3;
        if (!tv_option_accepts(rows[1], @"16") || tv_option_accepts(rows[1], @"8")) return 4;
        if (!tv_option_accepts(rows[3], @"off") || tv_option_accepts(rows[3], @"0") || !tv_option_accepts(rows[4], @"1")) return 5;
        if (tv_option_accepts(@{@"env": @"DM_X", @"kind": @"slider"}, @"1") || tv_option_accepts(rows[1], (NSString *)@16)) return 6;   // a kind it does not know, a value that is no text

        NSMutableDictionary<NSString *, NSString *> *env = [@{@"DM_OPMODE": @"0", @"DM_METAL_HUD": @"0"} mutableCopy];   // set at launch and by the player's env.txt
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        TVEnvGet get = ^NSString *(NSString *k) { return env[k]; };
        TVEnvSet set = ^(NSString *k, NSString *v) { env[k] = v; };
        TVLog log = ^(NSString *line) { [lines addObject:line]; };
        NSData *saved = json(@{@"DM_RENDER_SCALE": @"0.50", @"DM_FOLIAGE": @"off", @"DM_ANISO": @"8", @"DM_OPMODE": @"1", @"DM_NVN_SKIP_MESH": @"1", @"DM_METAL_HUD": @"1"});
        NSArray *applied = tv_options_apply(saved, rows, [NSSet setWithObject:@"DM_OPMODE"], get, set, log);
        if (![applied isEqual:(@[@"DM_FOLIAGE", @"DM_RENDER_SCALE"])]) return 10;                    // name order
        if (![env[@"DM_RENDER_SCALE"] isEqualToString:@"0.50"] || ![env[@"DM_FOLIAGE"] isEqualToString:@"off"]) return 11;
        if (![env[@"DM_OPMODE"] isEqualToString:@"0"] || ![env[@"DM_METAL_HUD"] isEqualToString:@"0"]) return 12;   // the launch environment and the env file win
        if (env[@"DM_NVN_SKIP_MESH"] || env[@"DM_ANISO"]) return 13;                                   // not a row of this game (a diagnostic switch); a value the row does not offer
        NSString *all = [lines componentsJoinedByString:@"\n"];
        for (NSString *want in @[@"boot: SwitchTV option DM_FOLIAGE=off", @"DM_OPMODE=1 not applied: kept at 0 (the launch environment)", @"DM_METAL_HUD=1 not applied: kept at 0 (the player's env.txt)",
                                 @"DM_NVN_SKIP_MESH skipped: not a setting of this game", @"DM_ANISO=8 skipped: not a value this game offers", @"boot: SwitchTV options: 2 applied, 2 kept, 2 skipped"])
            if ([all rangeOfString:want].location == NSNotFound) { fprintf(stderr, "missing log line: %s\n%s\n", want.UTF8String, all.UTF8String); return 14; }

        // nothing saved, or a broken item: nothing set, and the log says which
        [lines removeAllObjects]; [env removeAllObjects];
        if (tv_options_apply(nil, rows, [NSSet set], get, set, log).count || env.count || ![lines.firstObject isEqualToString:@"boot: SwitchTV options: none saved"]) return 20;
        [lines removeAllObjects];
        if (tv_options_apply([@"[1,2]" dataUsingEncoding:NSUTF8StringEncoding], rows, [NSSet set], get, set, log).count || env.count || ![lines.firstObject hasPrefix:@"[RED] boot: SwitchTV options: the saved item is not a JSON object"]) return 21;
        if (tv_options_apply(json(@{@"DM_FOLIAGE": @"off"}), nil, [NSSet set], get, set, ^(NSString *l) {}).count || env.count) return 22;   // no settings list: nothing is a setting of this game

        if (tv_apply_switchtv_options([NSSet set]).count) return 30;   // no DMSwitchTVGroup in this process (an unsigned build): reads nothing, says so on stderr
    }
    return 0;
}
"""


# boot_env's order on real files, with the env file reader main.m uses: the launch environment, then the player's env.txt, then SwitchTV's choices, then the bundle's dm/env.txt
ORDER = r"""
#import <Foundation/Foundation.h>
#include "env_file.h"
typedef NSString *(^TVEnvGet)(NSString *key);
typedef void (^TVEnvSet)(NSString *key, NSString *value);
typedef void (^TVLog)(NSString *line);
NSArray<NSString *> *tv_options_apply(NSData *saved, NSArray *rows, NSSet<NSString *> *fromLaunch, TVEnvGet get, TVEnvSet set, TVLog log);
static BOOL is(const char *key, const char *want) { const char *v = getenv(key); return v && !strcmp(v, want); }
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *dir = @(argv[1]), *player = [dir stringByAppendingPathComponent:@"env.txt"], *bundle = [dir stringByAppendingPathComponent:@"dm-env.txt"];
        [@"DM_FOLIAGE=on\n# a hand edit\nDM_BC_MAX_DIM=128\n" writeToFile:player atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"# Written by TVPort\nDM_OPMODE=0\nDM_BC_MAX_DIM=256\nDM_RENDER_SCALE=0.5\nDM_ANISO=8\n" writeToFile:bundle atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSArray *rows = @[
            @{@"env": @"DM_FOLIAGE", @"kind": @"toggle", @"default": @"on", @"on": @"on", @"off": @"off"},
            @{@"env": @"DM_OPMODE", @"kind": @"choice", @"default": @"1", @"options": @[@[@"1", @"Docked"], @[@"0", @"Handheld"]]},
            @{@"env": @"DM_ANISO", @"kind": @"choice", @"default": @"0", @"options": @[@[@"0", @"Auto"], @[@"8", @"8x"], @[@"16", @"16x"]]},
            @{@"env": @"DM_RENDER_SCALE", @"kind": @"range", @"default": @"1.0", @"min": @0.5, @"max": @1.0, @"step": @0.05}];
        NSData *saved = [NSJSONSerialization dataWithJSONObject:@{@"DM_FOLIAGE": @"off", @"DM_OPMODE": @"1", @"DM_ANISO": @"16"} options:0 error:nil];
        setenv("DM_ANISO", "4", 1);   // the launch environment
        NSMutableArray<NSString *> *from_file = [NSMutableArray array], *from_launch = [@[@"DM_ANISO"] mutableCopy], *from_player = [NSMutableArray array], *from_switchtv = [NSMutableArray array];
        NSString *(^winner)(NSString *) = ^NSString *(NSString *k) { return dm_env_source(k, from_launch, from_player, from_switchtv); };
        dm_env_file_apply(player, "env.txt", from_player, nil, winner);
        [from_file addObjectsFromArray:from_player];
        [from_switchtv addObjectsFromArray:tv_options_apply(saved, rows, [NSSet setWithArray:from_launch], ^NSString *(NSString *k) { const char *v = getenv(k.UTF8String); return v ? @(v) : nil; },
                                                          ^(NSString *k, NSString *v) { setenv(k.UTF8String, v.UTF8String, 1); }, ^(NSString *line) { fprintf(stderr, "%s\n", line.UTF8String); })];
        dm_env_file_apply(bundle, "dm/env.txt", from_file, nil, winner);
        if (!is("DM_OPMODE", "1")) return 1;          // SwitchTV's choice beats the bundle's dm/env.txt (TVPort's build choice)
        if (!is("DM_FOLIAGE", "on")) return 2;        // the player's env.txt beats SwitchTV's choice
        if (!is("DM_ANISO", "4")) return 3;           // the launch environment beats them all
        if (!is("DM_BC_MAX_DIM", "128")) return 4;    // the player's env.txt beats the bundle's
        if (!is("DM_RENDER_SCALE", "0.5")) return 5;  // the bundle's fills what nothing else set
        if (![from_switchtv isEqual:@[@"DM_OPMODE"]] || ![from_file isEqual:(@[@"DM_FOLIAGE", @"DM_BC_MAX_DIM", @"DM_RENDER_SCALE"])]) return 6;   // DM_ENV_FILE_KEYS: what the env files set
    }
    return 0;
}
"""


@unittest.skipUnless(sys.platform == "darwin", "clang for macOS required")
class TvOptionsTests(unittest.TestCase):
    def test_boot_order_switchtv_beats_the_bundle_and_the_player_beats_switchtv(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "order.m").write_text(ORDER)
            subprocess.run(["xcrun", "clang", "-fobjc-arc", f"-I{IOS / 'Sources'}", str(IOS / "SourcesTV/TVOptions.m"), str(root / "order.m"), "-framework", "Foundation", "-framework", "Security", "-o", str(root / "order")], check=True)
            result = subprocess.run([str(root / "order"), str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"order check {result.returncode} failed: {result.stderr}")
            for line in ("boot: env DM_FOLIAGE=on (env.txt)",
                         "SwitchTV option DM_FOLIAGE=off not applied: kept at on (the player's env.txt)",
                         "SwitchTV option DM_ANISO=16 not applied: kept at 4 (the launch environment)",
                         "boot: SwitchTV option DM_OPMODE=1",
                         "boot: env DM_OPMODE=0 (dm/env.txt) not applied: DM_OPMODE=1 from SwitchTV's choice wins",
                         "boot: env DM_BC_MAX_DIM=256 (dm/env.txt) not applied: DM_BC_MAX_DIM=128 from the player's env.txt wins",
                         "boot: env DM_ANISO=8 (dm/env.txt) not applied: DM_ANISO=4 from the launch environment wins",
                         "boot: env DM_RENDER_SCALE=0.5 (dm/env.txt)"):
                self.assertIn(line, result.stderr)   # the log names the source that won each key

    def test_saved_options_are_applied_after_the_environment_and_checked_against_the_games_rows(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "driver.m").write_text(DRIVER)
            subprocess.run(["xcrun", "clang", "-fobjc-arc", str(IOS / "SourcesTV/TVOptions.m"), str(root / "driver.m"), "-framework", "Foundation", "-framework", "Security", "-o", str(root / "check")], check=True)
            result = subprocess.run([str(root / "check")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"driver check {result.returncode} failed: {result.stderr}")
            self.assertIn("this build has no keychain group (unsigned or sideloaded), so none are read", result.stderr)

    def test_boot_applies_them_on_tvos_between_the_players_env_file_and_the_bundles(self):
        main = (IOS / "Sources/main.m").read_text()
        boot = main[main.index("static int boot_env(void) {"):main.index("static NSString *program_env(void) {", main.index("static int boot_env(void) {"))]
        call = re.search(r"#if TARGET_OS_TV\s*\[from_switchtv addObjectsFromArray:tv_apply_switchtv_options\(\[NSSet setWithArray:from_launch\]\)\];[^\n]*\n\s*#endif", boot)
        self.assertIsNotNone(call, "boot_env calls tv_apply_switchtv_options() on tvOS only")
        player = boot.index('dm_env_file_apply([doc stringByAppendingPathComponent:@"env.txt"], "env.txt", from_player')
        bundle = boot.index('dm_env_file_apply([[res stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"env.txt"], "dm/env.txt", from_file')
        self.assertLess(boot.index("[from_launch addObject:k]"), player)   # the launch environment is known first
        self.assertLess(player, call.start())                              # the player's env.txt, then SwitchTV's choices
        self.assertLess(call.end(), bundle)                                # then the bundle's dm/env.txt
        self.assertLess(bundle, boot.index('setenv("DM_ENV_FILE_KEYS"'))   # DM_ENV_FILE_KEYS and DM_ENV_LAUNCH_KEYS list both files' keys and the launch's
        self.assertIn("dm_env_source(k, from_launch, from_player, from_switchtv)", boot)   # the log's sources, as the order check above runs them
        for after in ("dm_diag_start(", "front_hud_env();", 'getenv("DM_LANG")', "program_env();", "dm_host_preload_start("):   # the host's first reads of the environment come after
            self.assertGreater(boot.index(after), bundle)

    def test_the_format_and_group_match_switchtv(self):
        source = (IOS / "SourcesTV/TVOptions.m").read_text()
        self.assertIn('@"dev.tvport.switchtv.options"', source)   # SwitchTV's Shared/GameOptions.swift: OptionsStore.service
        self.assertIn('info[@"DMSwitchTVGroup"]', source)          # the group TVLastPlayed.m uses, given only to a signed tvOS build (build_ipa.sh)
        self.assertIn("path: SourcesTV", (IOS / "project_tv.yml").read_text())


if __name__ == "__main__":
    unittest.main()

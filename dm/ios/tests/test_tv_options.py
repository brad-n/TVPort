"""An Apple TV game app takes the settings SwitchTV's Options page saved for it (through the shared keychain group): SourcesTV/TVOptions.m is compiled for the Mac and run with blocks standing in
for the environment, on rows in launcher.json's shape; and main.m applies them at boot after the env files, before the host reads its environment, on tvOS only."""
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
void tv_apply_switchtv_options(void);
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

        NSMutableDictionary<NSString *, NSString *> *env = [@{@"DM_OPMODE": @"0", @"DM_METAL_HUD": @"0"} mutableCopy];   // set at launch and by an env file
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
        for (NSString *want in @[@"boot: SwitchTV option DM_FOLIAGE=off", @"DM_OPMODE=1 not applied: kept at 0 (launch environment)", @"DM_METAL_HUD=1 not applied: kept at 0 (env file)",
                                 @"DM_NVN_SKIP_MESH skipped: not a setting of this game", @"DM_ANISO=8 skipped: not a value this game offers", @"boot: SwitchTV options: 2 applied, 2 kept, 2 skipped"])
            if ([all rangeOfString:want].location == NSNotFound) { fprintf(stderr, "missing log line: %s\n%s\n", want.UTF8String, all.UTF8String); return 14; }

        // nothing saved, or a broken item: nothing set, and the log says which
        [lines removeAllObjects]; [env removeAllObjects];
        if (tv_options_apply(nil, rows, [NSSet set], get, set, log).count || env.count || ![lines.firstObject isEqualToString:@"boot: SwitchTV options: none saved"]) return 20;
        [lines removeAllObjects];
        if (tv_options_apply([@"[1,2]" dataUsingEncoding:NSUTF8StringEncoding], rows, [NSSet set], get, set, log).count || env.count || ![lines.firstObject hasPrefix:@"[RED] boot: SwitchTV options: the saved item is not a JSON object"]) return 21;
        if (tv_options_apply(json(@{@"DM_FOLIAGE": @"off"}), nil, [NSSet set], get, set, ^(NSString *l) {}).count || env.count) return 22;   // no settings list: nothing is a setting of this game

        tv_apply_switchtv_options();   // no DMSwitchTVGroup in this process (an unsigned build): reads nothing, says so on stderr
    }
    return 0;
}
"""


@unittest.skipUnless(sys.platform == "darwin", "clang for macOS required")
class TvOptionsTests(unittest.TestCase):
    def test_saved_options_are_applied_after_the_environment_and_checked_against_the_games_rows(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "driver.m").write_text(DRIVER)
            subprocess.run(["xcrun", "clang", "-fobjc-arc", str(IOS / "SourcesTV/TVOptions.m"), str(root / "driver.m"), "-framework", "Foundation", "-framework", "Security", "-o", str(root / "check")], check=True)
            result = subprocess.run([str(root / "check")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"driver check {result.returncode} failed: {result.stderr}")
            self.assertIn("this build has no keychain group (unsigned or sideloaded), so none are read", result.stderr)

    def test_boot_applies_them_on_tvos_after_the_env_files_and_before_the_host_reads_the_environment(self):
        main = (IOS / "Sources/main.m").read_text()
        boot = main[main.index("static int boot_env(void) {"):main.index("static NSString *program_env(void) {", main.index("static int boot_env(void) {"))]
        call = re.search(r"#if TARGET_OS_TV\s*tv_apply_switchtv_options\(\);[^\n]*\n\s*#endif", boot)
        self.assertIsNotNone(call, "boot_env calls tv_apply_switchtv_options() on tvOS only")
        for before in ('setenv("DM_ENV_LAUNCH_KEYS"', 'for (NSString *ef in @['):   # the launch environment and the env files are in place first
            self.assertLess(boot.index(before), call.start())
        for after in ("dm_diag_start(", "front_hud_env();", 'getenv("DM_LANG")', "program_env();", "dm_host_preload_start("):   # the host's first reads of the environment come after
            self.assertGreater(boot.index(after), call.end())

    def test_the_format_and_group_match_switchtv(self):
        source = (IOS / "SourcesTV/TVOptions.m").read_text()
        self.assertIn('@"dev.tvport.switchtv.options"', source)   # SwitchTV's Shared/GameOptions.swift: OptionsStore.service
        self.assertIn('info[@"DMSwitchTVGroup"]', source)          # the group TVLastPlayed.m uses, given only to a signed tvOS build (build_ipa.sh)
        self.assertIn("path: SourcesTV", (IOS / "project_tv.yml").read_text())


if __name__ == "__main__":
    unittest.main()

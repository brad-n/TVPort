"""An Apple TV game app tells SwitchTV (through the shared keychain group) that it was played: SourcesTV/TVLastPlayed.m is compiled for the Mac and run with a dictionary standing in for the keychain."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]

DRIVER = r"""
#import <Foundation/Foundation.h>
typedef BOOL (^TVStorePut)(NSString *account, NSData *value);
BOOL tv_last_played_write(TVStorePut put, NSString *scheme, NSDate *when);
void tv_record_last_played(void);
int main(int argc, char **argv) {
    @autoreleasepool {
        NSMutableDictionary<NSString *, NSString *> *store = [NSMutableDictionary dictionary];
        TVStorePut put = ^BOOL(NSString *account, NSData *value) { store[account] = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding]; return YES; };
        NSDate *t = [NSDate dateWithTimeIntervalSince1970:1700000123];
        if (!tv_last_played_write(put, @"switchtv-010015100b514000", t)) return 1;
        if (![store[@"010015100B514000"] isEqualToString:@"1700000123"]) return 2;                 // account = upper-case title ID, value = Unix seconds
        if (!tv_last_played_write(put, @"switchtv-010015100b514000", [NSDate dateWithTimeIntervalSince1970:1700000999])) return 3;
        if (![store[@"010015100B514000"] isEqualToString:@"1700000999"]) return 4;                 // a later play replaces the record
        if (tv_last_played_write(put, @"somethingelse-010015100b514000", t)) return 5;              // not a SwitchTV scheme
        if (tv_last_played_write(put, @"switchtv-ci", t)) return 6;                                // not a title ID
        if (tv_last_played_write(put, @"switchtv-../../etcpasswd000", t)) return 7;                // never a path
        if (tv_last_played_write(nil, @"switchtv-010015100b514000", t)) return 8;                  // no store: nothing happens
        if (tv_last_played_write(^BOOL(NSString *a, NSData *v) { return NO; }, @"switchtv-010015100b514000", t)) return 9;   // a refusing keychain is reported, not raised
        tv_record_last_played();                                                                    // no DMSwitchTVGroup in this process: returns quietly
        if (store.count != 1) return 10;
    }
    return 0;
}
"""


@unittest.skipUnless(sys.platform == "darwin", "clang for macOS required")
class TvLastPlayedTests(unittest.TestCase):
    def test_records_are_written_and_bad_input_is_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "driver.m").write_text(DRIVER)
            subprocess.run(["xcrun", "clang", "-fobjc-arc", str(IOS / "SourcesTV/TVLastPlayed.m"), str(root / "driver.m"), "-framework", "Foundation", "-framework", "Security", "-o", str(root / "check")], check=True)
            result = subprocess.run([str(root / "check")])
            self.assertEqual(result.returncode, 0, f"driver check {result.returncode} failed")

    def test_host_calls_it_when_the_game_becomes_active_on_tvos_only(self):
        main = (IOS / "Sources/main.m").read_text()
        self.assertRegex(main, r"sceneDidBecomeActive:\(UIScene \*\)s \{\s*front_ios_focus_event\(3\);\s*#if TARGET_OS_TV\s*tv_record_last_played\(\);\s*#endif")

    def test_group_is_named_in_the_plist_and_given_only_to_a_signed_tvos_build(self):
        self.assertIn("DMSwitchTVGroup: ${DM_SWITCHTV_GROUP}", (IOS / "project_tv.yml").read_text())
        script = (IOS / "tools/build_ipa.sh").read_text()
        line = next(l for l in script.splitlines() if "export DM_SWITCHTV_GROUP=$DM_TEAM_ID" in l)
        self.assertIn("DM_TVOS", line)
        self.assertIn("0000000000", line)   # the unsigned IPA's placeholder team gets none
        self.assertIn("keychain-access-groups", script)
        self.assertNotIn("DMSwitchTVGroup", (IOS / "project.yml").read_text())


if __name__ == "__main__":
    unittest.main()

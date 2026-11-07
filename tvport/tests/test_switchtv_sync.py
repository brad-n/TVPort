"""When TVPort refreshes SwitchTV on the Apple TV (tvport/app/Sources/SwitchTVSync.swift): the trigger rules, compiled and run on their own."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'macOS Swift required')
class SwitchTVSyncTests(unittest.TestCase):
    def test_trigger_rules(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            checks = root / 'Checks.swift'
            checks.write_text(r'''
import Foundation
@main struct Checks {
    static func main() {
        func sync(_ t: SwitchTVSync.Trigger, keep: Bool = true, device: String? = "TV") -> Bool { SwitchTVSync.shouldSync(t, keepUpToDate: keep, device: device) }
        // a successful Build & Install and a removal refresh SwitchTV
        assert(sync(.gameBuilt(installed: true, succeeded: true)))
        assert(sync(.gameRemoved))
        // a failed build, or a build that was not installed, changes nothing on the TV
        assert(!sync(.gameBuilt(installed: true, succeeded: false)))
        assert(!sync(.gameBuilt(installed: false, succeeded: true)))
        // the Settings toggle, and having an Apple TV chosen
        assert(!sync(.gameBuilt(installed: true, succeeded: true), keep: false))
        assert(!sync(.gameRemoved, keep: false))
        assert(!sync(.gameRemoved, device: nil))
        // later builds in the queue go first; a paused queue (a failed build) does not hold it back
        assert(SwitchTVSync.canRunNow(buildActive: false, buildsWaiting: false, queuePaused: false, otherWork: false))
        assert(!SwitchTVSync.canRunNow(buildActive: false, buildsWaiting: true, queuePaused: false, otherWork: false))
        assert(SwitchTVSync.canRunNow(buildActive: false, buildsWaiting: true, queuePaused: true, otherWork: false))
        assert(!SwitchTVSync.canRunNow(buildActive: true, buildsWaiting: false, queuePaused: false, otherWork: false))
        assert(!SwitchTVSync.canRunNow(buildActive: false, buildsWaiting: false, queuePaused: false, otherWork: true))
        // default on, and a stored choice wins
        let defaults = UserDefaults(suiteName: "tvport-switchtv-sync-test")!
        defaults.removePersistentDomain(forName: "tvport-switchtv-sync-test")
        assert(SwitchTVSync.keepUpToDate(defaults))
        defaults.set(false, forKey: SwitchTVSync.keepKey)
        assert(!SwitchTVSync.keepUpToDate(defaults))
        defaults.removePersistentDomain(forName: "tvport-switchtv-sync-test")
        assert(SwitchTVSync.warning("x").hasPrefix("Warning: SwitchTV was not updated"))
        print("PASS: SwitchTV sync triggers")
    }
}
''')
            executable = root / 'check'
            subprocess.run(['swiftc', '-parse-as-library', str(REPO / 'tvport/app/Sources/SwitchTVSync.swift'), str(checks), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    unittest.main()

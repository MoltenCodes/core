"""Run the host spec of the real-client harness's session passes.

`tooling/tests/fixtures/harness/Harness_spec.lua` loads
`tests/client/MoltenCodesTest/Harness.lua` over the framework Kits in the
shared fake client and types `/mct run all`, `/mct run guided`, `/mct next`
and `/mct skip`. It needs Busted, so it is skipped where Busted is absent;
CI's `test` job runs it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import unittest

from tooling.validation.validate_manifests import ROOT

BUSTED = shutil.which("busted")

#: The Kits the harness resolves at load, and TestKit's own test environment.
HARNESS_KITS = (
    "registry",
    "signalKit",
    "eventKit",
    "lifecycleKit",
    "timerKit",
    "schedulerKit",
    "testKit",
)


@unittest.skipIf(BUSTED is None, "busted is not installed")
class HarnessSpecTests(unittest.TestCase):
    def test_the_session_passes_behave_as_documented(self):
        segments = [str(ROOT / "packages" / kit / "src" / "?.lua") for kit in HARNESS_KITS]
        segments += [
            str(ROOT / "packages" / "testKit" / "tests" / "support" / "?.lua"),
            str(ROOT / "tests" / "support" / "?.lua"),
            "",
            "",
        ]
        environment = dict(
            os.environ,
            LUA_PATH=";".join(segments),
            MOLTENCODES_HARNESS_FILE=str(ROOT / "tests" / "client" / "MoltenCodesTest" / "Harness.lua"),
        )
        result = subprocess.run(
            [BUSTED, str(ROOT / "tooling" / "tests" / "fixtures" / "harness")],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("5 successes / 0 failures / 0 errors", result.stdout)


if __name__ == "__main__":
    unittest.main()

import io
import unittest
from unittest import mock

from tooling.package import list as module


MANIFESTS = {
    "signalKit": {"dependencies": {}},
    "registry": {"dependencies": {}, "distribution": "release"},
    "testKit": {"dependencies": {}, "distribution": "development"},
}


class PackageListTests(unittest.TestCase):
    def test_lists_every_package_sorted(self):
        self.assertEqual(
            ["registry", "signalKit", "testKit"], module.package_ids(MANIFESTS, release_only=False)
        )

    def test_release_skips_development_packages(self):
        self.assertEqual(
            ["registry", "signalKit"], module.package_ids(MANIFESTS, release_only=True)
        )

    def test_main_prints_one_id_per_line(self):
        with (
            mock.patch.object(module, "load_manifests", return_value=(MANIFESTS, [])),
            mock.patch("sys.stdout", io.StringIO()) as output,
        ):
            status = module.main(["--release"])

        self.assertEqual(0, status)
        self.assertEqual("registry\nsignalKit\n", output.getvalue())

    def test_main_fails_on_manifest_errors(self):
        with (
            mock.patch.object(module, "load_manifests", return_value=({}, ["broken"])),
            mock.patch("sys.stderr", io.StringIO()) as errors,
        ):
            status = module.main(["--release"])

        self.assertEqual(1, status)
        self.assertIn("broken", errors.getvalue())


if __name__ == "__main__":
    unittest.main()

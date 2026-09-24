"""Each committed flavour describes its own client and nothing of another's.

Design document section 19: a function existing in Retail does not imply that
it exists in Classic Era, and identical names do not guarantee identical
signatures. The metadata is captured per flavour, so isolation holds by
construction; these tests make the property visible and keep a future
"share this between flavours" shortcut from slipping in unnoticed; that each
runtime file binds exactly its own metadata is proved by
`test_api_committed_flavours`. They run over whatever flavours are committed
and are skipped with fewer than two.
"""

from __future__ import annotations

import unittest

from tooling.api import flavours, model, render_runtime
from tooling.validation.validate_manifests import ROOT


PACKAGE_DIR = ROOT / "packages" / "apiKit"


def committed() -> dict[str, model.FlavourMetadata]:
    result = {}
    for flavour in flavours.load_flavours().flavours:
        directory = PACKAGE_DIR / "metadata" / flavour.id
        if (directory / model.PROVENANCE_FILE).is_file():
            result[flavour.id] = model.read_metadata(directory)
    return result


def bindings_of(metadata: model.FlavourMetadata) -> set[str]:
    return {
        function.binding
        for namespace in metadata.namespaces
        for function in namespace.functions
        if function.binding is not None
    }


class FlavourIsolationTests(unittest.TestCase):
    def setUp(self):
        self.metadata = committed()
        if len(self.metadata) < 2:
            self.skipTest("fewer than two flavours are committed")

    def test_every_flavour_names_itself_in_its_provenance_and_runtime_file(self):
        table = flavours.load_flavours()
        for flavour_id, metadata in self.metadata.items():
            with self.subTest(flavour=flavour_id):
                self.assertEqual(flavour_id, metadata.provenance.flavour)
                runtime = PACKAGE_DIR / "src" / render_runtime.runtime_file_name(table.by_id(flavour_id))
                text = runtime.read_text(encoding="utf-8")
                self.assertIn(f'ApiKit:RegisterFlavor("{flavour_id}"', text)
                for other in self.metadata:
                    if other != flavour_id:
                        self.assertNotIn(f'RegisterFlavor("{other}"', text)

    def test_flavours_differ_in_what_they_bind(self):
        """The captures are different clients; a shared surface would mean a copy slipped in."""
        ids = sorted(self.metadata)
        for index, first in enumerate(ids):
            for second in ids[index + 1 :]:
                with self.subTest(pair=(first, second)):
                    first_bindings = bindings_of(self.metadata[first])
                    second_bindings = bindings_of(self.metadata[second])
                    self.assertTrue(first_bindings - second_bindings, f"{first} adds nothing over {second}")
                    self.assertTrue(second_bindings - first_bindings, f"{second} adds nothing over {first}")


if __name__ == "__main__":
    unittest.main()

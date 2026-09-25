"""The real-client flavour table agrees with the apiKit flavours and the supported clients."""

from __future__ import annotations

import unittest

from tooling.api.flavours import load_flavours
from tooling.client import flavours as module
from tooling.validation.interface_numbers import load_supported_clients


class ClientFlavourTests(unittest.TestCase):
    def test_every_promised_flavour_is_an_apikit_flavour_with_the_same_project_id(self):
        api_flavours = load_flavours()

        for flavour in module.PROMISED_FLAVOURS:
            with self.subTest(flavour=flavour.flavour_id):
                detection = api_flavours.by_id(flavour.flavour_id).detection
                self.assertEqual(detection.project_id, flavour.project_id)
                self.assertFalse(detection.test_build)

    def test_every_flavour_is_a_supported_client_with_the_same_promise(self):
        clients = {client.toc_suffix: client for client in load_supported_clients().clients}

        self.assertEqual(set(clients), {flavour.toc_suffix for flavour in module.CLIENT_FLAVOURS})
        for flavour in module.CLIENT_FLAVOURS:
            with self.subTest(flavour=flavour.flavour_id):
                self.assertEqual(clients[flavour.toc_suffix].promised, flavour.promised)

    def test_folders_are_the_launcher_names_and_retail_is_the_default(self):
        self.assertEqual(
            ["_retail_", "_classic_era_", "_classic_", "_anniversary_"],
            [flavour.directory for flavour in module.CLIENT_FLAVOURS],
        )
        self.assertEqual(
            ["retail", "classic-era", "classic-mop"],
            [flavour.flavour_id for flavour in module.PROMISED_FLAVOURS],
        )
        self.assertEqual("_retail_", module.DEFAULT_FLAVOUR_DIRECTORY)

    def test_lookups(self):
        self.assertEqual("classic-mop", module.flavour_by_project_id(19).flavour_id)
        self.assertEqual("tbc-anniversary", module.flavour_by_project_id(5).flavour_id)
        self.assertIsNone(module.flavour_by_project_id(True))
        self.assertIsNone(module.flavour_by_project_id(3))
        self.assertEqual("classic-era", module.flavour_by_directory("_classic_era_").flavour_id)
        self.assertIsNone(module.flavour_by_directory("_classic_era_ptr_"))
        self.assertEqual("_classic_", module.flavour_by_id("classic-mop").directory)
        self.assertIsNone(module.flavour_by_id("ptr"))


if __name__ == "__main__":
    unittest.main()

"""Tests for the apiKit naming rules."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from tooling.api import naming as module


VALID_RULES = {
    "words": ["BNet", "PvP"],
    "namespaceAliases": {"addOnProfiler": "profiler"},
    "namespaceExceptions": {"C_Unit": "unitNamespace"},
    "functionExceptions": {"Unit.UnitName": "unitName"},
}


def rules(**overrides) -> module.NamingRules:
    data = copy.deepcopy(VALID_RULES)
    data.update(overrides)
    return module.parse_naming_rules(data)


class SplitWordsTests(unittest.TestCase):
    def test_lowercase_to_uppercase_starts_a_word(self):
        self.assertEqual(["Add", "On", "Profiler"], module.split_words("AddOnProfiler"))

    def test_a_run_of_capitals_ends_before_its_last_capital(self):
        self.assertEqual(["Get", "NPC", "Name"], module.split_words("GetNPCName"))
        self.assertEqual(["UI", "Widget", "Manager"], module.split_words("UIWidgetManager"))
        self.assertEqual(["GUID", "Is", "Player"], module.split_words("GUIDIsPlayer"))

    def test_a_trailing_run_of_capitals_is_one_word(self):
        self.assertEqual(["Object", "Entered", "AOI"], module.split_words("ObjectEnteredAOI"))
        self.assertEqual(["URL"], module.split_words("URL"))

    def test_digits_stay_with_their_word(self):
        self.assertEqual(["Axe1H"], module.split_words("Axe1H"))
        self.assertEqual(["Bar2", "Foo"], module.split_words("Bar2Foo"))

    def test_underscores_separate_words_and_capital_pieces_become_names(self):
        self.assertEqual(["Zoom", "In", "Position"], module.split_words("ZoomIn_Position"))
        self.assertEqual(["Lfg", "Role", "Constants"], module.split_words("LFG_ROLEConstants"))
        self.assertEqual(["Item", "Consts", "Mainline"], module.split_words("ItemConsts_Mainline"))
        self.assertEqual(["Player", "Login"], module.split_words("PLAYER_LOGIN"))
        self.assertEqual(["Leading"], module.split_words("_Leading_"))

    def test_known_words_are_kept_whole(self):
        self.assertEqual(["PvP", "Score", "Info"], module.split_words("PvPScoreInfo", ["PvP"]))
        self.assertEqual(["Get", "PvP", "Talent"], module.split_words("GetPvPTalent", ["PvP"]))
        self.assertEqual(["BNet", "Account"], module.split_words("BNetAccount", ["BNet"]))

    def test_a_known_word_followed_by_lowercase_is_not_cut(self):
        self.assertEqual(["Is", "Pv", "Per"], module.split_words("IsPvPer", ["PvP"]))

    def test_longest_known_word_wins(self):
        self.assertEqual(["BNetGame"], module.split_words("BNetGame", ["BNet", "BNetGame"]))

    def test_empty_name_gives_no_words(self):
        self.assertEqual([], module.split_words(""))


class LowerCamelTests(unittest.TestCase):
    def test_first_word_lowercase_rest_unchanged(self):
        self.assertEqual("getNPCName", module.lower_camel(["Get", "NPC", "Name"]))
        self.assertEqual("uiWidgetManager", module.lower_camel(["UI", "Widget", "Manager"]))
        self.assertEqual("pvpScoreInfo", module.lower_camel(["PvP", "Score", "Info"]))

    def test_no_words_is_an_error(self):
        with self.assertRaises(module.NamingError):
            module.lower_camel([])


class WrapperNameTests(unittest.TestCase):
    def test_namespace_drops_the_prefix(self):
        self.assertEqual("addOnProfiler", module.namespace_wrapper_name("C_AddOnProfiler", rules()))
        self.assertEqual("cvar", module.namespace_wrapper_name("C_CVar", rules(words=["CVar"])))

    def test_namespace_without_prefix_is_named_as_is(self):
        self.assertEqual("string", module.namespace_wrapper_name("string", rules()))

    def test_bare_prefix_is_an_error(self):
        with self.assertRaises(module.NamingError):
            module.namespace_wrapper_name("C_", rules())

    def test_global_system_name(self):
        self.assertEqual("unit", module.global_system_wrapper_name("Unit", rules()))
        self.assertEqual("bnetOutage", module.global_system_wrapper_name("BNetOutage", rules()))

    def test_global_function_drops_its_system_prefix(self):
        self.assertEqual("name", module.function_wrapper_name("UnitName", rules(), global_system="Unit"))
        self.assertEqual("isPVP", module.function_wrapper_name("UnitIsPVP", rules(), global_system="Unit"))

    def test_global_function_without_the_prefix_keeps_its_name(self):
        self.assertEqual("getTime", module.function_wrapper_name("GetTime", rules(), global_system="System"))

    def test_global_function_named_exactly_like_its_system_keeps_its_name(self):
        self.assertEqual("unit", module.function_wrapper_name("Unit", rules(), global_system="Unit"))

    def test_prefix_must_match_whole_words(self):
        self.assertEqual(
            "unitedFront", module.function_wrapper_name("UnitedFront", rules(), global_system="Unit")
        )

    def test_namespaced_function_never_drops_anything(self):
        self.assertEqual("measureCall", module.function_wrapper_name("MeasureCall", rules()))
        self.assertEqual("timerAfter", module.function_wrapper_name("TimerAfter", rules()))

    def test_member_names(self):
        self.assertEqual("addonLoaded", module.member_wrapper_name("AddonLoaded", rules()))
        self.assertEqual("phaseReason", module.member_wrapper_name("PhaseReason", rules()))

    def test_alias_lookup(self):
        self.assertEqual("profiler", rules().alias_for("addOnProfiler"))
        self.assertIsNone(rules().alias_for("timer"))


class RulesFileTests(unittest.TestCase):
    def test_valid_rules_are_parsed(self):
        parsed = rules()

        self.assertEqual(("BNet", "PvP"), parsed.words)
        self.assertEqual({"C_Unit": "unitNamespace"}, parsed.namespace_exceptions)
        self.assertEqual({"Unit.UnitName": "unitName"}, parsed.function_exceptions)

    def test_unknown_key_is_rejected(self):
        data = copy.deepcopy(VALID_RULES)
        data["extra"] = {}

        with self.assertRaisesRegex(module.NamingError, "exactly"):
            module.parse_naming_rules(data)

    def test_a_word_the_splitter_keeps_whole_is_refused(self):
        with self.assertRaisesRegex(module.NamingError, "GUID"):
            rules(words=["GUID"])

    def test_words_must_be_sorted_and_unique(self):
        with self.assertRaisesRegex(module.NamingError, "sorted"):
            rules(words=["PvP", "BNet"])
        with self.assertRaisesRegex(module.NamingError, "twice"):
            rules(words=["BNet", "BNet"])

    def test_alias_may_not_point_at_itself_or_at_an_alias(self):
        with self.assertRaisesRegex(module.NamingError, "itself"):
            rules(namespaceAliases={"profiler": "profiler"})
        with self.assertRaisesRegex(module.NamingError, "aliased"):
            rules(namespaceAliases={"addOnProfiler": "profiler", "profiler": "prof"})

    def test_one_alias_for_two_namespaces_is_rejected(self):
        with self.assertRaisesRegex(module.NamingError, "two namespaces"):
            rules(namespaceAliases={"addOnProfiler": "profiler", "cvar": "profiler"})

    def test_exception_targets_must_be_wrapper_names(self):
        with self.assertRaisesRegex(module.NamingError, "lowerCamelCase"):
            rules(namespaceExceptions={"C_Unit": "Unit"})
        with self.assertRaisesRegex(module.NamingError, "does not match"):
            rules(functionExceptions={"UnitName": "unitName"})

    def test_load_reads_a_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "naming.json"
            path.write_text(json.dumps(VALID_RULES), encoding="utf-8")

            self.assertEqual(("BNet", "PvP"), module.load_naming_rules(path).words)

    def test_repository_rules_are_valid(self):
        parsed = module.load_naming_rules()

        self.assertIn("PvP", parsed.words)
        self.assertEqual("profiler", parsed.alias_for("addOnProfiler"))


if __name__ == "__main__":
    unittest.main()

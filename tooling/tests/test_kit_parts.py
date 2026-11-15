"""Tests for Kit parts across the tools: manifests, load order, builder, embeds, validation.

ADR 0001 (`docs/decisions/0001-kit-core-and-parts.md`) makes a Kit a core
file plus optional part files. Every test here builds a small repository of
its own; the last class checks that the real repository's load order is the
one the builder has always computed for cores.
"""

from __future__ import annotations

import contextlib
import datetime
import io
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tooling.package import build
from tooling.package import embeds
from tooling.package import parts as kit_parts
from tooling.test import coverage
from tooling.test import run as test_run
from tooling.validation import validate_manifests
from tooling.validation import validate_repository


def core(name: str, **dependencies: list[str] | None) -> dict:
    """A minimal manifest for model tests; each keyword is a dependency, its value its parts."""
    contracts = {}
    for package, parts in dependencies.items():
        contract = {"api": 1}
        if parts:
            contract["parts"] = parts
        contracts[package] = contract
    return {"name": name, "api": 1, "revision": 1, "dependencies": contracts}


class PartModelTests(unittest.TestCase):
    """The node walk every tool shares."""

    def test_without_parts_the_walk_is_the_package_walk(self):
        manifests = {
            "registry": core("registry"),
            "signalKit": core("signalKit", registry=None),
            "eventKit": core("eventKit", registry=None, signalKit=None),
            "poolKit": core("poolKit", registry=None),
        }

        nodes = kit_parts.walk(kit_parts.roots_for(sorted(manifests), {}, manifests), manifests)

        self.assertEqual(
            build.load_order(sorted(manifests), manifests), [node.package for node in nodes]
        )
        self.assertTrue(all(node.part is None for node in nodes))

    def test_a_part_loads_after_its_core_and_what_it_needs(self):
        manifests = {
            "registry": core("registry"),
            "timerKit": core("timerKit", registry=None),
            "eventKit": core("eventKit", registry=None),
        }
        manifests["eventKit"]["parts"] = {
            "Throttle": {"description": "t", "revision": 1},
            "Coalescing": {
                "description": "c",
                "revision": 1,
                "dependencies": {"timerKit": {"api": 1}},
                "parts": ["Throttle"],
            },
        }

        nodes = kit_parts.walk(
            kit_parts.roots_for([], {"eventKit": ["Coalescing"]}, manifests), manifests
        )

        self.assertEqual(
            ["registry", "eventKit", "timerKit", "eventKit/Throttle", "eventKit/Coalescing"],
            [node.label for node in nodes],
        )

    def test_a_core_can_require_another_kits_part(self):
        manifests = {
            "registry": core("registry"),
            "widgetKit": core("widgetKit", registry=None),
            "panelKit": core("panelKit", registry=None, widgetKit=["Renderer"]),
        }
        manifests["widgetKit"]["parts"] = {"Renderer": {"description": "r", "revision": 1}}

        nodes = kit_parts.walk([kit_parts.Node("panelKit")], manifests)

        self.assertEqual(
            ["registry", "widgetKit", "widgetKit/Renderer", "panelKit"],
            [node.label for node in nodes],
        )

    def test_selected_parts_follow_manifest_order_not_typed_order(self):
        manifests = {"registry": core("registry"), "aKit": core("aKit", registry=None)}
        manifests["aKit"]["parts"] = {
            "First": {"description": "1", "revision": 1},
            "Second": {"description": "2", "revision": 1},
        }

        roots = kit_parts.roots_for([], {"aKit": ["Second", "First"]}, manifests)

        self.assertEqual(["aKit", "aKit/First", "aKit/Second"], [node.label for node in roots])

    def test_selectors(self):
        self.assertEqual(kit_parts.Selector("eventKit", None), kit_parts.parse_selector("eventKit"))
        self.assertEqual(
            kit_parts.Selector("eventKit", "Coalescing"),
            kit_parts.parse_selector("eventKit/Coalescing"),
        )
        self.assertEqual(kit_parts.Selector("eventKit", "*"), kit_parts.parse_selector("eventKit/*"))
        self.assertIsNone(kit_parts.parse_selector("EventKit"))
        self.assertIsNone(kit_parts.parse_selector("eventKit/coalescing"))
        self.assertIsNone(kit_parts.parse_selector("eventKit/"))

    def test_part_file_name_carries_the_facade(self):
        self.assertEqual(
            "parts/EventKit-Coalescing.lua", kit_parts.part_file_name("EventKit", "Coalescing")
        )


class FixtureRepository(unittest.TestCase):
    """A repository made for one test, with every tool pointed at it."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name) / "repository"
        self.packages = self.root / "packages"
        self.packages.mkdir(parents=True)
        (self.root / "LICENSE").write_text("MIT License\n", encoding="utf-8")
        self.output = Path(self.tempdir.name) / "out"
        self.output.mkdir()

        self.patches = [
            (validate_manifests, "ROOT", self.root),
            (validate_manifests, "PACKAGES", self.packages),
            (build, "ROOT", self.root),
            (validate_repository, "ROOT", self.root),
            (test_run, "PACKAGES", self.packages),
        ]
        self.originals = [(module, name, getattr(module, name)) for module, name, _ in self.patches]
        for module, name, value in self.patches:
            setattr(module, name, value)

    def tearDown(self):
        for module, name, value in self.originals:
            setattr(module, name, value)
        self.tempdir.cleanup()

    def write_package(
        self,
        name: str,
        facade: str,
        *,
        dependencies=None,
        parts=None,
        part_sources=None,
        version: str = "1.2.3",
    ) -> Path:
        """Write a package; ``parts`` is the manifest object, ``part_sources`` overrides files."""
        package_dir = self.packages / name
        source = package_dir / "src"
        source.mkdir(parents=True)
        (source / f"{facade}.lua").write_text("return {}\n", encoding="utf-8")
        for part, entry in (parts or {}).items():
            text = (part_sources or {}).get(
                part, f"local PART_REVISION = {entry.get('revision', 1)}\nreturn PART_REVISION\n"
            )
            path = source / kit_parts.part_file_name(facade, part)
            path.parent.mkdir(exist_ok=True)
            path.write_text(text, encoding="utf-8")
        manifest = {
            "name": name,
            "displayName": facade,
            "description": f"{facade} package",
            "version": version,
            "license": "MIT",
            "api": 1,
            "revision": 1,
            "dependencies": dependencies or {},
        }
        if parts is not None:
            manifest["parts"] = parts
        (package_dir / "package.manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        (package_dir / "CHANGELOG.md").write_text(
            f"# Changelog\n\n## {version} — 2026-11-15\n\n- Added.\n", encoding="utf-8"
        )
        for document in ("README.md",):
            (package_dir / document).write_text(f"# {facade}\n", encoding="utf-8")
        return package_dir

    def write_parted_repository(self):
        """Registry, TimerKit and an EventKit with two parts, one of which needs TimerKit."""
        self.write_package("registry", "Registry")
        self.write_package("timerKit", "TimerKit", dependencies={"registry": {"api": 1}})
        self.write_package(
            "eventKit",
            "EventKit",
            dependencies={"registry": {"api": 1}},
            parts={
                "Throttle": {"description": "Throttled delivery.", "revision": 2},
                "Coalescing": {
                    "description": "Coalesced delivery.",
                    "revision": 1,
                    "dependencies": {"timerKit": {"api": 1}},
                    "parts": ["Throttle"],
                },
            },
        )

    def manifests(self):
        manifests, errors = validate_manifests.load_manifests()
        errors.extend(validate_manifests.validate_graph(manifests))
        return manifests, errors


class ManifestPartsTests(FixtureRepository):
    """Validation of the `parts` object and of contracts that name parts."""

    def test_a_valid_parted_repository_has_no_errors(self):
        self.write_parted_repository()

        self.assertEqual([], self.manifests()[1])

    def test_part_entries_need_a_description_and_a_revision(self):
        self.write_package("registry", "Registry", parts={"Bad": {"revision": 0}})

        errors = self.manifests()[1]

        self.assertTrue(any('missing required field "description"' in e for e in errors))
        self.assertTrue(any('"parts.Bad.revision" must be a positive integer' in e for e in errors))

    def test_part_names_are_pascal_case(self):
        self.write_package("registry", "Registry", parts={"lower": {"description": "x", "revision": 1}})

        self.assertTrue(any("must match ^[A-Z]" in e for e in self.manifests()[1]))

    def test_a_contract_may_name_only_declared_parts(self):
        self.write_package("registry", "Registry")
        self.write_package(
            "aKit", "AKit", dependencies={"registry": {"api": 1, "parts": ["Missing"]}}
        )

        errors = self.manifests()[1]

        self.assertTrue(any('names part "Missing", which "registry" does not declare' in e for e in errors))

    def test_a_part_must_not_name_its_own_kit(self):
        self.write_package("registry", "Registry")
        self.write_package(
            "aKit",
            "AKit",
            dependencies={"registry": {"api": 1}},
            parts={"P": {"description": "p", "revision": 1, "dependencies": {"aKit": {"api": 1}}}},
        )

        self.assertTrue(any("must not depend on its own Kit" in e for e in self.manifests()[1]))

    def test_sibling_parts_must_exist_and_not_be_itself(self):
        self.write_package(
            "registry",
            "Registry",
            parts={
                "A": {"description": "a", "revision": 1, "parts": ["Ghost"]},
                "B": {"description": "b", "revision": 1, "parts": ["B"]},
            },
        )

        errors = self.manifests()[1]

        self.assertTrue(any('parts names "Ghost"' in e for e in errors))
        self.assertTrue(any('part "B" must not list itself' in e for e in errors))

    def test_a_cycle_through_parts_is_refused(self):
        self.write_package("registry", "Registry")
        self.write_package(
            "aKit",
            "AKit",
            dependencies={"registry": {"api": 1}, "bKit": {"api": 1, "parts": ["P"]}},
        )
        self.write_package(
            "bKit",
            "BKit",
            dependencies={"registry": {"api": 1}},
            parts={"P": {"description": "p", "revision": 1, "dependencies": {"aKit": {"api": 1}}}},
        )

        errors = self.manifests()[1]

        self.assertTrue(any("dependency cycle detected" in e and "bKit/P" in e for e in errors))

    def test_parts_must_come_after_api_and_revision(self):
        path = self.write_package("registry", "Registry") / "package.manifest.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        reordered = {"parts": {}, **data}
        path.write_text(json.dumps(reordered), encoding="utf-8")

        self.assertTrue(any('"parts" must come after' in e for e in self.manifests()[1]))


class BuilderPartsTests(FixtureRepository):
    """What the builder selects, copies, names and verifies when Kits have parts."""

    def select(self, **options):
        manifests, errors = self.manifests()
        self.assertEqual([], errors)
        return build.select(manifests, **options)

    def test_a_package_alone_is_its_core(self):
        self.write_parted_repository()

        selection = self.select(packages=["eventKit"])

        self.assertEqual(["registry/Registry.lua", "eventKit/EventKit.lua"], build.load_order_paths(selection))
        self.assertEqual("MoltenCodes-EventKit", selection.bundle_name)

    def test_a_part_brings_its_core_its_siblings_and_its_dependencies(self):
        self.write_parted_repository()

        selection = self.select(part_selectors=["eventKit/Coalescing"])

        self.assertEqual(
            [
                "registry/Registry.lua",
                "eventKit/EventKit.lua",
                "timerKit/TimerKit.lua",
                "eventKit/parts/EventKit-Throttle.lua",
                "eventKit/parts/EventKit-Coalescing.lua",
            ],
            build.load_order_paths(selection),
        )
        self.assertEqual("MoltenCodes-EventKit", selection.bundle_name)

    def test_several_kits_make_a_custom_bundle(self):
        self.write_parted_repository()

        selection = self.select(packages=["eventKit", "timerKit"])

        self.assertEqual(build.CUSTOM_BUNDLE_NAME, selection.bundle_name)
        self.assertEqual(
            "MoltenCodes-Mine", self.select(packages=["timerKit", "eventKit"], name="MoltenCodes-Mine").bundle_name
        )

    def test_names_are_checked(self):
        self.write_parted_repository()

        for name in ("Other", "MoltenCodes"):
            with self.subTest(name=name), self.assertRaises(build.BuildError):
                self.select(packages=["eventKit", "timerKit"], name=name)

    def test_every_package_takes_every_part(self):
        self.write_parted_repository()

        selection = self.select(every_package=True)

        self.assertIn("eventKit/parts/EventKit-Throttle.lua", build.load_order_paths(selection))
        self.assertEqual(["Throttle", "Coalescing"], selection.selected_parts("eventKit"))
        self.assertEqual(
            selection.load_nodes(),
            build.select_packages(self.manifests()[0]).load_nodes(),
        )

    def test_a_single_kit_release_is_the_whole_kit(self):
        self.write_parted_repository()

        selection = build.select_packages(self.manifests()[0], "eventKit")

        self.assertEqual(["Throttle", "Coalescing"], selection.selected_parts("eventKit"))

    def test_refusals_name_the_fix(self):
        self.write_parted_repository()

        cases = {
            "eventkit": 'did you mean "eventKit"?',
            "eventKit/Coalesce": 'did you mean "eventKit/Coalescing"?',
            "timerKit/Anything": "has no parts; select it with --package timerKit",
            "eventKit/lower": "must be written <packageId>/<Part>",
        }
        for selector, message in cases.items():
            with self.subTest(selector=selector):
                with self.assertRaises(build.BuildError) as raised:
                    if "/" in selector:
                        self.select(part_selectors=[selector])
                    else:
                        self.select(packages=[selector])
                self.assertIn(message, str(raised.exception))

    def test_the_bundle_holds_only_selected_parts_and_verifies(self):
        self.write_parted_repository()
        selection = self.select(packages=["timerKit"], part_selectors=["eventKit/Throttle"])

        manifest = build.build(self.output, selection=selection, write_embeds=True)

        bundle = self.output / build.CUSTOM_BUNDLE_NAME
        self.assertTrue((bundle / "eventKit/parts/EventKit-Throttle.lua").is_file())
        self.assertFalse((bundle / "eventKit/parts/EventKit-Coalescing.lua").exists())
        self.assertEqual(["Throttle"], list(manifest["packages"]["eventKit"]["parts"]))
        self.assertNotIn("parts", manifest["packages"]["timerKit"])
        self.assertEqual("selected", manifest["packages"]["timerKit"]["role"])
        self.assertEqual("dependency", manifest["packages"]["registry"]["role"])
        self.assertEqual("embeds.xml", manifest["embeds"])
        self.assertEqual([], build.verify_checksums(self.output))
        self.assertEqual([], build.verify_toc(bundle))
        self.assertEqual([], build.verify_embeds(bundle))

        (bundle / "embeds.xml").write_text("<Ui></Ui>\n", encoding="utf-8")
        self.assertEqual(1, len(build.verify_embeds(bundle)))

    def test_command_line_takes_several_packages_and_parts(self):
        self.write_parted_repository()

        with contextlib.redirect_stdout(io.StringIO()) as printed:
            status = build.main(
                [
                    "--package", "timerKit",
                    "--part", "eventKit/*",
                    "--embeds",
                    "--out", str(self.output),
                    "--verify",
                ]
            )

        self.assertEqual(0, status)
        self.assertIn("embeds.xml", printed.getvalue())

    def test_command_line_requires_a_selection(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            build.parse_args(["--out", str(self.output)])


class EmbedsGeneratorTests(FixtureRepository):
    """The author-facing generator."""

    def test_embeds_xml_under_a_root(self):
        self.write_parted_repository()
        manifests = self.manifests()[0]
        selection = embeds.selection_from_selectors(manifests, ["eventKit/Throttle", "timerKit"])

        text = embeds.render_embeds_xml(
            build.load_order_paths(selection), build.describe_selection(selection), "Libs\\MC"
        )

        self.assertTrue(text.startswith('<Ui xmlns="http://www.blizzard.com/wow/ui/">'))
        self.assertEqual(
            [
                "Libs/MC/registry/Registry.lua",
                "Libs/MC/eventKit/EventKit.lua",
                "Libs/MC/eventKit/parts/EventKit-Throttle.lua",
                "Libs/MC/timerKit/TimerKit.lua",
            ],
            embeds.listed_scripts(text),
        )
        self.assertIn('<Script file="Libs\\MC\\registry\\Registry.lua" />', text)

    def test_toc_lines(self):
        self.write_parted_repository()

        with contextlib.redirect_stdout(io.StringIO()) as printed:
            status = embeds.main(["timerKit", "--toc", "--root", "Libs/MC"])

        self.assertEqual(0, status)
        lines = [line for line in printed.getvalue().splitlines() if not line.startswith("#")]
        self.assertEqual(["Libs\\MC\\registry\\Registry.lua", "Libs\\MC\\timerKit\\TimerKit.lua"], lines)

    def test_toc_lines_carry_the_flavour_directive(self):
        text = embeds.render_toc_lines(
            ["apiKit/ApiKit.lua", "apiKit/flavours/ClassicMop.lua"], "apiKit", "Libs/MC"
        )

        self.assertIn("Libs\\MC\\apiKit\\ApiKit.lua\n", text)
        self.assertIn("Libs\\MC\\apiKit\\flavours\\ClassicMop.lua [AllowLoadGameType mists]", text)

    def test_unknown_selector_is_refused(self):
        self.write_parted_repository()

        with contextlib.redirect_stderr(io.StringIO()) as printed:
            status = embeds.main(["timerkit"])

        self.assertEqual(1, status)
        self.assertIn('did you mean "timerKit"?', printed.getvalue())

    def test_parts_table(self):
        self.write_parted_repository()

        table = embeds.render_parts_table(self.manifests()[0])

        self.assertIn(
            "| `eventKit/Coalescing` | `eventKit/parts/EventKit-Coalescing.lua` "
            "| Coalesced delivery. | `timerKit`, `eventKit/Throttle` |",
            table,
        )
        self.assertIn("| `eventKit/Throttle` | `eventKit/parts/EventKit-Throttle.lua` | Throttled delivery. | nothing |", table)

    def test_footprint_table_groups_kits(self):
        self.write_parted_repository()

        table = embeds.render_footprint_table(self.manifests()[0])

        self.assertIn("| 2 | `eventKit`, `timerKit` | nothing |", table)

    def test_generated_blocks_round_trip(self):
        block = embeds.generated_block("parts", "body\n")

        self.assertEqual("body\n", embeds.read_generated_block("x\n" + block, "parts"))
        self.assertIsNone(embeds.read_generated_block("x\n", "parts"))


class RepositoryPartsTests(FixtureRepository):
    """Repository validation of part files, the footprint blocks and changelog versions."""

    def test_part_files_match_the_manifest(self):
        self.write_parted_repository()

        self.assertEqual([], validate_repository.validate_part_files(self.packages / "eventKit", self.manifest("eventKit")))

    def manifest(self, name):
        return json.loads((self.packages / name / "package.manifest.json").read_text(encoding="utf-8"))

    def test_an_undeclared_part_file_and_a_missing_one_are_reported(self):
        self.write_parted_repository()
        parts_dir = self.packages / "eventKit" / "src" / "parts"
        (parts_dir / "EventKit-Throttle.lua").unlink()
        (parts_dir / "Stray.lua").write_text("return 1\n", encoding="utf-8")

        errors = validate_repository.validate_part_files(self.packages / "eventKit", self.manifest("eventKit"))

        self.assertEqual(2, len(errors))
        self.assertTrue(any("not a declared part" in e for e in errors))
        self.assertTrue(any('part "Throttle" is declared in the manifest but has no file' in e for e in errors))

    def test_part_revision_must_match(self):
        self.write_package(
            "registry",
            "Registry",
            parts={"P": {"description": "p", "revision": 3}},
            part_sources={"P": "local PART_REVISION = 2\n"},
        )

        errors = validate_repository.validate_part_files(self.packages / "registry", self.manifest("registry"))

        self.assertEqual(1, len(errors))
        self.assertIn("PART_REVISION is 2 but the manifest gives part \"P\" revision 3", errors[0])

    def test_language_server_closure_covers_parts(self):
        self.write_parted_repository()

        self.assertEqual(
            ["registry", "timerKit"],
            validate_repository._dependency_closure("eventKit", self.manifests()[0]),
        )

    def test_changelog_version_must_match_the_manifest(self):
        self.write_parted_repository()
        manifests = self.manifests()[0]
        self.assertEqual([], validate_repository.validate_changelog_versions(manifests))

        manifests["timerKit"]["version"] = "1.2.4"
        errors = validate_repository.validate_changelog_versions(manifests)

        self.assertEqual(1, len(errors))
        self.assertIn("the newest entry is 1.2.3 but the manifest version is 1.2.4", errors[0])

    def test_changelog_date_must_not_be_in_the_future(self):
        self.write_parted_repository()

        errors = validate_repository.validate_changelog_versions(
            self.manifests()[0], today=datetime.date(2026, 11, 13)
        )

        self.assertEqual(3, len(errors))
        self.assertIn("more than a day after today (2026-11-13, UTC)", errors[0])

    def test_changelog_date_may_be_one_day_ahead_of_utc(self):
        self.write_parted_repository()

        errors = validate_repository.validate_changelog_versions(
            self.manifests()[0], today=datetime.date(2026, 11, 14)
        )

        self.assertEqual([], errors)

    def test_changelog_needs_a_release_heading(self):
        self.write_parted_repository()
        (self.packages / "timerKit" / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n", encoding="utf-8")

        errors = validate_repository.validate_changelog_versions(self.manifests()[0])

        self.assertEqual(1, len(errors))
        self.assertIn('must read "## <version> — <YYYY-MM-DD>"', errors[0])

    def test_footprint_blocks_are_checked_and_replacements_printed(self):
        self.write_parted_repository()
        manifests = self.manifests()[0]
        document = self.root / "docs" / "EMBEDDING.md"
        document.parent.mkdir()
        document.write_text("# Embedding\n", encoding="utf-8")

        errors = validate_repository.validate_documented_footprint(manifests)
        self.assertEqual(2, len(errors))
        self.assertIn("<!-- generated:footprint -->", errors[0])

        document.write_text(
            "# Embedding\n\n"
            + embeds.generated_block("footprint", embeds.render_footprint_table(manifests))
            + "\n"
            + embeds.generated_block("parts", embeds.render_parts_table(manifests)),
            encoding="utf-8",
        )
        self.assertEqual([], validate_repository.validate_documented_footprint(manifests))


class RunnerAndCoveragePartsTests(FixtureRepository):
    """The test runner's path and coverage's treatment of parts."""

    def test_the_lua_path_carries_parts_directories(self):
        path = test_run.build_lua_path(["eventKit"], [])

        self.assertIn(str(self.packages / "eventKit" / "src" / "parts" / "?.lua"), path.split(";"))

    def test_a_suite_gets_what_its_parts_need(self):
        self.write_parted_repository()

        self.assertEqual(
            ["eventKit", "registry", "timerKit"],
            test_run.suite_source_packages("eventKit", self.manifests()[0]),
        )

    def test_coverage_reports_parts_and_unloaded_ones(self):
        self.write_parted_repository()
        report = (
            "\nSummary\n"
            "packages/eventKit/src/EventKit.lua 10 0 100.00%\n"
            "packages/eventKit/src/parts/EventKit-Throttle.lua 3 1 75.00%\n"
        )

        rows = coverage.parse_report(report)
        part_rows = coverage.parse_part_rows(report)
        messages = coverage.unloaded_parts(rows, part_rows, self.manifests()[0])

        self.assertEqual([coverage.PackageCoverage("eventKit", 13, 1)], rows)
        self.assertEqual([coverage.PartCoverage("eventKit", "Throttle", 3, 1)], part_rows)
        self.assertEqual(1, len(messages))
        self.assertIn('eventKit/Coalescing: no spec loaded this part; require "EventKit-Coalescing"', messages[0])
        markdown = coverage.render_markdown(rows, True, {"eventKit": 90}, None, messages, part_rows)
        self.assertIn("| `eventKit/Throttle` (part) | 3 | 1 | 75.0% | in `eventKit` |", markdown)

    @unittest.skipIf(shutil.which("busted") is None, "Busted is not installed")
    def test_a_spec_requires_a_part_by_its_file_name(self):
        self.write_parted_repository()
        tests = self.packages / "eventKit" / "tests"
        tests.mkdir()
        (tests / "Part_spec.lua").write_text(
            'describe("a part", function()\n'
            '  it("loads by its file name", function()\n'
            '    assert.are.equal(1, require("EventKit-Coalescing"))\n'
            "  end)\n"
            "end)\n",
            encoding="utf-8",
        )
        manifests = self.manifests()[0]
        environment_path = test_run.build_lua_path(test_run.suite_source_packages("eventKit", manifests), [])

        completed = subprocess.run(
            ["busted", "--lpath", environment_path, str(tests)],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)


class RealRepositoryTests(unittest.TestCase):
    """The real repository keeps the load order the builder always computed for cores."""

    def test_cores_keep_the_package_walk(self):
        # Every release Kit's core, with only the parts a dependency contract
        # names (PanelKit's WidgetKit Renderer). A part that needs another Kit
        # (CommandKit's Options part needs OptionsKit) may move that Kit ahead
        # when the part is selected, so the every-part bundle is checked below
        # for dependency order rather than against the package walk.
        manifests = build.load_valid_manifests()
        release = sorted(build.select_packages(manifests).selected)
        selection = build.select(manifests, packages=release)

        cores = [node.package for node in selection.load_nodes() if node.part is None]

        self.assertEqual(build.load_order(sorted(selection.selected), manifests), cores)

    def test_every_part_bundle_loads_each_core_after_its_dependencies(self):
        manifests = build.load_valid_manifests()
        selection = build.select_packages(manifests)

        loaded: set[str] = set()
        for node in selection.load_nodes():
            if node.part is None:
                for dependency in manifests[node.package].get("dependencies", {}):
                    self.assertIn(dependency, loaded, f"{node.package} loads before {dependency}")
                loaded.add(node.package)


if __name__ == "__main__":
    unittest.main()

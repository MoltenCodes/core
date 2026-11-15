"""Kit parts: the model shared by the validators, the builder and the test tools.

A Kit is a core file plus optional part files (ADR 0001,
``docs/decisions/0001-kit-core-and-parts.md``). An addon embeds a Kit's core
and only the parts it uses. This module holds the rules every tool must agree
on, as pure functions over the parsed manifests, so the builder, the embeds
generator, repository validation, the test runner and coverage can never
disagree about which file a part is or in which order files load.

Vocabulary:

- a **node** is one loadable unit, ``(package, None)`` for a Kit's core and
  ``(package, "Part")`` for one of its parts;
- a **contract** is one entry of a dependency map,
  ``{"api": <n>}`` or ``{"api": <n>, "parts": ["Part", ...]}``; the ``parts``
  list asks for parts of that other Kit;
- a **selector** is how a person names what they want on a command line:
  ``eventKit`` (the core), ``eventKit/Coalescing`` (one part and its core) or
  ``eventKit/*`` (the core and every part).

A part's manifest entry (``docs/PACKAGE_MANIFEST.md``, "Parts")::

    "parts": {
      "Coalescing": {
        "description": "Coalesced and bucketed delivery.",
        "revision": 1,
        "dependencies": {"schedulerKit": {"api": 1}},
        "optionalDependencies": {},
        "parts": ["Throttle"]
      }
    }

Its file is ``src/parts/<Facade>-<Part>.lua``: the facade prefix gives every
part one name across the repository, which is its ``require`` name in specs
and an unambiguous file name in a client error message.

Nothing here reads files or raises on malformed input: malformed entries are
skipped, because `tooling.validation.validate_manifests` reports them.
"""

from __future__ import annotations

import re
from typing import Any, Iterable, NamedTuple

#: A part name: PascalCase, like a facade.
PART_NAME_RE = re.compile(r"^[A-Z][A-Za-z0-9]*$")

#: A package ID, as `validate_manifests.NAME_RE` defines it.
PACKAGE_NAME_RE = re.compile(r"^[a-z][A-Za-z0-9]*$")

#: The directory under a package's ``src/`` that holds its part files.
PARTS_DIRECTORY = "parts"

#: The selector suffix meaning "every part of this Kit".
EVERY_PART = "*"

#: The fields a part entry may carry, and the ones it must.
PART_REQUIRED_FIELDS = frozenset({"description", "revision"})
PART_OPTIONAL_FIELDS = frozenset({"dependencies", "optionalDependencies", "parts"})

ManifestMap = dict[str, dict[str, Any]]


class Node(NamedTuple):
    """One loadable unit: a Kit's core (``part`` is ``None``) or one of its parts."""

    package: str
    part: str | None = None

    @property
    def label(self) -> str:
        """How messages and selectors spell the node: ``eventKit`` or ``eventKit/Coalescing``."""
        return self.package if self.part is None else f"{self.package}/{self.part}"


class Selector(NamedTuple):
    """A parsed command-line selector. ``part`` is ``None``, a part name or ``EVERY_PART``."""

    package: str
    part: str | None


def part_file_name(display_name: str, part: str) -> str:
    """Return a part's file path relative to ``src/``: ``parts/EventKit-Coalescing.lua``."""
    return f"{PARTS_DIRECTORY}/{display_name}-{part}.lua"


def part_entries(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Return a manifest's well-formed part entries, in manifest order."""
    parts = manifest.get("parts", {})
    if not isinstance(parts, dict):
        return {}
    return {
        name: entry
        for name, entry in parts.items()
        if isinstance(name, str) and PART_NAME_RE.fullmatch(name) and isinstance(entry, dict)
    }


def part_names(manifest: dict[str, Any]) -> list[str]:
    """Return a manifest's part names in the order the manifest declares them."""
    return list(part_entries(manifest))


def contract_parts(contract: Any) -> list[str]:
    """Return the well-formed part names one dependency contract asks for, in order."""
    if not isinstance(contract, dict):
        return []
    parts = contract.get("parts", [])
    if not isinstance(parts, list):
        return []
    named: list[str] = []
    for part in parts:
        if isinstance(part, str) and PART_NAME_RE.fullmatch(part) and part not in named:
            named.append(part)
    return named


def required_contracts(holder: dict[str, Any]) -> list[tuple[str, list[str]]]:
    """Return ``(package, parts)`` for each required dependency of a manifest or part entry.

    Sorted by package name, which is the order the load-order walk visits
    them in. Malformed entries are skipped.
    """
    dependencies = holder.get("dependencies", {})
    if not isinstance(dependencies, dict):
        return []
    return [
        (name, contract_parts(contract))
        for name, contract in sorted(dependencies.items())
        if isinstance(name, str) and PACKAGE_NAME_RE.fullmatch(name) and isinstance(contract, dict)
    ]


def optional_contracts(holder: dict[str, Any]) -> list[tuple[str, list[str]]]:
    """Return ``(package, parts)`` for each optional dependency, sorted by package name."""
    dependencies = holder.get("optionalDependencies", {})
    if not isinstance(dependencies, dict):
        return []
    return [
        (name, contract_parts(contract))
        for name, contract in sorted(dependencies.items())
        if isinstance(name, str) and PACKAGE_NAME_RE.fullmatch(name) and isinstance(contract, dict)
    ]


def sibling_parts(entry: dict[str, Any]) -> list[str]:
    """Return the parts of its own Kit a part entry needs, in the order it lists them."""
    return contract_parts({"parts": entry.get("parts", [])})


def node_needs(node: Node, manifests: ManifestMap) -> list[Node]:
    """Return the nodes that must load before ``node``, in the order the walk visits them.

    A core needs each required dependency's core (sorted by package name),
    each followed by the parts its contract names. A part needs its own core
    first, then its required dependencies the same way, then the sibling parts
    it lists. Nodes naming a package or part that does not exist are left
    out; validation reports them.
    """
    manifest = manifests.get(node.package)
    if manifest is None:
        return []

    needs: list[Node] = []
    if node.part is None:
        holder: dict[str, Any] = manifest
    else:
        holder = part_entries(manifest).get(node.part, {})
        needs.append(Node(node.package))

    for package, parts in required_contracts(holder):
        dependency = manifests.get(package)
        if dependency is None:
            continue
        needs.append(Node(package))
        declared = part_entries(dependency)
        needs.extend(Node(package, part) for part in parts if part in declared)

    if node.part is not None:
        declared = part_entries(manifest)
        needs.extend(
            Node(node.package, part) for part in sibling_parts(holder) if part in declared
        )
    return needs


def walk(roots: Iterable[Node], manifests: ManifestMap) -> list[Node]:
    """Return ``roots`` and everything they need, each after what it needs.

    A depth-first walk that visits each root in the order given and each
    node's needs in `node_needs` order, appending a node once all its needs
    are placed. With no parts anywhere this is exactly the package walk the
    builder has always used, so single-file Kits keep their load order.
    A cycle cannot occur in a validated repository; should one slip through,
    the node already being visited is skipped rather than looping forever.
    """
    ordered: list[Node] = []
    placed: set[Node] = set()
    visiting: set[Node] = set()

    def visit(node: Node) -> None:
        if node in placed or node in visiting:
            return
        visiting.add(node)
        for need in node_needs(node, manifests):
            visit(need)
        visiting.discard(node)
        placed.add(node)
        ordered.append(node)

    for root in roots:
        visit(root)
    return ordered


def roots_for(
    packages: Iterable[str], parts: dict[str, list[str]], manifests: ManifestMap
) -> list[Node]:
    """Return the walk's roots for a selection, in the order the walk takes them.

    Selected Kits are taken in sorted order; each core is followed by its
    selected parts in the order the manifest declares them, so a selection
    loads the same way whatever order the person typed it in.
    """
    roots: list[Node] = []
    for package in sorted(set(packages) | set(parts)):
        roots.append(Node(package))
        wanted = set(parts.get(package, []))
        roots.extend(
            Node(package, part)
            for part in part_names(manifests.get(package, {}))
            if part in wanted
        )
    return roots


def parse_selector(text: str) -> Selector | None:
    """Parse ``kit``, ``kit/Part`` or ``kit/*``; return ``None`` when it is neither."""
    package, separator, part = text.strip().partition("/")
    if not PACKAGE_NAME_RE.fullmatch(package):
        return None
    if not separator:
        return Selector(package, None)
    if part == EVERY_PART or PART_NAME_RE.fullmatch(part):
        return Selector(package, part)
    return None


def all_nodes(manifests: ManifestMap, packages: Iterable[str]) -> list[Node]:
    """Return every core and every part of ``packages``, in the order `walk` places them."""
    names = list(packages)
    return walk(
        roots_for(names, {name: part_names(manifests[name]) for name in names}, manifests),
        manifests,
    )


def closure_nodes(node: Node, manifests: ManifestMap) -> list[Node]:
    """Return ``node`` and everything it needs, in load order."""
    return walk([node], manifests)


def optional_closure_packages(node: Node, manifests: ManifestMap) -> list[str]:
    """Return the packages a node's optional dependencies bring onto a test path.

    Each optional dependency's own required closure, dependency-first.
    """
    manifest = manifests.get(node.package, {})
    holder = manifest if node.part is None else part_entries(manifest).get(node.part, {})
    packages: list[str] = []
    for package, parts in optional_contracts(holder):
        if package not in manifests:
            continue
        roots = [Node(package)] + [Node(package, part) for part in parts]
        for need in walk(roots, manifests):
            if need.package not in packages:
                packages.append(need.package)
    return packages

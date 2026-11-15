# 0001. A Kit is a core file plus optional parts

- Status: Accepted
- Date: 2026-11-15

## Context

Every Kit was one file holding every feature, so an addon embedding a Kit
paid for all of it. Measured on Lua 5.1 with debug information kept, as the
game client keeps it, the optional sections a typical addon never runs come
to about 339 KB of resident code: coalesced event and scheduler delivery,
compression, multipart reassembly, the options binding of slash commands,
settings views and spec profiles, the widget renderer and the widget types.
Smaller per-object fixes cannot close the gap to Ace3; only not loading that
code can. The same layout had pushed the largest files against Lua 5.1's
limit of 200 active locals per function.

Embedding was also manual: authors copied a load order of more than forty
lines by hand and the builder wrote no `embeds.xml`.

## Decision

1. A Kit is a **core** file, `src/<Facade>.lua`, plus optional **part** files,
   `src/parts/<Facade>-<Part>.lua`. An addon embeds the core and only the
   parts it uses. Parts ship as separate files; they are not assembled into
   the core at release time.
2. The manifest declares each part under `parts`, with its own `revision` and
   what it needs: other Kits (`dependencies`, `optionalDependencies`) and other
   parts of its Kit (`parts`). Any dependency contract may name parts of the
   Kit it depends on. See `docs/PACKAGE_MANIFEST.md`, "Parts".
3. A part loads after its core and everything it needs. It resolves its core
   through the Registry at file scope, and raises
   `MoltenCodes <Facade> part <Part> requires <Facade> API <n> to be loaded first`
   when the core is missing.
4. A part keeps its state inside its core's state with its own
   `PART_REVISION`. When two addons embed different revisions of a part, the
   highest wins and upgrades in place, as for a Kit.
5. A core feature whose part is not loaded raises at the caller's line with a
   message that names the part to embed.
6. The tools generate what an author used to write by hand: the builder takes
   several Kits and parts and writes `embeds.xml`, and
   `python3 -m tooling.package.embeds` prints it for any selection.

## Consequences

- The tools share one model of parts and one load-order walk
  (`tooling/package/parts.py`). Without parts it is the walk the builder
  always made, so Kits that stay single files load, build and checksum
  exactly as before.
- Validation, the test runner, coverage, the language-server configuration,
  the builder and the embedding guide's footprint tables all understand
  parts (`docs/TOOLING.md`, "Kit parts").
- A single-Kit release contains every part of the Kit, so the release a
  packager publishes and the one the builder writes agree.
- An addon's file list grows by one line per part it uses. The generated
  `embeds.xml` keeps that out of the author's hands.
- Each Kit is split by its own owner, along its existing sections; the
  WidgetKit renderer and widget types come first. apiKit's flavour files
  stay always-loaded core files for now; making them parts is later work.

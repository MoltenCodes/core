# Updating ApiKit to a new client build

ApiKit's surface is generated from the client's own API documentation tables,
so a new client build is a data refresh, not a code change. The whole
procedure is six commands per flavour, deterministic from the mirror commit
down to the last byte; the pipeline is described in
[`docs/TOOLING.md`](../../../docs/TOOLING.md#api-metadata-tooling) and its
design in [`docs/API_KIT_DESIGN.md`](../../../docs/API_KIT_DESIGN.md).

## When

Run the refresh when the community mirror `Gethe/wow-ui-source` publishes a
new export on a flavour's branch (see `tooling/api/flavours.json` for which
branch feeds which flavour). `python3 -m tooling.api.fetch --heads --flavour
<id>` shows each branch's head, build and date; compare the build with
`build` in `metadata/<flavour>/provenance.json`.

## Procedure

Work on a branch, one flavour at a time; each flavour is its own commit.

1. **Keep the build being replaced.** The change report and the history
   entry are computed against it:

   ```bash
   cp -r packages/apiKit/metadata/retail /tmp/apiKit-previous-retail
   ```

2. **Capture.** Downloads the tables at the branch's head (the newest build
   when a flavour names two branches, `ptr` and `ptr2`) into a directory
   outside the repository and records the commit, build and date:

   ```bash
   python3 -m tooling.api.fetch --flavour retail --out ~/wow-api
   ```

   Pin a commit with `--commit <sha>` when reproducing an earlier capture, or
   choose a branch with `--branch`.

3. **Normalise.** Parses every table, applies the naming rules and writes the
   metadata, refusing on any problem:

   ```bash
   python3 -m tooling.api.normalize --capture ~/wow-api/retail/<sha> \
       --out packages/apiKit/metadata/retail
   ```

   Two refusals are expected from time to time and have one-line fixes:

   - *type 'X' is not defined by this flavour or listed in types.json*: the
     tables reference a client type they do not describe. Add it to
     `tooling/api/types.json` with its kind and LuaCATS spelling (see
     `tooling/api/SCHEMA.md`, "Host types"), then normalise again.
   - *wrapper ... would be shared by ...*: two Blizzard names map to one
     wrapper name. Add an entry to `namespaceExceptions` or
     `functionExceptions` in `tooling/api/naming.json`, then normalise again.
     Never resolve a collision by editing generated files.

4. **Generate.** Writes the runtime file, the types, the change report and
   the history entry, and refuses when a generated Lua file does not compile
   or is not formatted:

   ```bash
   python3 -m tooling.api.generate --flavour retail --previous /tmp/apiKit-previous-retail
   ```

   Read the report under `docs/changes/retail/`: removed functions are the
   breaking part of the refresh and belong in the changelog.

5. **Verify.** The suites prove the committed file binds exactly the new
   metadata and that every output matches it:

   ```bash
   python3 -m tooling.api.generate --all --check
   python3 -m unittest discover -s tooling/tests -p "test_*.py"
   python3 -m tooling.test.run apiKit
   python3 -m tooling.validation.validate_repository
   ```

6. **Record and commit.** Add a changelog entry naming the mirror commit,
   client version and build and summarising the report; bump the package
   version (a refresh is at least a minor version, see
   [`RELEASES.md`](../../../docs/RELEASES.md#versioning)); commit the
   metadata, the runtime file, the types, the change report, the history and
   the changelog together.

The Markdown reference and the search index are not committed; the release
workflow builds them from the tagged metadata. To read them locally:

```bash
python3 -m tooling.api.generate --all --reference-out build/reference
```

## Adding a flavour

A new client flavour is one row in `tooling/api/flavours.json` (id,
namespace, runtime file, mirror branches, detection facts), the matching row
in `FLAVORS` of `src/ApiKit.lua` (a spec holds the two together), then the
procedure above for its first capture. Adding a flavour is an API-visible
change of the facade and is recorded in the design document.

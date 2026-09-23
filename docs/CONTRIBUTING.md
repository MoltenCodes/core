# Contributing

## Development principles

Keep changes small, explicit, documented, and testable.

StyLua is the authoritative Lua formatter for this repository. LuaLS formatting is disabled in [`.luarc.json`](../.luarc.json) to avoid competing formatters.

Before submitting a change:

1. Run `python3 -m tooling.validation.validate_repository`.
2. Run `python3 -m unittest discover -s tooling/tests -p "test_*.py"` when tooling changed.
3. Run `python3 -m tooling.test.run`, which covers every package and the example addon.
4. Run `python3 -m tooling.lint`, which covers runtime and test Lua. Both scopes
   must report zero errors and zero warnings.
5. Run `stylua --check .`.
6. Run `python3 -m tooling.spell` when you changed documentation. A word it does
   not know is either a typo to fix or a deliberate term to add to
   [`tooling/spell-words.txt`](../tooling/spell-words.txt) under the rule in
   [`TOOLING.md`](TOOLING.md#adding-a-word).
7. Run `lua-language-server --check packages/<name>/src --checklevel=Warning` for every
   package you touched, and `lua-language-server --check examples --checklevel=Warning`
   when the public surface changed.
8. Run `actionlint` when you changed `.github/workflows/`.
9. Update package documentation when public behavior changes.
10. Update the owning package changelog for user-visible changes.

## LuaCATS annotations

Every public function, method, facade table, class, field, alias and callback
signature in a package's `src/` carries LuaCATS annotations. They are what the
language server, editor autocomplete and the example addon are checked against,
so an unannotated public surface is an incomplete one.

The rules are:

- **Use `---@`, never `--- @`.** `---@param value string`, with no space between
  the comment marker and the tag. This is the canonical form LuaLS documents,
  and the repository uses exactly one form so a grep for a tag finds every use
  of it. Descriptions follow the same shape: `---Returns the ...`, not
  `--- Returns the ...`.
- **Name types `<Facade>` and `<Facade>.<Type>`.** The facade class is named
  after the Lua facade (`SignalKit`, `TimerKit`), and everything it owns is
  nested under it (`SignalKit.Connection`, `TimerKit.Scope`,
  `ModuleKit.DependencyPolicy`). Registry is the infrastructure exception in
  name only: its types are `Registry` and `Registry.PackageInfo`.
- **Declare classes in one place, not on the prototype local.** Packages publish
  methods by writing them onto Registry-owned prototype tables, so each file
  declares its `---@class` blocks in a "Public types" section near the top and
  leaves the `local Instance = rawget(...)` lines unannotated. Attaching a class
  with `@field` entries to a table literal makes the language server demand that
  the literal already contain those fields.
- **Prefer an `---@alias` to a repeated inline `fun(...)`.** A callback shape
  that appears in more than one signature gets a name
  (`EventKit.Listener`, `TimerKit.Callback`, `SchedulerKit.Callback`).
- **Name a return value when it is not obvious from the type.**
  `---@return boolean cancelled` reads better than `---@return boolean`.
- **Document the stack level.** Validation helpers take a `level` argument that
  decides which line an argument error points at; annotate it and say what it
  means.

Annotations never change executed code. A change that only adds or reformats
them is a `version` bump and a changelog line, never a `revision` bump; see
[`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md).

### Type-checking a package

`lua-language-server --check <dir>` treats `<dir>` as its workspace root and does
**not** look in parent directories for configuration. Every package source
directory therefore owns a `.luarc.json` that points at the shared
[`meta/`](../meta/) definitions and at the source directories of that package's
runtime dependencies. `examples/` owns one too.

Those files are generated from the manifests conceptually and checked against
them literally: `tooling.validation.validate_repository` fails when a package's
`.luarc.json` does not list exactly `meta/` plus its dependency closure. Adding a
dependency means updating that file in the same change.

The World of Warcraft API the Kits touch is declared in [`meta/wow/`](../meta/wow/).
A Kit that starts calling a new client API adds it there rather than silencing
the diagnostic.

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for local setup.

## Taint and secret values

Code that runs inside the client follows the taint rules in
[`EMBEDDING.md`](EMBEDDING.md#rules-for-taint-safe-addon-code). Before submitting
runtime Lua, check it against this list:

- [ ] No assignment over a Blizzard global, method or script handler; hooks are
      post-hooks.
- [ ] No field or table of ours is attached to a frame Blizzard code indexes;
      per-frame state lives in a table of our own, keyed by the frame.
- [ ] A key tainted by mistake is set to `nil`, not overwritten.
- [ ] Shared state is repaired only after `issecurevariable` says it is not
      secure.
- [ ] User intent is recorded at once; anything that touches protected frames is
      applied out of combat.
- [ ] A recycled region is cleared of secret values before it is reused.
- [ ] No value the Kit did not create is compared, tested as a boolean, used
      in arithmetic, measured with `#`, indexed, called or used as a table key
      without `issecretvalue` first (see
      [Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values)).
- [ ] New error messages describe a value that may be secret with a fixed
      placeholder rather than formatting it in, because a message built from a
      secret is itself secret. Existing Kits adopt this with `clientKit`'s
      `IsSecret`; see [`EMBEDDING.md`](EMBEDDING.md#rules-for-taint-safe-addon-code).
- [ ] A frame found by enumeration is touched only after `IsForbidden` and
      `CanBeAccessedInContext` allow it.

## Releases

Releases are cut by a maintainer following the procedure in
[`RELEASES.md`](RELEASES.md#release-procedure). A contribution bumps the
`version` of the packages it changes and updates their changelogs; it does not
add a release section or a tag.

## Commit scope

Prefer commits that represent one coherent change.

Do not mix unrelated package changes without a reason.

## Public API changes

Public API changes require:

- documentation;
- tests;
- changelog entry;
- explicit API-generation consideration.

A breaking public contract must not be hidden behind an implementation revision.

## New packages

New packages must satisfy the package layout and manifest contract in [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md), which includes a `src/.luarc.json` and, for a package consumers embed, a line in [`.pkgmeta`](../.pkgmeta) and an "Embedding" section in its README.

Public framework capability packages use a lowerCamelCase `Kit` package ID and matching PascalCase Lua facade/module name (for example `eventKit` / `EventKit`). `registry` / `Registry` is the infrastructure exception.

Repository tooling should discover a new package automatically. Avoid adding package names directly to CI or editor configuration.

## Documentation language

Repository and package documentation is written in English.

# Example addon

A complete, runnable World of Warcraft addon that embeds the MoltenCodes
framework. It exists so that the instructions in
[`../docs/EMBEDDING.md`](../docs/EMBEDDING.md) are demonstrably true rather than
merely written down.

```text
examples/
├── ExampleAddon.toc   # the addon manifest, including the load order
├── embeds.xml         # the embedded framework packages, in dependency order
├── Core.lua           # the addon itself
└── tests/             # a Busted spec that loads all of the above
```

## Running it in a client

Copy this directory to `Interface/AddOns/ExampleAddon/`, then copy the framework
files into `ExampleAddon/Libs/MoltenCodes/` in the layout `embeds.xml` expects.
`python3 -m tooling.package.build --all --out <dir>` produces that layout; see
[`../docs/RELEASES.md`](../docs/RELEASES.md).

`tests/` and `.luarc.json` are development files. Leave them behind.

## Why it cannot rot

`tests/ExampleAddon_spec.lua` reads the load order out of `embeds.xml`, loads
each listed package from its real package source, and then runs `Core.lua` the
way the client does — with the addon name and the addon's private table as the
file's `...` vararg. It then drives `ADDON_LOADED`, `PLAYER_LOGIN`, the events
the addon subscribes to, and `PLAYER_LOGOUT` through stubbed client APIs, and
asserts that the module was enabled, the callbacks ran, and everything was
released again.

Run it with the repository's Lua 5.1 toolchain:

```bash
busted examples/tests
```

`python3 -m unittest discover -s tooling/tests -p "test_*.py"` runs the same spec
and additionally checks that the `.toc`, `embeds.xml` and the package manifests
still agree about the load order.

`lua-language-server --check examples --checklevel=Warning` type-checks the
example against the framework's own LuaCATS annotations, so a change that breaks
a published signature breaks the example too.

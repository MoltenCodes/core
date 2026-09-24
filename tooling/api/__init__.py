"""Tooling for `apiKit`, the flavour-aware wrapper over the World of Warcraft API.

Everything under this package runs at development time: it reads the client's
own API documentation tables from the community mirror, normalises them into
the package's metadata and generates the runtime bindings, the LuaCATS
definitions and the reference from that metadata. Nothing here is a runtime
dependency of any Kit. The design is `docs/API_KIT_DESIGN.md`; the delivery
plan is package H in `docs/ROADMAP.md`.

The modules, in pipeline order:

- `flavours`: the table of supported flavours, their mirror branches and the
  facts that detect them;
- `fetch`: downloads one flavour's documentation tables at a pinned mirror
  commit into a directory outside the repository;
- `lua_tables`: parses those tables (Lua table constructors) into Python;
- `naming`: the rules that turn a Blizzard name into a wrapper name, with the
  reviewed words, aliases and exceptions in `naming.json`;
- `model`: the metadata model and its JSON form (`SCHEMA.md`), plus the host
  type table `types.json`;
- `normalize`: turns a capture into a flavour's metadata directory;
- `validate`: the checks a metadata directory must pass.

The generators (roadmap step H2) follow.
"""

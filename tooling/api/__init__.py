"""Tooling for `apiKit`, the flavour-aware wrapper over the World of Warcraft API.

Everything under this package runs at development time: it reads the client's
own API documentation tables from the community mirror, normalises them into
the package's metadata and generates the runtime bindings, the LuaCATS
definitions and the reference from that metadata. Nothing here is a runtime
dependency of any Kit. The design is `docs/API_KIT_DESIGN.md`; the delivery
plan is package H in `docs/ROADMAP.md`.

Modules arrive step by step with that plan. `flavours` (the table of supported
flavours and how each is sourced and detected) is the first.
"""

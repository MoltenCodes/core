"""Recorders of test fixtures produced by third-party libraries.

A fixture here is the output of a library MoltenCodes interoperates with, run
on host Lua 5.1 over the project's own inputs, so a spec can hold a Kit to the
real library's behaviour without the library's source ever entering the
repository. `ace_serializer` records AceSerializer-3.0 for bridgeKit
(`docs/BRIDGE_KIT_DESIGN.md`, sections 3.2 and 13.1); the Lua that drives the
library lives under `lua/`.
"""

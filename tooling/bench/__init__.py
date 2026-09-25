"""Host benchmark runner: MoltenCodes Kits against the Ace3 libraries doing the same work.

The runner is development tooling, never a runtime dependency. It fetches Ace3
at a pinned commit into a cache outside the repository (`ace3`), runs each Lua
workload under `lua/` in a fresh host Lua 5.1 process per case and per side
(`run`), and renders the raw JSON it collects as Markdown (`report`). The
methodology, the workloads and the in-client plan are in `docs/BENCHMARKS.md`.
"""

"""Benchmark runners: MoltenCodes Kits against the Ace3 libraries doing the same work.

The runners are development tooling, never a runtime dependency. The host
runner fetches Ace3 at a pinned commit into a cache outside the repository
(`ace3`), runs each Lua workload under `lua/` in a fresh host Lua 5.1 process
per case and per side (`run`), and renders the raw JSON it collects as Markdown
(`report`). The in-client runner installs a harness addon and one
load-on-demand addon per side into a game folder (`client_install`, with the
catalogue in `client_workloads` and the Lua under `client/`), and reads what the
harness saved back into a client results file (`client_report`). The
methodology, the workloads and both runners are in `docs/BENCHMARKS.md`.
"""

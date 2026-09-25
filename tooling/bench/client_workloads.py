"""The in-client benchmark catalogue: which workloads run inside the game client.

The host runner (`tooling/bench/run.py`) measures every workload of
`tooling/bench/workloads.py` on host Lua 5.1 and the shared fake client. The
in-client runner (`docs/BENCHMARKS.md`, "In-client runner") runs inside World
of Warcraft through the `MoltenCodesBench` addons and measures two groups:

* **Shared workloads**: the host workloads whose cases need nothing beyond
  the host interface the client can give them (`RequireAll`, `Global`,
  `LoadFiles`, `EventHandler`, `TakeReportedErrors` and the fake client's
  `Emit`, which the client host delivers to the side's own frames). The same
  Lua module runs, only the host differs, so a client row and a host row of
  the same case measure the same calls.
* **Client-only workloads**: measurements the host cannot make at all (frame
  time under load, memory over a session, real windows, native calls, a real
  throttled whisper) and the frame-driven replacements of the host cases that
  run on a simulated clock.

A host workload that needs the fake client's internals (the simulated clock,
the recording chat outbox, the counting chat frame, fake addon-loaded state,
its own `UIParent`) is listed in `NOT_IN_CLIENT` with the reason and what
measures it in the client instead. `tooling/tests/test_bench_client.py` holds
the three lists to the host catalogue and to the Lua files.

The installer (`tooling.bench.client_install`) writes this catalogue into the
harness addon, so the slash command and the report tool read one list.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from tooling.bench.workloads import BY_NAME as HOST_WORKLOADS
from tooling.bench.workloads import LUA_ROOT as HOST_LUA_ROOT

#: The client runner's own Lua modules (measurement, host, client-only workloads).
CLIENT_LUA_ROOT = Path(__file__).resolve().parent / "client" / "lua"

#: The harness addon's committed files (`.toc`, loader, slash command).
HARNESS_SOURCE = Path(__file__).resolve().parent / "client" / "MoltenCodesBench"


@dataclass(frozen=True)
class ClientWorkload:
    """One workload the in-client runner offers."""

    name: str
    module: str
    title: str
    compares: str
    #: `"shared"` for a host workload module run unchanged, `"client"` for a client-only one.
    origin: str

    @property
    def lua_file(self) -> Path:
        """The workload's Lua source file, in the host tree or the client tree."""
        root = HOST_LUA_ROOT if self.origin == "shared" else CLIENT_LUA_ROOT
        return root / (self.module.replace(".", "/") + ".lua")


def _shared(name: str) -> ClientWorkload:
    """A host workload run unchanged in the client, titled as the host report titles it."""
    host = HOST_WORKLOADS[name]
    return ClientWorkload(name, host.module, host.title, host.compares, "shared")


#: Host workloads the client runs unchanged, in the host catalogue's order.
SHARED_IN_CLIENT: tuple[str, ...] = (
    "eventDispatch",
    "messageDispatch",
    "settings",
    "codec",
    "libraryRegistry",
    "hooks",
    "slashCommands",
    "locale",
)

#: Host workloads the client does not run, with the reason and the replacement.
NOT_IN_CLIENT: dict[str, str] = {
    "timers": (
        "every case advances the simulated clock; the client-only timersLive workload "
        "measures real timers across frames instead"
    ),
    "comm": (
        "sends into the fake client's recording outbox and advances the simulated clock; "
        "the client-only whisper workload sends a real throttled whisper to the player"
    ),
    "buckets": (
        "delivery waits for the simulated clock; bucketing is left to the host numbers, "
        "and the timers it rests on are measured by timersLive"
    ),
    "addonModules": (
        "drives fake addons through the fake client's addon-loaded state, which a real "
        "client cannot fake without lying to LifecycleKit and AceAddon"
    ),
    "options": (
        "counts lines on the fake client's chat frame; in the client every typed command "
        "would print to the real chat frame thousands of times per batch"
    ),
    "widgets": (
        "creates its own UIParent for the fake client, which would replace the real one; "
        "the client-only window workload measures real windows instead"
    ),
}

#: Measurements only the client can make, in the order `/mcb list` shows them.
CLIENT_ONLY: tuple[ClientWorkload, ...] = (
    ClientWorkload(
        name="nativeCalls",
        module="clientWorkloads.NativeCalls",
        title="Native calls (client only)",
        compares=(
            "issecretvalue and securecallfunction as native calls, with an empty Lua call and "
            "pcall for scale; both sides run the same calls, so their ratio is the noise floor"
        ),
        origin="client",
    ),
    ClientWorkload(
        name="window",
        module="clientWorkloads.Window",
        title="Windows open and close (client only)",
        compares="WidgetKit windows against AceGUI-3.0 Frame windows holding the same 25 widgets",
        origin="client",
    ),
    ClientWorkload(
        name="timersLive",
        module="clientWorkloads.TimersLive",
        title="Timers on the client's clock (client only)",
        compares="TimerKit against AceTimer-3.0, firing on real frames",
        origin="client",
    ),
    ClientWorkload(
        name="whisper",
        module="clientWorkloads.Whisper",
        title="Whisper to self through the real throttle (client only)",
        compares="CommKit against AceComm-3.0 (with ChatThrottleLib), both at their default rates",
        origin="client",
    ),
    ClientWorkload(
        name="session",
        module="clientWorkloads.Session",
        title="Frame time and memory under a synthetic load (client only)",
        compares=(
            "EventKit, SignalKit, TimerKit, CommKit and WidgetKit against AceEvent-3.0, "
            "AceTimer-3.0, AceComm-3.0 and AceGUI-3.0 doing the same work every frame"
        ),
        origin="client",
    ),
)

#: Every workload the in-client runner offers: the shared ones, then the client-only ones.
CLIENT_WORKLOADS: tuple[ClientWorkload, ...] = (
    *(_shared(name) for name in SHARED_IN_CLIENT),
    *CLIENT_ONLY,
)

#: Client workloads by name.
BY_NAME: dict[str, ClientWorkload] = {workload.name: workload for workload in CLIENT_WORKLOADS}

#: The client runner's own modules besides the workloads: installed into the
#: harness with the workloads and required by name.
CLIENT_SUPPORT_MODULES: tuple[str, ...] = (
    "ClientBench",
    "ClientHost",
    "clientWorkloads.Adapters",
    "clientWorkloads.FrameStats",
)

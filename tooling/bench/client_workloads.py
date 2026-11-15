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
    #: `False` for a workload that loads one of the side's sets itself and
    #: measures that load (`login`, `savedVariables`); the harness then does
    #: not load the side before it.
    loads_side: bool = True

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
    "aceSerializer",
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

#: Workloads that load a set of a side themselves (`loads_side = False`).
SET_WORKLOADS: tuple[ClientWorkload, ...] = (
    ClientWorkload(
        name="login",
        module="clientWorkloads.Login",
        title="Loading each side as an addon (client only)",
        compares=(
            "the load time and held memory of three Kit sets against the Ace3 libraries "
            "that do the same work: the event-and-timer minimum, a typical addon, everything"
        ),
        origin="client",
        loads_side=False,
    ),
    ClientWorkload(
        name="savedVariables",
        module="clientWorkloads.SavedVariables",
        title="Opening a database restored from disk (client only)",
        compares=(
            "SettingsKit against AceDB-3.0 opening 1 and 20 profiles of 200 keys that the "
            "client restored at the next session"
        ),
        origin="client",
        loads_side=False,
    ),
)

CLIENT_ONLY = (*CLIENT_ONLY, *SET_WORKLOADS)


@dataclass(frozen=True)
class SideSet:
    """One set of a side's libraries, installed as a load-on-demand addon of its own.

    `kits` names the Kit cores the set selects (the builder adds what they
    require, no parts); `None` is the whole release bundle. `ace3` lists the
    pinned Ace3 files, relative to the Ace3 root, in load order.
    """

    name: str
    kits: tuple[str, ...] | None
    ace3: tuple[str, ...]
    #: The saved variable the set's addons declare, by side, or empty.
    saved_variables: tuple[tuple[str, str], ...] = ()


#: LibStub and CallbackHandler, which every Ace3 set loads first.
_ACE3_BASE = ("LibStub/LibStub.lua", "CallbackHandler-1.0/CallbackHandler-1.0.lua")

#: The sets the `login` and `savedVariables` workloads load, by name.
SIDE_SETS: tuple[SideSet, ...] = (
    SideSet(
        "minimum",
        ("registry", "signalKit", "eventKit", "lifecycleKit", "timerKit"),
        (
            *_ACE3_BASE,
            "AceAddon-3.0/AceAddon-3.0.lua",
            "AceEvent-3.0/AceEvent-3.0.lua",
            "AceTimer-3.0/AceTimer-3.0.lua",
        ),
    ),
    SideSet(
        "typical",
        ("addonKit",),
        (
            *_ACE3_BASE,
            "AceAddon-3.0/AceAddon-3.0.lua",
            "AceEvent-3.0/AceEvent-3.0.lua",
            "AceTimer-3.0/AceTimer-3.0.lua",
            "AceDB-3.0/AceDB-3.0.lua",
            "AceConsole-3.0/AceConsole-3.0.lua",
            "AceLocale-3.0/AceLocale-3.0.lua",
        ),
    ),
    SideSet("full", None, ()),
    SideSet(
        "saved",
        ("settingsKit",),
        (*_ACE3_BASE, "AceDB-3.0/AceDB-3.0.lua"),
        (("moltencodes", "MoltenCodesBenchKitsSavedDB"), ("ace3", "MoltenCodesBenchAce3SavedDB")),
    ),
)

#: The case names of every client-only workload, as the Lua modules define
#: them (`tooling/tests/test_bench_client.py` holds the two together).
CLIENT_CASES: dict[str, tuple[str, ...]] = {
    "nativeCalls": (),
    "window": ("open-close", "open-close-drawn"),
    "timersLive": ("oneshot-create-cancel", "oneshot-fire-1000", "repeat-200"),
    "whisper": (),
    "session": ("idle-30s", "load-60s", "memory-300s"),
    "login": ("minimum", "typical", "full"),
    "savedVariables": ("write-1x200", "read-1x200", "write-20x200", "read-20x200"),
}

#: The smoke profile: one headline case per shared workload and the cases
#: that matter most of the client-only ones, 13 cases, 26 sessions with both
#: sides. A run short enough to do in one sitting.
SMOKE_PROFILE: tuple[tuple[str, str], ...] = (
    ("eventDispatch", "dispatch-10"),
    ("messageDispatch", "dispatch-10"),
    ("settings", "read-saved"),
    ("codec", "encode-medium"),
    ("libraryRegistry", "lookup"),
    ("hooks", "call-posthooked-method"),
    ("slashCommands", "dispatch-words"),
    ("locale", "lookup"),
    ("aceSerializer", "decode-medium"),
    ("window", "open-close-drawn"),
    ("timersLive", "oneshot-fire-1000"),
    ("session", "load-60s"),
    ("session", "memory-300s"),
)

#: Seconds a case is expected to run, for the planner's estimate: a frame
#: case runs for its own length, a batch case about this long.
BATCH_CASE_SECONDS = 10
CASE_SECONDS: dict[tuple[str, str], int] = {
    ("session", "idle-30s"): 30,
    ("session", "load-60s"): 60,
    ("session", "memory-300s"): 300,
    ("timersLive", "repeat-200"): 10,
    ("login", "minimum"): 2,
    ("login", "typical"): 2,
    ("login", "full"): 2,
}

#: Reloads assumed per item by default: an item is one UI session.
DEFAULT_RELOAD_SECONDS = 20


def all_profile(host_cases: dict[str, tuple[str, ...]]) -> tuple[tuple[str, str], ...]:
    """Every case of every workload the client runs: the shared ones from `host_cases`."""
    entries: list[tuple[str, str]] = []
    for name in SHARED_IN_CLIENT:
        entries.extend((name, case) for case in host_cases.get(name, ()))
    for workload in CLIENT_ONLY:
        entries.extend((workload.name, case) for case in CLIENT_CASES.get(workload.name, ()))
    return tuple(entries)


@dataclass(frozen=True)
class Plan:
    """What a profile run costs before it is installed."""

    profile: str
    cases: int
    rounds: int
    items: int
    reloads: int
    seconds: int

    def describe(self) -> str:
        """The planner's output line."""
        minutes = (self.seconds + 59) // 60
        return (
            f"{self.profile}: {self.cases} cases x 2 sides x {self.rounds} round(s) = "
            f"{self.items} sessions, {self.reloads} reloads, about {minutes} min"
        )


def plan(
    profile: str,
    entries: tuple[tuple[str, str], ...],
    rounds: int = 1,
    reload_seconds: int = DEFAULT_RELOAD_SECONDS,
) -> Plan:
    """Count a profile's sessions and estimate its length (`reload_seconds` is an assumption)."""
    items = len(entries) * 2 * rounds
    case_seconds = sum(CASE_SECONDS.get(entry, BATCH_CASE_SECONDS) for entry in entries) * 2 * rounds
    return Plan(profile, len(entries), rounds, items, items, case_seconds + items * reload_seconds)


#: Every workload the in-client runner offers: the shared ones, then the client-only ones.
CLIENT_WORKLOADS: tuple[ClientWorkload, ...] = (
    *(_shared(name) for name in SHARED_IN_CLIENT),
    *CLIENT_ONLY,
)

#: Client workloads by name.
BY_NAME: dict[str, ClientWorkload] = {workload.name: workload for workload in CLIENT_WORKLOADS}


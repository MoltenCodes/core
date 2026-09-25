"""The benchmark workloads: what each compares, and which Kits it measures.

Each workload is a Lua module under `tooling/bench/lua/workloads/` that the
Lua entry point (`lua/main.lua`) names in its `WORKLOADS` table; the unit tests
hold the two lists equal. This table adds what the Python side needs: the
report title, the one-line statement of what is compared, and the packages
whose manifest versions are recorded with the results.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

LUA_ROOT = Path(__file__).resolve().parent / "lua"


@dataclass(frozen=True)
class Workload:
    """One workload: a Lua module and what it compares."""

    name: str
    module: str
    title: str
    compares: str
    packages: tuple[str, ...]

    @property
    def lua_file(self) -> Path:
        """The workload's Lua source file."""
        return LUA_ROOT / (self.module.replace(".", "/") + ".lua")


WORKLOADS: tuple[Workload, ...] = (
    Workload(
        name="eventDispatch",
        module="workloads.EventDispatch",
        title="Game-event dispatch",
        compares="EventKit (on SignalKit) against AceEvent-3.0 events (on CallbackHandler-1.0)",
        packages=("registry", "signalKit", "eventKit"),
    ),
    Workload(
        name="messageDispatch",
        module="workloads.MessageDispatch",
        title="Addon-message dispatch",
        compares="a SignalKit bus against AceEvent-3.0 messages (on CallbackHandler-1.0)",
        packages=("registry", "signalKit"),
    ),
    Workload(
        name="timers",
        module="workloads.Timers",
        title="Timers on a simulated clock",
        compares="TimerKit against AceTimer-3.0",
        packages=("registry", "timerKit"),
    ),
    Workload(
        name="settings",
        module="workloads.Settings",
        title="Saved settings and profiles",
        compares="SettingsKit (with SchemaKit) against AceDB-3.0",
        packages=("registry", "signalKit", "eventKit", "schemaKit", "settingsKit"),
    ),
    Workload(
        name="codec",
        module="workloads.Codec",
        title="Serialisation, compression off",
        compares="CodecKit (addon channel) against AceSerializer-3.0",
        packages=("registry", "poolKit", "codecKit"),
    ),
    Workload(
        name="comm",
        module="workloads.Comm",
        title="Multipart addon messages",
        compares="CommKit against AceComm-3.0 (with ChatThrottleLib)",
        packages=(
            "registry",
            "signalKit",
            "eventKit",
            "timerKit",
            "schedulerKit",
            "poolKit",
            "commKit",
        ),
    ),
)

#: Workloads by name.
BY_NAME: dict[str, Workload] = {workload.name: workload for workload in WORKLOADS}

#: The two sides, in the order they run and are reported.
SIDES: tuple[str, ...] = ("moltencodes", "ace3")

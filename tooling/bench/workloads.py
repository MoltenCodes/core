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
    Workload(
        name="libraryRegistry",
        module="workloads.LibraryRegistry",
        title="Library registration and lookup",
        compares="Registry (and InteropKit's LibStub bridge) against LibStub",
        packages=("registry", "interopKit"),
    ),
    Workload(
        name="addonModules",
        module="workloads.AddonModules",
        title="Addons, modules and their lifecycle",
        compares="ModuleKit with LifecycleKit against AceAddon-3.0",
        packages=("registry", "signalKit", "eventKit", "lifecycleKit", "moduleKit"),
    ),
    Workload(
        name="hooks",
        module="workloads.Hooks",
        title="Function, method and script hooks",
        compares="HookKit against AceHook-3.0",
        packages=("registry", "hookKit"),
    ),
    Workload(
        name="slashCommands",
        module="workloads.SlashCommands",
        title="Slash commands and argument parsing",
        compares="CommandKit against AceConsole-3.0",
        packages=("registry", "schemaKit", "commandKit"),
    ),
    Workload(
        name="locale",
        module="workloads.Locale",
        title="Translations",
        compares="LocaleKit against AceLocale-3.0",
        packages=("registry", "localeKit"),
    ),
    Workload(
        name="buckets",
        module="workloads.Buckets",
        title="Event bucketing",
        compares="SchedulerKit coalescing against AceBucket-3.0",
        packages=("registry", "signalKit", "eventKit", "timerKit", "schedulerKit"),
    ),
    Workload(
        name="options",
        module="workloads.Options",
        title="Options tables",
        compares=(
            "OptionsKit (with CommandKit's command line and SettingsKit's profiles) against "
            "AceConfigRegistry-3.0, AceConfigCmd-3.0 and AceDBOptions-3.0 (with AceDB-3.0)"
        ),
        packages=(
            "registry",
            "signalKit",
            "eventKit",
            "schemaKit",
            "settingsKit",
            "optionsKit",
            "commandKit",
        ),
    ),
    Workload(
        name="widgets",
        module="workloads.Widgets",
        title="Widgets on the fake client (indicative)",
        compares="WidgetKit against AceGUI-3.0 on the shared fake client",
        packages=("registry", "poolKit", "signalKit", "widgetKit"),
    ),
)

#: Workloads by name.
BY_NAME: dict[str, Workload] = {workload.name: workload for workload in WORKLOADS}

#: The two sides, in the order they run and are reported.
SIDES: tuple[str, ...] = ("moltencodes", "ace3")

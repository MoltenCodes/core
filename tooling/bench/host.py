"""Describe the machine and the code a benchmark ran on.

Timing numbers mean nothing without the machine, the interpreter and the exact
code that produced them, so the runner records all three with every result:

- the host: CPU model (`sysctl` on macOS, `lscpu` or `/proc/cpuinfo` on
  Linux), logical CPU count, memory, operating system and architecture;
- the Lua interpreter: its path and the version line it prints;
- the MoltenCodes side: the repository commit, whether `packages/` differed
  from it when the run started, and each measured package's manifest version.

Every probe is best-effort: a probe that fails records `null` rather than
failing the run, because a missing CPU name must not cost a benchmark run.
Every command here only reads (`git rev-parse`, `git status`).
"""

from __future__ import annotations

import json
import os
import platform
import subprocess
from pathlib import Path
from typing import Callable, Sequence

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ROOT / "packages"

#: Runs a command and returns its standard output, or `None` when it failed.
CommandRunner = Callable[[Sequence[str]], "str | None"]


def run_command(command: Sequence[str]) -> str | None:
    """Run `command` and return its stripped standard output, or `None` on failure."""
    try:
        result = subprocess.run(
            list(command), cwd=ROOT, capture_output=True, text=True, check=False, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def parse_lscpu_model(output: str) -> str | None:
    """Return the `Model name:` value from `lscpu` output."""
    for line in output.splitlines():
        key, _, value = line.partition(":")
        if key.strip() == "Model name" and value.strip():
            return value.strip()
    return None


def parse_cpuinfo_model(text: str) -> str | None:
    """Return the first `model name` value from `/proc/cpuinfo`."""
    for line in text.splitlines():
        key, _, value = line.partition(":")
        if key.strip() == "model name" and value.strip():
            return value.strip()
    return None


def cpu_model(system: str, runner: CommandRunner = run_command) -> str | None:
    """The CPU model name on macOS or Linux, or `None` when it cannot be read."""
    if system == "Darwin":
        return runner(["sysctl", "-n", "machdep.cpu.brand_string"])
    if system == "Linux":
        output = runner(["lscpu"])
        model = parse_lscpu_model(output) if output else None
        if model is None:
            try:
                model = parse_cpuinfo_model(Path("/proc/cpuinfo").read_text(encoding="utf-8"))
            except OSError:
                model = None
        return model
    return None


def memory_bytes(system: str, runner: CommandRunner = run_command) -> int | None:
    """Physical memory in bytes on macOS or Linux, or `None`."""
    if system == "Darwin":
        output = runner(["sysctl", "-n", "hw.memsize"])
        return int(output) if output and output.isdigit() else None
    if system == "Linux":
        try:
            for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024
        except (OSError, ValueError, IndexError):
            return None
    return None


def operating_system(system: str, runner: CommandRunner = run_command) -> str:
    """A readable operating-system name and version."""
    if system == "Darwin":
        name = runner(["sw_vers", "-productName"]) or "macOS"
        version = runner(["sw_vers", "-productVersion"]) or platform.mac_ver()[0]
        build = runner(["sw_vers", "-buildVersion"])
        return f"{name} {version}" + (f" ({build})" if build else "")
    if system == "Linux":
        try:
            release = platform.freedesktop_os_release()
            return release.get("PRETTY_NAME", "Linux") + f" (kernel {platform.release()})"
        except OSError:
            return f"Linux {platform.release()}"
    return f"{system} {platform.release()}"


def load_average() -> list[float] | None:
    """The 1, 5 and 15 minute load averages, or `None` where the OS has none.

    Recorded at the start and the end of a run: CPU time per operation grows
    when other processes compete for the fast cores, so a reader needs to know
    how busy the machine was.
    """
    try:
        return [round(value, 2) for value in os.getloadavg()]
    except (AttributeError, OSError):
        return None


def describe_host(runner: CommandRunner = run_command) -> dict[str, object]:
    """The machine: CPU, core count, memory, operating system, architecture, Python."""
    system = platform.system()
    return {
        "cpu": cpu_model(system, runner),
        "logicalCpus": os.cpu_count(),
        "memoryBytes": memory_bytes(system, runner),
        "os": operating_system(system, runner),
        "architecture": platform.machine(),
        "python": platform.python_version(),
    }


def describe_repository(
    packages: Sequence[str], runner: CommandRunner = run_command
) -> dict[str, object]:
    """The MoltenCodes side: commit, whether `packages/` has local changes, versions."""
    commit = runner(["git", "rev-parse", "HEAD"])
    status = runner(["git", "status", "--porcelain", "--", "packages"])
    versions: dict[str, str | None] = {}
    for name in packages:
        try:
            manifest = json.loads(
                (PACKAGES / name / "package.manifest.json").read_text(encoding="utf-8")
            )
            versions[name] = manifest.get("version")
        except (OSError, ValueError):
            versions[name] = None
    return {
        "commit": commit,
        "packagesModified": None if status is None else bool(status),
        "packageVersions": versions,
    }

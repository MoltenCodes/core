"""The supported World of Warcraft clients, read from one machine-readable table.

`supported_clients.json` beside this file is the single source of truth for the
`## Interface` numbers the framework supports. Every document, the example addon
and the registry's `.toc` example quote those numbers, and
`validate_repository` fails when any of them disagrees with the table. A
maintainer bumping the numbers on patch day edits the table, then copies what
this command prints:

    python3 -m tooling.validation.interface_numbers            # the .toc line
    python3 -m tooling.validation.interface_numbers --table    # EMBEDDING.md rows

See `docs/TOOLING.md` for the procedure and `docs/RELEASES.md` for where it sits
in a release.
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


#: Default location of the table, next to this module.
SUPPORTED_CLIENTS_PATH = Path(__file__).resolve().parent / "supported_clients.json"

#: The keys every client entry carries, and nothing else.
CLIENT_KEYS = {"flavour", "interface", "patch", "tocSuffix", "promised"}

#: The keys the table itself carries, and nothing else.
TABLE_KEYS = {"verified", "source", "clients"}


class SupportedClientsError(ValueError):
    """The table exists but does not have the shape this module documents."""


@dataclass(frozen=True)
class SupportedClient:
    """One client flavour the framework supports.

    `promised` separates the flavours a change is considered against (Retail,
    the current Classic progression client, Classic Era) from flavours the
    framework lists because it does not exclude them.
    """

    flavour: str
    interface: int
    patch: str
    toc_suffix: str
    promised: bool


@dataclass(frozen=True)
class SupportedClients:
    """The whole table: when it was last checked, against what, and its rows."""

    verified: str
    source: str
    clients: tuple[SupportedClient, ...]

    def interface_numbers(self) -> list[int]:
        """The Interface numbers in table order, which is newest client first."""
        return [client.interface for client in self.clients]

    def toc_line(self) -> str:
        """The `## Interface` line a `.toc` supporting every listed client carries."""
        return "## Interface: " + ", ".join(str(number) for number in self.interface_numbers())

    def markdown_rows(self) -> list[str]:
        """The rows of the table in `docs/EMBEDDING.md`, in the order it lists them."""
        return [
            f"| {client.flavour} | `{client.interface}` | {client.patch} | `{client.toc_suffix}` |"
            for client in self.clients
        ]


def _is_positive_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _parse_client(index: int, entry: Any) -> SupportedClient:
    """Validate and convert one entry of the `clients` array."""
    where = f"clients[{index}]"
    if not isinstance(entry, dict):
        raise SupportedClientsError(f"{where} must be an object")
    if set(entry) != CLIENT_KEYS:
        raise SupportedClientsError(f"{where} must have exactly the keys {sorted(CLIENT_KEYS)}")
    if not _is_positive_integer(entry["interface"]):
        raise SupportedClientsError(f"{where}.interface must be a positive integer")
    for key in ("flavour", "patch", "tocSuffix"):
        if not isinstance(entry[key], str) or not entry[key]:
            raise SupportedClientsError(f"{where}.{key} must be a non-empty string")
    if not isinstance(entry["promised"], bool):
        raise SupportedClientsError(f"{where}.promised must be true or false")

    return SupportedClient(
        flavour=entry["flavour"],
        interface=entry["interface"],
        patch=entry["patch"],
        toc_suffix=entry["tocSuffix"],
        promised=entry["promised"],
    )


def parse_supported_clients(data: Any) -> SupportedClients:
    """Validate the decoded JSON table and convert it to `SupportedClients`.

    The schema is strict for the same reason the package manifests are: a typo
    in a key is a silent omission otherwise.
    """
    if not isinstance(data, dict) or set(data) != TABLE_KEYS:
        raise SupportedClientsError(f"table must be an object with exactly {sorted(TABLE_KEYS)}")

    verified = data["verified"]
    try:
        datetime.date.fromisoformat(verified)
    except (TypeError, ValueError):
        raise SupportedClientsError("verified must be an ISO date (YYYY-MM-DD)") from None

    if not isinstance(data["source"], str) or not data["source"]:
        raise SupportedClientsError("source must be a non-empty string")

    entries = data["clients"]
    if not isinstance(entries, list) or not entries:
        raise SupportedClientsError("clients must be a non-empty array")

    clients = tuple(_parse_client(index, entry) for index, entry in enumerate(entries))
    numbers = [client.interface for client in clients]
    if len(set(numbers)) != len(numbers):
        raise SupportedClientsError("clients lists the same interface number twice")

    return SupportedClients(verified=verified, source=data["source"], clients=clients)


def load_supported_clients(path: Path = SUPPORTED_CLIENTS_PATH) -> SupportedClients:
    """Read and validate the table at `path`.

    Raises `OSError` when the file cannot be read, `json.JSONDecodeError` when
    it is not JSON, and `SupportedClientsError` when its shape is wrong.
    """
    return parse_supported_clients(json.loads(path.read_text(encoding="utf-8")))


def main(argv: Sequence[str] | None = None) -> int:
    """Print the `.toc` line, or the documentation table rows, from the table."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.validation.interface_numbers",
        description="Print the supported Interface numbers from supported_clients.json.",
    )
    parser.add_argument(
        "--table",
        action="store_true",
        help="print the rows of the supported-client table in docs/EMBEDDING.md instead",
    )
    arguments = parser.parse_args(argv)

    try:
        clients = load_supported_clients()
    except (OSError, ValueError) as exc:
        print(f"{SUPPORTED_CLIENTS_PATH.name}: {exc}", file=sys.stderr)
        return 1

    if arguments.table:
        print("\n".join(clients.markdown_rows()))
    else:
        print(clients.toc_line())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

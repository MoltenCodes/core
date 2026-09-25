"""The client flavours the real-client tests know, and where each one lives.

The real-client tests (``tests/client/README.md``) cover the three flavours the
framework promises: Retail, Classic Era and Mists of Pandaria Classic. The
Burning Crusade Classic Anniversary client is listed as well, because
``tooling/validation/supported_clients.json`` lists it (not promised) and the
test addons' ``## Interface`` line therefore loads there too; the result
matrix shows it as optional. Each flavour is installed in its own folder under
the game folder, and each one identifies itself in the client through
``WOW_PROJECT_ID``, which the harness saves with every result. The installer
uses the folder names; the report tool uses both, so a results file is
attributed by what the client said, not by where it lay.

The promised flavours' IDs and project IDs are the apiKit ones
(``tooling/api/flavours.json``, ``detection.projectId``); every flavour's
``toc_suffix`` names its row in ``supported_clients.json``, whose ``promised``
flag it repeats. ``tooling/tests/test_client_flavours.py`` holds this table to
both files. The folder names are the ones the Battle.net launcher creates:
``_retail_``, ``_classic_era_`` (Classic Era, Hardcore and Season of Discovery
share it), ``_classic_`` (the current Classic progression client, Mists of
Pandaria) and ``_anniversary_``. Test-realm folders (``_ptr_``,
``_classic_era_ptr_``, ...) are deliberately absent: a test build is not part
of the matrix.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ClientFlavour:
    """One flavour the real-client tests know."""

    #: The flavour ID, the apiKit one for a promised flavour, for example ``"classic-era"``.
    flavour_id: str
    #: The name the result matrix uses, for example ``"Classic Era"``.
    display_name: str
    #: The folder of this flavour under the game folder, for example ``"_classic_era_"``.
    directory: str
    #: The ``WOW_PROJECT_ID`` the client of this flavour reports.
    project_id: int
    #: The packager suffix of its row in ``supported_clients.json``, for example ``"_Vanilla"``.
    toc_suffix: str
    #: Whether the framework promises to run on it; the matrix always shows a
    #: promised flavour and shows an optional one only once it has a run.
    promised: bool


#: Every known flavour, in the order the result matrix lists them.
CLIENT_FLAVOURS: tuple[ClientFlavour, ...] = (
    ClientFlavour("retail", "Retail", "_retail_", 1, "_Mainline", True),
    ClientFlavour("classic-era", "Classic Era", "_classic_era_", 2, "_Vanilla", True),
    ClientFlavour("classic-mop", "Mists Classic", "_classic_", 19, "_Mists", True),
    ClientFlavour("tbc-anniversary", "TBC Anniversary", "_anniversary_", 5, "_TBC", False),
)

#: The flavours the framework promises, which the matrix always shows.
PROMISED_FLAVOURS: tuple[ClientFlavour, ...] = tuple(
    flavour for flavour in CLIENT_FLAVOURS if flavour.promised
)

#: The flavour folder the installer uses when none is given.
DEFAULT_FLAVOUR_DIRECTORY = CLIENT_FLAVOURS[0].directory


def flavour_by_id(flavour_id: str) -> ClientFlavour | None:
    """The known flavour with this ID, or ``None``."""
    for flavour in CLIENT_FLAVOURS:
        if flavour.flavour_id == flavour_id:
            return flavour
    return None


def flavour_by_project_id(project_id: object) -> ClientFlavour | None:
    """The known flavour whose client reports this ``WOW_PROJECT_ID``, or ``None``."""
    for flavour in CLIENT_FLAVOURS:
        is_integer = isinstance(project_id, int) and not isinstance(project_id, bool)
        if is_integer and flavour.project_id == project_id:
            return flavour
    return None


def flavour_by_directory(directory: str) -> ClientFlavour | None:
    """The known flavour installed in this folder name, or ``None``."""
    for flavour in CLIENT_FLAVOURS:
        if flavour.directory == directory:
            return flavour
    return None

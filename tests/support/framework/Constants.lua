--- Names the fixture shares with the packages it stands in for.
---
--- These are the private keys and host limits the framework itself depends on.
--- They live in one module so that the facade and every stub factory quote the
--- same value rather than each carrying its own copy of a string a package
--- could change.

local Constants = {}

--- Private bootstrap-state key the Registry API 2 implementation publishes.
Constants.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"

--- The retired API 1 bootstrap-state key. Specs that prove it is *not* adopted
--- still have to clear it between attempts.
Constants.LEGACY_REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V1"

--- The documented public namespace every package hands off through.
Constants.NAMESPACE_KEY = "MoltenCodes"

--- The host's `Frame:RegisterUnitEvent(event, unit1, unit2)` slot count.
Constants.MAXIMUM_UNIT_TOKENS = 2

--- Globals an environment owns and therefore always clears on `Reset`.
---
--- One flat list rather than one per stub module: `Reset` has to clear every
--- global the fixture ever installed, including those belonging to a stub the
--- current spec never asked for, and a single list is what makes that checkable
--- by reading.
Constants.OWNED_GLOBALS = {
    "CreateFrame",
    "C_AddOns",
    "IsAddOnLoaded",
    "IsLoggedIn",
    "C_Timer",
    "GetTimePreciseSec",
    "debugprofilestop",
    "geterrorhandler",
    "securecallfunction",
    "CombatLogGetCurrentEventInfo",
}

return Constants

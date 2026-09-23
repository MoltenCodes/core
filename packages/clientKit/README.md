# ClientKit

ClientKit answers "which client is this and what can it do" in one place, and
normalises the few host calls whose name or shape differs between World of
Warcraft flavours.

```lua
local ClientKit = MoltenCodes.Registries[2]:Get("clientKit", 1)

if ClientKit:GetFlavor() == "mainline" and ClientKit:IsAtLeast(120100) then
    -- Midnight 12.1 or later.
end

if ClientKit:Has("eventValidity") and ClientKit:IsEventValid("LEARNED_SPELL_IN_TAB") then
    frame:RegisterEvent("LEARNED_SPELL_IN_TAB")
end

local info = ClientKit:GetSpellInfo(116) -- same table shape on every flavour
if info then
    print(info.name, info.castTime)
end

if not ClientKit:IsSecret(name) and name == trackedName then
    -- only a non-secret value may be compared
end
```

What it offers:

- **Identity** — `GetFlavor()` (`"mainline"`, `"mists"`, `"tbc"`, `"classic"`),
  `GetBuild()`, `GetInterfaceNumber()` and `IsAtLeast(interfaceNumber)`.
- **Capabilities** — `Has(capability)` over a fixed, documented table. Every
  flag is probed from the host, never inferred from the flavour, so it reads
  `false` whenever the host lacks the facility.
- **Taint probes** — `IsSecret(value)`, `CanAccessFrame(frame)` and
  `IsEventValid(eventName)`.
- **Shims** — `GetAddOnMetadata`, `IsAddOnLoaded`, `GetSpellInfo` and
  `GetItemInfo`, each with one documented shape on every flavour.

An absent `WOW_PROJECT_ID` never makes ClientKit report every flavour or every
capability: it answers `"classic"`, the flavour that assumes the least, and the
capability flags still come from the host.

Everything is read once when the file loads and re-read in place when a newer
embedded copy upgrades it. After that every probe is a table read and every
shim adds one call. ClientKit owns nothing that needs tearing down.

It is not a polyfill: a missing facility is reported, not emulated, and game
data, range and spell logic belong to the libraries that need them.

See [`docs/API.md`](docs/API.md) for the capability table, the shim shapes and
what each answer means on a client that lacks the underlying call.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\clientKit\ClientKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `clientKit/ClientKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

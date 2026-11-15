# ClientKit

ClientKit answers "which client is this and what can it do" in one place,
normalises the few host calls whose name or shape differs between World of
Warcraft flavours, and carries the framework's deprecation warnings.

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

local manifest = ClientKit:GetManifest("MyAddon") -- read once, cached for the session
if manifest then
  print(manifest.title, manifest.version, #manifest.savedVariables)
  print(manifest:Get("X-Website"))
end

-- In a Kit: declare once, warn on the deprecated path (told once per call site).
local reporter = ClientKit:Deprecate({
  name = "TimerKit:After",
  replacement = "TimerKit:Delay",
  removal = "TimerKit API 2",
})
reporter:Warn()

-- In an addon under development: list what this session used, or fail loudly.
for _, report in ipairs(ClientKit:GetDeprecationReports()) do
  print(report.addon, report.name, report.site)
end
ClientKit:SetDeprecationMode("raise")
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
- **Manifests** — `GetManifest(addonName)`: a read-only snapshot of an
  addon's `.toc` with `Title`/`Notes` in the client's locale when the file
  has them, the dependency and saved-variable lists split into arrays, and
  any other field (`X-…` included) through `manifest:Get(field)`. Read once
  per addon and kept for the session; an addon the client does not list
  answers `nil, "unknown"`.
- **Deprecation warnings** — `Deprecate(spec)` returns a reporter a Kit calls
  on its deprecated path; the consuming addon is told once per call site (or
  once per addon) through the host error handler, with the replacement and
  the removal plan, and nothing is raised. `GetDeprecationReports()` lists
  what the session used, and `SetDeprecationMode` switches the session to
  `"silent"` or, for development, `"raise"`. Kits find ClientKit through
  `Registry:Find`, so none depends on it; `SetLimits` bounds what is kept.

An absent `WOW_PROJECT_ID` never makes ClientKit report every flavour or every
capability: it answers `"classic"`, the flavour that assumes the least, and the
capability flags still come from the host.

Everything is read once when the file loads and re-read in place when a newer
embedded copy upgrades it. After that every probe is a table read and every
shim adds one call; a manifest is read on its first request and is a table
read from then on. A Kit that deprecates nothing costs nothing. ClientKit owns
nothing that needs tearing down.

It is not a polyfill: a missing facility is reported, not emulated, and game
data, range and spell logic belong to the libraries that need them.

See [`docs/API.md`](docs/API.md) for the capability table, the shim shapes,
the manifest fields, the deprecation reporter and its modes, and what each
answer means on a client that lacks the underlying call.

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

local Env = require("ClientKitTestEnv")

---Install one client global, as a spec that changes the host between loads does.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- The spec stands in for a client whose API only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

describe("ClientKit bootstrap", function()
  after_each(function()
    Env.Reset()
  end)

  it("publishes the facade through Registry", function()
    local ClientKit, Registry = Env.NewPackageFor("mainline")
    assert.are.equal(ClientKit, Registry:Get("clientKit", 1))
    assert.are.equal(1, ClientKit.API)
    assert.are.equal(7, ClientKit.REVISION)
  end)

  it("reuses the shared facade and state on a duplicate load", function()
    local ClientKit = Env.NewPackageFor("mainline")
    local state = ClientKit._state
    local reloaded = Env.ReloadPackage()

    assert.are.equal(ClientKit, reloaded)
    assert.are.equal(state, reloaded._state)
    assert.are.equal("mainline", reloaded:GetFlavor())
  end)

  it("does not downgrade a newer compatible embedded revision", function()
    local ClientKit, Registry = Env.NewPackageFor("mainline")
    local shared = Registry:Register("clientKit", 1, 99)
    assert.are.equal(ClientKit, shared)
    rawset(shared, "REVISION", 99)

    local reloaded = Env.ReloadPackage()
    assert.are.equal(shared, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place and re-reads the host", function()
    local ClientKit = Env.NewPackageFor("mists")
    local state = ClientKit._state
    local capabilities = state.capabilities
    local host = state.host
    local GetFlavor = ClientKit.GetFlavor
    assert.is_false(ClientKit:Has("secretValues"))

    -- The host gained a facility between the two copies loading, as it
    -- would when a newer embedded copy loads after a client patch. Only
    -- `secret` is secret, so the capability names stay usable as keys.
    local secret = {}
    setGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)

    local nextRevision = ClientKit.REVISION + 1
    local upgraded = Env.LoadSourceAtRevision(nextRevision)

    assert.are.equal(ClientKit, upgraded)
    assert.are.equal(nextRevision, ClientKit.REVISION)
    assert.are.equal(state, ClientKit._state)
    assert.are.equal(capabilities, ClientKit._state.capabilities)
    assert.are.equal(host, ClientKit._state.host)
    assert.are_not.equal(GetFlavor, ClientKit.GetFlavor)

    -- A reference taken before the upgrade reads the re-probed state.
    assert.is_true(ClientKit:Has("secretValues"))
    assert.is_true(ClientKit:IsSecret(secret))
    assert.is_false(ClientKit:IsSecret({}))
    assert.are.equal("mists", GetFlavor(ClientKit))
  end)

  it("keeps the newest copy when an older one loads after an upgrade", function()
    local ClientKit = Env.NewPackageFor("mainline")
    local nextRevision = ClientKit.REVISION + 1
    Env.LoadSourceAtRevision(nextRevision)
    local selected = Env.ReloadPackage()
    assert.are.equal(ClientKit, selected)
    assert.are.equal(nextRevision, selected.REVISION)
  end)

  it("upgrades a revision 1 layout in place and adds the manifest tables", function()
    Env.Reset()
    Env.SetWowProfile("mainline")
    Env.InstallWowApi()
    require("Registry")
    local ClientKit = Env.LoadSourceAtRevision(1)
    local state = ClientKit._state
    local host = state.host
    -- Strip what revision 1 never had: the locale, the manifest cache,
    -- the manifest prototype and the four host functions revision 2 binds.
    rawset(state, "locale", nil)
    rawset(state, "manifests", nil)
    rawset(state, "manifestPrototype", nil)
    for _, name in ipairs({
      "getLocale",
      "getAddOnInfo",
      "getAddOnDependencies",
      "getAddOnOptionalDependencies",
    }) do
      rawset(host, name, nil)
    end

    -- The host gained a locale between the two copies loading.
    setGlobal("GetLocale", function()
      return "deDE"
    end)
    Env.SetAddOnMetadata("MyAddon", "Title-deDE", "Mein Addon")

    -- The working file loads over the revision 1 layout.
    local upgraded = Env.ReloadPackage()

    assert.are.equal(ClientKit, upgraded)
    assert.are.equal(7, ClientKit.REVISION)
    assert.are.equal(state, ClientKit._state)
    assert.are.equal(host, ClientKit._state.host)
    assert.is_table(state.manifests)
    assert.is_table(state.manifestPrototype)
    assert.are.equal("deDE", state.locale)
    assert.are.equal("Mein Addon", ClientKit:GetManifest("MyAddon").title)
  end)

  it("upgrades a revision 2 layout in place and keeps its manifest cache", function()
    Env.NewHostFor("mainline")
    local ClientKit = Env.LoadSourceAtRevision(2)
    local state = ClientKit._state
    Env.RegisterAddOn("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
    local manifest = ClientKit:GetManifest("MyAddon")

    -- Revisions 3, 4, 5 and 7 changed no state field, and the copy loaded as
    -- revision 2 is the working file, so it already carries the deprecation
    -- state revision 6 adds: the real file loads over it as a plain in-place
    -- upgrade. "upgrades a revision 5 layout" covers adding that state.
    local upgraded = Env.ReloadPackage()

    assert.are.equal(ClientKit, upgraded)
    assert.are.equal(7, ClientKit.REVISION)
    assert.are.equal(state, ClientKit._state)
    assert.are.equal(manifest, ClientKit:GetManifest("MyAddon"))
    assert.are.equal("My Addon", manifest:Get("Title"))
    assert.are.equal(1, Env.MetadataReads("MyAddon", "Title"))
  end)

  it("upgrades a revision 3 package in place to the working file", function()
    Env.NewHostFor("mainline", { locale = "deDE" })
    local ClientKit = Env.LoadSourceAtRevision(3)
    local state = ClientKit._state
    Env.RegisterAddOn("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
    local manifest = ClientKit:GetManifest("MyAddon")

    local upgraded = Env.ReloadPackage()

    assert.are.equal(ClientKit, upgraded)
    assert.are.equal(7, upgraded.REVISION)
    assert.are.equal(state, upgraded._state)
    assert.are.equal(manifest, upgraded:GetManifest("MyAddon"))
    assert.are.equal(1, Env.MetadataReads("MyAddon", "Title"))
  end)

  it("upgrades the previous revision in place to the working file", function()
    local previousRevision = 6
    Env.NewHostFor("mainline", { locale = "deDE", secretStrings = { 120000 } })
    local ClientKit = Env.LoadSourceAtRevision(previousRevision)
    local state = ClientKit._state
    local capabilities = state.capabilities
    Env.RegisterAddOn("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
    local manifest = ClientKit:GetManifest("MyAddon")
    Env.InstallHostErrorHandler()
    ClientKit:SetDeprecationMode("silent")
    local reporter = ClientKit:Deprecate({ name = "TimerKit:After", removal = "TimerKit API 2" })
    reporter:Warn(1, "MyAddon")

    local upgraded = Env.ReloadPackage()

    assert.are.equal(ClientKit, upgraded)
    assert.are.equal(previousRevision + 1, upgraded.REVISION)
    assert.are.equal(state, upgraded._state)
    assert.are.equal(capabilities, upgraded._state.capabilities)
    assert.are.equal("deDE", state.locale)
    assert.are.equal(manifest, upgraded:GetManifest("MyAddon"))
    assert.are.equal(1, Env.MetadataReads("MyAddon", "Title"))
    -- The manifest cached by the previous revision resolves `Get` through
    -- the rewritten prototype, so it asks about a receiver's name first.
    assert.are.equal("My Addon", manifest:Get("Title"))
    assert.has_error(function()
      manifest.Get({ name = Env.NewSecretValue() }, "Title")
    end, "ClientKit.Manifest:Get must be called on a manifest")
    -- Revision 7 changed no state field: the deprecation state, its
    -- reporter and its report are kept, and the rewritten `IsAtLeast`
    -- refuses a secret before comparing it.
    assert.are.equal("silent", upgraded:GetDeprecationMode())
    assert.are.equal(
      reporter,
      upgraded:Deprecate({ name = "TimerKit:After", removal = "TimerKit API 2" })
    )
    assert.are.equal(1, #upgraded:GetDeprecationReports())
    assert.has_error(function()
      upgraded:IsAtLeast(120000)
    end, "ClientKit:IsAtLeast interfaceNumber must not be a secret value")
  end)

  it("upgrades a revision 5 layout in place and adds the deprecation state", function()
    Env.NewHostFor("mainline", { debugStack = {} })
    local ClientKit = Env.LoadSourceAtRevision(5)
    local state = ClientKit._state
    Env.RegisterAddOn("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
    local manifest = ClientKit:GetManifest("MyAddon")
    -- Strip what revision 5 never had: the deprecation state and the six
    -- deprecation methods.
    rawset(state, "deprecation", nil)
    for _, methodName in ipairs({
      "Deprecate",
      "GetDeprecationReports",
      "SetDeprecationMode",
      "GetDeprecationMode",
      "SetLimits",
      "GetLimits",
    }) do
      rawset(ClientKit, methodName, nil)
    end

    local upgraded = Env.ReloadPackage()

    assert.are.equal(ClientKit, upgraded)
    assert.are.equal(7, upgraded.REVISION)
    assert.are.equal(state, upgraded._state)
    assert.are.equal(manifest, upgraded:GetManifest("MyAddon"))
    assert.are.equal(1, Env.MetadataReads("MyAddon", "Title"))
    assert.are.equal("report", upgraded:GetDeprecationMode())
    assert.are.same({ maxDeprecations = 128, maxReports = 256 }, upgraded:GetLimits())

    Env.InstallHostErrorHandler()
    local reporter = upgraded:Deprecate({ name = "TimerKit:After", removal = "TimerKit API 2" })
    reporter:Warn(1)
    assert.are.equal(1, #upgraded:GetDeprecationReports())
    assert.are.equal("MyAddon", upgraded:GetDeprecationReports()[1].addon)
  end)

  it("keeps reporters, their once-keys, reports and the mode across an upgrade", function()
    local ClientKit = Env.NewPackageFor("mainline", { debugStack = {} })
    ClientKit:SetDeprecationMode("silent")
    ClientKit:SetLimits({ maxReports = 64 })
    local reporter = ClientKit:Deprecate({ name = "TimerKit:After", removal = "TimerKit API 2" })
    reporter:Warn(1, "MyAddon")
    local Warn = reporter.Warn

    local nextRevision = ClientKit.REVISION + 1
    Env.LoadSourceAtRevision(nextRevision)

    -- The same reporter is handed out again, its `Warn` is the one the newer
    -- copy rewrote, and the addon it already reported stays reported.
    assert.are.equal(
      reporter,
      ClientKit:Deprecate({ name = "TimerKit:After", removal = "TimerKit API 2" })
    )
    assert.are_not.equal(Warn, reporter.Warn)
    reporter:Warn(1, "MyAddon")
    assert.are.equal(1, #ClientKit:GetDeprecationReports())
    assert.are.equal("silent", ClientKit:GetDeprecationMode())
    assert.are.equal(64, ClientKit:GetLimits().maxReports)
  end)

  it("refuses to upgrade over deprecation state that is not the shape revision 6 made", function()
    local ClientKit = Env.NewPackageFor("mainline")
    rawset(ClientKit._state.deprecation, "mode", "loud")
    local nextRevision = ClientKit.REVISION + 1
    Env.expectErrorContaining(
      "MoltenCodes ClientKit package state is corrupted or incomplete",
      function()
        Env.LoadSourceAtRevision(nextRevision)
      end
    )
  end)

  for _, case in ipairs({
    { "the deprecation state", nil, nil },
    { "a deprecation limit", "limits", "maxReports" },
    { "the inert reporter", nil, "inert" },
  }) do
    it("rejects same-revision state that lost or broke " .. case[1], function()
      local ClientKit = Env.NewPackageFor("mainline")
      local deprecation = ClientKit._state.deprecation
      if case[2] ~= nil then
        rawset(deprecation[case[2]], case[3], "many")
      elseif case[3] ~= nil then
        rawset(deprecation, case[3], "none")
      else
        rawset(ClientKit._state, "deprecation", nil)
      end
      assert.has_error(function()
        Env.ReloadPackage()
      end)
    end)
  end

  it("keeps cached manifests and their Get across an upgrade", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.RegisterAddOn("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
    Env.SetAddOnMetadata("MyAddon", "X-Website", "https://example.invalid")
    local manifest = ClientKit:GetManifest("MyAddon")
    local Get = manifest.Get

    local nextRevision = ClientKit.REVISION + 1
    Env.LoadSourceAtRevision(nextRevision)

    -- The same snapshot is handed out, and the method a caller kept from
    -- before the upgrade is the one the newer copy rewrote in place.
    assert.are.equal(manifest, ClientKit:GetManifest("MyAddon"))
    assert.are_not.equal(Get, manifest.Get)
    assert.are.equal("https://example.invalid", manifest:Get("X-Website"))
    assert.are.equal(1, Env.MetadataReads("MyAddon", "X-Website"))
  end)

  it("refuses to load before Registry", function()
    Env.Reset()
    Env.SetWowProfile("mainline")
    Env.InstallWowApi()
    Env.expectErrorContaining(
      "MoltenCodes ClientKit requires Registry API 2 to be loaded first",
      function()
        Env.requireAfterFailedLoad("ClientKit")
      end
    )
  end)

  it("refuses a Registry facade without Bootstrap", function()
    Env.Reset()
    setGlobal(Env.NAMESPACE_KEY, { Registries = { [2] = { API = 2 } } })
    Env.expectErrorContaining(
      "MoltenCodes ClientKit requires a valid Registry API 2 facade",
      function()
        Env.requireAfterFailedLoad("ClientKit")
      end
    )
  end)

  it("rejects same-revision state that lost its capability table", function()
    local ClientKit = Env.NewPackageFor("mainline")
    rawset(ClientKit._state, "capabilities", nil)
    assert.has_error(function()
      Env.ReloadPackage()
    end)
  end)

  it("refuses to upgrade over state that lost its host table", function()
    local ClientKit = Env.NewPackageFor("mainline")
    rawset(ClientKit._state, "host", nil)
    local nextRevision = ClientKit.REVISION + 1
    Env.expectErrorContaining(
      "MoltenCodes ClientKit package state is corrupted or incomplete",
      function()
        Env.LoadSourceAtRevision(nextRevision)
      end
    )
  end)

  for _, tableName in ipairs({ "manifests", "manifestPrototype" }) do
    it("refuses to upgrade over a " .. tableName .. " value that is not a table", function()
      local ClientKit = Env.NewPackageFor("mainline")
      rawset(ClientKit._state, tableName, "not a table")
      local nextRevision = ClientKit.REVISION + 1
      Env.expectErrorContaining(
        "MoltenCodes ClientKit package state is corrupted or incomplete",
        function()
          Env.LoadSourceAtRevision(nextRevision)
        end
      )
    end)
  end

  it("rejects same-revision state that lost its manifest cache", function()
    local ClientKit = Env.NewPackageFor("mainline")
    rawset(ClientKit._state, "manifests", nil)
    assert.has_error(function()
      Env.ReloadPackage()
    end)
  end)

  it("rejects same-revision state whose locale is neither false nor a string", function()
    local ClientKit = Env.NewPackageFor("mainline")
    rawset(ClientKit._state, "locale", 1)
    assert.has_error(function()
      Env.ReloadPackage()
    end)
  end)

  it("rejects same-revision state with a capability that is not a boolean", function()
    local ClientKit = Env.NewPackageFor("mainline")
    rawset(ClientKit._state.capabilities, "C_Spell", "yes")
    assert.has_error(function()
      Env.ReloadPackage()
    end)
  end)
end)

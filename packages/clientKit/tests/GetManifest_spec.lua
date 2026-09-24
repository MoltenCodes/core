local Env = require("ClientKitTestEnv")

--- Every `.toc` field a snapshot reads, with the value the specs give it.
local TOC = {
  Title = "My Addon",
  Notes = "Does things.",
  Version = "1.2.3",
  Author = "Someone",
  Interface = "120100",
  IconTexture = "Interface\\Icons\\INV_Misc_QuestionMark",
  IconAtlas = "questlog-questtypeicon-daily",
  Category = "Utility",
  Group = "MyAddons",
  LoadOnDemand = "1",
  DefaultState = "enabled",
  AddonCompartmentFunc = "MyAddon_OnCompartmentClick",
  Dependencies = "Ace3, LibStub",
  OptionalDeps = "LibDataBroker-1.1,  LibDBIcon-1.0 ",
  SavedVariables = "MyAddonDB",
  SavedVariablesPerCharacter = "MyAddonCharDB, MyAddonLayout",
  ["X-Website"] = "https://example.invalid",
}

---Register `MyAddon` on the host and give it every field in `TOC`.
local function installMyAddon()
  Env.RegisterAddOn("MyAddon")
  for field, value in pairs(TOC) do
    Env.SetAddOnMetadata("MyAddon", field, value)
  end
end

describe("ClientKit:GetManifest", function()
  after_each(function()
    Env.Reset()
  end)

  for _, profileName in ipairs({ "mainline", "mists", "tbc", "classic" }) do
    it("reads every snapshot field on the " .. profileName .. " host", function()
      local ClientKit = Env.NewPackageFor(profileName)
      installMyAddon()

      local manifest = ClientKit:GetManifest("MyAddon")
      assert.is_table(manifest)
      assert.are.equal("MyAddon", manifest.name)
      assert.are.equal("My Addon", manifest.title)
      assert.are.equal("Does things.", manifest.notes)
      assert.are.equal("1.2.3", manifest.version)
      assert.are.equal("Someone", manifest.author)
      assert.are.equal("120100", manifest.interface)
      assert.are.equal(TOC.IconTexture, manifest.iconTexture)
      assert.are.equal(TOC.IconAtlas, manifest.iconAtlas)
      assert.are.equal("Utility", manifest.category)
      assert.are.equal("MyAddons", manifest.group)
      assert.are.equal("1", manifest.loadOnDemand)
      assert.are.equal("enabled", manifest.defaultState)
      assert.are.equal(TOC.AddonCompartmentFunc, manifest.addonCompartmentFunc)
    end)
  end

  it("uses the legacy globals on a client without C_AddOns", function()
    local ClientKit = Env.NewPackageFor("classic")
    -- The spec reads the client global the classic profile publishes.
    -- selene: allow(global_usage)
    assert.is_nil(rawget(_G, "C_AddOns"))
    -- selene: allow(global_usage)
    assert.is_function(rawget(_G, "GetAddOnInfo"))
    installMyAddon()
    assert.are.equal("1.2.3", ClientKit:GetManifest("MyAddon").version)
  end)

  it("splits the list fields into arrays and keeps the raw strings behind Get", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.are.same({ "Ace3", "LibStub" }, manifest.dependencies)
    assert.are.same({ "LibDataBroker-1.1", "LibDBIcon-1.0" }, manifest.optionalDependencies)
    assert.are.same({ "MyAddonDB" }, manifest.savedVariables)
    assert.are.same({ "MyAddonCharDB", "MyAddonLayout" }, manifest.savedVariablesPerCharacter)
    assert.are.equal("Ace3, LibStub", manifest:Get("Dependencies"))
    assert.are.equal(TOC.OptionalDeps, manifest:Get("OptionalDeps"))
  end)

  it("reads RequiredDeps when the .toc spells the dependency list that way", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.RegisterAddOn("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
    Env.SetAddOnMetadata("MyAddon", "RequiredDeps", "LibStub")

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.are.same({ "LibStub" }, manifest.dependencies)
    assert.is_nil(manifest:Get("Dependencies"))
    assert.are.equal("LibStub", manifest:Get("RequiredDeps"))
  end)

  it("falls back to the host's dependency calls when the metadata call exports no list", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.RegisterAddOn("MyAddon", {
      dependencies = { "Ace3", "LibStub" },
      optionalDependencies = { "LibDBIcon-1.0" },
    })
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.are.same({ "Ace3", "LibStub" }, manifest.dependencies)
    assert.are.same({ "LibDBIcon-1.0" }, manifest.optionalDependencies)
    assert.are.same({}, manifest.savedVariables)
    assert.are.same({}, manifest.savedVariablesPerCharacter)
  end)

  it("answers empty arrays on a host without the dependency calls", function()
    local ClientKit = Env.NewPackageFor("mainline", { addOnInfo = false })
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.are.same({}, manifest.dependencies)
    assert.are.same({}, manifest.optionalDependencies)
  end)

  it("prefers the locale-suffixed Title and Notes", function()
    local ClientKit = Env.NewPackageFor("mainline", { locale = "deDE" })
    installMyAddon()
    Env.SetAddOnMetadata("MyAddon", "Title-deDE", "Mein Addon")

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.are.equal("Mein Addon", manifest.title)
    -- No `Notes-deDE`, so the plain field is used.
    assert.are.equal("Does things.", manifest.notes)
    -- The raw fields stay reachable under their own spellings.
    assert.are.equal("My Addon", manifest:Get("Title"))
    assert.are.equal("Mein Addon", manifest:Get("Title-deDE"))
  end)

  it("never asks for a suffixed field when the host reports no locale", function()
    local ClientKit = Env.NewPackageFor("mainline", { locale = false })
    installMyAddon()
    Env.SetAddOnMetadata("MyAddon", "Title-enUS", "Never read")

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.are.equal("My Addon", manifest.title)
    assert.are.equal(0, Env.MetadataReads("MyAddon", "Title-enUS"))
    assert.is_false(ClientKit._state.locale)
  end)

  it("treats a value that is not a locale code as no locale", function()
    local ClientKit = Env.NewPackageFor("mainline", { locale = "not a locale" })
    assert.is_false(ClientKit._state.locale)
  end)

  it("reads X- fields through Get, once each", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.are.equal(0, Env.MetadataReads("MyAddon", "X-Website"))
    assert.are.equal("https://example.invalid", manifest:Get("X-Website"))
    assert.are.equal("https://example.invalid", manifest:Get("X-Website"))
    assert.are.equal(1, Env.MetadataReads("MyAddon", "X-Website"))
    assert.is_nil(manifest["X-Website"])
  end)

  it("asks the host once per snapshot field, and not again through Get", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()

    local manifest = ClientKit:GetManifest("MyAddon")
    ClientKit:GetManifest("MyAddon")
    assert.are.equal("1.2.3", manifest:Get("Version"))
    assert.is_nil(manifest:Get("Notes-enUS"))
    assert.are.equal("Does things.", manifest:Get("Notes"))

    for field in pairs(TOC) do
      if field ~= "X-Website" then
        assert.are.equal(1, Env.MetadataReads("MyAddon", field), field)
      end
    end
    assert.are.equal(1, Env.MetadataReads("MyAddon", "Title-enUS"))
    assert.are.equal(1, Env.MetadataReads("MyAddon", "Notes-enUS"))
  end)

  it("does not remember a field the .toc lacks", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.is_nil(manifest:Get("X-Missing"))
    assert.is_nil(manifest:Get("X-Missing"))
    assert.are.equal(2, Env.MetadataReads("MyAddon", "X-Missing"))
  end)

  it("treats an empty field as absent", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.RegisterAddOn("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
    Env.SetAddOnMetadata("MyAddon", "Version", "")

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.is_nil(manifest.version)
    assert.is_nil(manifest:Get("Version"))
  end)

  it("reads a field the client does not export as absent instead of raising", function()
    local ClientKit = Env.NewPackageFor("classic")
    installMyAddon()
    Env.RefuseMetadataField("Category")
    Env.RefuseMetadataField("X-Website")

    local manifest = ClientKit:GetManifest("MyAddon")
    assert.is_nil(manifest.category)
    assert.is_nil(manifest:Get("X-Website"))
    assert.are.equal("1.2.3", manifest.version)
  end)

  it("hands out the same snapshot on every call", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()
    local first = ClientKit:GetManifest("MyAddon")
    assert.are.equal(first, ClientKit:GetManifest("MyAddon"))
    assert.are.equal(first.dependencies, ClientKit:GetManifest("MyAddon").dependencies)
  end)

  it("does not see a .toc change made after the snapshot", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()
    local manifest = ClientKit:GetManifest("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Version", "9.9.9")
    assert.are.equal("1.2.3", manifest.version)
    assert.are.equal("1.2.3", ClientKit:GetManifest("MyAddon").version)
  end)

  it("returns nil, unknown for an addon the host does not list", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()

    local manifest, reason = ClientKit:GetManifest("NotInstalled")
    assert.is_nil(manifest)
    assert.are.equal("unknown", reason)
    -- Nothing is cached for it, so a later install is seen.
    assert.is_nil(ClientKit._state.manifests.NotInstalled)
    Env.RegisterAddOn("NotInstalled")
    assert.is_table(ClientKit:GetManifest("NotInstalled"))
  end)

  it("caches nothing for unknown names, however many are asked", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()
    ClientKit:GetManifest("MyAddon")

    for index = 1, 50 do
      local manifest, reason = ClientKit:GetManifest("Unknown" .. index)
      assert.is_nil(manifest)
      assert.are.equal("unknown", reason)
    end

    local count = 0
    for _ in pairs(ClientKit._state.manifests) do
      count = count + 1
    end
    assert.are.equal(1, count)
  end)

  it("matches the addon name case-insensitively, as the host does", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()

    local manifest = ClientKit:GetManifest("myaddon")
    assert.are.equal(manifest, ClientKit:GetManifest("MYADDON"))
    assert.are.equal(manifest, ClientKit:GetManifest("MyAddon"))
    -- The host's own spelling of the folder, not the caller's.
    assert.are.equal("MyAddon", manifest.name)
    assert.are.equal("1.2.3", manifest.version)
    assert.are.equal(1, Env.MetadataReads("MyAddon", "Version"))

    local count = 0
    for _ in pairs(ClientKit._state.manifests) do
      count = count + 1
    end
    assert.are.equal(1, count)
    assert.are.equal("https://example.invalid", manifest:Get("X-Website"))
  end)

  it("keeps the caller's spelling of the name when the host cannot report one", function()
    local ClientKit = Env.NewPackageFor("mainline", { addOnInfo = false })
    Env.SetAddOnMetadata("myaddon", "Title", "My Addon")

    local manifest = ClientKit:GetManifest("myaddon")
    assert.are.equal("myaddon", manifest.name)
    assert.are.equal(manifest, ClientKit:GetManifest("MyAddon"))
  end)

  it("refuses a secret addon name or field before using it as a key", function()
    local ClientKit = Env.NewPackageFor("mainline", { secretStrings = { "Hidden" } })
    installMyAddon()

    Env.expectErrorContaining(
      "ClientKit:GetManifest addonName must not be a secret value",
      function()
        ClientKit:GetManifest("Hidden")
      end
    )
    local manifest = ClientKit:GetManifest("MyAddon")
    Env.expectErrorContaining("ClientKit.Manifest:Get field must not be a secret value", function()
      manifest:Get("Hidden")
    end)
    assert.is_nil(ClientKit._state.manifests.hidden)
  end)

  it("knows a listed addon without a Title", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.RegisterAddOn("Untitled")

    local untitled = ClientKit:GetManifest("Untitled")
    assert.is_table(untitled)
    assert.is_nil(untitled.title)
  end)

  it("trusts GetAddOnInfo and asks for no Title once it answers MISSING", function()
    local ClientKit = Env.NewPackageFor("mainline")
    -- Metadata that reads for a name the host does not list cannot happen
    -- on a real client; the stub allows it so the spec can see that the
    -- Title is never asked for after a "MISSING" answer.
    Env.SetAddOnMetadata("Unlisted", "Title", "Unlisted Addon")

    local manifest, reason = ClientKit:GetManifest("Unlisted")
    assert.is_nil(manifest)
    assert.are.equal("unknown", reason)
    assert.are.equal(0, Env.MetadataReads("Unlisted", "Title"))
    assert.are.equal(0, Env.MetadataReads("Unlisted", "Title-enUS"))
  end)

  it("falls back to the Title when the host has no GetAddOnInfo", function()
    local ClientKit = Env.NewPackageFor("mainline", { addOnInfo = false })
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")

    assert.are.equal("My Addon", ClientKit:GetManifest("MyAddon").title)
    local manifest, reason = ClientKit:GetManifest("Untitled")
    assert.is_nil(manifest)
    assert.are.equal("unknown", reason)
  end)

  it("returns nil, unavailable on a host with neither metadata call", function()
    local ClientKit = Env.NewPackageFor("noProjectId")
    Env.RegisterAddOn("MyAddon")
    Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")

    local manifest, reason = ClientKit:GetManifest("MyAddon")
    assert.is_nil(manifest)
    assert.are.equal("unavailable", reason)
  end)

  it("refuses every write to the snapshot", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()
    local manifest = ClientKit:GetManifest("MyAddon")

    Env.expectErrorContaining(
      'ClientKit manifest for "MyAddon" is read-only; field "version" cannot be written',
      function()
        manifest.version = "2.0.0"
      end
    )
    Env.expectErrorContaining('field "brandNew" cannot be written', function()
      manifest.brandNew = true
    end)
    assert.are.equal("1.2.3", manifest.version)
    assert.is_nil(rawget(manifest, "version"))
    assert.is_false(getmetatable(manifest))
  end)

  it("caches only addons the host lists, one record each", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()
    Env.RegisterAddOn("Other")

    ClientKit:GetManifest("MyAddon")
    ClientKit:GetManifest("MyAddon")
    ClientKit:GetManifest("Other")
    ClientKit:GetManifest("Missing")
    ClientKit:GetManifest("AlsoMissing")

    local count = 0
    for _ in pairs(ClientKit._state.manifests) do
      count = count + 1
    end
    assert.are.equal(2, count)
  end)

  it("allocates nothing for a cached manifest or a remembered field #allocation", function()
    local ClientKit = Env.NewPackageFor("mainline")
    installMyAddon()
    local manifest = ClientKit:GetManifest("MyAddon")
    manifest:Get("X-Website")

    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 200 do
      ClientKit:GetManifest("MyAddon")
      manifest:Get("X-Website")
      manifest:Get("Version")
    end
    local after = collectgarbage("count")
    collectgarbage("restart")
    assert.are.equal(before, after)
  end)

  it("rejects an addon name that is not a string", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.expectErrorContaining("ClientKit:GetManifest addonName must be a string", function()
      ClientKit:GetManifest(1)
    end)
  end)
end)

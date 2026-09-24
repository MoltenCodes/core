local Env = require("CompatKitTestEnv")

describe("CompatKit flavour filtering", function()
  after_each(Env.Reset)

  ---Register three shims: one for `mainline` only, one for the Classic
  ---flavours, one for every flavour. Returns the names that ran.
  ---@param CompatKit table
  ---@return string[] ran
  local function registerFlavourShims(CompatKit)
    local ran = {}
    CompatKit:Shim("retail-only", 1, function()
      ran[#ran + 1] = "retail-only"
    end, { flavours = { "mainline" } })
    CompatKit:Shim("classic-family", 1, function()
      ran[#ran + 1] = "classic-family"
    end, { flavours = { "classic", "tbc", "mists" } })
    CompatKit:Shim("everywhere", 1, function()
      ran[#ran + 1] = "everywhere"
    end)
    return ran
  end

  ---The status of the shim `name`.
  ---@param CompatKit table
  ---@param name string
  ---@return string
  local function statusOf(CompatKit, name)
    for _, row in ipairs(CompatKit:GetShims()) do
      if row.name == name then
        return row.status
      end
    end
    error("no shim named " .. name, 2)
  end

  it("applies every shim when ClientKit is absent, and reports no flavour", function()
    local CompatKit = Env.NewPackageFor("mainline")
    local ran = registerFlavourShims(CompatKit)
    local flavour
    CompatKit:Shim("z-inspect", 1, function(context)
      flavour = context.flavour
    end, { flavours = { "classic" } })
    assert.are.same({ 4, 0, 0 }, { CompatKit:Apply() })
    assert.are.same({ "classic-family", "everywhere", "retail-only" }, ran)
    assert.is_false(flavour)
  end)

  it("filters by the ClientKit flavour on a Retail client", function()
    local CompatKit = Env.NewPackageFor("mainline")
    Env.LoadClientKit()
    local ran = registerFlavourShims(CompatKit)
    local flavour
    CompatKit:Shim("z-inspect", 1, function(context)
      flavour = context.flavour
    end)
    assert.are.same({ 3, 1, 0 }, { CompatKit:Apply() })
    assert.are.same({ "everywhere", "retail-only" }, ran)
    assert.are.equal("mainline", flavour)
    assert.are.equal("filtered", statusOf(CompatKit, "classic-family"))
    assert.are.equal("applied", statusOf(CompatKit, "retail-only"))
  end)

  it("filters by the ClientKit flavour on a Classic Era client", function()
    local CompatKit = Env.NewPackageFor("classic")
    Env.LoadClientKit()
    local ran = registerFlavourShims(CompatKit)
    assert.are.same({ 2, 1, 0 }, { CompatKit:Apply() })
    assert.are.same({ "classic-family", "everywhere" }, ran)
    assert.are.equal("filtered", statusOf(CompatKit, "retail-only"))
  end)

  it("never runs a filtered shim later, even after a newer registration", function()
    local CompatKit = Env.NewPackageFor("mainline")
    Env.LoadClientKit()
    local ran = registerFlavourShims(CompatKit)
    CompatKit:Apply()
    assert.are.same({ true, "recorded" }, {
      CompatKit:Shim("classic-family", 2, function()
        ran[#ran + 1] = "classic-family v2"
      end, { flavours = { "classic" } }),
    })
    assert.are.same({ 0, 0, 0 }, { CompatKit:Apply() })
    assert.are.same({ "everywhere", "retail-only" }, ran)
    assert.are.equal("filtered", statusOf(CompatKit, "classic-family"))
  end)

  it("reads the flavour at Apply, so ClientKit loaded after CompatKit counts", function()
    local CompatKit = Env.NewPackageFor("mists")
    local ran = registerFlavourShims(CompatKit)
    Env.LoadClientKit()
    assert.are.same({ 2, 1, 0 }, { CompatKit:Apply() })
    assert.are.same({ "classic-family", "everywhere" }, ran)
  end)

  it("counts a skipped shim as skipped before its flavour is considered", function()
    local CompatKit = Env.NewPackageFor("classic")
    Env.LoadClientKit()
    registerFlavourShims(CompatKit)
    CompatKit:SkipShim("retail-only")
    assert.are.same({ 2, 1, 0 }, { CompatKit:Apply() })
    assert.are.equal("skipped", statusOf(CompatKit, "retail-only"))
  end)

  it("treats a ClientKit flavour that is not a string as no flavour", function()
    local CompatKit = Env.NewPackageFor("mainline")
    local ClientKit = Env.LoadClientKit()
    -- A ClientKit that cannot name the client answers `nil`; CompatKit then
    -- filters nothing, exactly as it does without ClientKit.
    rawset(ClientKit, "GetFlavor", function()
      return nil
    end)
    local ran = registerFlavourShims(CompatKit)
    local flavour
    CompatKit:Shim("z-inspect", 1, function(context)
      flavour = context.flavour
    end)
    assert.are.same({ 4, 0, 0 }, { CompatKit:Apply() })
    assert.are.same({ "classic-family", "everywhere", "retail-only" }, ran)
    assert.is_false(flavour)
  end)
end)

local Env = require("ClientKitTestEnv")

---Install one client global, as a spec that bends a profile needs to.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- The spec stands in for a client whose API only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Reload ClientKit from scratch against the host as it currently stands.
---@return table ClientKit
local function reloadFresh()
  package.loaded["Registry"] = nil
  package.loaded["ClientKit"] = nil
  setGlobal(Env.NAMESPACE_KEY, nil)
  setGlobal(Env.REGISTRY_STATE_KEY, nil)
  require("Registry")
  return require("ClientKit")
end

---The `## Interface` number of each packager TOC suffix in the supported-client
---table every document and tool reads.
---@return table<string, integer>
local function supportedInterfaceNumbers()
  local file = assert(io.open("tooling/validation/supported_clients.json", "r"))
  local contents = file:read("*a")
  file:close()

  local numbers = {}
  for interfaceNumber, suffix in
    contents:gmatch('"interface"%s*:%s*(%d+).-"tocSuffix"%s*:%s*"([^"]+)"')
  do
    numbers[suffix] = tonumber(interfaceNumber)
  end
  return numbers
end

local EXPECTED = {
  mainline = { suffix = "_Mainline", version = "12.1.0" },
  mists = { suffix = "_Mists", version = "5.5.4" },
  tbc = { suffix = "_TBC", version = "2.5.6" },
  classic = { suffix = "_Vanilla", version = "1.15.9" },
}

describe("ClientKit flavour and build", function()
  after_each(function()
    Env.Reset()
  end)

  for _, flavor in ipairs({ "mainline", "mists", "tbc", "classic" }) do
    it("identifies the " .. flavor .. " client", function()
      local ClientKit = Env.NewPackageFor(flavor)
      local expected = EXPECTED[flavor]
      local interfaceNumber = supportedInterfaceNumbers()[expected.suffix]

      assert.is_number(interfaceNumber)
      assert.are.equal(flavor, ClientKit:GetFlavor())
      assert.are.equal(interfaceNumber, ClientKit:GetInterfaceNumber())

      local version, build, buildDate = ClientKit:GetBuild()
      assert.are.equal(expected.version, version)
      assert.is_number(build)
      assert.is_string(buildDate)
    end)
  end

  it("answers the most conservative flavour when WOW_PROJECT_ID is absent", function()
    local ClientKit = Env.NewPackageFor("noProjectId")

    assert.are.equal("classic", ClientKit:GetFlavor())
    assert.are.equal(0, ClientKit:GetInterfaceNumber())
    assert.is_false(ClientKit:IsAtLeast(1))

    local version, build, buildDate = ClientKit:GetBuild()
    assert.is_nil(version)
    assert.is_nil(build)
    assert.is_nil(buildDate)
  end)

  it("does not match a flavour through absent WOW_PROJECT_* constants", function()
    -- Every constant is absent and the id is absent too: the comparison a
    -- naive detector makes (`WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`) would
    -- be `nil == nil` and succeed for every flavour.
    local ClientKit = Env.NewPackageFor("noProjectId")
    -- The spec reads the client global the profile deliberately left out.
    -- selene: allow(global_usage)
    assert.is_nil(rawget(_G, "WOW_PROJECT_MAINLINE"))
    assert.are.equal("classic", ClientKit:GetFlavor())
  end)

  it("maps the project id by value even when its constant is missing", function()
    Env.NewPackageFor("mists")
    setGlobal("WOW_PROJECT_MISTS_CLASSIC", nil)

    assert.are.equal("mists", reloadFresh():GetFlavor())
  end)

  it("treats an unknown project id as the most conservative flavour", function()
    Env.NewPackageFor("mists")
    -- 11 was Wrath of the Lich King Classic: a real id, but not a supported flavour.
    setGlobal("WOW_PROJECT_ID", 11)

    local ClientKit = reloadFresh()
    assert.are.equal("classic", ClientKit:GetFlavor())
    assert.are.equal(50504, ClientKit:GetInterfaceNumber())
  end)

  it("refuses a project id that is not a number", function()
    Env.NewPackageFor("mainline")
    setGlobal("WOW_PROJECT_ID", "1")

    assert.are.equal("classic", reloadFresh():GetFlavor())
  end)

  it("publishes the build number as an integer", function()
    local ClientKit = Env.NewPackageFor("mainline")
    local _, build = ClientKit:GetBuild()
    assert.are.equal(64123, build)
  end)

  it("reports nothing it cannot read from a partial GetBuildInfo", function()
    Env.NewPackageFor("mainline")
    setGlobal("GetBuildInfo", function()
      return "12.1.0", "not a number"
    end)

    local ClientKit = reloadFresh()
    local version, build, buildDate = ClientKit:GetBuild()
    assert.are.equal("12.1.0", version)
    assert.is_nil(build)
    assert.is_nil(buildDate)
    assert.are.equal(0, ClientKit:GetInterfaceNumber())
  end)
end)

describe("ClientKit:IsAtLeast", function()
  after_each(function()
    Env.Reset()
  end)

  it("includes the running interface number itself", function()
    local ClientKit = Env.NewPackageFor("mainline")
    assert.is_true(ClientKit:IsAtLeast(120100))
    assert.is_true(ClientKit:IsAtLeast(120099))
    assert.is_true(ClientKit:IsAtLeast(120000))
    assert.is_false(ClientKit:IsAtLeast(120101))
    assert.is_false(ClientKit:IsAtLeast(math.huge))
    assert.is_true(ClientKit:IsAtLeast(-math.huge))
  end)

  it("compares within a flavour, not across flavours", function()
    local ClientKit = Env.NewPackageFor("classic")
    assert.is_true(ClientKit:IsAtLeast(11509))
    assert.is_false(ClientKit:IsAtLeast(11510))
    -- Classic Era is current, yet numerically below Mists Classic.
    assert.is_false(ClientKit:IsAtLeast(50504))
  end)

  it("rejects a floor that is not a number", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.expectErrorContaining("ClientKit:IsAtLeast interfaceNumber must be a number", function()
      ClientKit:IsAtLeast("120100")
    end)
    Env.expectErrorContaining("ClientKit:IsAtLeast interfaceNumber must be a number", function()
      ClientKit:IsAtLeast(0 / 0)
    end)
  end)
end)

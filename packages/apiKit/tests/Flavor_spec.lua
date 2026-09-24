local TestEnv = require("ApiKitTestEnv")

describe("ApiKit flavour detection", function()
  after_each(TestEnv.Reset)

  local cases = {
    { client = "retail", expected = "retail" },
    { client = "classic-era", expected = "classic-era" },
    { client = "classic-mop", expected = "classic-mop" },
    { client = "ptr", expected = "ptr" },
    { client = "beta", expected = "beta" },
    { client = "tbc", expected = "unsupported" },
    { client = "none", expected = "unsupported" },
  }

  for _, case in ipairs(cases) do
    it("reports " .. case.expected .. " for a " .. case.client .. " client", function()
      local ApiKit = TestEnv.NewPackageFor(case.client)
      assert.are.equal(case.expected, ApiKit:GetFlavor())
    end)
  end

  it("gives a Classic test realm its Classic flavour's surface", function()
    for projectId, expected in pairs({ [2] = "classic-era", [19] = "classic-mop" }) do
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.SetClient({ projectId = projectId, testBuild = true, betaBuild = false })
      require("Registry")
      local ApiKit = require("ApiKit")
      assert.are.equal(expected, ApiKit:GetFlavor())
    end
  end)

  it("treats a beta client as a test build whatever IsTestBuild says", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetClient({ projectId = 1, testBuild = false, betaBuild = true })
    require("Registry")
    local ApiKit = require("ApiKit")
    assert.are.equal("beta", ApiKit:GetFlavor())
  end)

  it("treats a missing probe as false", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetClient({ projectId = 1 })
    require("Registry")
    local ApiKit = require("ApiKit")
    assert.are.equal("retail", ApiKit:GetFlavor())
  end)

  it("ignores a project id that is not a number", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetClient({ projectId = nil })
    -- selene: allow(global_usage)
    rawset(_G, "WOW_PROJECT_ID", "1")
    require("Registry")
    local ApiKit = require("ApiKit")
    assert.are.equal("unsupported", ApiKit:GetFlavor())
  end)

  it("reads the client once, at load", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    TestEnv.SetClient({ projectId = 2, testBuild = false, betaBuild = false })
    assert.are.equal("retail", ApiKit:GetFlavor())
  end)
end)

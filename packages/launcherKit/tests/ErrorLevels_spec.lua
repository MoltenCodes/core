local TestEnv = require("LauncherKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run every `{ action, message }` case and check the failure is reported at
---the line after the function's `function()` line, where its statement sits.
---@param cases { [1]: fun(), [2]: string }[]
local function checkCases(cases)
  for _, case in ipairs(cases) do
    local action = case[1]
    local line = debug.getinfo(action, "S").linedefined + 1
    local ok, value = pcall(action)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. line .. ": " .. case[2], value)
  end
end

describe("LauncherKit error levels", function()
  local LauncherKit, BrokerKit, launcher
  before_each(function()
    LauncherKit, BrokerKit = TestEnv.NewPackage()
    BrokerKit:New("MyAddon")
    BrokerKit:New("Other")
    launcher = LauncherKit:Register("MyAddon", {})
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          LauncherKit:Register(1, {})
        end,
        "LauncherKit:Register objectName must be a non-empty string",
      },
      {
        function()
          LauncherKit:Register("Missing", {})
        end,
        "LauncherKit:Register has no BrokerKit object named Missing; create it with BrokerKit:New first",
      },
      {
        function()
          LauncherKit:Register("Other", 1)
        end,
        "LauncherKit:Register storage must be a table or a function returning one",
      },
      {
        function()
          LauncherKit:Register("MyAddon", {})
        end,
        "LauncherKit:Register MyAddon already has a launcher",
      },
      {
        function()
          LauncherKit:Get(nil)
        end,
        "LauncherKit:Get objectName must be a non-empty string",
      },
      {
        function()
          LauncherKit:AddToCompartment("")
        end,
        "LauncherKit:AddToCompartment objectName must be a non-empty string",
      },
      {
        function()
          LauncherKit:SetLimits({ maxLaunchers = 0 })
        end,
        "LauncherKit:SetLimits limits.maxLaunchers must be an integer from 1 to 256",
      },
      {
        function()
          LauncherKit.GetLimits(nil)
        end,
        "LauncherKit:GetLimits must be called on the LauncherKit facade; use LauncherKit:GetLimits(...)",
      },
      {
        function()
          launcher.Refresh({})
        end,
        "LauncherKit.Launcher:Refresh must be called on a LauncherKit launcher; use launcher:Refresh(...)",
      },
      {
        function()
          launcher.GetButton(1)
        end,
        "LauncherKit.Launcher:GetButton must be called on a LauncherKit launcher; use launcher:GetButton(...)",
      },
    })
    LauncherKit:SetLimits({ maxLaunchers = 1 })
    checkCases({
      {
        function()
          LauncherKit:Register("Other", {})
        end,
        "LauncherKit:Register holds at most 1 launchers; raise maxLaunchers with LauncherKit:SetLimits",
      },
    })
    LauncherKit:SetLimits({ maxLaunchers = 2 })
    TestEnv.SetGlobal("Minimap", nil)
    checkCases({
      {
        function()
          LauncherKit:Register("Other", {})
        end,
        "LauncherKit:Register needs the client's Minimap and CreateFrame, which this host does not have",
      },
    })
  end)
end)

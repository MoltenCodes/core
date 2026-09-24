local TestEnv = require("OptionsKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("OptionsKit allocation #allocation", function()
  local OptionsKit
  local tree
  local store

  before_each(function()
    local Registry
    OptionsKit, Registry = TestEnv.NewPackage()
    TestEnv.InstallSettingsKitStub(Registry)
    store = { scale = 1, enabled = true, mode = "a", color = { r = 1, g = 1, b = 1 } }
    local db = TestEnv.NewDatabase({ profile = { frame = { scale = 1 } } })
    tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        general = {
          type = "group",
          name = "General",
          hidden = function()
            return false
          end,
          args = {
            scale = {
              type = "range",
              name = "Scale",
              min = 0.5,
              max = 2,
              get = function()
                return store.scale
              end,
              set = function(_, value)
                store.scale = value
              end,
              validate = function()
                return true
              end,
            },
            enabled = {
              type = "toggle",
              name = "Enabled",
              get = function()
                return store.enabled
              end,
              set = function(_, value)
                store.enabled = value
              end,
            },
            mode = {
              type = "select",
              name = "Mode",
              values = { a = "A", b = "B" },
              get = function()
                return store.mode
              end,
              set = function(_, value)
                store.mode = value
              end,
            },
            color = {
              type = "color",
              name = "Color",
              get = function()
                return store.color
              end,
              set = function(_, value)
                store.color = value
              end,
            },
            bound = {
              type = "range",
              name = "Bound",
              min = 0.5,
              max = 2,
              bind = "profile.frame.scale",
            },
          },
        },
      },
    }, { db = db })
    tree:OnChange(function() end)
  end)
  after_each(TestEnv.Reset)

  ---@param label string
  ---@param workload fun()
  local function assertAllocatesNothing(label, workload)
    workload()
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        workload()
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, label .. " allocated " .. allocated .. " KiB")
  end

  it("allocates nothing on Get", function()
    assertAllocatesNothing("Get through a getter", function()
      tree:Get("general.scale")
    end)
    assertAllocatesNothing("Get through a bind", function()
      tree:Get("general.bound")
    end)
  end)

  it("allocates nothing on a valid Set", function()
    local color = { r = 0.5, g = 0.5, b = 0.5 }
    assertAllocatesNothing("Set of a range with validate", function()
      tree:Set("general.scale", 1.5)
    end)
    assertAllocatesNothing("Set of a toggle", function()
      tree:Set("general.enabled", false)
    end)
    assertAllocatesNothing("Set of a select", function()
      tree:Set("general.mode", "b")
    end)
    assertAllocatesNothing("Set of a color", function()
      tree:Set("general.color", color)
    end)
    assertAllocatesNothing("Set through a bind", function()
      tree:Set("general.bound", 1.25)
    end)
  end)

  it("allocates nothing on Walk", function()
    local visited = 0
    local function visitor()
      visited = visited + 1
    end
    assertAllocatesNothing("Walk", function()
      tree:Walk(visitor)
    end)
    assert.is_true(visited > 0)
  end)

  it("allocates nothing on Validate of a valid value, IsDisabled and IsHidden", function()
    assertAllocatesNothing("Validate", function()
      tree:Validate("general.scale", 1)
    end)
    assertAllocatesNothing("IsDisabled", function()
      tree:IsDisabled("general.scale")
    end)
    assertAllocatesNothing("IsHidden", function()
      tree:IsHidden("general.scale")
    end)
  end)
end)

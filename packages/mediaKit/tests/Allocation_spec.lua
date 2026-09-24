local TestEnv = require("MediaKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("MediaKit allocation #allocation", function()
  local MediaKit
  before_each(function()
    MediaKit = TestEnv.NewPackage("enUS")
    MediaKit:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar")
    MediaKit:Register("sound", "Pack Sound", 569593)
    MediaKit:Register("font", "Pack Font", "Fonts\\Pack.ttf", { scripts = { "latin" } })
  end)
  after_each(TestEnv.Reset)

  it("allocates nothing for Fetch and Has, with and without options", function()
    local options = { anyScript = true }
    local misses = 0
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        if
          MediaKit:Fetch("statusbar", "Pack Bar") == nil
          or MediaKit:Fetch("sound", "Pack Sound") == nil
          or MediaKit:Fetch("font", "Pack Font") == nil
          or MediaKit:Fetch("font", "Pack Font", options) == nil
          or MediaKit:Fetch("statusbar", "Missing") ~= nil
          or not MediaKit:Has("font", "Friz Quadrata TT")
        then
          misses = misses + 1
        end
      end
    end)
    assert.are.equal(0, misses)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "Fetch allocated " .. allocated .. " KiB")
  end)

  it("allocates nothing for List while nothing was registered", function()
    local fonts = MediaKit:List("font")
    local bars = MediaKit:List("statusbar")
    local allFonts = MediaKit:List("font", { anyScript = true })
    local options = { anyScript = true }
    local changed = 0
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        if
          MediaKit:List("font") ~= fonts
          or MediaKit:List("statusbar") ~= bars
          or MediaKit:List("font", options) ~= allFonts
        then
          changed = changed + 1
        end
      end
    end)
    assert.are.equal(0, changed)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "List allocated " .. allocated .. " KiB")
  end)

  it("allocates nothing for a consumer's Get", function()
    local defaults = MediaKit:Defaults("MyAddon")
    defaults:Set("statusbar", "Pack Bar")
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        defaults:Get("statusbar")
        defaults:Get("font")
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "Get allocated " .. allocated .. " KiB")
  end)
end)

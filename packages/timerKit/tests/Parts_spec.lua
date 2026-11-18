local TestEnv = require("TimerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src
local PAUSING_FILE_HINT =
  "part, which is not loaded: add timerKit\\parts\\TimerKit-Pausing.lua to embeds.xml after timerKit\\TimerKit.lua"

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of this
---spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local function noop() end

describe("TimerKit without the Pausing part", function()
  local TimerKit
  before_each(function()
    TimerKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("answers false from HasPart", function()
    assert.is_false(TimerKit:HasPart("Pausing"))
    assert.is_false(TimerKit:HasPart("Unknown"))
  end)

  it("keeps Pause, Resume and IsPaused as stubs that raise at the caller's line", function()
    local timer = TimerKit:After(2, noop)
    for _, member in ipairs({ "Pause", "Resume", "IsPaused" }) do
      local line
      local ok, value = pcall(function()
        line = currentLine() + 1
        timer[member](timer)
      end)
      assertReportedAt(
        line,
        "TimerKit.Timer:" .. member .. " is in TimerKit's Pausing " .. PAUSING_FILE_HINT,
        ok,
        value
      )
    end
    assert.is_true(timer:IsPending())
  end)

  it("serves every other timer and scope method", function()
    local scope = TimerKit:CreateScope()
    local fired = 0
    local timer = scope:After(1, function()
      fired = fired + 1
    end)
    assert.are.equal("running", timer:GetState())
    TestEnv.FireNative(1)
    assert.are.equal(1, fired)
    assert.is_true(timer:Restart())
    assert.are.equal(1, scope:CancelAll())
    assert.is_true(scope:Close())
  end)
end)

describe("TimerKit with the Pausing part", function()
  local TimerKit
  before_each(function()
    TimerKit = TestEnv.NewPackage()
    TestEnv.LoadPausing()
  end)
  after_each(TestEnv.Reset)

  it("answers true from HasPart", function()
    assert.is_true(TimerKit:HasPart("Pausing"))
  end)

  it("refuses a HasPart name that is not a string, at the caller's line", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      TimerKit:HasPart(42)
    end)
    assertReportedAt(line, "TimerKit:HasPart name must be a part name string", ok, value)
  end)

  it("leaves a paused timer to the core's CancelAll, Close and Restart", function()
    local scope = TimerKit:CreateScope()
    local first = scope:After(2, noop)
    local second = scope:After(2, noop)
    local third = scope:After(2, noop)
    assert.is_true(first:Pause())
    assert.is_true(second:Pause())
    assert.is_true(third:Pause())
    assert.are.equal(3, scope:GetActiveCount())

    assert.is_true(third:Restart())
    assert.are.equal("running", third:GetState())
    assert.are.equal(3, scope:CancelAll())
    assert.is_true(first:IsCancelled())
    assert.is_true(second:IsCancelled())
    assert.is_true(third:IsCancelled())

    local paused = scope:After(2, noop)
    assert.is_true(paused:Pause())
    assert.is_true(scope:Close())
    assert.is_true(paused:IsCancelled())
    assert.is_false(paused:Resume())
  end)

  it("keeps its members when the core is loaded again", function()
    local pause = rawget(TimerKit.Timer, "Pause")
    package.loaded["TimerKit"] = nil
    TestEnv.LoadRevision(TimerKit.REVISION + 1)

    assert.are.equal(pause, rawget(TimerKit.Timer, "Pause"))
    assert.is_true(TimerKit:HasPart("Pausing"))
    local timer = TimerKit:After(2, noop)
    assert.is_true(timer:Pause())
    assert.is_true(timer:Resume())
  end)

  it("returns the facade when an equal revision of the part loads again", function()
    package.loaded["TimerKit-Pausing"] = nil
    assert.are.equal(TimerKit, require("TimerKit-Pausing"))
  end)
end)

describe("TimerKit Pausing part bootstrap", function()
  after_each(TestEnv.Reset)

  it("refuses to load before TimerKit's core, naming it", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local ok, value = pcall(require, "TimerKit-Pausing")
    assert.is_false(ok)
    assert.is_truthy(
      tostring(value):find("part Pausing requires TimerKit API 1 to be loaded first", 1, true)
    )
  end)
end)

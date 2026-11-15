local TestEnv = require("SchedulerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

local function noop() end

---Assert that `callback` raised `message` at a line of this spec file.
---@param message string
---@param callback function
local function expectErrorHere(message, callback)
  local ok, value = pcall(callback)
  assert.is_false(ok)
  value = tostring(value)
  assert.is_not_nil(value:find(SOURCE .. ":", 1, true), value)
  assert.is_not_nil(value:find(message, 1, true), value)
end

---The message a member of `part` raises while that part is not loaded.
---@param label string
---@param part string
---@return string
local function missingPart(label, part)
  local after = part == "Coalescing" and "schedulerKit\\SchedulerKit.lua"
    or "schedulerKit\\parts\\SchedulerKit-Coalescing.lua"
  return label
    .. " is in SchedulerKit's "
    .. part
    .. " part, which is not loaded: add schedulerKit\\parts\\SchedulerKit-"
    .. part
    .. ".lua to embeds.xml after "
    .. after
end

---Load Registry and TimerKit only, for specs that choose what loads next.
local function newHost()
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  require("Registry")
  require("TimerKit")
end

describe("SchedulerKit core without its parts", function()
  after_each(TestEnv.Reset)

  it("keeps every part member on the facade and the scope prototype", function()
    local SchedulerKit = TestEnv.NewCore()
    for _, name in ipairs({ "Debounce", "Coalesce", "Watch", "Lane" }) do
      assert.is_function(rawget(SchedulerKit, name))
    end
    for _, name in ipairs({ "Debounce", "Coalesce", "Watch" }) do
      assert.is_function(rawget(SchedulerKit.Scope, name))
    end
  end)

  it("raises at the caller's line with the file to embed", function()
    local SchedulerKit = TestEnv.NewCore()
    local scope = SchedulerKit:CreateScope()
    expectErrorHere(missingPart("SchedulerKit:Debounce", "Coalescing"), function()
      SchedulerKit:Debounce(noop, 1)
    end)
    expectErrorHere(missingPart("SchedulerKit:Coalesce", "Coalescing"), function()
      SchedulerKit:Coalesce(noop, 1)
    end)
    expectErrorHere(missingPart("SchedulerKit.Scope:Debounce", "Coalescing"), function()
      scope:Debounce(noop, 1)
    end)
    expectErrorHere(missingPart("SchedulerKit.Scope:Coalesce", "Coalescing"), function()
      scope:Coalesce(noop, 1)
    end)
    expectErrorHere(missingPart("SchedulerKit:Lane", "Lanes"), function()
      SchedulerKit:Lane("bags")
    end)
    expectErrorHere(missingPart("SchedulerKit:Watch", "Watch"), function()
      SchedulerKit:Watch(noop, 1, noop)
    end)
    expectErrorHere(missingPart("SchedulerKit.Scope:Watch", "Watch"), function()
      scope:Watch(noop, 1, noop)
    end)
  end)

  it("answers HasPart for each part as it loads", function()
    local SchedulerKit = TestEnv.NewCore()
    assert.is_false(SchedulerKit:HasPart("Coalescing"))
    assert.is_false(SchedulerKit:HasPart("Lanes"))
    assert.is_false(SchedulerKit:HasPart("Watch"))
    TestEnv.LoadPart("Coalescing")
    assert.is_true(SchedulerKit:HasPart("Coalescing"))
    assert.is_false(SchedulerKit:HasPart("Lanes"))
    TestEnv.LoadPart("Watch")
    assert.is_true(SchedulerKit:HasPart("Watch"))
    assert.is_false(SchedulerKit:HasPart("Unknown"))
  end)

  it("refuses a HasPart call that is not a method call or names no string", function()
    local SchedulerKit = TestEnv.NewCore()
    expectErrorHere("SchedulerKit:HasPart must be called on the SchedulerKit facade", function()
      SchedulerKit.HasPart("Coalescing")
    end)
    expectErrorHere("SchedulerKit:HasPart name must be a string", function()
      SchedulerKit:HasPart(1)
    end)
  end)

  it("still cancels and closes scopes and keeps the family limits", function()
    local SchedulerKit = TestEnv.NewCore()
    local scope = SchedulerKit:CreateScope()
    scope:Schedule(noop)
    assert.is_true(scope:CancelAll())
    assert.is_true(scope:Close())
    SchedulerKit:SetLimits({ maxLanes = 4, maxDebounceArguments = 16 })
    local limits = SchedulerKit:GetLimits()
    assert.are.equal(4, limits.maxLanes)
    assert.are.equal(16, limits.maxDebounceArguments)
    assert.are.equal(32, limits.maxWatchIntervals)
  end)
end)

describe("SchedulerKit part bootstrap", function()
  after_each(TestEnv.Reset)

  it("refuses to load a part before the core", function()
    newHost()
    local ok, message = pcall(require, "SchedulerKit-Coalescing")
    assert.is_false(ok)
    assert.is_not_nil(
      tostring(message):find(
        "MoltenCodes SchedulerKit part Coalescing requires SchedulerKit API 1 to be loaded first",
        1,
        true
      )
    )
  end)

  it("refuses Lanes and Watch before the Coalescing part", function()
    TestEnv.NewCore()
    for _, name in ipairs({ "Lanes", "Watch" }) do
      local ok, message = pcall(require, "SchedulerKit-" .. name)
      assert.is_false(ok)
      assert.is_not_nil(
        tostring(message):find(
          "MoltenCodes SchedulerKit part " .. name .. " requires SchedulerKit part Coalescing",
          1,
          true
        )
      )
    end
  end)

  it("refuses a lane option while the Lanes part is not loaded", function()
    local SchedulerKit = TestEnv.NewCore()
    TestEnv.LoadPart("Coalescing")
    expectErrorHere(missingPart("SchedulerKit:Debounce lane", "Lanes"), function()
      SchedulerKit:Debounce(noop, 1, { lane = {} })
    end)
    expectErrorHere(missingPart("SchedulerKit:Coalesce lane", "Lanes"), function()
      SchedulerKit:Coalesce(noop, 1, { lane = {} })
    end)
  end)

  it("leaves an equal or newer part revision in place", function()
    local SchedulerKit = TestEnv.NewPackage()
    local debounce = rawget(SchedulerKit, "Debounce")
    TestEnv.LoadPartRevision("Coalescing", 1)
    assert.are.equal(debounce, rawget(SchedulerKit, "Debounce"))
    TestEnv.LoadPartRevision("Coalescing", 2)
    local upgraded = rawget(SchedulerKit, "Debounce")
    assert.are_not.equal(debounce, upgraded)
    TestEnv.LoadPartRevision("Coalescing", 1)
    assert.are.equal(upgraded, rawget(SchedulerKit, "Debounce"))
    assert.are.equal(2, SchedulerKit._state.parts.Coalescing.revision)
  end)

  it("upgrades a part in place with its live handles", function()
    local SchedulerKit = TestEnv.NewPackage()
    local calls = 0
    local debounced = SchedulerKit:Debounce(function()
      calls = calls + 1
    end, 1)
    local lane = SchedulerKit:Lane("kept")
    local watched = 0
    local watcher = SchedulerKit:Watch(function()
      watched = watched + 1
      return watched
    end, 1, noop)
    debounced()
    for _, name in ipairs(TestEnv.PARTS) do
      TestEnv.LoadPartRevision(name, 2)
    end
    TestEnv.AdvanceMs(1000)
    TestEnv.FireNative(#TestEnv.NativeTimers())
    assert.are.equal(1, calls)
    assert.is_true(watcher:IsActive())
    assert.are.equal("kept", lane:GetName())
    assert.are.equal(lane, SchedulerKit:Lane("kept"))
  end)

  it("keeps parts an older core served when a newer core upgrades in place", function()
    local SchedulerKit = TestEnv.NewPackage()
    local seen = nil
    local coalesced = SchedulerKit:Coalesce(function(set)
      seen = set.key
    end, 1)
    TestEnv.LoadRevision(SchedulerKit.REVISION + 1)
    assert.is_true(SchedulerKit:HasPart("Coalescing"))
    coalesced("key")
    TestEnv.FireNative(#TestEnv.NativeTimers())
    assert.is_true(seen)
  end)
end)

describe("SchedulerKit hand-over from the whole-file revision 21", function()
  after_each(TestEnv.Reset)

  ---Revision 21 with a handle of every kind in an addon scope.
  ---@return table old the revision 21 facade
  ---@return table objects
  local function wholeRevisionWithObjects()
    newHost()
    local old = TestEnv.LoadWholeRevision()
    assert.are.equal(21, old.REVISION)
    local scope = old:ForAddon("Legacy")
    local objects = { calls = 0 }
    objects.debounced = scope:Debounce(function()
      objects.calls = objects.calls + 1
    end, 1)
    objects.coalesced = scope:Coalesce(noop, 1)
    objects.watcher = scope:Watch(function()
      return 1
    end, 1, noop)
    objects.lane = old:Lane("legacy")
    objects.scope = scope
    return old, objects
  end

  it("keeps every live handle working when the parts load with the core", function()
    local old, objects = wholeRevisionWithObjects()
    objects.debounced()
    local upgraded = require("SchedulerKit")
    TestEnv.LoadParts()
    assert.are.equal(old, upgraded)
    assert.are.equal(22, upgraded.REVISION)

    TestEnv.AdvanceMs(1000)
    for index = 1, #TestEnv.NativeTimers() do
      TestEnv.FireNative(index)
    end
    assert.are.equal(1, objects.calls)
    assert.is_true(objects.watcher:IsActive())
    assert.is_false(objects.coalesced:IsClosed())
    assert.are.equal("legacy", objects.lane:GetName())
    assert.are.equal(0, #TestEnv.TakeReportedErrors())
  end)

  it("closes the live objects of missing parts on the next frame and reports once", function()
    local old, objects = wholeRevisionWithObjects()
    local upgraded = require("SchedulerKit")
    assert.are.equal(old, upgraded)
    expectErrorHere(missingPart("SchedulerKit.DebounceHandle:IsClosed", "Coalescing"), function()
      objects.debounced:IsClosed()
    end)

    -- The settle timer is the last one armed.
    TestEnv.FireNative(#TestEnv.NativeTimers())
    local reports = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reports)
    local message = tostring(reports[1].value)
    assert.is_not_nil(message:find("took over from revision 21", 1, true), message)
    assert.is_not_nil(message:find("closed 4 live handles and lanes", 1, true), message)
    assert.is_not_nil(message:find("schedulerKit\\parts\\SchedulerKit-Lanes.lua", 1, true))

    local state = rawget(upgraded, "_state")
    assert.is_true(rawget(objects.debounced, "_closed"))
    assert.is_true(rawget(objects.coalesced, "_closed"))
    assert.is_true(rawget(objects.watcher, "_closed"))
    assert.is_true(rawget(objects.lane, "_closed"))
    assert.is_nil(next(rawget(state, "lanes")))
    assert.is_nil(next(rawget(state, "watchGroups")))
    assert.is_false(rawget(objects.scope, "_familyHead"))
    assert.is_true(objects.scope:Close())
  end)

  it("lets parts loaded later serve new handles after the hand-over", function()
    wholeRevisionWithObjects()
    local upgraded = require("SchedulerKit")
    TestEnv.FireNative(#TestEnv.NativeTimers())
    TestEnv.TakeReportedErrors()
    TestEnv.LoadParts()
    local calls = 0
    local debounced = upgraded:Debounce(function()
      calls = calls + 1
    end, 0)
    debounced()
    TestEnv.FireNative(#TestEnv.NativeTimers())
    assert.are.equal(1, calls)
  end)

  it("serves what revision 21 left in manual scopes and lanes without the parts", function()
    newHost()
    local old = TestEnv.LoadWholeRevision()
    -- Reachable, so the hand-over is settled on the next frame.
    old:ForAddon("Legacy"):Debounce(noop, 1)
    local manual = old:CreateScope()
    local armed = manual:Debounce(noop, 1)
    armed()
    local idle = manual:Coalesce(noop, 1)
    local watcher = manual:Watch(function()
      return 1
    end, 2, noop)
    local lane = old:Lane("busy", { maxInFlight = 1 })
    local ran = 0
    local first = lane:Submit(function()
      ran = ran + 1
    end, { scope = manual })
    local waiting = lane:Submit(function()
      ran = ran + 1
    end, { scope = manual })
    local timersBefore = #TestEnv.NativeTimers()

    local upgraded = require("SchedulerKit")
    -- The admitted job runs as an ordinary job; its lane is let go.
    TestEnv.Tick()
    assert.are.equal(1, ran)
    assert.are.equal("completed", first:GetState())

    -- Every timer revision 21 armed fires into the core's defaults: the
    -- debounce wake retires its handle and the watch tick stops its ticker.
    for index = 1, timersBefore do
      TestEnv.FireNative(index)
    end
    assert.is_true(rawget(armed, "_closed"))

    -- The settle timer closes the lane and its waiting job, and the watcher.
    TestEnv.FireNative(#TestEnv.NativeTimers())
    assert.are.equal(1, #TestEnv.TakeReportedErrors())
    assert.is_true(rawget(lane, "_closed"))
    assert.are.equal("cancelled", waiting:GetState())
    assert.is_true(rawget(watcher, "_closed"))

    -- Closing the manual scope retires the handle nobody could reach.
    assert.is_false(rawget(idle, "_closed"))
    assert.is_true(manual:Close())
    assert.is_true(rawget(idle, "_closed"))
    assert.are.equal(0, upgraded:GetActiveCount())
  end)

  it("yields when the whole-file revision loads after a core without parts", function()
    local SchedulerKit = TestEnv.NewCore()
    local selected = TestEnv.LoadWholeRevision()
    assert.are.equal(SchedulerKit, selected)
    assert.are.equal(22, selected.REVISION)
    expectErrorHere(missingPart("SchedulerKit:Debounce", "Coalescing"), function()
      selected:Debounce(noop, 1)
    end)
  end)

  it("arms nothing when the whole-file revision left no family objects", function()
    newHost()
    TestEnv.LoadWholeRevision()
    local before = #TestEnv.NativeTimers()
    require("SchedulerKit")
    assert.are.equal(before, #TestEnv.NativeTimers())
  end)
end)

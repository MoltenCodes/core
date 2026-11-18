local Env = require("PoolKitTestEnv")
local Core = Env.Core

local SOURCE = debug.getinfo(1, "S").short_src

-- Revision 12 splits PoolKit into the plain-pool core and four parts (ADR
-- 0001): Waiting, Children, Deferred and Generations. These specs pin the core
-- without them, the parts' bootstrap, the upgrade from revision 11 (the last
-- whole file, `fixtures/PoolKit-revision11.lua`) with and without the parts,
-- and the sparse pools revision 12 builds.

---The text a member of `part` raises while the part is not loaded.
---@param member string
---@param part string
---@return string
local function missing(member, part)
  return member
    .. " is in PoolKit's "
    .. part
    .. " part, which is not loaded: add poolKit\\parts\\PoolKit-"
    .. part
    .. ".lua to embeds.xml after poolKit\\PoolKit.lua"
end

---Run `action` and assert it failed with `message` at the line after the one
---that called `mark()`.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

local function create()
  return {}
end

---Load one part's source again with its `PART_REVISION` set to `revision`.
---@param part string
---@param revision integer
---@return table PoolKit
local function loadPartAtRevision(part, revision)
  local path = "packages/poolKit/src/parts/PoolKit-" .. part .. ".lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  local patched, count =
    text:gsub("local PART_REVISION = %d+", "local PART_REVISION = " .. revision, 1)
  assert.are.equal(1, count)
  return assert(loadstring(patched, "@" .. path))()
end

---Count the fields a table carries.
---@param value table
---@return integer
local function countFields(value)
  local count = 0
  for _ in next, value do
    count = count + 1
  end
  return count
end

---Build, on the revision 11 whole file, one pool in each mechanism's state:
---a queued request, a parked object, an attached child and a raised
---generation. Returns what the specs need to look at afterwards.
---@return table scene
local function buildRevision11Scene()
  require("Registry")
  local previous = Env.LoadRevision(11)
  assert.are.equal(11, previous.REVISION)
  local scene = { previous = previous, served = {}, destroyed = {} }

  scene.frames = previous:New({ create = create, maxCreated = 1, maxWaiting = 1 })
  scene.frame = scene.frames:Acquire()
  assert.are.same({ nil, "waiting" }, {
    scene.frames:Acquire(function(object, _, reason)
      scene.served[#scene.served + 1] = reason or object
    end),
  })

  scene.fading = previous:NewTablePool()
  scene.group = Env.NewAnimationGroup()
  scene.parked = scene.fading:Acquire()
  assert.is_true(scene.fading:ReleaseAfter(scene.parked, scene.group))

  scene.parents = previous:NewTablePool()
  scene.children = previous:NewTablePool()
  scene.parent = scene.parents:Acquire()
  scene.child = scene.children:Acquire()
  scene.parents:AttachChild(scene.parent, scene.child, scene.children)

  scene.versioned = previous:New({
    create = create,
    destroy = function(object)
      scene.destroyed[#scene.destroyed + 1] = object
    end,
  })
  scene.old = scene.versioned:Acquire()
  scene.versioned:SetGeneration(2)
  return scene
end

describe("PoolKit parts", function()
  after_each(function()
    Env.Reset()
    Core.Reset()
  end)

  describe("without the parts", function()
    it("answers HasPart false for each part", function()
      local PoolKit = Core.NewPackage()
      for _, part in ipairs({ "Waiting", "Children", "Deferred", "Generations" }) do
        assert.is_false(PoolKit:HasPart(part))
      end
      assert.is_false(PoolKit:HasPart("Unknown"))
    end)

    it("refuses a HasPart name that is not a string, and a call on another receiver", function()
      local PoolKit = Core.NewPackage()
      assertReportedAtCaller("PoolKit:HasPart name must be a string", function(mark)
        mark()
        PoolKit:HasPart(1)
      end)
      assertReportedAtCaller(
        "PoolKit:HasPart must be called on the PoolKit facade; use PoolKit:HasPart(...)",
        function(mark)
          mark()
          PoolKit.HasPart("Waiting")
        end
      )
    end)

    it("refuses PoolKit.New called with a dot with the facade message", function()
      local PoolKit = Core.NewPackage()
      assertReportedAtCaller(
        "PoolKit:New must be called on the PoolKit facade; use PoolKit:New(...)",
        function(mark)
          mark()
          PoolKit.New({ create = create })
        end
      )
    end)

    it(
      "keeps every part's mutator on the prototype, raising at the caller with the file to add",
      function()
        local PoolKit = Core.NewPackage()
        local pool = PoolKit:New({ create = create })
        local object = pool:Acquire()
        assertReportedAtCaller(missing("PoolKit.Pool:CancelWaiting", "Waiting"), function(mark)
          mark()
          pool:CancelWaiting(create)
        end)
        assertReportedAtCaller(missing("PoolKit.Pool:AttachChild", "Children"), function(mark)
          mark()
          pool:AttachChild(object, {}, pool)
        end)
        assertReportedAtCaller(missing("PoolKit.Pool:DetachChild", "Children"), function(mark)
          mark()
          pool:DetachChild(object)
        end)
        assertReportedAtCaller(missing("PoolKit.Pool:ReleaseAfter", "Deferred"), function(mark)
          mark()
          pool:ReleaseAfter(object, Env.NewAnimationGroup())
        end)
        assertReportedAtCaller(missing("PoolKit.Pool:SetGeneration", "Generations"), function(mark)
          mark()
          pool:SetGeneration(2)
        end)
      end
    )

    it("refuses each part's constructor option at the caller with the file to add", function()
      local PoolKit = Core.NewPackage()
      assertReportedAtCaller(missing("PoolKit:New maxActive", "Waiting"), function(mark)
        mark()
        PoolKit:New({ create = create, maxActive = 1 })
      end)
      assertReportedAtCaller(missing("PoolKit:New maxWaiting", "Waiting"), function(mark)
        mark()
        PoolKit:New({ create = create, maxCreated = 1, maxWaiting = 1 })
      end)
      assertReportedAtCaller(missing("PoolKit:New generation", "Generations"), function(mark)
        mark()
        PoolKit:New({ create = create, generation = 2 })
      end)
      assertReportedAtCaller(
        missing("PoolKit:NewTablePool generation", "Generations"),
        function(mark)
          mark()
          PoolKit:NewTablePool({ generation = 2 })
        end
      )
    end)

    it("answers each part's getter with its neutral value", function()
      local PoolKit = Core.NewPackage()
      local pool = PoolKit:New({ create = create })
      assert.are.equal(0, pool:GetWaitingCount())
      assert.are.equal(0, pool:GetParkedCount())
      assert.are.equal(1, pool:GetGeneration())
      assert.is_false(pool:GetMaxCreated())
      assert.is_false(pool:IsClosed())
    end)

    it("answers Acquire(onAvailable) at capacity with queueFull, there being no queue", function()
      local PoolKit = Core.NewPackage()
      local pool = PoolKit:New({ create = create, maxCreated = 1 })
      local object = pool:Acquire()
      assert.are.same({ nil, "queueFull" }, { pool:Acquire(create) })
      assert.are.same({ nil, "exhausted" }, { pool:Acquire() })
      pool:Release(object)
      assert.are.equal(object, pool:Acquire(create))
    end)

    it("builds sparse pools of at most 16 fields", function()
      local PoolKit = Core.NewPackage()
      -- What the Kits in this repository build, plus `destroy`: 16 fields.
      -- Only all five optional settings together (adding `maxActiveWarning`)
      -- reach 17.
      local full = PoolKit:New({
        create = create,
        reset = function() end,
        destroy = function() end,
        maxRetained = PoolKit.UNBOUNDED,
        maxCreated = 4,
      })
      local tables = PoolKit:NewTablePool()
      assert.is_true(countFields(full) <= 16)
      assert.is_true(countFields(tables) <= 16)
      assert.is_nil(rawget(full, "_waitingCount"))
      assert.is_nil(rawget(full, "_generation"))
      assert.is_nil(rawget(full, "_children"))
      assert.are.equal(
        getmetatable(rawget(full, "_released")),
        getmetatable(rawget(tables, "_released"))
      )
    end)
  end)

  describe("bootstrap", function()
    it("records each part with its revision and answers HasPart true", function()
      local PoolKit = Env.NewPackage()
      for _, part in ipairs({ "Waiting", "Children", "Deferred", "Generations" }) do
        assert.is_true(PoolKit:HasPart(part))
        assert.are.equal(1, PoolKit._state.parts[part].revision)
      end
    end)

    it("loads the parts in either order", function()
      Env.Reset()
      require("Registry")
      local PoolKit = require("PoolKit")
      for index = #Env.PARTS, 1, -1 do
        require(Env.PARTS[index])
      end
      local pool = PoolKit:New({ create = create, maxActive = 1, generation = 3 })
      assert.are.equal(3, pool:GetGeneration())
      local object = pool:Acquire()
      assert.are.same({ nil, "exhausted" }, { pool:Acquire() })
      pool:Release(object)
    end)

    it("refuses to load a part without its core", function()
      for _, part in ipairs({ "Waiting", "Children", "Deferred", "Generations" }) do
        Env.Reset()
        require("Registry")
        Env.expectErrorContaining(
          "MoltenCodes PoolKit part " .. part .. " requires PoolKit API 1 to be loaded first",
          function()
            require("PoolKit-" .. part)
          end
        )
      end
    end)

    it(
      "refuses to load a part over the revision 11 whole file, which offers no part interface",
      function()
        Env.Reset()
        require("Registry")
        Env.LoadRevision(11)
        Env.expectErrorContaining(
          "MoltenCodes PoolKit part Waiting requires PoolKit API 1 to be loaded first",
          function()
            require("PoolKit-Waiting")
          end
        )
      end
    )

    it("lets a part of an equal revision return without touching anything", function()
      local PoolKit = Env.NewPackage()
      local record = PoolKit._state.parts.Children
      local attach = PoolKit.Pool.AttachChild
      loadPartAtRevision("Children", 1)
      assert.are.equal(record, PoolKit._state.parts.Children)
      assert.are.equal(attach, PoolKit.Pool.AttachChild)
    end)

    it("upgrades a part in place to a higher revision", function()
      local PoolKit = Env.NewPackage()
      local cancel = PoolKit.Pool.CancelWaiting
      loadPartAtRevision("Waiting", 2)
      assert.are.equal(2, PoolKit._state.parts.Waiting.revision)
      assert.are_not.equal(cancel, PoolKit.Pool.CancelWaiting)
    end)

    it("keeps the parts serving when a later core revision loads over them", function()
      local PoolKit = Env.NewPackage()
      local setGeneration = PoolKit.Pool.SetGeneration
      local later = Env.LoadSourceWithRevision("PoolKit", PoolKit.REVISION + 1)
      assert.are.equal(PoolKit, later)
      assert.are.equal(setGeneration, PoolKit.Pool.SetGeneration)
      local pool = PoolKit:New({ create = create })
      assert.are.equal(0, pool:SetGeneration(2))
    end)

    it("does not keep the fallbacks for older pools in a session that never had one", function()
      local PoolKit = Env.NewPackage()
      assert.is_nil(PoolKit._state.fullPools)
      assert.is_nil(PoolKit._state.legacyPools)
    end)
  end)

  describe("the upgrade from revision 11", function()
    it("keeps every mechanism working when the parts are loaded", function()
      Env.Reset()
      local scene = buildRevision11Scene()
      local PoolKit = Env.ReloadPackage()
      assert.are.equal(scene.previous, PoolKit)
      assert.is_true(PoolKit._state.fullPools)

      -- The queued request is served by the next release.
      scene.frames:Release(scene.frame)
      assert.are.same({ scene.frame }, scene.served)

      -- The hook revision 11 installed runs the part's completion.
      scene.group:Finish()
      assert.are.equal(0, scene.fading:GetParkedCount())
      assert.are.equal(1, scene.fading:GetAvailableCount())

      -- The child is released with its parent.
      scene.parents:Release(scene.parent)
      assert.is_false(scene.children:IsActive(scene.child))

      -- The stale object is destroyed, not retained.
      scene.versioned:Release(scene.old)
      assert.are.same({ scene.old }, scene.destroyed)
      assert.are.equal(2, scene.versioned:GetGeneration())
    end)

    it(
      "takes the safe exact path for each mechanism without the parts, reported once each",
      function()
        Env.Reset()
        Env.InstallHostErrorHandler()
        local scene = buildRevision11Scene()
        package.loaded["PoolKit"] = nil
        local PoolKit = require("PoolKit")
        assert.are.equal(scene.previous, PoolKit)
        assert.is_false(PoolKit:HasPart("Waiting"))

        -- The queued request fails with "closed" instead of waiting forever.
        scene.frames:Release(scene.frame)
        assert.are.same({ "closed" }, scene.served)
        assert.are.equal(0, scene.frames:GetWaitingCount())

        -- The parked object is released when its animation finishes.
        scene.group:Finish()
        assert.are.equal(0, scene.fading:GetParkedCount())
        assert.are.equal(1, scene.fading:GetAvailableCount())

        -- The child is detached without being released.
        scene.parents:Release(scene.parent)
        assert.is_true(scene.children:IsActive(scene.child))
        scene.children:Release(scene.child)

        -- The stale object is destroyed, not retained.
        scene.versioned:Release(scene.old)
        assert.are.same({ scene.old }, scene.destroyed)

        local reports = Env.ReportedWarnings()
        local seen = {}
        for _, report in ipairs(reports) do
          for _, part in ipairs({ "Waiting", "Deferred", "Children", "Generations" }) do
            if tostring(report):find("PoolKit-" .. part .. ".lua", 1, true) then
              seen[part] = (seen[part] or 0) + 1
            end
          end
        end
        assert.are.same({ Waiting = 1, Deferred = 1, Children = 1, Generations = 1 }, seen)
      end
    )

    it(
      "without the parts, Close completes every parked release and a released child leaves its siblings linked",
      function()
        Env.Reset()
        Env.InstallHostErrorHandler()
        require("Registry")
        local previous = Env.LoadRevision(11)
        local destroyed = {}
        local fading = previous:New({
          create = create,
          destroy = function(object)
            destroyed[#destroyed + 1] = object
          end,
        })
        local firstGroup, secondGroup = Env.NewAnimationGroup(), Env.NewAnimationGroup()
        local first, second = fading:Acquire(), fading:Acquire()
        assert.is_true(fading:ReleaseAfter(first, firstGroup))
        assert.is_true(fading:ReleaseAfter(second, secondGroup))
        local parents, children = previous:NewTablePool(), previous:NewTablePool()
        local parent = parents:Acquire()
        local oldest, middle, newest = children:Acquire(), children:Acquire(), children:Acquire()
        for _, child in ipairs({ oldest, middle, newest }) do
          parents:AttachChild(parent, child, children)
        end

        package.loaded["PoolKit"] = nil
        local PoolKit = require("PoolKit")
        assert.is_false(PoolKit:HasPart("Deferred"))
        assert.is_false(PoolKit:HasPart("Children"))

        -- Close completes both parked releases at once; a closed pool keeps
        -- nothing, so both objects are destroyed.
        fading:Close()
        assert.are.equal(0, fading:GetParkedCount())
        assert.are.equal(2, #destroyed)
        assert.is_false(fading:Owns(first))
        assert.is_false(fading:Owns(second))
        -- The animations finishing afterwards find nothing left to release.
        firstGroup:Finish()
        secondGroup:Finish()
        assert.are.equal(2, #destroyed)

        -- Releasing the middle child unlinks it alone: its siblings stay
        -- attached and the parent's release detaches both, unreleased.
        children:Release(middle)
        assert.is_false(children:IsActive(middle))
        parents:Release(parent)
        assert.is_true(children:IsActive(oldest))
        assert.is_true(children:IsActive(newest))
        children:Release(oldest)
        children:Release(newest)
        assert.are.equal(3, children:GetAvailableCount())
      end
    )

    it("serves a revision 11 full pool and a sparse pool side by side", function()
      Env.Reset()
      require("Registry")
      local previous = Env.LoadRevision(11)
      local full = previous:NewTablePool({ maxRetained = 2 })
      local borrowed = full:Acquire()
      local PoolKit = Env.ReloadPackage()
      local sparse = PoolKit:NewTablePool({ maxRetained = 2 })
      assert.is_false(rawget(full, "_children"))
      assert.is_nil(rawget(sparse, "_children"))
      for _, pool in ipairs({ full, sparse }) do
        local object = pool:Acquire()
        pool:Release(object)
        assert.are.equal(object, pool:Acquire())
        assert.are.equal(0, pool:GetWaitingCount())
        assert.are.equal(1, pool:GetGeneration())
        pool:Close()
        assert.is_true(pool:IsClosed())
      end
      assert.is_true(full:Owns(borrowed))
    end)
  end)
end)

--- Library registration and lookup: Registry (and InteropKit) against LibStub.
---
--- Registry and LibStub do the same job for embedded libraries: several addons
--- ship copies of one library, the newest copy wins, and every consumer finds
--- the one shared table by name. The pairs compared are:
---
---   new library       `Registry:Register(name, 1, 1)`   `LibStub:NewLibrary(name, 1)`
---   upgrade           `Register` with a higher revision `NewLibrary` with a higher minor
---   stale copy        `Register` with an equal revision `NewLibrary` with an equal minor
---   lookup            `Registry:Get(name, 1)`           `LibStub:GetLibrary(name)`
---   silent miss       `Registry:Find(name, 1)`          `LibStub:GetLibrary(name, true)`
---
--- Registry identifies a library by name and API generation, LibStub by one
--- major string; the benchmark gives both the same names (`benchLib12`), which
--- fit both naming rules. LibStub also accepts a minor inside a string
--- (`"$Revision: 12 $"`) and parses it on every `NewLibrary`; the benchmark
--- passes plain numbers, the common form, and LibStub still converts each to a
--- string for its `string.match`, which is part of its measured cost.
---
--- InteropKit is the bridge from MoltenCodes code to LibStub libraries, so its
--- rows need LibStub on the MoltenCodes side too (`LibStub.lua` from the same
--- pinned checkout, loaded in that process only for these rows' sake):
---
--- - `foreign-lookup` compares `InteropKit:Find(major)` of an adopted LibStub
---   library with the Ace3 way of reaching it, `LibStub:GetLibrary(major, true)`.
--- - `expose-to-libstub` (`InteropKit:ExposeToLibStub`, making a Kit a LibStub
---   library) has no Ace3 counterpart and is reported for MoltenCodes alone.
---
--- Left out: `Registry:Bootstrap`, the path a Kit's own file takes (surface
--- validation, retire hooks, migrations, sealing). LibStub has nothing of the
--- kind; its libraries write their upgrade code by hand, so there is no equal
--- work to compare with.

local LibraryRegistry = {}

--- Registrations per timed batch for the cases that create or upgrade.
local REGISTER_ITERATIONS = 20000

--- Lookups per timed batch.
local LOOKUP_ITERATIONS = 500000

--- Libraries registered before the lookup cases, looked up in turn.
local LOOKUP_LIBRARIES = 50

--- Kits exposed per `expose-to-libstub` batch.
local EXPOSE_ITERATIONS = 5000

---Names `prefix1`, `prefix2`, ... for one batch, built outside every timed region.
---@param prefix string
---@param first integer
---@param count integer
---@return string[]
local function freshNames(prefix, first, count)
  local names = {}
  for index = 1, count do
    names[index] = prefix .. (first + index - 1)
  end
  return names
end

---@param host table
---@param directory string the Ace3 checkout, for LibStub on the bridge rows
---@return table adapter, table[] libraries
local function kitAdapter(host, directory)
  local loaded = host.RequireAll({ "Registry", "InteropKit" })
  local Registry, InteropKit = loaded[1], loaded[2]
  host.LoadFiles(directory, { "LibStub/LibStub.lua" })
  local LibStub = host.Global("LibStub")
  local adapter = { side = "moltencodes" }

  function adapter.register(name, revision)
    return Registry:Register(name, 1, revision)
  end

  function adapter.get(name)
    return Registry:Get(name, 1)
  end

  function adapter.findSilently(name)
    return Registry:Find(name, 1)
  end

  ---Put a foreign library into LibStub and return the side's lookup of it.
  function adapter.foreignLookup(major)
    LibStub:NewLibrary(major, 1)
    InteropKit:AdoptFromLibStub(major)
    return function()
      return InteropKit:Find(major)
    end
  end

  function adapter.expose(name)
    return InteropKit:ExposeToLibStub(name, 1)
  end

  function adapter.libStubLibrary(major)
    return LibStub:GetLibrary(major, true)
  end

  return adapter,
    {
      { name = "Registry", revision = Registry.REVISION },
      { name = "InteropKit", revision = InteropKit.REVISION },
    }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, { "LibStub/LibStub.lua" })
  local LibStub = host.Global("LibStub")
  local adapter = { side = "ace3" }

  function adapter.register(name, revision)
    return LibStub:NewLibrary(name, revision)
  end

  function adapter.get(name)
    return LibStub:GetLibrary(name)
  end

  function adapter.findSilently(name)
    return LibStub:GetLibrary(name, true)
  end

  function adapter.foreignLookup(major)
    LibStub:NewLibrary(major, 1)
    return function()
      return LibStub:GetLibrary(major, true)
    end
  end

  return adapter, { { name = "LibStub", minor = LibStub.minor } }
end

---@param adapter table
---@return Bench.Case[]
local function cases(adapter)
  local list = {
    {
      name = "new-library",
      iterations = REGISTER_ITERATIONS,
      operation = "register a library name never seen, at its first revision",
      prepare = function()
        local names, nextIndex = nil, 1
        return {
          beforeBatch = function(iterations)
            names = freshNames("benchLib", nextIndex, iterations)
            nextIndex = nextIndex + iterations
          end,
          run = function(iterations)
            local register = adapter.register
            for index = 1, iterations do
              register(names[index], 1)
            end
          end,
        }
      end,
    },
    {
      name = "upgrade",
      iterations = REGISTER_ITERATIONS,
      operation = "register a higher revision of an existing library (same table back)",
      prepare = function()
        adapter.register("benchUpgraded", 1)
        local revision = 1
        return {
          run = function(iterations)
            local register = adapter.register
            for _ = 1, iterations do
              revision = revision + 1
              register("benchUpgraded", revision)
            end
          end,
        }
      end,
    },
    {
      name = "stale-copy",
      iterations = REGISTER_ITERATIONS,
      operation = "register an equal revision of an existing library (refused)",
      prepare = function()
        adapter.register("benchStale", 5)
        return {
          run = function(iterations)
            local register = adapter.register
            for _ = 1, iterations do
              register("benchStale", 5)
            end
          end,
        }
      end,
    },
    {
      name = "lookup",
      iterations = LOOKUP_ITERATIONS,
      operation = "look up a registered library by name (50 registered)",
      prepare = function()
        local names = freshNames("benchLookup", 1, LOOKUP_LIBRARIES)
        for index = 1, LOOKUP_LIBRARIES do
          adapter.register(names[index], 1)
        end
        local found, asked = 0, 0
        return {
          run = function(iterations)
            local get = adapter.get
            local slot = 0
            for _ = 1, iterations do
              slot = slot + 1
              if slot > LOOKUP_LIBRARIES then
                slot = 1
              end
              if get(names[slot]) ~= nil then
                found = found + 1
              end
            end
            asked = asked + iterations
          end,
          metrics = function()
            return { foundPerLookup = found / asked }
          end,
        }
      end,
    },
    {
      name = "silent-miss",
      iterations = LOOKUP_ITERATIONS,
      operation = "look up a library nobody registered, without raising",
      prepare = function()
        return {
          run = function(iterations)
            local findSilently = adapter.findSilently
            for _ = 1, iterations do
              findSilently("benchAbsent")
            end
          end,
        }
      end,
    },
    {
      name = "foreign-lookup",
      iterations = LOOKUP_ITERATIONS,
      operation = "reach a LibStub library by its major (InteropKit:Find or LibStub:GetLibrary silent)",
      prepare = function()
        local lookup = adapter.foreignLookup("LibForeign-1.0")
        return {
          run = function(iterations)
            for _ = 1, iterations do
              lookup()
            end
          end,
        }
      end,
    },
  }

  if adapter.expose ~= nil then
    list[#list + 1] = {
      name = "expose-to-libstub",
      iterations = EXPOSE_ITERATIONS,
      operation = "make a registered Kit a LibStub library (InteropKit:ExposeToLibStub)",
      note = "MoltenCodes only: Ace3 has no bridge from another registry into LibStub",
      prepare = function()
        local names, nextIndex = nil, 1
        return {
          -- Each batch exposes Kits registered for it, outside the timed region.
          beforeBatch = function(iterations)
            names = freshNames("benchExposed", nextIndex, iterations)
            nextIndex = nextIndex + iterations
            for index = 1, iterations do
              adapter.register(names[index], 1)
            end
          end,
          run = function(iterations)
            local expose = adapter.expose
            for index = 1, iterations do
              expose(names[index])
            end
          end,
        }
      end,
    }
  end
  return list
end

---@param adapter table
---@return table[] checks
local function checks(adapter)
  local results = {}
  local isKit = adapter.side == "moltencodes"

  local first = adapter.register("checkUpgrade", 1)
  first.marker = true
  local second, previous = adapter.register("checkUpgrade", 2)
  results[#results + 1] = {
    name = "upgrade-keeps-table",
    passed = second == first and previous == 1,
    detail = "same table: " .. tostring(second == first) .. ", previous revision: " .. tostring(
      previous
    ),
    promised = true,
  }

  local lower = adapter.register("checkUpgrade", 1)
  local equal = adapter.register("checkUpgrade", 2)
  results[#results + 1] = {
    name = "older-and-equal-refused",
    passed = lower == nil and equal == nil,
    detail = "lower: " .. tostring(lower) .. ", equal: " .. tostring(equal),
    promised = true,
  }

  local library, reason = adapter.findSilently("checkAbsent")
  results[#results + 1] = {
    name = "silent-miss-says-why",
    passed = library == nil and reason ~= nil,
    detail = "result: " .. tostring(library) .. ", reason: " .. tostring(reason),
    promised = isKit,
  }

  local accepted = pcall(adapter.register, "checkFraction", 1.5)
  local stored = accepted and adapter.findSilently("checkFraction") ~= nil
  results[#results + 1] = {
    name = "fractional-revision-refused",
    passed = not stored,
    detail = "revision 1.5 " .. (stored and "was accepted" or "was refused"),
    promised = isKit,
  }

  if adapter.expose ~= nil then
    adapter.register("checkExposed", 3)
    local exposed, major = adapter.expose("checkExposed")
    local viaLibStub = exposed and adapter.libStubLibrary(major)
    results[#results + 1] = {
      name = "kit-reachable-through-libstub",
      passed = exposed == true and viaLibStub == adapter.get("checkExposed"),
      detail = "exposed as "
        .. tostring(major)
        .. ", LibStub returns the Kit's table: "
        .. tostring(viaLibStub == adapter.get("checkExposed")),
      promised = true,
    }
  end
  return results
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function LibraryRegistry.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host, settings.ace3)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  return {
    libraries = libraries,
    cases = cases(adapter),
    checks = function()
      return checks(adapter)
    end,
  }
end

return LibraryRegistry

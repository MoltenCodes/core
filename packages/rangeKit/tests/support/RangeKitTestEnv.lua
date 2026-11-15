--- Package-specific test environment for the RangeKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and a small world the
--- range checks answer from:
---
---   the player     a class (`SetClass`), a spellbook (`Learn`, `Forget`) of
---                  spells whose reach `DefineSpell` sets;
---   units          `PlaceUnit(unit, yards, relation)`: a unit at a distance,
---                  `"hostile"`, `"friendly"`, `"dead"` (friendly and dead),
---                  `"deadHostile"` or `"neutral"`; `RemoveUnit`;
---   the checks     `C_Spell.IsSpellInRange` and `CheckInteractDistance`
---                  answer from those distances (7 and 28 yards for interact
---                  indexes 3 and 4); every check is counted (`CheckCount`);
---   combat         `SetCombat`;
---   events         `C_EventUtils.IsEventValid` from the shared fixture;
---   secret values  `InstallSecretProbe` and `NewSecret`;
---   upgrades       `LoadRevision`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local RangeKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "RangeKit" },
})

-- Globals this file installs besides those the shared fixture owns.
local OWNED_GLOBALS = {
  "Enum",
  "UnitClass",
  "UnitExists",
  "UnitCanAttack",
  "UnitCanAssist",
  "UnitIsDeadOrGhost",
  "UnitIsUnit",
  "InCombatLockdown",
  "CheckInteractDistance",
}

local INTERACT_YARDS = { [3] = 7, [4] = 28 }

local secrets = setmetatable({}, { __mode = "k" })
local world = {}
local sharedNewPackage = RangeKitTestEnv.NewPackage
local sharedReset = RangeKitTestEnv.Reset
local sharedInstallWowApi = RangeKitTestEnv.InstallWowApi

---Read a host global.
---@param name string
---@return any
function RangeKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function RangeKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---A fresh world: a priest with no spells, no units, out of combat.
local function newWorld()
  world = {
    class = "PRIEST",
    spells = {},
    known = {},
    units = {},
    combat = false,
    checks = 0,
  }
end

newWorld()

---Install the client calls the range checks read, answering from `world`.
local function installClient()
  local set = RangeKitTestEnv.SetGlobal
  set("Enum", { SpellBookSpellBank = { Player = 0, Pet = 1 } })
  set("UnitClass", function()
    return "Class", world.class
  end)
  set("UnitExists", function(unit)
    return world.units[unit] ~= nil
  end)
  set("UnitCanAttack", function(_, unit)
    local placed = world.units[unit]
    return placed ~= nil and (placed.relation == "hostile")
  end)
  set("UnitCanAssist", function(_, unit)
    local placed = world.units[unit]
    return placed ~= nil and (placed.relation == "friendly" or placed.relation == "dead")
  end)
  set("UnitIsDeadOrGhost", function(unit)
    local placed = world.units[unit]
    return placed ~= nil and (placed.relation == "dead" or placed.relation == "deadHostile")
  end)
  set("UnitIsUnit", function(left, right)
    local placed = world.units[left]
    return right == "pet" and placed ~= nil and placed.isPet == true
  end)
  set("InCombatLockdown", function()
    return world.combat
  end)
  set("CheckInteractDistance", function(unit, index)
    world.checks = world.checks + 1
    local placed = world.units[unit]
    return placed ~= nil and placed.yards <= INTERACT_YARDS[index]
  end)
  set("C_Spell", {
    GetSpellInfo = function(spellID)
      local spell = world.spells[spellID]
      if spell == nil then
        return nil
      end
      return {
        name = "Spell " .. spellID,
        spellID = spellID,
        minRange = spell.minRange,
        maxRange = spell.maxRange,
      }
    end,
    IsSpellInRange = function(spellID, unit)
      world.checks = world.checks + 1
      local spell, placed = world.spells[spellID], world.units[unit]
      if spell == nil or placed == nil then
        return nil
      end
      if spell.answer ~= nil then
        return spell.answer
      end
      return placed.yards <= spell.maxRange and placed.yards >= spell.minRange
    end,
  })
  set("C_SpellBook", {
    IsSpellInSpellBook = function(spellID)
      return world.known[spellID] == true
    end,
  })
end

---Install the shared host stubs and the range world's client calls.
function RangeKitTestEnv.InstallWowApi()
  sharedInstallWowApi()
  installClient()
end

---Reset, install the host stubs and a fresh range world, load the chain.
---@return table RangeKit
---@return table Registry
function RangeKitTestEnv.NewPackage()
  newWorld()
  return sharedNewPackage()
end

---Install the range world's client calls again after a spec removed some.
function RangeKitTestEnv.InstallClient()
  installClient()
end

---Make the player's class file name `classFile`.
---@param classFile string?
function RangeKitTestEnv.SetClass(classFile)
  world.class = classFile
end

---Give `spellID` a reach. `answer` makes `IsSpellInRange` answer it always.
---@param spellID integer
---@param maxRange number
---@param minRange number?
---@param answer any?
function RangeKitTestEnv.DefineSpell(spellID, maxRange, minRange, answer)
  world.spells[spellID] = { maxRange = maxRange, minRange = minRange or 0, answer = answer }
end

---Put `spellID` in the player's spellbook, with a reach when given.
---@param spellID integer
---@param maxRange number?
---@param minRange number?
function RangeKitTestEnv.Learn(spellID, maxRange, minRange)
  if maxRange ~= nil then
    RangeKitTestEnv.DefineSpell(spellID, maxRange, minRange)
  end
  world.known[spellID] = true
end

---Take `spellID` out of the player's spellbook.
---@param spellID integer
function RangeKitTestEnv.Forget(spellID)
  world.known[spellID] = nil
end

---Put `unit` at `yards` from the player.
---@param unit string
---@param yards number
---@param relation "hostile"|"friendly"|"dead"|"deadHostile"|"neutral"
---@param isPet boolean?
function RangeKitTestEnv.PlaceUnit(unit, yards, relation, isPet)
  world.units[unit] = { yards = yards, relation = relation, isPet = isPet }
end

---Take `unit` away.
---@param unit string
function RangeKitTestEnv.RemoveUnit(unit)
  world.units[unit] = nil
end

---Enter or leave combat lockdown.
---@param combat boolean
function RangeKitTestEnv.SetCombat(combat)
  world.combat = combat
end

---How many range checks the client answered since the last call.
---@return integer
function RangeKitTestEnv.CheckCount()
  local count = world.checks
  world.checks = 0
  return count
end

---The sources of `kind`'s checkers, shortest first.
---@param RangeKit table
---@param kind string
---@return string[]
function RangeKitTestEnv.Sources(RangeKit, kind)
  local sources = {}
  for index, checker in ipairs(RangeKit:DescribeCheckers(kind)) do
    sources[index] = checker.source
  end
  return sources
end

---The values the host error handler received since the last call.
---@return any[]
function RangeKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(RangeKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function RangeKitTestEnv.InstallSecretProbe()
  RangeKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function RangeKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Clear everything the shared fixture clears, plus the range world's globals.
function RangeKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    RangeKitTestEnv.SetGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Load the RangeKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table RangeKit
function RangeKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "RangeKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("RangeKitTestEnv.LoadRevision could not find RangeKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("RangeKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return RangeKitTestEnv

--- Saved settings: SettingsKit (with SchemaKit) against AceDB-3.0.
---
--- Both sides describe the same settings: eight profile fields with the same
--- defaults, a nested frame record, and a keyed section of auras whose entries
--- default through a wildcard (`S.map` values with a default on the Kit side,
--- `["**"]` on the AceDB side). The populated saved variable is the same table
--- shape for both, because SettingsKit's layout (`profiles`, `profileKeys`,
--- `global`) is AceDB's.
---
--- What differs, and is reported as a difference rather than hidden:
---
--- - **Writes.** A SettingsKit write is validated against the schema at the
---   writer's line and fires the scope's change signal; an AceDB write is a
---   plain table store. The write rows are marked not equivalent: their gap is
---   the price of validation and change notification, not of storage.
--- - **Profile switch.** AceDB strips values equal to their defaults from the
---   old profile on every switch; SettingsKit leaves that to its logout
---   compaction. Each side does what it does on a switch, so the row compares
---   the switch a user of each library pays for.
--- - `validate` has no AceDB counterpart and is reported for SettingsKit alone.

local Bench = require("Bench")

local Settings = {}

--- Profiles and aura entries in the populated saved variable.
local PROFILES = 20
local AURAS_PER_PROFILE = 20
local CHARACTERS = 50

--- The one aura key every "entry" case reads or writes.
local AURA = 118

---A populated saved variable, the same for both sides.
---@return table
local function populatedSavedVariable()
  local profiles, profileKeys = {}, {}
  for profileIndex = 1, PROFILES do
    local auras = {}
    for auraIndex = 1, AURAS_PER_PROFILE do
      auras[1000 + auraIndex] = { shown = false, color = { 0.5, 0.5, 0.5 } }
    end
    profiles["Profile " .. profileIndex] = {
      scale = 1.5,
      anchor = "TOP",
      frame = { x = profileIndex, y = -profileIndex },
      auras = auras,
    }
  end
  profiles.Alpha = { scale = 1.5 }
  profiles.Beta = { scale = 0.75 }
  for characterIndex = 1, CHARACTERS do
    profileKeys["Character" .. characterIndex .. " - Silvermoon"] = "Profile "
      .. (characterIndex % PROFILES + 1)
  end
  profileKeys["Tester - Silvermoon"] = "Alpha"
  return { global = { installs = 3 }, profiles = profiles, profileKeys = profileKeys }
end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded =
    host.RequireAll({ "Registry", "SignalKit", "EventKit", "SchemaKit", "SettingsKit" })
  local SchemaKit, SettingsKit = loaded[4], loaded[5]
  local S = SchemaKit

  local aura = S.table({
    fields = {
      shown = S.optional(S.boolean(), true),
      color = S.optional(
        S.array({ of = S.number({ min = 0, max = 1 }), min = 3, max = 4 }),
        { 1, 1, 1 }
      ),
      sound = S.optional(S.string({ max = 64 })),
    },
  })
  local schema = {
    global = S.table({
      fields = { installs = S.optional(S.number({ integer = true, min = 0 }), 0) },
    }),
    profile = S.table({
      fields = {
        scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
        alpha = S.optional(S.number({ min = 0, max = 1 }), 1),
        locked = S.optional(S.boolean(), false),
        anchor = S.optional(S.enum({ "TOP", "CENTER", "BOTTOM" }), "CENTER"),
        font = S.optional(S.string({ max = 64 }), "Friz Quadrata TT"),
        fontSize = S.optional(S.number({ integer = true, min = 6, max = 32 }), 12),
        frame = S.optional(
          S.table({
            fields = {
              x = S.optional(S.number(), 0),
              y = S.optional(S.number(), 0),
              width = S.optional(S.number({ min = 1 }), 200),
              height = S.optional(S.number({ min = 1 }), 40),
            },
          }),
          {}
        ),
        auras = S.optional(
          S.map({
            keys = S.number({ integer = true, min = 1 }),
            values = S.optional(aura, {}),
            max = 256,
          }),
          {}
        ),
      },
    }),
  }

  local adapter = {}

  function adapter.open(name)
    return SettingsKit:Open(name, schema, { defaultProfile = "Default" })
  end

  function adapter.setProfile(db, name)
    db:SetProfile(name)
  end

  function adapter.validate(db, path, value)
    return db:Validate("profile", path, value)
  end

  return adapter,
    {
      { name = "SettingsKit", revision = SettingsKit.REVISION },
      { name = "SchemaKit", revision = SchemaKit.REVISION },
      { name = "SignalKit", revision = loaded[2].REVISION },
      { name = "EventKit", revision = loaded[3].REVISION },
    }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, {
    "LibStub/LibStub.lua",
    "CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "AceDB-3.0/AceDB-3.0.lua",
  })
  local LibStub = host.Global("LibStub")
  local AceDB, minor = LibStub:GetLibrary("AceDB-3.0")
  local _, callbackHandlerMinor = LibStub:GetLibrary("CallbackHandler-1.0")

  local defaults = {
    global = { installs = 0 },
    profile = {
      scale = 1,
      alpha = 1,
      locked = false,
      anchor = "CENTER",
      font = "Friz Quadrata TT",
      fontSize = 12,
      frame = { x = 0, y = 0, width = 200, height = 40 },
      auras = { ["**"] = { shown = true, color = { 1, 1, 1 } } },
    },
  }

  local adapter = {}

  function adapter.open(name)
    return AceDB:New(name, defaults, "Default")
  end

  function adapter.setProfile(db, name)
    db:SetProfile(name)
  end

  return adapter,
    {
      { name = "AceDB-3.0", minor = minor },
      { name = "CallbackHandler-1.0", minor = callbackHandlerMinor },
    }
end

--- A counter for saved-variable names, so every `Open` in a process opens a
--- database it has not opened before (both libraries return or reuse the
--- database of a name already open).
local nextName = 0

---@return string
local function freshName()
  nextName = nextName + 1
  return "BenchSettingsDB" .. nextName
end

---@param name string
---@param value any
local function setGlobal(name, value)
  -- A saved variable is a global, as the client loads it.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Open a populated database on the "Alpha" profile.
---@param adapter table
---@return table db
local function openPopulated(adapter)
  local name = freshName()
  setGlobal(name, populatedSavedVariable())
  return adapter.open(name)
end

---@param adapter table
---@return Bench.Case[]
local function cases(adapter)
  local list = {}

  list[#list + 1] = {
    name = "open-empty",
    iterations = 2000,
    operation = "open a database over a new, empty saved variable",
    prepare = function()
      return {
        run = function(iterations)
          for _ = 1, iterations do
            adapter.open(freshName())
          end
        end,
      }
    end,
  }

  list[#list + 1] = {
    name = "open-populated",
    iterations = 200,
    operation = "open a database over a saved variable with 22 profiles and 50 characters",
    prepare = function()
      local names = {}
      return {
        beforeBatch = function(iterations)
          for index = 1, iterations do
            names[index] = freshName()
            setGlobal(names[index], populatedSavedVariable())
          end
        end,
        run = function(iterations)
          for index = 1, iterations do
            local db = adapter.open(names[index])
            local _ = db.profile.scale
          end
        end,
        -- The heap one open database holds beyond its saved variable.
        metrics = function()
          local name = freshName()
          setGlobal(name, populatedSavedVariable())
          local baseline = Bench.RetainedBytes()
          -- Held in a table that outlives the measurement, so the collector
          -- cannot free the database before it is counted.
          local keep = { adapter.open(name) }
          local _ = keep[1].profile.scale
          local retained = Bench.RetainedBytes() - baseline
          return { retainedBytesPerOpenDatabase = retained, databasesHeld = #keep }
        end,
      }
    end,
  }

  ---A case over one populated database opened once.
  ---@param name string
  ---@param operation string
  ---@param iterations integer
  ---@param body fun(db: table, iterations: integer)
  ---@param options table?
  local function onDatabase(name, operation, iterations, body, options)
    local case = {
      name = name,
      iterations = iterations,
      operation = operation,
      prepare = function()
        local db = openPopulated(adapter)
        return {
          run = function(count)
            body(db, count)
          end,
        }
      end,
    }
    for key, value in pairs(options or {}) do
      case[key] = value
    end
    list[#list + 1] = case
  end

  onDatabase(
    "switch-profile",
    "switch between two existing profiles and read one value",
    5000,
    function(db, count)
      for index = 1, count do
        adapter.setProfile(db, index % 2 == 0 and "Alpha" or "Beta")
        local _ = db.profile.scale
      end
    end,
    {
      note = "AceDB also strips default-equal values from the old profile on every switch",
    }
  )

  onDatabase(
    "read-default",
    "read a profile value nothing was saved for",
    200000,
    function(db, count)
      local profile = db.profile
      for _ = 1, count do
        local _ = profile.fontSize
      end
    end
  )

  onDatabase("read-saved", "read a saved profile value", 200000, function(db, count)
    local profile = db.profile
    for _ = 1, count do
      local _ = profile.scale
    end
  end)

  onDatabase(
    "read-nested",
    "read a nested record value (profile.frame.x)",
    200000,
    function(db, count)
      local profile = db.profile
      for _ = 1, count do
        local _ = profile.frame.x
      end
    end
  )

  onDatabase(
    "read-entry-default",
    "read a field of an unsaved keyed entry (profile.auras[118].shown)",
    200000,
    function(db, count)
      local profile = db.profile
      for _ = 1, count do
        local _ = profile.auras[AURA].shown
      end
    end
  )

  onDatabase("write-scalar", "write a profile number (profile.scale)", 100000, function(db, count)
    local profile = db.profile
    for index = 1, count do
      profile.scale = index % 2 == 0 and 1.25 or 1.5
    end
  end, {
    equivalent = false,
    note = "SettingsKit validates the value and fires its change signal; AceDB stores it unchecked",
  })

  onDatabase(
    "write-nested",
    "write a nested record value (profile.frame.x)",
    100000,
    function(db, count)
      local frame = db.profile.frame
      for index = 1, count do
        frame.x = index % 100
      end
    end,
    {
      equivalent = false,
      note = "SettingsKit validates the value and fires its change signal; AceDB stores it unchecked",
    }
  )

  if adapter.validate ~= nil then
    local path = { "frame", "x" }
    onDatabase(
      "validate",
      "check a write without writing it (db:Validate)",
      100000,
      function(db, count)
        for index = 1, count do
          adapter.validate(db, path, index % 100)
        end
      end,
      { equivalent = false, note = "SettingsKit only: AceDB has no validation" }
    )
  end

  return list
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Settings.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end

  local function checks()
    local results = {}
    local function check(name, passed, detail, promised)
      results[#results + 1] =
        { name = name, passed = passed, detail = detail, promised = promised ~= false }
    end

    local db = openPopulated(adapter)
    local profile = db.profile
    check("reads-default", profile.fontSize == 12, "fontSize: " .. tostring(profile.fontSize))
    check("reads-saved", profile.scale == 1.5, "scale on Alpha: " .. tostring(profile.scale))
    check(
      "reads-entry-wildcard",
      profile.auras[AURA].shown == true,
      "auras[" .. AURA .. "].shown: " .. tostring(profile.auras[AURA].shown)
    )

    profile.frame.x = 42
    adapter.setProfile(db, "Beta")
    local betaScale, betaX = db.profile.scale, db.profile.frame.x
    adapter.setProfile(db, "Alpha")
    check(
      "profiles-are-separate",
      betaScale == 0.75 and betaX == 0 and db.profile.frame.x == 42,
      "Beta scale "
        .. tostring(betaScale)
        .. ", Beta frame.x "
        .. tostring(betaX)
        .. ", Alpha frame.x "
        .. tostring(db.profile.frame.x)
    )

    local refused = not pcall(function()
      db.profile.scale = "large"
    end)
    check(
      "refuses-invalid-write",
      refused,
      "writing a string to a number field " .. (refused and "raised" or "was stored"),
      side == "moltencodes"
    )
    return results
  end

  return { libraries = libraries, cases = cases(adapter), checks = checks }
end

return Settings

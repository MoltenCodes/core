--- Opening a database the client restored from disk (client only).
---
--- The most common startup path of a real addon: at `ADDON_LOADED` the
--- client has restored its saved variables, and the addon opens its database
--- over them. The host cannot measure the client's saved-variables loader, so
--- this workload uses two sessions per size:
---
--- - `write-<profiles>x<keys>` builds a database of that many profiles of that
---   many keys through the side's own library (AceDB-3.0 profiles, or
---   SettingsKit profiles with the same values) into the side addon's saved
---   variable; the following `/reload` writes it to disk;
--- - `read-<profiles>x<keys>`, in the next session, loads the side addon
---   (`LoadAddOn` includes the client restoring the table) and opens the
---   database over what was restored, timing the two apart, and reads the
---   addon's memory after a full collection.
---
--- The harness queues a read right after its write, so a read without a
--- write before it in the same queue is refused rather than measuring an
--- empty table. The side addons (`MoltenCodesBench_KitsSaved` and
--- `MoltenCodesBench_Ace3Saved`) each declare one saved variable.

local SavedVariables = {}

--- The sizes, as `{ profiles, keys }`.
local SIZES = { { 1, 200 }, { 20, 200 } }

--- The saved variable each side's saved-variables addon declares.
local VARIABLES = {
  moltencodes = "MoltenCodesBenchKitsSavedDB",
  ace3 = "MoltenCodesBenchAce3SavedDB",
}

---The defaults AceDB opens the database with: `keys` numbered values of 0.
---@param keys integer
---@return table
local function aceDefaults(keys)
  local values = {}
  for index = 1, keys do
    values["key" .. index] = 0
  end
  return values
end

---The same profile as a SchemaKit schema: `keys` numbers defaulting to 0.
---@param SchemaKit table
---@param keys integer
---@return table
local function kitSchema(SchemaKit, keys)
  local fields = {}
  for index = 1, keys do
    fields["key" .. index] = SchemaKit.optional(SchemaKit.number(), 0)
  end
  return { profile = SchemaKit.table({ fields = fields }) }
end

---Open the database of `side` over its saved variable.
---@param side string
---@param host table
---@param keys integer
---@return fun(profile: string) switch, fun(key: string, value: any) write
local function open(side, host, keys)
  local variable = VARIABLES[side]
  local database
  if side == "ace3" then
    local AceDB = host.Global("LibStub")("AceDB-3.0")
    database = AceDB:New(variable, { profile = aceDefaults(keys) }, true)
  else
    -- The saved set carries SettingsKit and what it requires, not EventKit.
    local loaded = host.RequireAll({ "Registry", "SchemaKit", "SettingsKit" })
    local SchemaKit, SettingsKit = loaded[2], loaded[3]
    database =
      SettingsKit:Open(variable, kitSchema(SchemaKit, keys), { defaultProfile = "Default" })
  end
  return function(profile)
    database:SetProfile(profile)
  end, function(key, value)
    database.profile[key] = value
  end
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table the client host
---@return table suite `{ cases, checks, libraries }`
function SavedVariables.Build(side, host)
  local clock = host.Global("debugprofilestop")
  local addOns = host.Global("C_AddOns")
  local addon = host.SetAddon("saved")
  local cases = {}
  for _, size in ipairs(SIZES) do
    local profiles, keys = size[1], size[2]
    local label = profiles .. "x" .. keys
    cases[#cases + 1] = {
      name = "write-" .. label,
      kind = "frames",
      operation = "write " .. profiles .. " profiles of " .. keys .. " keys for the next session",
      prepare = function()
        return {
          maximumSeconds = 2,
          start = function()
            addOns.LoadAddOn(addon)
            local switch, write = open(side, host, keys)
            for profile = 1, profiles do
              switch("profile" .. profile)
              for index = 1, keys do
                write("key" .. index, profile * 1000 + index)
              end
            end
          end,
          frame = function()
            return true
          end,
          finish = function()
            return { written = profiles * keys }
          end,
        }
      end,
    }
    cases[#cases + 1] = {
      name = "read-" .. label,
      kind = "frames",
      operation = "open " .. profiles .. " restored profiles of " .. keys .. " keys",
      prepare = function()
        local measured = {}
        return {
          maximumSeconds = 2,
          start = function()
            local started = clock()
            addOns.LoadAddOn(addon)
            measured.loadMilliseconds = clock() - started
            if type(host.Global(VARIABLES[side])) ~= "table" then
              error("nothing was restored: run write-" .. label .. " in the session before", 0)
            end
            started = clock()
            local switch = open(side, host, keys)
            switch("profile" .. profiles)
            measured.openMilliseconds = clock() - started
          end,
          frame = function()
            return true
          end,
          finish = function()
            collectgarbage("collect")
            host.Global("UpdateAddOnMemoryUsage")()
            measured.kilobytes = host.Global("GetAddOnMemoryUsage")(addon)
            return measured
          end,
        }
      end,
    }
  end
  return {
    libraries = {},
    cases = cases,
    checks = function()
      return {}
    end,
  }
end

return SavedVariables

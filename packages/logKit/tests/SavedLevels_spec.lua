local Env = require("LogKitTestEnv")

-- The saved level section stays LogKit's to read back (implementation
-- revision 4): `"*"` is the global level and never an addon name, a typed
-- name that is neither a logger nor an installed addon is not saved, and
-- `/log show` and `/log clear` list and remove what is saved.

local SAVED_VARIABLE = "LogKitSavedLevelsDB"

---Open a database whose global scope declares `logLevels` as documented.
---@param SettingsKit table
---@param S table SchemaKit
---@param maxEntries integer?
---@return table db
local function openDatabase(SettingsKit, S, maxEntries)
  return SettingsKit:Open(SAVED_VARIABLE, {
    global = S.table({
      fields = {
        logLevels = S.optional(
          S.map({ keys = S.string(), values = S.string(), max = maxEntries or 64 }),
          {}
        ),
      },
    }),
  })
end

---The saved `logLevels` section as a plain table.
---@return table<string, any>
local function savedLevels()
  -- selene: allow(global_usage)
  local raw = rawget(_G, SAVED_VARIABLE)
  return raw.global and raw.global.logLevels or {}
end

describe("LogKit addon names", function()
  local LogKit

  before_each(function()
    LogKit = Env.NewPackage()
    Env.SavedVariable(SAVED_VARIABLE)
  end)
  after_each(function()
    Env.Reset()
  end)

  it(
    "refuses * as an addon name at the caller, so it never overwrites the saved global level",
    function()
      local SettingsKit, S = Env.LoadSettingsKit()
      local db = openDatabase(SettingsKit, S)
      LogKit:BindLevels(db)
      LogKit:SetGlobalLevel("error")

      Env.expectErrorContaining(
        'LogKit:ForAddon addonName must not be "*", which names the global level',
        function()
          LogKit:ForAddon("*")
        end
      )
      Env.expectErrorContaining(
        'LogKit:History addonName must not be "*", which names the global level',
        function()
          LogKit:History("*")
        end
      )
      assert.is_nil(LogKit._state.loggers["*"])
      assert.are.equal("error", savedLevels()["*"])

      -- The next session restores the global level it saved.
      LogKit:BindLevels(nil)
      LogKit:SetGlobalLevel(nil)
      LogKit:BindLevels(db)
      assert.are.equal("error", LogKit:GetGlobalLevel())
    end
  )
end)

describe("LogKit saved levels from the slash command", function()
  local LogKit
  local db

  before_each(function()
    LogKit = Env.NewPackage()
    Env.InstallChatApi()
    Env.SavedVariable(SAVED_VARIABLE)
    Env.LoadCommandKit()
    local SettingsKit, S = Env.LoadSettingsKit()
    db = openDatabase(SettingsKit, S)
    LogKit:BindLevels(db)
    assert.is_true(LogKit:RegisterCommand())
  end)
  after_each(function()
    Env.Reset()
  end)

  it("refuses a level for a name that is neither a logger nor an installed addon", function()
    Env.InstallAddOns({ "Installed" })
    LogKit:ForAddon("Library")
    Env.RunSlash("/log Typo debug")
    Env.RunSlash("/log Installed debug")
    Env.RunSlash("/log Library info")
    assert.are.same({
      '/log: no logger or installed addon is named "Typo"; nothing was set',
      "Installed: debug (addon)",
      "Library: info (addon)",
    }, Env.ChatLines())
    assert.is_nil(LogKit._state.addonLevels.Typo)
    assert.is_nil(savedLevels().Typo)
    assert.are.equal("debug", savedLevels().Installed)
    assert.are.equal("info", savedLevels().Library)
  end)

  it("accepts any name when the client cannot tell which addons are installed", function()
    Env.RunSlash("/log Unchecked debug")
    -- selene: allow(global_usage)
    local addOns = rawget(_G, "C_AddOns")
    function addOns.DoesAddOnExist()
      error("no such index")
    end
    Env.RunSlash("/log Raising info")
    function addOns.DoesAddOnExist()
      return 1
    end
    Env.RunSlash("/log NotBoolean warn")
    Env.InstallSecretProbe(false)
    function addOns.DoesAddOnExist()
      return false
    end
    Env.RunSlash("/log Secret error")
    assert.are.same({
      "Unchecked: debug (addon)",
      "Raising: info (addon)",
      "NotBoolean: warn (addon)",
      "Secret: error (addon)",
    }, Env.ChatLines())
  end)

  it(
    "lists the levels of names without a logger with /log show, and /log show * the global level",
    function()
      db.global.logLevels.Removed = "trace"
      LogKit:BindLevels(db)
      LogKit:ForAddon("Alpha")
      LogKit:SetGlobalLevel("error")
      Env.RunSlash("/log Later debug")
      Env.RunSlash("/log show")
      Env.RunSlash("/log show *")
      assert.are.same({
        "Later: debug (addon)",
        "global: error",
        "Alpha: error (global)",
        "Later: debug (addon, no logger)",
        "Removed: trace (addon, no logger)",
        "global: error",
      }, Env.ChatLines())
    end
  )

  it("clears one saved level with /log clear <addon>, even one no logger or addon has", function()
    db.global.logLevels.Removed = "trace"
    db.global.logLevels.Unreadable = "verbose"
    LogKit:BindLevels(db)
    Env.InstallAddOns({})
    Env.RunSlash("/log clear Removed")
    Env.RunSlash("/log clear Unreadable")
    assert.are.same({ "Removed: warn (default)", "Unreadable: warn (default)" }, Env.ChatLines())
    assert.is_nil(LogKit._state.addonLevels.Removed)
    assert.is_nil(savedLevels().Removed)
    assert.is_nil(savedLevels().Unreadable)
  end)

  it(
    "clears every addon level, saved ones included, with /log clear, and the global one with *",
    function()
      db.global.logLevels.Removed = "trace"
      db.global.logLevels.Unreadable = "verbose"
      LogKit:BindLevels(db)
      local logger = LogKit:ForAddon("Alpha")
      logger:SetLevel("debug")
      LogKit:SetGlobalLevel("info")

      Env.RunSlash("/log clear")
      assert.are.same({ "cleared 3 addon levels" }, Env.ChatLines())
      assert.are.same({ ["*"] = "info" }, savedLevels())
      assert.are.same({ "info", "global" }, { logger:GetLevel() })

      Env.RunSlash("/log clear *")
      assert.is_nil(LogKit:GetGlobalLevel())
      assert.are.same({}, savedLevels())
      assert.are.same({ "warn", "default" }, { logger:GetLevel() })
    end
  )

  it(
    "keeps room in a full section: a refused typo writes nothing, and /log clear frees it",
    function()
      Env.Reset()
      LogKit = Env.NewPackage()
      Env.InstallChatApi()
      Env.SavedVariable(SAVED_VARIABLE)
      Env.LoadCommandKit()
      local SettingsKit, S = Env.LoadSettingsKit()
      db = openDatabase(SettingsKit, S, 2)
      LogKit:BindLevels(db)
      assert.is_true(LogKit:RegisterCommand())
      Env.InstallAddOns({ "Old", "Gone", "Real" })
      Env.RunSlash("/log Old debug")
      Env.RunSlash("/log Gone debug")
      Env.InstallAddOns({ "Real" })
      Env.RunSlash("/log Typo debug")
      assert.is_nil(savedLevels().Typo)

      Env.RunSlash("/log clear Gone")
      LogKit:ForAddon("Real"):SetLevel("trace")
      assert.are.equal("trace", savedLevels().Real)
      assert.are.equal("debug", savedLevels().Old)
    end
  )

  it("routes /log clear through the top-level handler of a /log registered without it", function()
    -- A `/log` a revision 3 copy registered has no `clear` sub-command, and
    -- CommandKit then hands `clear` to the top-level handler as the addon.
    LogKit:ForAddon("Alpha"):SetLevel("debug")
    local lines = {}
    local context = {
      Print = function(_, text)
        lines[#lines + 1] = text
      end,
      Usage = function()
        lines[#lines + 1] = "usage"
      end,
      Fail = function(_, reason)
        lines[#lines + 1] = reason
      end,
    }
    local dispatch = LogKit._state.dispatch
    dispatch.commandSetLevel(context, "Clear", "Alpha")
    dispatch.commandSetLevel(context, "clear", nil)
    assert.are.same({ "Alpha: warn (default)", "cleared 0 addon levels" }, lines)
  end)
end)

--- Options tables: OptionsKit against AceConfigRegistry-3.0, AceConfigCmd-3.0
--- and AceDBOptions-3.0.
---
--- Both sides describe the same options: groups of a header, a toggle, a
--- range, a select, an input, a colour, a multiselect, a button and a
--- description, each value option with its own `get` and `set` over one plain
--- table. The tables differ only where the two formats do: an AceConfig colour
--- is read and written as `r, g, b, a` and a multiselect one key at a time,
--- where OptionsKit uses one table value.
---
--- The same work:
---
--- - **Define** (`define-50`, `define-200`): make an options table available
---   and checked, then drop it. `OptionsKit:Define` checks, copies and indexes
---   the tree and builds one schema per value option; `OptionsKit:Undefine`
---   drops it. AceConfigRegistry checks a table the first time a UI asks for it,
---   so the Ace side is `RegisterOptionsTable` and `GetOptionsTable(name,
---   "dialog", ...)`, which runs `ValidateOptionsTable`, and then clears the
---   registry's "already validated" mark (AceConfigRegistry has no
---   unregistration; registering the name again replaces the table).
--- - **Command line** (`cmd-*`): a typed slash command that changes one option,
---   dispatched through the function under its `SlashCmdList` key. CommandKit's
---   `BindOptions` (`/cmd set g1.scale 1.25`) against AceConfigCmd's
---   `CreateChatCommand` (`/cmd g1 scale 1.25`). Both parse the line, find the
---   option, convert the text for the option's kind, check it and call `set`.
---   CommandKit also echoes `path = value` to the chat frame and describes
---   the named option once per command; AceConfigCmd prints nothing on
---   success.
--- - **Profile options** (`profile-*`): the ready-made profile group over a
---   database, `OptionsKit:ProfileOptions(db)` over SettingsKit against
---   `AceDBOptions:GetOptionsTable(db)` over AceDB-3.0, built, and used from the
---   command line to choose a profile.
---
--- One side only: `tree-get` and `tree-set`. AceConfigRegistry keeps tables and
--- has no call that reads or writes an option through the table; an Ace3 addon
--- calls its own getter and setter. They are measured for OptionsKit alone.
---
--- Left out: AceConfigDialog-3.0, which needs real frames; a dialog is the
--- in-client runner's.

local Options = {}

--- Operations per timed batch.
local DEFINE_ITERATIONS = { [50] = 200, [200] = 50 }
local COMMAND_ITERATIONS = 2000
local TREE_ITERATIONS = 20000
local PROFILE_ITERATIONS = 1000

--- The addon name every tree is defined or registered under.
local APP = "BenchOptions"
local PROFILE_APP = "BenchProfiles"

--- The option kinds of one group, in order.
local SELECT_VALUES = { TOP = "Top", CENTER = "Centre", BOTTOM = "Bottom" }
local CHANNEL_VALUES = { SAY = "Say", PARTY = "Party", RAID = "Raid", GUILD = "Guild" }

---@param name string
---@param value any
local function setGlobal(name, value)
  -- A saved variable is a global, as the client loads it.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---@param name string
---@return any
local function getGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---The function the client would call for `/name`.
---@param name string
---@return function?
local function slashFunction(name)
  local wanted = "/" .. name:lower()
  for key, handler in pairs(getGlobal("SlashCmdList")) do
    local slash = getGlobal("SLASH_" .. key .. "1")
    if type(slash) == "string" and slash:lower() == wanted then
      return handler
    end
  end
  return nil
end

---Build an options table of `groups` groups of ten options (the group and
---nine children), for one side's format, over `store`.
---@param groups integer
---@param side string
---@param store table values by `group.key`
---@return table tree
local function buildTree(groups, side, store)
  local ace = side == "ace3"
  local args = {}
  for groupIndex = 1, groups do
    local prefix = "g" .. groupIndex .. "."
    local function plain(key)
      local path = prefix .. key
      return function()
        return store[path]
      end, function(_, value)
        store[path] = value
      end
    end

    local toggleGet, toggleSet = plain("enabled")
    local rangeGet, rangeSet = plain("scale")
    local selectGet, selectSet = plain("anchor")
    local inputGet, inputSet = plain("label")
    store[prefix .. "enabled"] = true
    store[prefix .. "scale"] = 1
    store[prefix .. "anchor"] = "CENTER"
    store[prefix .. "label"] = ""
    store[prefix .. "color"] = { r = 1, g = 1, b = 1 }
    store[prefix .. "channels"] = {}

    local colorGet, colorSet, channelsGet, channelsSet
    if ace then
      colorGet = function()
        local color = store[prefix .. "color"]
        return color.r, color.g, color.b
      end
      colorSet = function(_, r, g, b)
        store[prefix .. "color"] = { r = r, g = g, b = b }
      end
      channelsGet = function(_, key)
        return store[prefix .. "channels"][key] == true
      end
      channelsSet = function(_, key, state)
        store[prefix .. "channels"][key] = state
      end
    else
      colorGet, colorSet = plain("color")
      channelsGet, channelsSet = plain("channels")
    end

    args["g" .. groupIndex] = {
      type = "group",
      name = "Group " .. groupIndex,
      order = groupIndex,
      args = {
        heading = { type = "header", name = "Heading", order = 1 },
        enabled = {
          type = "toggle",
          name = "Enabled",
          desc = "Turn the group on.",
          order = 2,
          get = toggleGet,
          set = toggleSet,
        },
        scale = {
          type = "range",
          name = "Scale",
          order = 3,
          min = 0.5,
          max = 2,
          get = rangeGet,
          set = rangeSet,
        },
        anchor = {
          type = "select",
          name = "Anchor",
          order = 4,
          values = SELECT_VALUES,
          get = selectGet,
          set = selectSet,
        },
        label = {
          type = "input",
          name = "Label",
          order = 5,
          pattern = "^[%w ]*$",
          get = inputGet,
          set = inputSet,
        },
        color = { type = "color", name = "Colour", order = 6, get = colorGet, set = colorSet },
        channels = {
          type = "multiselect",
          name = "Announce in",
          order = 7,
          values = CHANNEL_VALUES,
          get = channelsGet,
          set = channelsSet,
        },
        reset = { type = "execute", name = "Reset", order = 8, func = function() end },
        note = { type = "description", name = "Settings of this group.", order = 9 },
      },
    }
  end
  return { type = "group", name = "Bench options", args = args }
end

---The profile schema and defaults both databases use.
---@param SchemaKit table
---@return table
local function kitProfileSchema(SchemaKit)
  local S = SchemaKit
  return {
    profile = S.table({
      fields = {
        scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
        locked = S.optional(S.boolean(), false),
      },
    }),
  }
end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({
    "Registry",
    "SignalKit",
    "EventKit",
    "SchemaKit",
    "SettingsKit",
    "OptionsKit",
    "CommandKit",
  })
  local SchemaKit, SettingsKit, OptionsKit, CommandKit = loaded[4], loaded[5], loaded[6], loaded[7]
  local scope = CommandKit:CreateScope()
  local adapter = {}

  function adapter.define(name, tree)
    return OptionsKit:Define(name, tree)
  end

  function adapter.forget(name)
    OptionsKit:Undefine(name)
  end

  ---Define `tree` and give it the slash command `/command`.
  function adapter.bindCommand(name, tree, command)
    scope:BindOptions(OptionsKit:Define(name, tree), command)
  end

  ---The text after `/command` that sets `group.key` to `value`.
  function adapter.setLine(group, key, value)
    return "set " .. group .. "." .. key .. " " .. value
  end

  function adapter.openDatabase(name)
    return SettingsKit:Open(name, kitProfileSchema(SchemaKit), { defaultProfile = "Default" })
  end

  function adapter.profileGroup(db)
    return OptionsKit:ProfileOptions(db)
  end

  function adapter.currentProfile(db)
    return db:GetProfile()
  end

  ---The line that chooses profile `name` through the profile group.
  function adapter.chooseProfileLine(name)
    return "set profiles.current " .. name
  end

  return adapter,
    {
      { name = "OptionsKit", revision = OptionsKit.REVISION },
      { name = "CommandKit", revision = CommandKit.REVISION },
      { name = "SchemaKit", revision = SchemaKit.REVISION },
      { name = "SettingsKit", revision = SettingsKit.REVISION },
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
    "AceConsole-3.0/AceConsole-3.0.lua",
    "AceDB-3.0/AceDB-3.0.lua",
    "AceDBOptions-3.0/AceDBOptions-3.0.lua",
    "AceConfig-3.0/AceConfigRegistry-3.0/AceConfigRegistry-3.0.lua",
    "AceConfig-3.0/AceConfigCmd-3.0/AceConfigCmd-3.0.lua",
  })
  local LibStub = host.Global("LibStub")
  local AceConfigRegistry, registryMinor = LibStub:GetLibrary("AceConfigRegistry-3.0")
  local AceConfigCmd, commandMinor = LibStub:GetLibrary("AceConfigCmd-3.0")
  local AceDB, databaseMinor = LibStub:GetLibrary("AceDB-3.0")
  local AceDBOptions, databaseOptionsMinor = LibStub:GetLibrary("AceDBOptions-3.0")
  local _, consoleMinor = LibStub:GetLibrary("AceConsole-3.0")
  local _, callbackHandlerMinor = LibStub:GetLibrary("CallbackHandler-1.0")
  local validated = AceConfigRegistry.validated.dialog
  local adapter = {}

  function adapter.define(name, tree)
    AceConfigRegistry:RegisterOptionsTable(name, tree)
    return AceConfigRegistry:GetOptionsTable(name, "dialog", "Bench-1.0")
  end

  function adapter.forget(name)
    validated[name] = nil
  end

  function adapter.bindCommand(name, tree, command)
    AceConfigRegistry:RegisterOptionsTable(name, tree)
    AceConfigCmd:CreateChatCommand(command, name)
  end

  function adapter.setLine(group, key, value)
    return group .. " " .. key .. " " .. value
  end

  function adapter.openDatabase(name)
    return AceDB:New(name, { profile = { scale = 1, locked = false } }, "Default")
  end

  function adapter.profileGroup(db)
    return AceDBOptions:GetOptionsTable(db)
  end

  function adapter.currentProfile(db)
    return db:GetCurrentProfile()
  end

  function adapter.chooseProfileLine(name)
    return "profiles choose " .. name
  end

  return adapter,
    {
      { name = "AceConfigRegistry-3.0", minor = registryMinor },
      { name = "AceConfigCmd-3.0", minor = commandMinor },
      { name = "AceConsole-3.0", minor = consoleMinor },
      { name = "AceDBOptions-3.0", minor = databaseOptionsMinor },
      { name = "AceDB-3.0", minor = databaseMinor },
      { name = "CallbackHandler-1.0", minor = callbackHandlerMinor },
    }
end

--- Saved-variable names, so no case opens a database twice.
local nextDatabase = 0

---Open a database with the profiles Alpha and Beta, on Alpha.
---@param adapter table
---@return table db
local function openProfiles(adapter)
  nextDatabase = nextDatabase + 1
  local name = "BenchOptionsDB" .. nextDatabase
  setGlobal(name, {
    profiles = { Default = {}, Alpha = { scale = 1.5 }, Beta = { scale = 0.75 } },
    profileKeys = { ["Tester - Silvermoon"] = "Alpha" },
  })
  return adapter.openDatabase(name)
end

--- The note of the command-line cases that succeed.
local ECHO_NOTE =
  "CommandKit echoes the new value and describes the named option once per command; AceConfigCmd prints nothing"

---@param adapter table
---@param side string
---@param host table
---@return Bench.Case[]
local function cases(adapter, side, host)
  local list = {}

  for _, groups in ipairs({ 5, 20 }) do
    local size = groups * 10
    list[#list + 1] = {
      name = "define-" .. size,
      iterations = DEFINE_ITERATIONS[size],
      operation = "define and check a " .. size .. "-option table, then drop it",
      note = "Ace3 checks on the first GetOptionsTable; OptionsKit also copies, indexes and builds schemas, shared per kind and inputs",
      prepare = function()
        local tree = buildTree(groups, side, {})
        return {
          run = function(iterations)
            for _ = 1, iterations do
              adapter.define(APP, tree)
              adapter.forget(APP)
            end
          end,
        }
      end,
    }
  end

  ---A command-line case over a 50-option table bound to `/benchopt`.
  local function commandCase(name, operation, note, line)
    return {
      name = name,
      iterations = COMMAND_ITERATIONS,
      operation = operation,
      note = note,
      prepare = function()
        local store = {}
        adapter.bindCommand(APP, buildTree(5, side, store), "benchopt")
        local dispatch = slashFunction("benchopt")
        local pool = {}
        for index = 1, COMMAND_ITERATIONS do
          pool[index] = line(index)
        end
        local chat, typed, linesBefore = host.chatFrame, 0, host.chatFrame.lines
        return {
          run = function(iterations)
            for index = 1, iterations do
              dispatch(pool[index])
            end
            typed = typed + iterations
          end,
          metrics = function()
            return { chatLinesPerCommand = (chat.lines - linesBefore) / typed }
          end,
        }
      end,
    }
  end

  list[#list + 1] = commandCase(
    "cmd-set-range",
    "type a command setting a range option to a number",
    ECHO_NOTE,
    function(index)
      return adapter.setLine("g2", "scale", string.format("%.5f", 0.5 + index * 0.0007))
    end
  )
  list[#list + 1] = commandCase(
    "cmd-set-toggle",
    "type a command turning a toggle on or off",
    ECHO_NOTE,
    function(index)
      return adapter.setLine("g3", "enabled", index % 2 == 0 and "on" or "off")
    end
  )
  list[#list + 1] = commandCase(
    "cmd-set-select",
    "type a command choosing a select value by key",
    ECHO_NOTE,
    function(index)
      local keys = { "TOP", "CENTER", "BOTTOM" }
      return adapter.setLine("g4", "anchor", keys[index % 3 + 1])
    end
  )
  list[#list + 1] = commandCase(
    "cmd-refused",
    "type a command choosing a value the select does not have",
    "both print the refusal; CommandKit describes the named option once per command",
    function(index)
      return adapter.setLine("g4", "anchor", "LEFT" .. index)
    end
  )

  list[#list + 1] = {
    name = "profile-options-build",
    iterations = PROFILE_ITERATIONS,
    operation = "build the profile options group for a database",
    note = "AceDBOptions and OptionsKit (revision 8) both return one cached group per database; OptionsKit still runs its argument and database checks on every call",
    prepare = function()
      local db = openProfiles(adapter)
      return {
        run = function(iterations)
          for _ = 1, iterations do
            adapter.profileGroup(db)
          end
        end,
      }
    end,
  }

  list[#list + 1] = {
    name = "profile-choose-cmd",
    iterations = PROFILE_ITERATIONS,
    operation = "type a command choosing the profile (Alpha and Beta in turn)",
    note = "includes each database's own profile switch",
    prepare = function()
      local db = openProfiles(adapter)
      adapter.bindCommand(
        PROFILE_APP,
        { type = "group", name = "Bench profiles", args = { profiles = adapter.profileGroup(db) } },
        "benchprof"
      )
      local dispatch = slashFunction("benchprof")
      local lines = { adapter.chooseProfileLine("Beta"), adapter.chooseProfileLine("Alpha") }
      local switched, typed = 0, 0
      return {
        run = function(iterations)
          for index = 1, iterations do
            local before = adapter.currentProfile(db)
            dispatch(lines[index % 2 + 1])
            if adapter.currentProfile(db) ~= before then
              switched = switched + 1
            end
          end
          typed = typed + iterations
        end,
        metrics = function()
          return { switchesPerCommand = switched / typed }
        end,
      }
    end,
  }

  if side == "moltencodes" then
    local note = "OptionsKit only: AceConfigRegistry has no call that reads or writes an option"
    list[#list + 1] = {
      name = "tree-get",
      iterations = TREE_ITERATIONS,
      operation = "read a range option through the tree (tree:Get)",
      equivalent = false,
      note = note,
      prepare = function()
        local tree = adapter.define(APP, buildTree(5, side, {}))
        return {
          run = function(iterations)
            for _ = 1, iterations do
              tree:Get("g2.scale")
            end
          end,
        }
      end,
    }
    list[#list + 1] = {
      name = "tree-set",
      iterations = TREE_ITERATIONS,
      operation = "write a range option through the tree (tree:Set, checked and signalled)",
      equivalent = false,
      note = note,
      prepare = function()
        local tree = adapter.define(APP, buildTree(5, side, {}))
        return {
          run = function(iterations)
            for index = 1, iterations do
              tree:Set("g2.scale", 0.5 + (index % 1000) * 0.001)
            end
          end,
        }
      end,
    }
  end
  return list
end

---Whether defining `tree` is refused (raises).
---@param adapter table
---@param tree table
---@return boolean refused
---@return string detail
local function refuses(adapter, tree)
  local ok, problem = pcall(adapter.define, "BenchCheck", tree)
  adapter.forget("BenchCheck")
  if ok then
    return false, "accepted"
  end
  return true, "refused: " .. tostring(problem):gsub("^.-: ", "", 1):sub(1, 90)
end

---@param adapter table
---@param side string
---@param host table
---@return table[]
local function checks(adapter, side, host)
  local results = {}
  local kit = side == "moltencodes"

  local function withOption(option)
    return { type = "group", name = "Check", args = { option = option } }
  end

  local refused, detail = refuses(adapter, withOption({ type = "toggle", name = 5 }))
  results[#results + 1] = {
    name = "wrong-field-type-refused",
    passed = refused,
    detail = "a label that is a number: " .. detail,
    promised = true,
  }

  refused, detail = refuses(
    adapter,
    withOption({ type = "execute", name = "Run", desk = "misspelled", func = function() end })
  )
  results[#results + 1] = {
    name = "misspelled-field-refused",
    passed = refused,
    detail = "a field named desk: " .. detail,
    promised = true,
  }

  local function noop() end
  refused, detail = refuses(
    adapter,
    withOption({ type = "range", name = "Scale", min = 2, max = 1, get = noop, set = noop })
  )
  results[#results + 1] = {
    name = "min-above-max-refused",
    passed = refused,
    detail = "a range with min 2 and max 1: " .. detail,
    promised = kit,
  }

  -- The command line against the option's bounds and values.
  local store = {}
  adapter.bindCommand("BenchCheckCmd", buildTree(5, side, store), "benchcheck")
  local dispatch = slashFunction("benchcheck")
  local chat = host.chatFrame

  dispatch(adapter.setLine("g1", "scale", "5"))
  results[#results + 1] = {
    name = "cmd-range-bounds-enforced",
    passed = store["g1.scale"] == 1,
    detail = "typed 5 for a 0.5..2 range; stored value: "
      .. tostring(store["g1.scale"])
      .. ", said: "
      .. tostring(chat.lastLine),
    promised = true,
  }

  local linesBefore = chat.lines
  dispatch(adapter.setLine("g1", "nosuch", "1"))
  results[#results + 1] = {
    name = "cmd-unknown-option-reported",
    passed = chat.lines > linesBefore,
    detail = "said: " .. tostring(chat.lastLine),
    promised = true,
  }

  dispatch(adapter.setLine("g1", "anchor", "bottom"))
  results[#results + 1] = {
    name = "cmd-select-ignores-case",
    passed = store["g1.anchor"] == "BOTTOM",
    detail = "typed bottom; stored: " .. tostring(store["g1.anchor"]),
    promised = true,
  }

  dispatch(adapter.setLine("g1", "label", "bad*text"))
  results[#results + 1] = {
    name = "cmd-input-pattern-enforced",
    passed = store["g1.label"] == "",
    detail = "typed bad*text for ^[%w ]*$; stored: " .. string.format("%q", store["g1.label"]),
    promised = true,
  }

  local db = openProfiles(adapter)
  adapter.bindCommand(
    "BenchCheckProfiles",
    { type = "group", name = "Check profiles", args = { profiles = adapter.profileGroup(db) } },
    "benchcheckprof"
  )
  slashFunction("benchcheckprof")(adapter.chooseProfileLine("Beta"))
  results[#results + 1] = {
    name = "cmd-profile-chosen",
    passed = adapter.currentProfile(db) == "Beta",
    detail = "current profile after choosing Beta: " .. tostring(adapter.currentProfile(db)),
    promised = true,
  }
  return results
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Options.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  return {
    libraries = libraries,
    cases = cases(adapter, side, host),
    checks = function()
      return checks(adapter, side, host)
    end,
  }
end

return Options

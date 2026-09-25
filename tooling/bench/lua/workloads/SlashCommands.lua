--- Slash commands: CommandKit against AceConsole-3.0.
---
--- The same work, as an addon author meets it:
---
--- - **Register and unregister** one slash command. `scope:Register` and
---   `scope:Unregister` against `RegisterChatCommand` and
---   `UnregisterChatCommand`. Both write `SlashCmdList` and the `SLASH_<key>1`
---   global. CommandKit also compiles the spec and checks that no other addon,
---   chat type or emote owns the name (its "taken" check reads the foreign
---   commands' `SLASH_` globals on every call; the `EMOTE<n>_CMD<m>` globals,
---   none of which the host defines, are read once into an index since
---   CommandKit revision 7, and every later check asks the index); AceConsole
---   overwrites whatever held the name. The host holds 50 foreign commands on
---   both sides, as a client with a few addons would.
--- - **Dispatch** a typed line: the client calls the function under the
---   command's `SlashCmdList` key with the text after the slash name, so the
---   cases call that function. An AceConsole handler receives the raw text and
---   splits it itself with `GetArgs`, which is how AceConsole addons are
---   written; a CommandKit handler receives the tokens. `dispatch-words` hands
---   two words to the handler. `dispatch-subcommand` runs `scale <number>`: on
---   the Kit side a sub-command with a `SchemaKit.number{ min, max }` argument,
---   on the Ace side the handler's own `GetArgs`, `tonumber` and bounds test,
---   which is the code an AceConsole addon writes for the same command.
--- - **Parse** a line into its arguments: `CommandKit:ParseInto` against
---   `AceConsole:GetArgs(text, n)` for plain words, quoted strings and a
---   colour-wrapped item link.
---
--- Every typed line is different (a pool of distinct texts, one per operation
--- of a batch), so the tokens are new strings on every operation and interning
--- cannot hide their allocation.
---
--- Dropped: `register-unregister-one-emote`, which ran `register-unregister`
--- with `maxEmotes = 1` to show how much of it the emote scan cost. Since
--- CommandKit revision 7 the scan runs once per session and later checks ask
--- the index, so capping it no longer isolates anything: the case measured
--- the same work as `register-unregister`.
---
--- Left out: AceConfigCmd-3.0, which is AceConsole's command line over an
--- options table; the `options` workload compares it with CommandKit's
--- `BindOptions`. Tab completion is left out: AceTab-3.0 is not part of the
--- pinned comparison and completion needs the client's edit box.

local SlashCommands = {}

--- Operations per timed batch.
local REGISTER_ITERATIONS = 1000
local DISPATCH_ITERATIONS = 4000
local PARSE_ITERATIONS = 4000

--- Foreign slash commands the host holds on both sides.
local FOREIGN_COMMANDS = 50

--- The command every case registers.
local COMMAND = "benchcmd"

---@param name string
---@param value any
local function setGlobal(name, value)
  -- Slash commands are client globals (`SlashCmdList`, `SLASH_<key><n>`).
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---@param name string
---@return any
local function getGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Register the foreign commands other addons would have, the same on both
---sides: a `SlashCmdList` entry, its `SLASH_<key>1` global, and the client's
---lookup table entry.
local function installForeignCommands()
  local list, hash = getGlobal("SlashCmdList"), getGlobal("hash_SlashCmdList")
  for index = 1, FOREIGN_COMMANDS do
    local key = "OTHERADDON" .. index
    local function handler() end
    list[key] = handler
    setGlobal("SLASH_" .. key .. "1", "/other" .. index)
    hash["/OTHER" .. index] = handler
  end
end

---The function the client would call for `/name`, found as the client finds
---it: through the `SLASH_<key>1` global naming it.
---@param name string
---@return function? handler
---@return string? key
local function slashFunction(name)
  local wanted = "/" .. name:lower()
  for key, handler in pairs(getGlobal("SlashCmdList")) do
    local slash = getGlobal("SLASH_" .. key .. "1")
    if type(slash) == "string" and slash:lower() == wanted then
      return handler, key
    end
  end
  return nil, nil
end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({ "Registry", "SchemaKit", "CommandKit" })
  local SchemaKit, CommandKit = loaded[2], loaded[3]
  local scope = CommandKit:CreateScope()
  local parsed = {}
  local adapter = {}

  function adapter.registerWords(name, receive)
    return scope:Register(name, {
      handler = function(_, first, second)
        receive(first, second)
      end,
    })
  end

  function adapter.registerScale(name, receive)
    return scope:Register(name, {
      subcommands = {
        scale = {
          arguments = { SchemaKit.number({ min = 0.5, max = 2 }) },
          handler = function(_, scale)
            receive(scale)
          end,
        },
      },
    })
  end

  function adapter.unregister(name)
    scope:Unregister(name)
  end

  function adapter.parse(text)
    return CommandKit:ParseInto(text, parsed)
  end

  ---The tokens of `text`, or `nil` and the reason when it is refused.
  function adapter.tokens(text)
    return CommandKit:Parse(text)
  end

  return adapter,
    {
      { name = "CommandKit", revision = CommandKit.REVISION },
      { name = "SchemaKit", revision = SchemaKit.REVISION },
    }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, { "LibStub/LibStub.lua", "AceConsole-3.0/AceConsole-3.0.lua" })
  local LibStub = host.Global("LibStub")
  local AceConsole, minor = LibStub:GetLibrary("AceConsole-3.0")
  local owner = AceConsole:Embed({})
  local adapter = {}

  function adapter.registerWords(name, receive)
    return owner:RegisterChatCommand(name, function(input)
      local first, second = owner:GetArgs(input, 2)
      receive(first, second)
    end)
  end

  function adapter.registerScale(name, receive)
    return owner:RegisterChatCommand(name, function(input)
      local command, value = owner:GetArgs(input, 2)
      if command == nil or command:lower() ~= "scale" then
        owner:Print("Usage: /" .. name .. " scale <number 0.5..2>")
        return
      end
      local scale = tonumber(value)
      if scale == nil or scale < 0.5 or scale > 2 then
        owner:Print("Usage: /" .. name .. " scale <number 0.5..2>")
        return
      end
      receive(scale)
    end)
  end

  function adapter.unregister(name)
    owner:UnregisterChatCommand(name)
  end

  local counts = { plain = 5, quoted = 3, link = 3 }

  function adapter.parse(text, kind)
    return AceConsole:GetArgs(text, counts[kind])
  end

  ---The tokens of `text` as `GetArgs` returns them, up to eight.
  function adapter.tokens(text)
    local tokens = { AceConsole:GetArgs(text, 8) }
    local result = {}
    for index = 1, 8 do
      if tokens[index] ~= nil then
        result[#result + 1] = tokens[index]
      end
    end
    return result
  end

  return adapter, { { name = "AceConsole-3.0", minor = minor } }
end

---Texts for the parse cases, one per operation of a batch, each distinct.
local TEXTS = {
  plain = function(index)
    return "target" .. index .. " focus" .. index .. " mouseover " .. index .. " on"
  end,
  quoted = function(index)
    return 'say "hello there ' .. index .. "\" 'second part " .. index .. "'"
  end,
  link = function(index)
    return "watch |cffa335ee|Hitem:"
      .. (19000 + index)
      .. "::::::::70:::::|h[Some Long Item "
      .. index
      .. "]|h|r now"
  end,
}

---@param count integer
---@param make fun(index: integer): string
---@return string[]
local function textPool(count, make)
  local pool = {}
  for index = 1, count do
    pool[index] = make(index)
  end
  return pool
end

---@param adapter table
---@return Bench.Case[]
local function cases(adapter)
  local list = {
    {
      name = "register-unregister",
      iterations = REGISTER_ITERATIONS,
      operation = "register a slash command and unregister it (50 foreign commands present)",
      note = "CommandKit also checks the name against other addons', chat types and emotes",
      prepare = function()
        local function receive() end
        return {
          run = function(iterations)
            for _ = 1, iterations do
              adapter.registerWords(COMMAND, receive)
              adapter.unregister(COMMAND)
            end
          end,
        }
      end,
    },
    {
      name = "dispatch-words",
      iterations = DISPATCH_ITERATIONS,
      operation = "run a typed /command with two words, handed to the handler",
      prepare = function()
        local received = 0
        local function receive(first, second)
          if first ~= nil and second ~= nil then
            received = received + 1
          end
        end
        adapter.registerWords(COMMAND, receive)
        local dispatch = slashFunction(COMMAND)
        local pool = textPool(DISPATCH_ITERATIONS, function(index)
          return "alpha" .. index .. " beta" .. index
        end)
        local calls = 0
        return {
          run = function(iterations)
            for index = 1, iterations do
              dispatch(pool[index])
            end
            calls = calls + iterations
          end,
          metrics = function()
            return { handlerCallsPerLine = received / calls }
          end,
        }
      end,
    },
    {
      name = "dispatch-subcommand",
      iterations = DISPATCH_ITERATIONS,
      operation = "run /command scale <number>, checked against 0.5..2",
      note = "Ace3: the handler's own GetArgs, tonumber and bounds test; CommandKit: a sub-command with a number schema",
      prepare = function()
        local received = 0
        local function receive(scale)
          if type(scale) == "number" then
            received = received + 1
          end
        end
        adapter.registerScale(COMMAND, receive)
        local dispatch = slashFunction(COMMAND)
        local pool = textPool(DISPATCH_ITERATIONS, function(index)
          return string.format("scale %.5f", 0.5 + index * 0.0003)
        end)
        local calls = 0
        return {
          run = function(iterations)
            for index = 1, iterations do
              dispatch(pool[index])
            end
            calls = calls + iterations
          end,
          metrics = function()
            return { handlerCallsPerLine = received / calls }
          end,
        }
      end,
    },
  }

  for _, kind in ipairs({ "plain", "quoted", "link" }) do
    local descriptions = {
      plain = "split five plain words",
      quoted = "split a word and two quoted strings",
      link = "split a word, a colour-wrapped item link with spaces, and a word",
    }
    list[#list + 1] = {
      name = "parse-" .. kind,
      iterations = PARSE_ITERATIONS,
      operation = descriptions[kind],
      prepare = function()
        local pool = textPool(PARSE_ITERATIONS, TEXTS[kind])
        return {
          run = function(iterations)
            for index = 1, iterations do
              adapter.parse(pool[index], kind)
            end
          end,
        }
      end,
    }
  end

  return list
end

---@param adapter table
---@param side string
---@return table[]
local function checks(adapter, side)
  local results = {}
  local kit = side == "moltencodes"

  local quoted = adapter.tokens('say "two words" end')
  results[#results + 1] = {
    name = "quoted-argument-kept-whole",
    passed = quoted ~= nil and quoted[2] == "two words" and quoted[3] == "end",
    detail = "second token: " .. tostring(quoted and quoted[2]),
    promised = true,
  }

  local link = "|cffa335ee|Hitem:19019::::::::70:::::|h[Thunderfury, Blessed Blade]|h|r"
  local linked = adapter.tokens("watch " .. link .. " now")
  results[#results + 1] = {
    name = "item-link-kept-whole",
    passed = linked ~= nil and linked[2] == link and linked[3] == "now",
    detail = "link token intact: " .. tostring(linked ~= nil and linked[2] == link),
    promised = true,
  }

  local escaped = adapter.tokens('say "say \\"hi\\"" end')
  results[#results + 1] = {
    name = "escaped-quote",
    passed = escaped ~= nil and escaped[2] == 'say "hi"',
    detail = "second token: " .. tostring(escaped and escaped[2]),
    promised = kit,
  }

  local unterminated, reason = adapter.tokens('say "open')
  results[#results + 1] = {
    name = "unterminated-quote-refused",
    passed = unterminated == nil,
    detail = unterminated == nil and ("refused: " .. tostring(reason))
      or ("accepted as: " .. tostring(unterminated[2])),
    promised = kit,
  }

  -- A name another addon already registered: afterwards, how many
  -- `SlashCmdList` keys claim `/other1`? More than one leaves the client to
  -- pick whichever it finds first.
  local registered = adapter.registerWords("other1", function() end)
  local claimants = 0
  for key in pairs(getGlobal("SlashCmdList")) do
    if getGlobal("SLASH_" .. key .. "1") == "/other1" then
      claimants = claimants + 1
    end
  end
  results[#results + 1] = {
    name = "taken-name-refused",
    passed = registered ~= true and claimants == 1,
    detail = "register returned "
      .. tostring(registered)
      .. ", keys claiming /other1: "
      .. claimants,
    promised = kit,
  }

  local ran = 0
  adapter.registerWords("benchgone", function()
    ran = ran + 1
  end)
  local cached, key = slashFunction("benchgone")
  adapter.unregister("benchgone")
  local reachable = getGlobal("SlashCmdList")[key] ~= nil
  if reachable and cached ~= nil then
    cached("a b")
  end
  results[#results + 1] = {
    name = "unregistered-command-does-nothing",
    passed = ran == 0,
    detail = "handler calls after unregister: "
      .. ran
      .. ", key still in SlashCmdList: "
      .. tostring(reachable),
    promised = true,
  }
  return results
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function SlashCommands.Build(side, host, settings)
  installForeignCommands()
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  return {
    libraries = libraries,
    cases = cases(adapter),
    checks = function()
      return checks(adapter, side)
    end,
  }
end

return SlashCommands

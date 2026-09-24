-- MoltenCodes Test: CommandKitSuite.lua
--
-- Real-client suites for the `commandKit` package. The Busted specs under
-- packages/commandKit/tests/ prove CommandKit against a scripted slash table,
-- a scripted chat frame and a stand-in `ChatEdit_CustomTabPressed`; these
-- prove, inside the game client with the installed MoltenCodes addon, what
-- that fixture can only simulate:
--
--   * the installed facade and its committed revision, and which of the host
--     facilities docs/API.md names this client has (`SlashCmdList`,
--     `SecureCmdList`, `ChatTypeInfo`, the `EMOTE<n>_CMD<m>` globals,
--     `DEFAULT_CHAT_FRAME`, `ChatEdit_CustomTabPressed`,
--     `ChatEdit_GetActiveWindow`) and which optional Kits it found;
--   * registration of the real slash command `/mcttestcmd` in the client's own
--     `SlashCmdList` and `SLASH_<key>1` globals, the refusal of a name the
--     client already uses for a chat type, a slash command or an emote, and
--     the inert entry a closed scope leaves behind;
--   * dispatch without the player typing: the test calls the client's
--     `SlashCmdList[<key>]` entry exactly as the chat box does, with the default
--     chat frame's edit box, and reads the output from a capture sink;
--   * the parser over real item links the client builds
--     (`C_Item.GetItemInfo`), with the quality colour and a name with spaces,
--     kept as one argument;
--   * generated usage text, schema-checked arguments, a handler failure
--     reported to the client's error handler, and the default sink writing to
--     the real chat frame (one visible line, see EXPECTED.md);
--   * `BindOptions` over a real OptionsKit tree;
--   * tab completion through the client's `ChatEdit_CustomTabPressed`, handed
--     a stand-in edit box so nothing is typed, and put back afterwards;
--   * the documented allocation-free paths on the client's own collector;
--   * argument errors naming CommandKitSuite.lua at the calling line, and
--     secret values made by the client's `secretwrap` refused where
--     docs/API.md says they are.
--
-- Nothing here needs combat, a group or an instance, and nothing is typed:
-- every command runs through the function the client keeps in `SlashCmdList`.
-- The one visible effect is a single line in the default chat frame, written
-- by the default-sink test on purpose. Two item links are read with
-- `C_Item.GetItemInfo`; an item the client has not cached is requested from the
-- server with `C_Item.RequestLoadItemDataByID`, a read-only data query.
--
-- Run with `/mct run commandKit`; tests/client/MoltenCodesTest_CommandKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. The After hook of every suite unregisters every
-- command a test registered, closes every manual scope, undefines the
-- OptionsKit tree, turns completion off (which writes the client's
-- `ChatEdit_CustomTabPressed` back) and points the addon scope's output back
-- at the chat frame, whatever the test's outcome. What the client keeps for
-- the session, because CommandKit never removes what it wrote (docs/API.md,
-- "Inert globals and re-registration"): the `SlashCmdList` entries and
-- `SLASH_<key>1` globals of `/mcttestcmd`, `/mcttestopts`, `/mcttestinert` and
-- `/mcttestsecret`, each an inert dispatcher that does nothing when typed. A
-- later run registers the same names again under the same keys. This addon's
-- own CommandKit scope (`CommandKit:ForAddon("MoltenCodesTest_CommandKit")`)
-- stays open, and empty, until logout. CommandKit's package-wide limits are
-- never changed: every `SetLimits` call here is a refusal the test checks.
-- Nothing is written to a saved variable or a CVar.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
  error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local REGISTRY_API = 2
local COMMAND_KIT_API = 1
local SCHEMA_KIT_API = 1
local OPTIONS_KIT_API = 1
local PACKAGE_ID = "commandKit"

--- The slash command the suites register: `/mcttestcmd`. The prefix keeps it
--- clear of every command the client and common addons define.
local COMMAND_NAME = "mcttestcmd"

--- The command `BindOptions` registers over the test's OptionsKit tree.
local OPTIONS_COMMAND_NAME = "mcttestopts"

--- The command a manual scope registers and closes, to observe the inert entry.
local INERT_COMMAND_NAME = "mcttestinert"

--- The command whose handler raises a secret message.
local SECRET_COMMAND_NAME = "mcttestsecret"

--- The line the default-sink test writes to the real chat frame on purpose.
local DEFAULT_SINK_LINE =
  "CommandKit test: this line reached the chat frame through the default sink"

--- What the failing sub-command raises.
local HANDLER_FAILURE = "the probe handler failed on purpose"

--- The Hearthstone: every character has one, so the client usually has its
--- item data cached. Its name has no space.
local HEARTHSTONE_ITEM_ID = 6948

--- Linen Cloth: a common item whose enUS name has a space, so its link is a
--- token the parser must keep whole across whitespace.
local LINEN_CLOTH_ITEM_ID = 2589

--- How long a test waits for the server to answer an item data request.
local ITEM_WAIT_SECONDS = 5

--- How many cycles each allocation guard runs.
local ALLOCATION_CYCLES = 5000

--- Kilobytes an allocation guard tolerates: a stray allocation by the client
--- between the two readings, not a per-cycle one.
local ALLOCATION_TOLERANCE_KB = 1

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The slash tables, the chat frame, the chat edit functions, the emote and
  -- slash globals, item data and the secret-value functions are World of
  -- Warcraft client globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Read a function from a client namespace table such as `C_Item`, or `nil`.
---@param namespaceName string
---@param functionName string
---@return function|nil
local function readHostFunction(namespaceName, functionName)
  local hostNamespace = readHost(namespaceName)
  if type(hostNamespace) ~= "table" then
    return nil
  end
  local candidate = hostNamespace[functionName]
  if type(candidate) ~= "function" then
    return nil
  end
  return candidate
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- CommandKit, SchemaKit and OptionsKit are not in the language-server
-- workspace of tests/client (its .luarc.json lists TestKit's dependency
-- closure only), so their facades and objects are typed `any` here.

---@type any
local CommandKit = Registry:Get(PACKAGE_ID, COMMAND_KIT_API)
---@type any
local SchemaKit = Registry:Get("schemaKit", SCHEMA_KIT_API)
---@type any
local OptionsKit = Registry:Get("optionsKit", OPTIONS_KIT_API)
if type(CommandKit) == "nil" or type(SchemaKit) == "nil" or type(OptionsKit) == "nil" then
  error(
    addonName .. " requires CommandKit, SchemaKit and OptionsKit API 1 in the MoltenCodes addon",
    0
  )
end

local S = SchemaKit

--- This addon's canonical CommandKit scope, asked for while the addon loads,
--- which is when docs/API.md says an addon registers its commands. It stays
--- open for the session; every test unregisters what it registered here.
---@type any
local addonScope = CommandKit:ForAddon(addonName)

---The slash-table key CommandKit derives for a name first registered by this
---addon's scope: `MOLTENCODES_<ADDON>_<NAME>` (docs/API.md, Registration).
---@param name string
---@return string
local function addonKey(name)
  return "MOLTENCODES_" .. (addonName:gsub("[^%w]", "_")):upper() .. "_" .. name:upper()
end

---The key of a name first registered by a manual scope: `MOLTENCODES_<NAME>`.
---@param name string
---@return string
local function manualKey(name)
  return "MOLTENCODES_" .. name:upper()
end

local COMMAND_KEY = addonKey(COMMAND_NAME)
local OPTIONS_COMMAND_KEY = addonKey(OPTIONS_COMMAND_NAME)
local INERT_COMMAND_KEY = manualKey(INERT_COMMAND_NAME)
local SECRET_COMMAND_KEY = addonKey(SECRET_COMMAND_NAME)

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

---Whether `value` is a secret. `false` on a client without `issecretvalue`.
---@param value any
---@return boolean
local function isSecret(value)
  return SECRETS_AVAILABLE and isSecretValue(value) == true
end

---Text with every `|` doubled, so a log line shows a link's escape codes
---instead of the client drawing them.
---@param text string
---@return string
local function showEscapes(text)
  return (text:gsub("|", "||"))
end

-- The probe command ------------------------------------------------------------------------

--- What the probe handlers saw, read by the test after the dispatch returned.
--- Handlers never assert: a failed expectation inside a handler would be
--- caught by CommandKit's own `pcall` and reported instead of failing the test.
local probe = {
  calls = 0,
  scale = 0,
  quietScale = false,
  mode = false,
  quiet = "unset",
  link = false,
  note = false,
  tokens = {},
  rawText = false,
  commandPath = false,
  keptContext = false,
  failureLine = 0,
}

---Forget everything the probe handlers recorded.
local function resetProbe()
  probe.calls = 0
  probe.scale = 0
  probe.quietScale = false
  probe.mode = false
  probe.quiet = "unset"
  probe.link = false
  probe.note = false
  for index = #probe.tokens, 1, -1 do
    probe.tokens[index] = nil
  end
  probe.rawText = false
  probe.commandPath = false
  probe.keptContext = false
  probe.failureLine = 0
end

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
  local file, line = position:match("^(.-):(%d+): ")
  return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
---@return integer
local function currentLine()
  local _, position = pcall(error, "", 3)
  local _, line = splitPosition(position or "")
  return line or 0
end

---A new spec for `/mcttestcmd`: seven sub-commands covering every kind of
---argument declaration. The spec is compiled at `Register`, so each test may
---register a fresh one.
---@return table
local function newProbeSpec()
  return {
    description = "CommandKit real-client probe.",
    subcommands = {
      scale = {
        description = "Set the probe scale.",
        arguments = { S.number({ min = 0.5, max = 2 }) },
        handler = function(context, scale)
          probe.calls = probe.calls + 1
          probe.scale = scale
          if not probe.quietScale then
            probe.commandPath = context:GetCommandPath()
            probe.rawText = context:GetRawText()
            context:Printf("Scale %.2f.", scale)
          end
        end,
      },
      mode = {
        description = "Choose the probe mode.",
        arguments = { S.enum({ "party", "raid", "all" }), S.optional(S.boolean()) },
        handler = function(_, mode, quiet)
          probe.calls = probe.calls + 1
          probe.mode = mode
          probe.quiet = quiet
        end,
      },
      watch = {
        description = "Remember an item link.",
        usage = "<item link> [note]",
        arguments = { S.string({ pattern = "|Hitem:" }), S.optional(S.string()) },
        handler = function(_, link, note)
          probe.calls = probe.calls + 1
          probe.link = link
          probe.note = note
        end,
      },
      echo = {
        description = "Keep every token.",
        handler = function(context, ...)
          probe.calls = probe.calls + 1
          probe.rawText = context:GetRawText()
          for index = 1, select("#", ...) do
            probe.tokens[index] = (select(index, ...))
          end
        end,
      },
      announce = {
        description = "Print one line.",
        handler = function(context)
          probe.calls = probe.calls + 1
          context:Print(DEFAULT_SINK_LINE)
        end,
      },
      boom = {
        description = "Raise an error.",
        handler = function()
          probe.calls = probe.calls + 1
          probe.failureLine = currentLine()
          error(HANDLER_FAILURE)
        end,
      },
      keep = {
        description = "Keep the context past the command.",
        handler = function(context)
          probe.calls = probe.calls + 1
          probe.keptContext = context
        end,
      },
    },
  }
end

--- The usage lines `/mcttestcmd` with nothing after it prints, generated from
--- `newProbeSpec` by the rules of docs/API.md, "Usage text".
local PROBE_USAGE = {
  "Usage: /mcttestcmd <announce|boom|echo|keep|mode|scale|watch>",
  "CommandKit real-client probe.",
  "  /mcttestcmd announce - Print one line.",
  "  /mcttestcmd boom - Raise an error.",
  "  /mcttestcmd echo - Keep every token.",
  "  /mcttestcmd keep - Keep the context past the command.",
  "  /mcttestcmd mode <party|raid|all> [on|off] - Choose the probe mode.",
  "  /mcttestcmd scale <number 0.5..2> - Set the probe scale.",
  "  /mcttestcmd watch <item link> [note] - Remember an item link.",
}

-- State of the running test ------------------------------------------------------------------

--- Names the running test registered in the addon scope; the After hook
--- unregisters them.
---@type string[]
local registeredNames = {}

--- Manual scopes the running test created; the After hook closes them.
---@type any[]
local manualScopes = {}

--- Whether the running test defined this addon's OptionsKit tree.
local treeDefined = false

---Register `name` in the addon scope and remember it for the After hook.
---@param name string
---@param spec table
---@return true|nil registered
---@return string|nil reason
local function registerInAddonScope(name, spec)
  registeredNames[#registeredNames + 1] = name
  local registered, reason = addonScope:Register(name, spec)
  return registered, reason
end

---Register `/mcttestcmd` in the addon scope with its output sent to a new
---capture sink, failing the test when the client refuses it.
---@param ctx TestKit.Context
---@return any sink
local function registerProbe(ctx)
  local sink = CommandKit:CaptureSink()
  addonScope:SetSink(sink)
  local registered, reason = registerInAddonScope(COMMAND_NAME, newProbeSpec())
  if registered ~= true then
    ctx:Fail("Register('" .. COMMAND_NAME .. "') was refused: " .. tostring(reason))
  end
  return sink
end

---A manual scope the After hook closes.
---@param options table|nil
---@return any scope
local function newManualScope(options)
  local scope = CommandKit:CreateScope(options)
  manualScopes[#manualScopes + 1] = scope
  return scope
end

---Undo everything the running test did. The After hook of every suite.
local function cleanUp()
  for index = #registeredNames, 1, -1 do
    local name = registeredNames[index]
    registeredNames[index] = nil
    pcall(addonScope.Unregister, addonScope, name)
  end
  for index = #manualScopes, 1, -1 do
    local scope = manualScopes[index]
    manualScopes[index] = nil
    pcall(scope.Close, scope)
  end
  pcall(addonScope.DisableCompletion, addonScope)
  pcall(addonScope.SetSink, addonScope, nil)
  if treeDefined then
    treeDefined = false
    pcall(OptionsKit.Undefine, OptionsKit, addonName)
  end
  resetProbe()
end

---Register a suite of this package whose tests all end with every command
---unregistered and every client global CommandKit may put back put back.
---@param part string
---@param options table|nil
---@return TestKit.Suite
local function newSuite(part, options)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName, options)
  suite:After(cleanUp)
  return suite
end

-- The client's slash table and chat frame ------------------------------------------------------

---The client's `SlashCmdList` entry under `key`, or `nil`.
---@param key string
---@return any
local function slashEntry(key)
  local slashList = readHost("SlashCmdList")
  if type(slashList) ~= "table" then
    return nil
  end
  return rawget(slashList, key)
end

---The default chat frame's edit box, which the client hands a slash function
---as its second argument, or `nil`.
---@return table|nil
local function chatEditBox()
  local chatFrame = readHost("DEFAULT_CHAT_FRAME")
  local editBox = nil
  if type(chatFrame) == "table" then
    editBox = rawget(chatFrame, "editBox")
  end
  if type(editBox) ~= "table" then
    editBox = readHost("ChatFrame1EditBox")
  end
  if type(editBox) ~= "table" then
    return nil
  end
  return editBox
end

---Run a slash command without typing it: call the function the client keeps
---in `SlashCmdList[key]` with `text` and the default chat frame's edit box,
---exactly as the chat box does after it matched the slash name.
---@param key string
---@param text string what the player would type after the slash name
local function runSlash(key, text)
  local entry = slashEntry(key)
  if type(entry) ~= "function" then
    error("SlashCmdList." .. key .. " is not a function", 2)
  end
  entry(text, chatEditBox())
end

---The number of lines the default chat frame holds and the text of the last
---one, or `nil` when the frame cannot be read. A line that is secret reads as
---`"(secret)"`.
---@return integer|nil count
---@return string|nil lastText
local function readChatFrame()
  local chatFrame = readHost("DEFAULT_CHAT_FRAME")
  if
    type(chatFrame) ~= "table"
    or type(chatFrame.GetNumMessages) ~= "function"
    or type(chatFrame.GetMessageInfo) ~= "function"
  then
    return nil, nil
  end
  local count = chatFrame:GetNumMessages()
  if type(count) ~= "number" or isSecret(count) then
    return nil, nil
  end
  if count == 0 then
    return 0, ""
  end
  local text = chatFrame:GetMessageInfo(count)
  if isSecret(text) then
    return count, "(secret)"
  end
  return count, tostring(text)
end

-- Errors ------------------------------------------------------------------------------------------

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" then
    return nil
  end
  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#"CommandKitSuite.lua")):ToBe("CommandKitSuite.lua")
  return line
end

---Check a failure already caught: it must name this file at `startLine + 1`
---and end with `expected`.
---@param ctx TestKit.Context
---@param succeeded boolean
---@param message any
---@param startLine integer
---@param expected string The message after the position, compared literally.
local function expectCaughtError(ctx, succeeded, message, startLine, expected)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))
  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(startLine + 1)
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
  local succeeded, message = pcall(raise)
  expectCaughtError(ctx, succeeded, message, lineBox.start, expected)
end

---Run `action` with the client's error handler replaced by a collector, and
---return what it collected and whether the swap took effect.
---
---CommandKit hands a handler failure to `geterrorhandler()`. On the Retail
---client the handler is swapped with `seterrorhandler` for the one call and
---put back at once (tests/client/README.md, "Catching an error a Kit reports
---instead of raising"); elsewhere the global is replaced for this test.
---@param ctx TestKit.Context
---@param action fun()
---@return any[] reported
---@return boolean observed
local function collectReportedErrors(ctx, action)
  local reported = {}
  ---@param message any
  local function collector(message)
    reported[#reported + 1] = message
  end

  local restore = nil
  local observed = false
  if type(readHost("securecallfunction")) == "function" then
    local setErrorHandler = readHost("seterrorhandler")
    local getErrorHandler = readHost("geterrorhandler")
    if type(setErrorHandler) == "function" and type(getErrorHandler) == "function" then
      local previous = getErrorHandler()
      setErrorHandler(collector)
      -- An error-capturing addon (BugGrabber) may refuse the swap.
      observed = getErrorHandler() == collector
      restore = function()
        setErrorHandler(previous)
      end
    end
  else
    -- The global is replaced for this test only; TestKit puts it back.
    -- selene: allow(global_usage)
    ctx:Replace(_G, "geterrorhandler", function()
      return collector
    end)
    observed = true
  end

  local succeeded, problem = pcall(action)
  if restore ~= nil then
    restore()
  end
  if not succeeded then
    error(problem, 0)
  end
  return reported, observed
end

-- Item links ----------------------------------------------------------------------------------------

---The item link `C_Item.GetItemInfo` answers for `itemId`, or `nil` while the
---client has no data for it. The call may return nothing at all, so its
---results are read into locals before anything looks at them.
---@param getItemInfo function
---@param itemId integer
---@return string|nil
local function readItemLink(getItemInfo, itemId)
  local _, link = getItemInfo(itemId)
  if type(link) ~= "string" or isSecret(link) then
    return nil
  end
  return link
end

---The client's link for `itemId`, asking the server for the item's data and
---waiting up to `ITEM_WAIT_SECONDS` when the client has not cached it. Ends
---the test as skipped when the client has no `C_Item.GetItemInfo` or the
---server does not answer in time.
---@param ctx TestKit.Context
---@param itemId integer
---@return string link
local function requireItemLink(ctx, itemId)
  local getItemInfo = readHostFunction("C_Item", "GetItemInfo")
  if type(getItemInfo) == "nil" then
    Harness:SkipTest(ctx, "the client has no C_Item.GetItemInfo")
  end
  ---@cast getItemInfo function
  local link = readItemLink(getItemInfo, itemId)
  if type(link) == "nil" then
    ctx:Log(("item %d was not cached; asking the server for its data"):format(itemId))
    local requestLoad = readHostFunction("C_Item", "RequestLoadItemDataByID")
    if type(requestLoad) ~= "nil" then
      ---@cast requestLoad function
      requestLoad(itemId)
    end
    local loaded = ctx:WaitUntil(function()
      link = readItemLink(getItemInfo, itemId)
      return type(link) ~= "nil"
    end, ITEM_WAIT_SECONDS)
    if not loaded then
      Harness:SkipTest(
        ctx,
        ("C_Item.GetItemInfo(%d) answered no link within %d seconds; the server did not send the item data"):format(
          itemId,
          ITEM_WAIT_SECONDS
        )
      )
    end
  end
  ---@cast link string
  ctx:Log(("item %d link: %s"):format(itemId, showEscapes(link)))
  return link
end

-- Allocation ----------------------------------------------------------------------------------------

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
  local before = collectgarbage("count")
  work()
  return collectgarbage("count") - before
end

---Collect in a step of its own, measure `work`, log the delta and hold it to
---the tolerance. The full collection runs before `ctx:Yield()`, so the
---measurement starts far from the next collector cycle.
---@param ctx TestKit.Context
---@param label string what `work` does, for the log
---@param work fun()
local function expectNoAllocation(ctx, label, work)
  collectgarbage("collect")
  ctx:Yield()
  local grownKilobytes = measureAllocation(work)
  ctx:Log(("memory delta over %s: %.3f KB"):format(label, grownKilobytes))
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

---A sink that drops every line, for the allocation guards: a capture sink
---keeps lines, and the chat frame would show them.
local silentSink = {
  AddMessage = function() end,
}

-- The OptionsKit tree --------------------------------------------------------------------------------

--- The values behind the test tree's `get`/`set` options.
local optionValues = {
  scale = 1,
  shown = true,
  anchor = "CENTER",
  wiped = 0,
  writes = 0,
}

---Put the tree's values back to where every test starts.
local function resetOptionValues()
  optionValues.scale = 1
  optionValues.shown = true
  optionValues.anchor = "CENTER"
  optionValues.wiped = 0
  optionValues.writes = 0
end

---Define this addon's OptionsKit tree: a range, a toggle, a select and a
---button with a confirmation question, each over `optionValues`. The After
---hook undefines it. `extraArgs` adds options to the root.
---@param extraArgs table|nil
---@return any tree
local function defineTree(extraArgs)
  resetOptionValues()
  local args = {
    scale = {
      type = "range",
      name = "Scale",
      order = 1,
      min = 0.5,
      max = 2,
      get = function()
        return optionValues.scale
      end,
      set = function(_, value)
        optionValues.writes = optionValues.writes + 1
        optionValues.scale = value
      end,
    },
    shown = {
      type = "toggle",
      name = "Shown",
      order = 2,
      get = function()
        return optionValues.shown
      end,
      set = function(_, value)
        optionValues.writes = optionValues.writes + 1
        optionValues.shown = value
      end,
    },
    anchor = {
      type = "select",
      name = "Anchor",
      order = 3,
      values = { TOP = "Top", CENTER = "Center" },
      get = function()
        return optionValues.anchor
      end,
      set = function(_, value)
        optionValues.writes = optionValues.writes + 1
        optionValues.anchor = value
      end,
    },
    wipe = {
      type = "execute",
      name = "Wipe",
      order = 4,
      confirm = "Wipe the probe values?",
      func = function()
        optionValues.wiped = optionValues.wiped + 1
      end,
    },
  }
  for key, option in pairs(extraArgs or {}) do
    args[key] = option
  end
  treeDefined = true
  return OptionsKit:Define(addonName, { type = "group", name = "CommandKit probe", args = args })
end

---Bind the tree to `/mcttestopts` in the addon scope, with its output sent to
---a new capture sink, failing the test when the client refuses the name.
---@param ctx TestKit.Context
---@param tree any
---@return any sink
local function bindTree(ctx, tree)
  local sink = CommandKit:CaptureSink()
  addonScope:SetSink(sink)
  registeredNames[#registeredNames + 1] = OPTIONS_COMMAND_NAME
  local registered, reason =
    addonScope:BindOptions(tree, OPTIONS_COMMAND_NAME, { description = "Probe options." })
  if registered ~= true then
    ctx:Fail("BindOptions('" .. OPTIONS_COMMAND_NAME .. "') was refused: " .. tostring(reason))
  end
  return sink
end

-- commandKit.facade ---------------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('commandKit', 1) is the CommandKit facade with API 1, its methods, UNBOUNDED, MAX_COMMANDS 64 and MAX_DEPTH 3",
  function(ctx)
    ctx:Expect(type(CommandKit)):ToBe("table")
    ctx:Expect(rawget(CommandKit, "API")):ToBe(COMMAND_KIT_API)
    for _, methodName in ipairs({
      "CreateScope",
      "ForAddon",
      "CloseAddonScopes",
      "Parse",
      "ParseInto",
      "CaptureSink",
      "SetLimits",
      "GetLimits",
    }) do
      ctx:Expect(type(CommandKit[methodName])):ToBe("function")
    end
    ctx:Expect(type(CommandKit.UNBOUNDED)):ToBe("table")
    ctx:Expect(CommandKit.MAX_COMMANDS):ToBe(64)
    ctx:Expect(CommandKit.MAX_DEPTH):ToBe(3)
    ctx:Expect(type(CommandKit.Scope)):ToBe("table")
    ctx:Expect(type(CommandKit.Context)):ToBe("table")
    local limits = CommandKit:GetLimits()
    ctx:Log(
      ("limits in this session: maxCaptured %s, maxCompletions %s, maxEmotes %s"):format(
        tostring(limits.maxCaptured),
        tostring(limits.maxCompletions),
        tostring(limits.maxEmotes)
      )
    )
  end
)

facade:Test("the installed CommandKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, COMMAND_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(CommandKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list commandKit")
end)

facade:Test(
  "the client has SlashCmdList and a default chat frame with AddMessage, OptionsKit is found, and the other host facilities are logged",
  function(ctx)
    ctx:Expect(type(readHost("SlashCmdList"))):ToBe("table")
    local chatFrame = readHost("DEFAULT_CHAT_FRAME")
    ctx:Expect(type(chatFrame)):ToBe("table")
    ctx:Expect(type(chatFrame and chatFrame.AddMessage)):ToBe("function")
    local foundOptionsKit = Registry:Find("optionsKit", OPTIONS_KIT_API)
    ctx:Expect(type(foundOptionsKit)):ToBe("table")

    for _, name in ipairs({
      "SecureCmdList",
      "ChatTypeInfo",
      "MAXEMOTEINDEX",
      "EMOTE1_CMD1",
      "SLASH_SAY1",
      "hash_SlashCmdList",
      "ChatEdit_CustomTabPressed",
      "ChatEdit_GetActiveWindow",
      "ChatFrame1EditBox",
      "securecallfunction",
    }) do
      local value = readHost(name)
      local description = type(value)
      if type(value) == "string" or type(value) == "number" then
        description = description .. " " .. tostring(value)
      end
      ctx:Log(name .. ": " .. description)
    end
    local isSecureVariable = readHost("issecurevariable")
    if type(isSecureVariable) == "function" then
      for _, name in ipairs({ "ChatEdit_CustomTabPressed", "ChatEdit_GetActiveWindow" }) do
        if type(readHost(name)) ~= "nil" then
          ctx:Log(("issecurevariable('%s'): %s"):format(name, tostring(isSecureVariable(name))))
        end
      end
    end
    local editBox = chatEditBox()
    ctx:Log("the default chat frame's edit box: " .. type(editBox))
    for _, packageName in ipairs({ "localeKit", "clientKit", "lifecycleKit", "eventKit" }) do
      local found, revisionOrReason = Registry:Find(packageName, 1)
      ctx:Log(
        ("Registry:Find('%s', 1): %s %s"):format(
          packageName,
          type(found),
          tostring(revisionOrReason)
        )
      )
    end
  end
)

-- commandKit.registration ------------------------------------------------------------------------

local registration = newSuite("registration")

registration:Test(
  "Register('mcttestcmd') writes a function to the client's SlashCmdList under MOLTENCODES_<ADDON>_MCTTESTCMD and '/mcttestcmd' to its SLASH_ global",
  function(ctx)
    registerProbe(ctx)
    ctx:Log("key: " .. COMMAND_KEY)
    ctx:Expect(type(slashEntry(COMMAND_KEY))):ToBe("function")
    ctx:Expect(readHost("SLASH_" .. COMMAND_KEY .. "1")):ToBe("/" .. COMMAND_NAME)
    ctx:Expect(type(readHost("SLASH_" .. COMMAND_KEY .. "2"))):ToBe("nil")
    ctx:Expect(addonScope:IsRegistered(COMMAND_NAME)):ToBe(true)
    ctx:Expect(addonScope:IsRegistered("MctTestCmd")):ToBe(true)
    ctx:Expect(addonScope:GetActiveCount()):ToBe(1)
    ctx:Expect(addonScope:GetAddonName()):ToBe(addonName)
    ctx:Expect(CommandKit:ForAddon(addonName)):ToBe(addonScope)
    local hashTable = readHost("hash_SlashCmdList")
    if type(hashTable) == "table" then
      ctx:Log(
        "the client's slash cache holds /MCTTESTCMD (only after it was typed): "
          .. type(rawget(hashTable, "/" .. COMMAND_NAME:upper()))
      )
    end
  end
)

---Register `name` in a manual scope, expecting a refusal. Should the client's
---name be registered after all, the command is unregistered and its
---`SLASH_<key>1` global cleared at once, so the client never resolves the
---client's own command to CommandKit's inert entry for the rest of the
---session.
---@param ctx TestKit.Context
---@param name string
---@return any registered
---@return any reason
local function registerExpectingRefusal(ctx, name)
  local scope = newManualScope()
  local registered, reason = scope:Register(name, { handler = function() end })
  ctx:Log(("Register('%s'): %s, %s"):format(name, tostring(registered), tostring(reason)))
  if registered == true then
    scope:Unregister(name)
    local key = manualKey(name)
    if readHost("SLASH_" .. key .. "1") == "/" .. name:lower() then
      -- A safety net for a failed test only: the name belongs to the client.
      -- selene: allow(global_usage)
      rawset(_G, "SLASH_" .. key .. "1", nil)
    end
  end
  return registered, reason
end

---The name, without the slash, that `global` holds when it is a plain slash
---name CommandKit accepts, or `nil`.
---@param global string
---@return string|nil
local function slashNameIn(global)
  local value = readHost(global)
  if type(value) ~= "string" or isSecret(value) then
    return nil
  end
  local name = value:match("^/(%a[%w_]*)$")
  if type(name) == "nil" or #name > 32 then
    return nil
  end
  return name
end

---The first key, in sorted order, of the client's `SlashCmdList` that
---CommandKit did not write and whose `SLASH_<key>1` is a plain slash name, and
---that name.
---@return string|nil key
---@return string|nil name
local function firstClientSlashCommand()
  local slashList = readHost("SlashCmdList")
  if type(slashList) ~= "table" then
    return nil, nil
  end
  local keys = {}
  for key in next, slashList do
    if type(key) == "string" and key:sub(1, #"MOLTENCODES") ~= "MOLTENCODES" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local name = slashNameIn("SLASH_" .. key .. "1")
    if type(name) ~= "nil" then
      return key, name
    end
  end
  return nil, nil
end

registration:Test(
  "a name the client uses for a chat type (SLASH_SAY1) or for one of its slash commands is refused as taken, and an emote's name (EMOTE1_CMD1) as emote",
  function(ctx)
    local chatTypeName = slashNameIn("SLASH_SAY1")
    local slashKey, slashName = firstClientSlashCommand()
    local emoteName = slashNameIn("EMOTE1_CMD1")
    ctx:Log(
      ("SLASH_SAY1: %s; first client slash command: %s (%s); EMOTE1_CMD1: %s"):format(
        tostring(chatTypeName),
        tostring(slashName),
        tostring(slashKey),
        tostring(emoteName)
      )
    )
    if type(chatTypeName) == "nil" or type(slashName) == "nil" or type(emoteName) == "nil" then
      Harness:SkipTest(
        ctx,
        "the client has no SLASH_SAY1, no plain SLASH_<key>1 in SlashCmdList, or no EMOTE1_CMD1, so CommandKit's taken and emote checks have nothing to find (docs/API.md); send the log"
      )
    end
    ---@cast chatTypeName string
    ---@cast slashName string
    ---@cast emoteName string
    local chatTypeResult, chatTypeReason = registerExpectingRefusal(ctx, chatTypeName)
    ctx:Expect(chatTypeResult):ToBeNil()
    ctx:Expect(chatTypeReason):ToBe("taken")
    local slashResult, slashReason = registerExpectingRefusal(ctx, slashName)
    ctx:Expect(slashResult):ToBeNil()
    ctx:Expect(slashReason):ToBe("taken")
    local emoteResult, emoteReason = registerExpectingRefusal(ctx, emoteName)
    ctx:Expect(emoteResult):ToBeNil()
    ctx:Expect(emoteReason):ToBe("emote")
  end
)

registration:Test(
  "a closed scope leaves the client's SlashCmdList entry and SLASH_ global in place, inert and silent, and registering the name again answers through the same function",
  function(ctx)
    local sink = CommandKit:CaptureSink()
    local firstScope = newManualScope()
    firstScope:SetSink(sink)
    local calls = 0
    local registered = firstScope:Register(INERT_COMMAND_NAME, {
      handler = function(context, word)
        calls = calls + 1
        context:Print("inert probe", word)
      end,
    })
    ctx:Expect(registered):ToBe(true)
    local entry = slashEntry(INERT_COMMAND_KEY)
    ctx:Expect(type(entry)):ToBe("function")
    runSlash(INERT_COMMAND_KEY, "first")
    ctx:Expect(sink:Messages()):ToEqual({ "inert probe first" })

    ctx:Expect(firstScope:Close()):ToBe(true)
    ctx:Expect(slashEntry(INERT_COMMAND_KEY)):ToBe(entry)
    ctx:Expect(readHost("SLASH_" .. INERT_COMMAND_KEY .. "1")):ToBe("/" .. INERT_COMMAND_NAME)
    sink:Clear()
    local reported = collectReportedErrors(ctx, function()
      runSlash(INERT_COMMAND_KEY, "while closed")
    end)
    ctx:Expect(#reported):ToBe(0)
    ctx:Expect(sink:Messages()):ToEqual({})
    ctx:Expect(calls):ToBe(1)

    local secondScope = newManualScope()
    secondScope:SetSink(sink)
    ctx
      :Expect(secondScope:Register(INERT_COMMAND_NAME, {
        handler = function(context, word)
          calls = calls + 1
          context:Print("second owner", word)
        end,
      }))
      :ToBe(true)
    ctx:Expect(slashEntry(INERT_COMMAND_KEY)):ToBe(entry)
    runSlash(INERT_COMMAND_KEY, "again")
    ctx:Expect(sink:Messages()):ToEqual({ "second owner again" })
    ctx:Expect(calls):ToBe(2)
  end
)

registration:Test(
  "the addon scope is arranged to close at logout: LifecycleKit announces it closes commandKit scopes, and the scope is open now",
  function(ctx)
    local LifecycleKit = Registry:Find("lifecycleKit", 1)
    ctx:Expect(type(LifecycleKit)):ToBe("table")
    local closes = type(LifecycleKit) == "table" and rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
      or nil
    ctx:Expect(type(closes)):ToBe("table")
    ctx:Expect(type(closes) == "table" and closes[PACKAGE_ID] == true):ToBe(true)
    ctx:Log(
      "case (a) of docs/API.md, At logout: LifecycleKit closes this addon's scope after its shutdown callbacks"
    )
    ctx:Expect(addonScope:IsClosed()):ToBe(false)
  end
)

registration:Skip(
  "typing /mcttestcmd in the chat box reaches the same SlashCmdList entry",
  "needs the player to type; the tests call the SlashCmdList entry the chat box calls, see EXPECTED.md for the optional manual check"
)

registration:Skip(
  "the addon scope is closed when the player logs out",
  "logout ends the session the results are saved from; LifecycleKit's own client suite covers its shutdown callbacks"
)

-- commandKit.dispatch ---------------------------------------------------------------------------------

local dispatchSuite = newSuite("dispatch")

dispatchSuite:Test(
  "calling SlashCmdList.<key>('scale 1.5', the chat frame's edit box) runs the handler with the number 1.5 and writes only to the capture sink",
  function(ctx)
    local sink = registerProbe(ctx)
    local countBefore, lastBefore = readChatFrame()
    runSlash(COMMAND_KEY, "scale 1.5")
    local countAfter, lastAfter = readChatFrame()

    ctx:Expect(probe.calls):ToBe(1)
    ctx:Expect(probe.scale):ToBe(1.5)
    ctx:Expect(probe.commandPath):ToBe("/mcttestcmd scale")
    ctx:Expect(probe.rawText):ToBe("scale 1.5")
    ctx:Expect(sink:Messages()):ToEqual({ "Scale 1.50." })
    ctx:Log(
      ("chat frame lines before %s, after %s"):format(tostring(countBefore), tostring(countAfter))
    )
    ctx:Expect(countAfter):ToBe(countBefore)
    ctx:Expect(lastAfter):ToBe(lastBefore)
  end
)

dispatchSuite:Test(
  "/mcttestcmd with nothing after it prints the generated usage, and an unknown sub-command prints its name with the usage",
  function(ctx)
    local sink = registerProbe(ctx)
    runSlash(COMMAND_KEY, "")
    ctx:Expect(sink:Messages()):ToEqual(PROBE_USAGE)
    sink:Clear()

    runSlash(COMMAND_KEY, "fly away")
    local expected = { '/mcttestcmd: unknown sub-command "fly"' }
    for _, line in ipairs(PROBE_USAGE) do
      expected[#expected + 1] = line
    end
    ctx:Expect(sink:Messages()):ToEqual(expected)
    ctx:Expect(probe.calls):ToBe(0)
  end
)

dispatchSuite:Test(
  "arguments are checked against their schemas: scale 5 is refused with the schema's message and the usage, mode raid off converts off to false",
  function(ctx)
    local sink = registerProbe(ctx)
    runSlash(COMMAND_KEY, "scale 5")
    ctx:Expect(sink:Messages()):ToEqual({
      "/mcttestcmd scale: argument 1: expected number <= 2, found larger number",
      "Usage: /mcttestcmd scale <number 0.5..2>",
      "Set the probe scale.",
    })
    ctx:Expect(probe.calls):ToBe(0)
    sink:Clear()

    runSlash(COMMAND_KEY, "scale 1 2")
    ctx:Expect(sink:Messages()[1]):ToBe("/mcttestcmd scale: expected at most 1 argument")
    ctx:Expect(probe.calls):ToBe(0)
    sink:Clear()

    runSlash(COMMAND_KEY, "MODE raid off")
    ctx:Expect(probe.calls):ToBe(1)
    ctx:Expect(probe.mode):ToBe("raid")
    ctx:Expect(probe.quiet):ToBe(false)
    ctx:Expect(sink:Messages()):ToEqual({})

    runSlash(COMMAND_KEY, "mode loud")
    ctx:Expect(sink:Messages()):ToEqual({
      '/mcttestcmd mode: argument 1: expected one of "party", "raid", "all", found unlisted string',
      "Usage: /mcttestcmd mode <party|raid|all> [on|off]",
      "Choose the probe mode.",
    })
    ctx:Expect(probe.calls):ToBe(1)
  end
)

dispatchSuite:Test(
  "a handler that raises is reported to the sink as '/mcttestcmd boom failed' and to the client's error handler naming CommandKitSuite.lua at the raising line",
  function(ctx)
    local sink = registerProbe(ctx)
    local reported, observed = collectReportedErrors(ctx, function()
      runSlash(COMMAND_KEY, "boom")
    end)
    ctx:Expect(probe.calls):ToBe(1)
    local lines = sink:Messages()
    ctx:Expect(#lines):ToBe(1)
    ctx:Log("sink: " .. tostring(lines[1]))
    ctx
      :Expect((lines[1] or ""):sub(1, #"/mcttestcmd boom failed: "))
      :ToBe("/mcttestcmd boom failed: ")
    ctx:Expect((lines[1] or ""):sub(-#HANDLER_FAILURE)):ToBe(HANDLER_FAILURE)
    if not observed then
      ctx:Fail(
        "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"
      )
      return
    end
    ctx:Expect(#reported):ToBe(1)
    ctx:Log("reported: " .. tostring(reported[1]))
    local line = expectThisFile(ctx, reported[1])
    ctx:Expect(line):ToBe(probe.failureLine + 1)
  end
)

dispatchSuite:Test(
  "with no sink set, a handler's Print reaches the real default chat frame as its newest line (one visible line)",
  function(ctx)
    local registered = registerInAddonScope(COMMAND_NAME, newProbeSpec())
    ctx:Expect(registered):ToBe(true)
    addonScope:SetSink(nil)
    local countBefore = readChatFrame()
    if type(countBefore) == "nil" then
      Harness:SkipTest(
        ctx,
        "the default chat frame has no GetNumMessages and GetMessageInfo to read the line back"
      )
    end
    runSlash(COMMAND_KEY, "announce")
    local countAfter, lastAfter = readChatFrame()
    ctx:Log(
      ("chat frame lines before %s, after %s"):format(tostring(countBefore), tostring(countAfter))
    )
    ctx:Log("the chat frame's newest line: " .. tostring(lastAfter))
    ctx:Expect(probe.calls):ToBe(1)
    -- Compared from the end: a chat frame that shows timestamps may put one
    -- in front of the text an addon adds.
    ctx:Expect((lastAfter or ""):sub(-#DEFAULT_SINK_LINE)):ToBe(DEFAULT_SINK_LINE)
  end
)

-- commandKit.parser -----------------------------------------------------------------------------------

local parser = newSuite("parser")

parser:Test(
  "a real Linen Cloth (2589) link from C_Item.GetItemInfo, colour code and spaced name included, is one token bare, quoted and between two words",
  function(ctx)
    local link = requireItemLink(ctx, LINEN_CLOTH_ITEM_ID)
    ctx:Log("the link's text holds a space: " .. tostring(link:find(" ", 1, true) ~= nil))
    ctx:Expect(CommandKit:Parse(link)):ToEqual({ link })
    ctx:Expect(CommandKit:Parse('"' .. link .. '"')):ToEqual({ link })
    ctx:Expect(CommandKit:Parse("before " .. link .. " after")):ToEqual({ "before", link, "after" })
    local tokens = { "stale", "stale", "stale", "stale" }
    ctx:Expect(CommandKit:ParseInto("x " .. link, tokens)):ToBe(2)
    ctx:Expect(tokens):ToEqual({ "x", link })
  end
)

parser:Test(
  "watch followed by a real Hearthstone (6948) link and a quoted note hands the handler the whole link and the note, and the link passes the |Hitem: pattern",
  function(ctx)
    local link = requireItemLink(ctx, HEARTHSTONE_ITEM_ID)
    local sink = registerProbe(ctx)
    runSlash(COMMAND_KEY, "watch " .. link .. ' "for the log"')
    ctx:Expect(sink:Messages()):ToEqual({})
    ctx:Expect(probe.calls):ToBe(1)
    ctx:Expect(probe.link):ToBe(link)
    ctx:Expect(probe.note):ToBe("for the log")

    runSlash(COMMAND_KEY, "echo  " .. link .. "\t" .. link)
    ctx:Expect(probe.tokens):ToEqual({ link, link })
  end
)

parser:Test(
  "a real link cut before its closing |h is refused as an unterminated link, by Parse and by dispatch with the usage",
  function(ctx)
    local link = requireItemLink(ctx, HEARTHSTONE_ITEM_ID)
    local linkStart = link:find("|H", 1, true)
    ctx:Expect(type(linkStart)):ToBe("number")
    local cut = link:sub(1, (linkStart or 1) + 12)
    ctx:Log("cut link: " .. showEscapes(cut))
    local tokens, reason = CommandKit:Parse(cut)
    ctx:Expect(tokens):ToBeNil()
    ctx:Expect(reason):ToBe("unterminated link")

    local sink = registerProbe(ctx)
    runSlash(COMMAND_KEY, "watch " .. cut)
    local lines = sink:Messages()
    ctx:Expect(lines[1]):ToBe("/mcttestcmd: unterminated link")
    ctx:Expect(lines[2]):ToBe(PROBE_USAGE[1])
    ctx:Expect(probe.calls):ToBe(0)
  end
)

-- commandKit.options -------------------------------------------------------------------------------------

local optionsSuite = newSuite("options")

optionsSuite:Test(
  "BindOptions registers /mcttestopts over an OptionsKit tree: set scale 1.25 writes through the tree's set, get prints it, set shown off and set anchor top convert the words",
  function(ctx)
    local tree = defineTree()
    local sink = bindTree(ctx, tree)
    ctx:Expect(type(slashEntry(OPTIONS_COMMAND_KEY))):ToBe("function")
    ctx:Expect(readHost("SLASH_" .. OPTIONS_COMMAND_KEY .. "1")):ToBe("/" .. OPTIONS_COMMAND_NAME)

    runSlash(OPTIONS_COMMAND_KEY, "set scale 1.25")
    runSlash(OPTIONS_COMMAND_KEY, "get scale")
    runSlash(OPTIONS_COMMAND_KEY, "set shown off")
    runSlash(OPTIONS_COMMAND_KEY, "set anchor top")
    local lines = sink:Messages()
    for _, line in ipairs(lines) do
      ctx:Log("sink: " .. line)
    end
    ctx:Expect(optionValues.scale):ToBe(1.25)
    ctx:Expect(optionValues.shown):ToBe(false)
    ctx:Expect(optionValues.anchor):ToBe("TOP")
    ctx:Expect(optionValues.writes):ToBe(3)
    ctx
      :Expect(lines)
      :ToEqual({ "scale = 1.25", "scale = 1.25", "shown = off", "anchor = TOP (Top)" })
  end
)

optionsSuite:Test(
  "refusals of /mcttestopts: set scale 5 prints the schema's message, an unknown path and reset of a get/set option are refused, and nothing is written",
  function(ctx)
    local tree = defineTree()
    local sink = bindTree(ctx, tree)
    runSlash(OPTIONS_COMMAND_KEY, "set scale 5")
    runSlash(OPTIONS_COMMAND_KEY, "set scale big")
    runSlash(OPTIONS_COMMAND_KEY, "get nothing")
    runSlash(OPTIONS_COMMAND_KEY, "reset scale")
    local lines = sink:Messages()
    for _, line in ipairs(lines) do
      ctx:Log("sink: " .. line)
    end
    ctx:Expect(lines):ToEqual({
      "/mcttestopts set: expected number <= 2, found larger number",
      "/mcttestopts set: expected a number",
      '/mcttestopts get: unknown option "nothing"',
      '/mcttestopts reset: "scale" has no default to reset to',
    })
    ctx:Expect(optionValues.writes):ToBe(0)
    ctx:Expect(optionValues.scale):ToBe(1)
  end
)

optionsSuite:Test(
  "list prints one line per option of the tree, and exec wipe asks its question until the word confirm follows, then runs the button once",
  function(ctx)
    local tree = defineTree()
    local sink = bindTree(ctx, tree)
    runSlash(OPTIONS_COMMAND_KEY, "list")
    local listed = sink:Messages()
    for _, line in ipairs(listed) do
      ctx:Log("list: " .. line)
    end
    ctx:Expect(listed):ToEqual({
      "scale = 1 - Scale",
      "shown = on - Shown",
      "anchor = CENTER (Center) - Anchor",
      "wipe - Wipe (exec)",
    })
    sink:Clear()

    runSlash(OPTIONS_COMMAND_KEY, "exec wipe")
    ctx:Expect(sink:Messages()):ToEqual({
      "Wipe the probe values?",
      "Type /mcttestopts exec wipe confirm to run it.",
    })
    ctx:Expect(optionValues.wiped):ToBe(0)
    runSlash(OPTIONS_COMMAND_KEY, "exec wipe confirm")
    ctx:Expect(optionValues.wiped):ToBe(1)
  end
)

-- commandKit.completion ----------------------------------------------------------------------------------

local completionSuite = newSuite("completion")

---A stand-in for the chat edit box: the three methods CommandKit's completion
---calls, over a plain field, with the cursor at the end of the text. The real
---edit box is never touched, so nothing is typed and nothing is tainted.
---@param text string
---@return table
local function newStandInEditBox(text)
  local editBox = { text = text }
  function editBox.GetText(self)
    return self.text
  end
  function editBox.SetText(self, newText)
    self.text = newText
  end
  function editBox.GetCursorPosition(self)
    return #self.text
  end
  return editBox
end

---The client's `ChatEdit_CustomTabPressed`, or end the test as skipped.
---@param ctx TestKit.Context
---@return function
local function requireTabExtensionPoint(ctx)
  local tabPressed = readHost("ChatEdit_CustomTabPressed")
  if type(tabPressed) ~= "function" then
    Harness:SkipTest(
      ctx,
      "the client has no ChatEdit_CustomTabPressed; EnableCompletion returns false and completion is not available"
    )
  end
  ---@cast tabPressed function
  return tabPressed
end

completionSuite:Test(
  "EnableCompletion answers whether the client has ChatEdit_CustomTabPressed; when it does, it replaces the global, and DisableCompletion writes the client's function back",
  function(ctx)
    local original = readHost("ChatEdit_CustomTabPressed")
    local getActiveWindow = readHost("ChatEdit_GetActiveWindow")
    ctx:Log("ChatEdit_CustomTabPressed: " .. type(original))
    ctx:Log("ChatEdit_GetActiveWindow: " .. type(getActiveWindow))
    if type(getActiveWindow) == "function" then
      local succeeded, activeWindow = pcall(getActiveWindow)
      ctx:Log(
        ("ChatEdit_GetActiveWindow() with no chat box open: %s %s"):format(
          tostring(succeeded),
          type(activeWindow)
        )
      )
    end
    local isSecureVariable = readHost("issecurevariable")
    if type(original) ~= "function" then
      ctx:Expect(addonScope:EnableCompletion()):ToBe(false)
      ctx:Expect(type(readHost("ChatEdit_CustomTabPressed"))):ToBe("nil")
      return
    end
    if type(isSecureVariable) == "function" then
      ctx:Log(
        "issecurevariable before: " .. tostring(isSecureVariable("ChatEdit_CustomTabPressed"))
      )
    end
    ctx:Expect(addonScope:EnableCompletion()):ToBe(true)
    ctx:Expect(type(readHost("ChatEdit_CustomTabPressed"))):ToBe("function")
    ctx:Expect(readHost("ChatEdit_CustomTabPressed") == original):ToBe(false)
    ctx:Expect(addonScope:DisableCompletion()):ToBe(true)
    ctx:Expect(readHost("ChatEdit_CustomTabPressed")):ToBe(original)
    if type(isSecureVariable) == "function" then
      ctx:Log("issecurevariable after: " .. tostring(isSecureVariable("ChatEdit_CustomTabPressed")))
    end
  end
)

completionSuite:Test(
  "a Tab press handed to the installed ChatEdit_CustomTabPressed completes '/mcttestcmd sc' to 'scale ', lists every sub-command after '/mcttestcmd ', and completes a bound option path",
  function(ctx)
    requireTabExtensionPoint(ctx)
    local sink = registerProbe(ctx)
    bindTree(ctx, defineTree())
    addonScope:SetSink(sink)
    ctx:Expect(addonScope:EnableCompletion()):ToBe(true)
    local installed = readHost("ChatEdit_CustomTabPressed")

    local editBox = newStandInEditBox("/mcttestcmd sc")
    ctx:Expect(installed(editBox)):ToBe(true)
    ctx:Expect(editBox.text):ToBe("/mcttestcmd scale ")

    editBox = newStandInEditBox("/mcttestcmd ")
    ctx:Expect(installed(editBox)):ToBe(true)
    ctx:Expect(editBox.text):ToBe("/mcttestcmd ")
    ctx:Expect(sink:Messages()):ToEqual({ "announce  boom  echo  keep  mode  scale  watch" })

    editBox = newStandInEditBox("/mcttestopts set sc")
    ctx:Expect(installed(editBox)):ToBe(true)
    ctx:Expect(editBox.text):ToBe("/mcttestopts set scale ")
  end
)

completionSuite:Skip(
  "a real Tab press in the chat box calls ChatEdit_CustomTabPressed with that edit box",
  "needs the player to press Tab in the chat box; the tests hand the installed function a stand-in edit box instead"
)

-- commandKit.allocation --------------------------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "5000 dispatches of 'scale 1.5' through the client's SlashCmdList entry allocate nothing",
  function(ctx)
    registerProbe(ctx)
    addonScope:SetSink(silentSink)
    probe.quietScale = true
    runSlash(COMMAND_KEY, "scale 1.5")
    local entry = slashEntry(COMMAND_KEY)
    local editBox = chatEditBox()
    expectNoAllocation(ctx, ALLOCATION_CYCLES .. " dispatches", function()
      for _ = 1, ALLOCATION_CYCLES do
        entry("scale 1.5", editBox)
      end
    end)
    ctx:Expect(probe.calls):ToBe(ALLOCATION_CYCLES + 1)
    ctx:Expect(probe.scale):ToBe(1.5)
  end
)

allocation:Test(
  "5000 ParseInto calls over text holding a real Hearthstone link allocate nothing",
  function(ctx)
    local link = requireItemLink(ctx, HEARTHSTONE_ITEM_ID)
    local text = 'watch "' .. link .. '" note'
    local tokens = {}
    ctx:Expect(CommandKit:ParseInto(text, tokens)):ToBe(3)
    expectNoAllocation(ctx, ALLOCATION_CYCLES .. " ParseInto calls", function()
      for _ = 1, ALLOCATION_CYCLES do
        CommandKit:ParseInto(text, tokens)
      end
    end)
    ctx:Expect(tokens):ToEqual({ "watch", link, "note" })
  end
)

allocation:Test(
  "5000 calls to the inert SlashCmdList entry of an unregistered command allocate nothing",
  function(ctx)
    registerProbe(ctx)
    ctx:Expect(addonScope:Unregister(COMMAND_NAME)):ToBe(true)
    local entry = slashEntry(COMMAND_KEY)
    local editBox = chatEditBox()
    expectNoAllocation(ctx, ALLOCATION_CYCLES .. " inert calls", function()
      for _ = 1, ALLOCATION_CYCLES do
        entry("scale 1.5", editBox)
      end
    end)
    ctx:Expect(probe.calls):ToBe(0)
  end
)

-- commandKit.errors ----------------------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "a spec with an unknown field and a name with a hyphen are refused at the calling line",
  function(ctx)
    local scope = newManualScope()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      scope:Register("mcttestbad", { handler = function() end, desc = "misspelt" })
    end, lines, 'CommandKit.Scope:Register spec contains unknown field "desc"')
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        scope:Register("mct-test", { handler = function() end })
      end,
      lines,
      'CommandKit.Scope:Register name "mct-test" must be letters, digits and underscores, starting with a letter, at most 32 long'
    )
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

errors:Test(
  "registering /mcttestcmd twice in one scope, and Register on a closed scope, are refused at the calling line",
  function(ctx)
    registerProbe(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        addonScope:Register(COMMAND_NAME, newProbeSpec())
      end,
      lines,
      'CommandKit.Scope:Register "mcttestcmd" is already registered in this scope; Unregister it first'
    )
    local closed = newManualScope()
    closed:Close()
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      closed:Register("mcttestclosed", { handler = function() end })
    end, lines, "CommandKit.Scope:Register cannot be used on a closed scope")
  end
)

errors:Test(
  "SetSink with UIParent, a real Frame without AddMessage, and BindOptions with a plain table are refused at the calling line",
  function(ctx)
    local uiParent = readHost("UIParent")
    ctx:Expect(type(uiParent)):ToBe("table")
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      addonScope:SetSink(uiParent)
    end, lines, "CommandKit.Scope:SetSink sink must be a table with an AddMessage method")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      addonScope:BindOptions({ type = "group", args = {} }, OPTIONS_COMMAND_NAME)
    end, lines, "CommandKit.Scope:BindOptions tree must be an OptionsKit tree")
    ctx:Expect(addonScope:IsRegistered(OPTIONS_COMMAND_NAME)):ToBe(false)
  end
)

errors:Test(
  "a context kept past its command, and Parse called with a dot, are refused at the calling line",
  function(ctx)
    registerProbe(ctx)
    runSlash(COMMAND_KEY, "keep")
    ctx:Expect(probe.calls):ToBe(1)
    local kept = probe.keptContext
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      kept:Print("too late")
    end, lines, "CommandKit.Context:Print cannot be used after its command returned")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        CommandKit.Parse("text")
      end,
      lines,
      "CommandKit:Parse must be called on the CommandKit facade; use CommandKit:Parse(...)"
    )
  end
)

-- commandKit.secrets ------------------------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if SECRETS_AVAILABLE then
    secrets:Test(name, body)
  else
    secrets:Skip(name, SECRETS_SKIP_REASON)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
  local succeeded, secret = pcall(secretWrap, value)
  if not succeeded then
    ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
  end
  if isSecretValue(secret) ~= true then
    ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
  end
  return secret
end

secretTest("Parse and ParseInto refuse a secret text at the calling line", function(ctx)
  local secretText = makeSecret(ctx, "scale 1")
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    CommandKit:Parse(secretText)
  end, lines, "CommandKit:Parse text must not be a secret value")
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    CommandKit:ParseInto(secretText, {})
  end, lines, "CommandKit:ParseInto text must not be a secret value")
end)

secretTest(
  "Register with a secret name and CreateScope with a secret maxCommands are refused at the calling line",
  function(ctx)
    local secretName = makeSecret(ctx, "mcttestsecretname")
    local secretLimit = makeSecret(ctx, 8)
    local scope = newManualScope()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      scope:Register(secretName, { handler = function() end })
    end, lines, "CommandKit.Scope:Register name must not be a secret value")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        CommandKit:CreateScope({ maxCommands = secretLimit })
      end,
      lines,
      "CommandKit:CreateScope options.maxCommands must be a positive integer or CommandKit.UNBOUNDED"
    )
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

secretTest(
  "SetLimits with a secret maxCaptured or maxCompletions is refused at the calling line and the limits stay as they were",
  function(ctx)
    local before = CommandKit:GetLimits()
    local secretLimit = makeSecret(ctx, 16)
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        CommandKit:SetLimits({ maxCaptured = secretLimit })
      end,
      lines,
      "CommandKit:SetLimits limits.maxCaptured must be a positive integer or CommandKit.UNBOUNDED"
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CommandKit:SetLimits({ maxCompletions = secretLimit })
    end, lines, "CommandKit:SetLimits limits.maxCompletions must be an integer from 1 to 256")
    ctx:Expect(CommandKit:GetLimits()):ToEqual(before)
  end
)

secretTest(
  "inside a dispatched handler, context:Print and Printf refuse a secret argument at the handler's line in CommandKitSuite.lua and write nothing",
  function(ctx)
    local secretText = makeSecret(ctx, "hidden")
    local sink = CommandKit:CaptureSink()
    addonScope:SetSink(sink)
    local outcomes = {}
    local registered = registerInAddonScope(SECRET_COMMAND_NAME, {
      handler = function(context)
        local printLine = 0
        local printSucceeded, printMessage = pcall(function()
          printLine = currentLine()
          context:Print("value", secretText)
        end)
        local formatLine = 0
        local formatSucceeded, formatMessage = pcall(function()
          formatLine = currentLine()
          context:Printf("%s", secretText)
        end)
        outcomes[1] = { printSucceeded, printMessage, printLine }
        outcomes[2] = { formatSucceeded, formatMessage, formatLine }
      end,
    })
    ctx:Expect(registered):ToBe(true)
    runSlash(SECRET_COMMAND_KEY, "")
    ctx:Expect(#outcomes):ToBe(2)
    if #outcomes < 2 then
      return
    end
    expectCaughtError(
      ctx,
      outcomes[1][1],
      outcomes[1][2],
      outcomes[1][3],
      "CommandKit.Context:Print argument 2 must not be a secret value"
    )
    expectCaughtError(
      ctx,
      outcomes[2][1],
      outcomes[2][2],
      outcomes[2][3],
      "CommandKit.Context:Printf argument 2 must not be a secret value"
    )
    ctx:Expect(sink:Messages()):ToEqual({})
  end
)

secretTest(
  "a handler that raises a secret message writes '/mcttestsecret failed' without the message and hands the secret, still secret, to the client's error handler",
  function(ctx)
    local secretMessage = makeSecret(ctx, "a secret failure")
    local sink = CommandKit:CaptureSink()
    addonScope:SetSink(sink)
    local registered = registerInAddonScope(SECRET_COMMAND_NAME, {
      handler = function()
        error(secretMessage, 0)
      end,
    })
    ctx:Expect(registered):ToBe(true)
    local reported, observed = collectReportedErrors(ctx, function()
      runSlash(SECRET_COMMAND_KEY, "")
    end)
    ctx:Expect(sink:Messages()):ToEqual({ "/mcttestsecret failed" })
    if not observed then
      ctx:Fail(
        "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"
      )
      return
    end
    ctx:Expect(#reported):ToBe(1)
    ctx:Expect(isSecretValue(reported[1])):ToBe(true)
    ctx:Expect(type(reported[1])):ToBe(type(secretMessage))
  end
)

secretTest(
  "a bound option whose getter returns a secret prints '(secret value)', and set toggle on a secret toggle is refused and writes nothing",
  function(ctx)
    local secretNumber = makeSecret(ctx, 1.5)
    local secretFlag = makeSecret(ctx, true)
    local secretWrites = 0
    local tree = defineTree({
      level = {
        type = "range",
        name = "Level",
        order = 5,
        min = 0,
        max = 10,
        get = function()
          return secretNumber
        end,
        set = function()
          secretWrites = secretWrites + 1
        end,
      },
      flag = {
        type = "toggle",
        name = "Flag",
        order = 6,
        get = function()
          return secretFlag
        end,
        set = function()
          secretWrites = secretWrites + 1
        end,
      },
    })
    local sink = bindTree(ctx, tree)
    runSlash(OPTIONS_COMMAND_KEY, "get level")
    runSlash(OPTIONS_COMMAND_KEY, "set flag toggle")
    local lines = sink:Messages()
    for _, line in ipairs(lines) do
      ctx:Log("sink: " .. line)
    end
    ctx:Expect(lines):ToEqual({
      "level = (secret value)",
      "/mcttestopts set: the current value is secret; use on or off",
    })
    ctx:Expect(secretWrites):ToBe(0)
  end
)

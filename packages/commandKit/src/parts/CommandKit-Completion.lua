-- MoltenCodes CommandKit part Completion
--
-- Tab completion in chat edit boxes:
--
--   scope:EnableCompletion()          complete the scope's own commands: their
--                                     sub-command names and what each
--                                     command's `complete` function offers
--   scope:DisableCompletion()
--   scope:RegisterCompletion(name, pattern, provider)
--                                     AceTab-3.0's counterpart: complete any
--                                     word of chat input whose text before it
--                                     matches `pattern`
--   scope:UnregisterCompletion(name)
--   scope:IsCompletionRegistered(name)
--
-- The client calls `ChatEdit_CustomTabPressed(editBox)` from the chat edit
-- box's tab handler, after its own name auto-complete declined and before its
-- own completion, and skips the latter when the call returns `true`. Blizzard's
-- UI source declares the global empty and "left intentionally global ... to
-- enable secure tab completion hooks in addons"
-- (`Blizzard_ChatFrameBase/Shared/ChatFrameEditBox.lua`, the same on Retail,
-- Mists of Pandaria Classic and Classic Era). CommandKit replaces it with a
-- closure that remembers the previous function and calls it for any text it
-- does not complete. A secure post-hook (`hooksecurefunc`) cannot be used: its
-- return value is discarded, so the client would complete over CommandKit's
-- completion. The trade-off is taint: the global becomes addon code, as it
-- does for every addon that completes chat input. The closure is removed again
-- when no scope has completion enabled and no provider is registered, and
-- nobody has replaced the global since; otherwise it stays in the chain,
-- forwarding. See `docs/API.md`, "Tab completion".
--
-- Other edit boxes are not covered: the client calls the hook from chat edit
-- boxes alone, and completing elsewhere needs the frame's own `OnTabPressed`,
-- which a `HookScript` cannot stop.
--
-- Contents
-- --------
--   Constants ........ identity
--   Dependencies ..... CommandKit's core, its state and helpers
--   Candidates ....... matching, the common prefix, applying the result
--   Own commands ..... completing `/name <text>` of an enabled scope
--   Providers ........ the registered completion providers
--   Tab handler ...... the ChatEdit_CustomTabPressed replacement chain
--   Scope methods .... Enable/DisableCompletion, Register/Unregister/IsCompletionRegistered
--   Commit ........... the part's record, methods and dispatch

-- Constants ------------------------------------------------------------------

local PART_NAME = "Completion"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "commandKit", 1

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local CommandKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  CommandKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(CommandKit) == "table" and rawget(CommandKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "completion")) ~= "table"
then
  error("MoltenCodes CommandKit part Completion requires CommandKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every scope.
  return CommandKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")
-- Shared tables every revision keeps: the tab chain's state, the dispatch
-- table the installed closure calls through, the active command records and
-- the package-wide limits.
local completion = rawget(state, "completion")
local dispatch = rawget(state, "dispatch")
local activeByName = rawget(state, "activeByName")
local sharedLimits = rawget(state, "limits")

-- The registered providers in registration order, in the shared completion
-- state so every revision of the part walks the same list. Each entry is
-- `{ scope, name, pattern, provider }`.
if type(rawget(completion, "providers")) ~= "table" then
  rawset(completion, "providers", {})
end
local providers = rawget(completion, "providers")

---Read a client global without triggering a metatable on the global table.
---@param name string
---@return any
local function readGlobal(name)
  -- `ChatEdit_CustomTabPressed` and `ChatEdit_GetActiveWindow` are client globals of the chat edit box.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a client global without triggering a metatable on the global table.
---@param name string
---@param value any
local function writeGlobal(name, value)
  -- `ChatEdit_CustomTabPressed` is the client global an addon writes to extend the chat box.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

-- Candidates -----------------------------------------------------------------

---The longest common prefix of `candidates`.
---@param candidates string[]
---@return string
local function commonPrefix(candidates)
  local prefix = candidates[1]
  for index = 2, #candidates do
    local candidate = candidates[index]
    local length = 0
    local limit = math.min(#prefix, #candidate)
    while length < limit and prefix:byte(length + 1) == candidate:byte(length + 1) do
      length = length + 1
    end
    prefix = prefix:sub(1, length)
  end
  return prefix
end

---Add `candidate` to `candidates` when it starts with `partial`, ignoring case.
---A secret candidate (a `complete` function or a provider may return names read
---from the client) is skipped before it is compared.
---@param candidates string[]
---@param candidate any
---@param lowerPartial string
local function offer(candidates, candidate, lowerPartial)
  if
    type(candidate) ~= "string"
    or #candidates >= rawget(sharedLimits, "maxCompletions")
    or helpers.isSecret(candidate)
  then
    return
  end
  if candidate:sub(1, #lowerPartial):lower() == lowerPartial then
    candidates[#candidates + 1] = candidate
  end
end

---Offer every string of `offered`, when it is a table.
---@param candidates string[]
---@param offered any
---@param lowerPartial string
local function offerAll(candidates, offered, lowerPartial)
  if type(offered) == "table" then
    for position = 1, #offered do
      offer(candidates, offered[position], lowerPartial)
    end
  end
end

---Apply what was found: one candidate replaces the word and adds a space,
---several fill in their longest common start, and when that adds nothing they
---are listed on `scope`'s sink.
---@param editBox table
---@param before string the text before the word being completed
---@param partial string the word being completed
---@param candidates string[]
---@param scope CommandKit.Scope|nil whose sink lists the candidates; never `nil` when there are candidates
---@return boolean handled `false` when there is no candidate
local function applyCandidates(editBox, before, partial, candidates, scope)
  if #candidates == 0 then
    return false
  end
  if #candidates == 1 then
    editBox:SetText(before .. candidates[1] .. " ")
    return true
  end
  local prefix = commonPrefix(candidates)
  if #prefix > #partial then
    editBox:SetText(before .. prefix)
  elseif scope ~= nil then
    helpers.writeLine(scope, table.concat(candidates, "  "))
  end
  return true
end

-- Own commands ---------------------------------------------------------------

---Complete the word before the cursor in a borrowed frame.
---@param frame table
---@param record table the top-level record
---@param editBox table
---@param text string the whole edit-box text
---@param argumentText string the text between the slash name and the partial word
---@param partial string the word being completed
---@param partialStart integer where `partial` starts in `text`
---@return boolean handled
local function completeInFrame(frame, record, editBox, text, argumentText, partial, partialStart)
  local scope = rawget(record, "_scope")
  local tokens = frame.tokens
  local count = helpers.tokenize(argumentText, tokens)
  if count == nil then
    return false
  end
  local node, index = helpers.walkSubcommands(record, tokens, count)
  local context = helpers.openContext(frame, node, argumentText .. partial)
  local candidates = {}
  local lowerPartial = partial:lower()
  if index > count then
    local names = rawget(node, "_subcommandNames")
    for position = 1, #names do
      offer(candidates, names[position], lowerPartial)
    end
  end
  local complete = rawget(node, "_complete")
  if complete ~= false then
    offerAll(candidates, complete(context, partial, count - index + 2), lowerPartial)
  end
  return applyCandidates(editBox, text:sub(1, partialStart - 1), partial, candidates, scope)
end

---Complete `/name <text>` when `/name` belongs to a scope with completion on.
---@param editBox table
---@param text string
---@param partialStart integer
---@param partial string
---@return boolean handled
local function completeOwnCommand(editBox, text, partialStart, partial)
  -- A bare `/name` without a space is the client's own slash completion.
  local slashName, argumentStart = text:match("^/([%w_]+)%s+()")
  if slashName == nil then
    return false
  end
  local record = activeByName[slashName:lower()]
  if record == nil or rawget(rawget(record, "_scope"), "_completion") ~= true then
    return false
  end
  local argumentText = text:sub(argumentStart, partialStart - 1)
  local frame = helpers.acquireFrame()
  if frame == nil then
    return false
  end
  local ok, handled =
    pcall(completeInFrame, frame, record, editBox, text, argumentText, partial, partialStart)
  helpers.releaseFrame(frame)
  if not ok then
    error(handled, 0)
  end
  return handled
end

-- Providers ------------------------------------------------------------------

---Ask every provider whose pattern matches the text before the word. A
---provider that raises is reported and the others still run.
---@param editBox table
---@param before string
---@param partial string
---@return boolean handled
local function completeFromProviders(editBox, before, partial)
  local candidates = {}
  local lowerPartial = partial:lower()
  local listingScope = nil
  for index = 1, #providers do
    local entry = providers[index]
    if before:find(entry.pattern) ~= nil then
      local ok, offered = pcall(entry.provider, partial, before, editBox)
      if not ok then
        helpers.reportError(offered)
      else
        local count = #candidates
        offerAll(candidates, offered, lowerPartial)
        if listingScope == nil and #candidates > count then
          listingScope = entry.scope
        end
      end
    end
  end
  return applyCandidates(editBox, before, partial, candidates, listingScope)
end

---Remove the provider at `index`, keeping the order of the others.
---@param index integer
local function removeProvider(index)
  local entry = providers[index]
  table.remove(providers, index)
  local scope = entry.scope
  rawset(scope, "_completionProviders", (rawget(scope, "_completionProviders") or 1) - 1)
end

---The index of `scope`'s provider called `name`, or `nil`.
---@param scope CommandKit.Scope
---@param name string
---@return integer|nil
local function findProvider(scope, name)
  for index = 1, #providers do
    local entry = providers[index]
    if entry.scope == scope and entry.name == name then
      return index
    end
  end
  return nil
end

-- Tab handler ----------------------------------------------------------------

---Try to complete the edit box's text. `true` when CommandKit handled it.
---@param editBox any
---@return boolean handled
local function tryComplete(editBox)
  if type(editBox) == "nil" then
    local getActiveWindow = readGlobal("ChatEdit_GetActiveWindow")
    if type(getActiveWindow) == "function" then
      editBox = getActiveWindow()
    end
  end
  if
    type(editBox) ~= "table"
    or type(editBox.GetText) ~= "function"
    or type(editBox.SetText) ~= "function"
  then
    return false
  end
  local text = editBox:GetText()
  if type(text) ~= "string" or helpers.isSecret(text) then
    return false
  end
  if type(editBox.GetCursorPosition) == "function" then
    local cursor = editBox:GetCursorPosition()
    -- A secret cursor cannot be compared; completing without knowing
    -- where the cursor is could rewrite text after it, so leave it.
    if type(cursor) == "number" and (helpers.isSecret(cursor) or cursor < #text) then
      return false
    end
  end
  local lastSpace = text:find("%s[^%s]*$")
  local partialStart = lastSpace ~= nil and lastSpace + 1 or 1
  local partial = text:sub(partialStart)
  if completion.enabledScopes > 0 and completeOwnCommand(editBox, text, partialStart, partial) then
    return true
  end
  if #providers == 0 then
    return false
  end
  return completeFromProviders(editBox, text:sub(1, partialStart - 1), partial)
end

---The body of the installed `ChatEdit_CustomTabPressed` replacement.
---@param editBox any
---@param ... any
---@return any
local function tabPressed(editBox, ...)
  if completion.enabledScopes > 0 or #providers > 0 then
    local ok, handled = pcall(tryComplete, editBox)
    if not ok then
      helpers.reportError(handled)
    elseif handled then
      return true
    end
  end
  local previous = completion.previous
  if type(previous) == "function" then
    return previous(editBox, ...)
  end
  return false
end

---Install the replacement once. `false` when the host has no
---`ChatEdit_CustomTabPressed`.
---@return boolean
local function installTabHandler()
  if completion.installed then
    return true
  end
  local current = readGlobal("ChatEdit_CustomTabPressed")
  if type(current) ~= "function" then
    return false
  end
  local handler = completion.handler
  if handler == false then
    handler = function(editBox, ...)
      return dispatch.tabPressed(editBox, ...)
    end
    completion.handler = handler
  end
  if current ~= handler then
    completion.previous = current
    writeGlobal("ChatEdit_CustomTabPressed", handler)
  end
  completion.installed = true
  return true
end

---Remove the replacement when nothing uses it any more and it is still the
---installed function; otherwise leave it in the chain, forwarding to the
---function it replaced.
local function uninstallTabHandlerWhenUnused()
  if not completion.installed or completion.enabledScopes > 0 or #providers > 0 then
    return
  end
  local current = readGlobal("ChatEdit_CustomTabPressed")
  if type(current) ~= "function" or current ~= completion.handler then
    return
  end
  writeGlobal("ChatEdit_CustomTabPressed", completion.previous)
  completion.previous = false
  completion.installed = false
end

---Turn a scope's completion off, if it was on.
---@param scope CommandKit.Scope
---@return boolean disabled
local function disableCompletion(scope)
  if rawget(scope, "_completion") ~= true then
    return false
  end
  rawset(scope, "_completion", false)
  completion.enabledScopes = completion.enabledScopes - 1
  uninstallTabHandlerWhenUnused()
  return true
end

---Release everything of `scope` this part holds: its completion and its
---providers. The core's `Close` calls it.
---@param scope CommandKit.Scope
local function releaseScope(scope)
  if rawget(scope, "_completion") == true then
    rawset(scope, "_completion", false)
    completion.enabledScopes = completion.enabledScopes - 1
  end
  if (rawget(scope, "_completionProviders") or 0) > 0 then
    for index = #providers, 1, -1 do
      if providers[index].scope == scope then
        removeProvider(index)
      end
    end
  end
  uninstallTabHandlerWhenUnused()
end

-- Scope methods --------------------------------------------------------------

---Complete this scope's sub-command names and arguments on Tab. Returns
---`false` when the host has no `ChatEdit_CustomTabPressed`.
---@param self CommandKit.Scope
---@return boolean enabled
local function scopeEnableCompletion(self)
  helpers.validateScope(self, "CommandKit.Scope:EnableCompletion", 3)
  helpers.ensureOpen(self, "CommandKit.Scope:EnableCompletion", 3)
  if rawget(self, "_completion") == true then
    return true
  end
  if not installTabHandler() then
    return false
  end
  rawset(self, "_completion", true)
  completion.enabledScopes = completion.enabledScopes + 1
  return true
end

---Stop completing this scope's commands.
---@param self CommandKit.Scope
---@return boolean disabled `false` when completion was not enabled.
local function scopeDisableCompletion(self)
  helpers.validateScope(self, "CommandKit.Scope:DisableCompletion", 3)
  return disableCompletion(self)
end

---Complete any word of chat input whose preceding text matches `pattern`
---(a Lua pattern; `""` matches anywhere) with what `provider(partial, before,
---editBox)` returns. AceTab-3.0's `RegisterTabCompletion`.
---@param self CommandKit.Scope
---@param name string the provider's name in this scope
---@param pattern string
---@param provider fun(partial: string, before: string, editBox: table): string[]?
---@return true|nil registered
---@return "taken"|"full"|"unavailable"|nil reason
local function scopeRegisterCompletion(self, name, pattern, provider)
  local methodName = "CommandKit.Scope:RegisterCompletion"
  helpers.validateScope(self, methodName, 3)
  helpers.ensureOpen(self, methodName, 3)
  helpers.validateString(name, methodName .. " name", 3)
  if type(pattern) ~= "string" then
    error(methodName .. " pattern must be a string", 2)
  end
  if helpers.isSecret(pattern) then
    error(methodName .. " pattern must not be a secret value", 2)
  end
  -- A malformed pattern raises here, at registration, not on every Tab press.
  local valid, problem = pcall(string.find, "", pattern)
  if not valid then
    error(methodName .. " pattern is not a valid Lua pattern: " .. tostring(problem), 2)
  end
  if type(provider) ~= "function" then
    error(methodName .. " provider must be a function", 2)
  end
  if findProvider(self, name) ~= nil then
    return nil, "taken"
  end
  if #providers >= rawget(sharedLimits, "maxCompletionProviders") then
    return nil, "full"
  end
  if not installTabHandler() then
    return nil, "unavailable"
  end
  providers[#providers + 1] = { scope = self, name = name, pattern = pattern, provider = provider }
  rawset(self, "_completionProviders", (rawget(self, "_completionProviders") or 0) + 1)
  return true
end

---Remove this scope's provider called `name`.
---@param self CommandKit.Scope
---@param name string
---@return boolean removed `false` when the scope has no such provider
local function scopeUnregisterCompletion(self, name)
  helpers.validateScope(self, "CommandKit.Scope:UnregisterCompletion", 3)
  helpers.validateString(name, "CommandKit.Scope:UnregisterCompletion name", 3)
  local index = findProvider(self, name)
  if index == nil then
    return false
  end
  removeProvider(index)
  uninstallTabHandlerWhenUnused()
  return true
end

---Whether this scope has a provider called `name`.
---@param self CommandKit.Scope
---@param name string
---@return boolean
local function scopeIsCompletionRegistered(self, name)
  helpers.validateScope(self, "CommandKit.Scope:IsCompletionRegistered", 3)
  helpers.validateString(name, "CommandKit.Scope:IsCompletionRegistered name", 3)
  return findProvider(self, name) ~= nil
end

-- Commit ---------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  methods = {
    EnableCompletion = scopeEnableCompletion,
    DisableCompletion = scopeDisableCompletion,
    RegisterCompletion = scopeRegisterCompletion,
    UnregisterCompletion = scopeUnregisterCompletion,
    IsCompletionRegistered = scopeIsCompletionRegistered,
  },
  releaseScope = releaseScope,
})
rawset(dispatch, "tabPressed", tabPressed)
helpers.installPartMethods()

return CommandKit

--- Package-specific test environment for the CommandKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the chat host
--- surface only CommandKit touches, which the shared fixture does not model:
---
---   `SlashCmdList`                 a plain table, as in the client;
---   `DEFAULT_CHAT_FRAME`           a frame whose `AddMessage` records lines,
---                                  read back with `ChatLines`;
---   `ChatEdit_CustomTabPressed`    the client's empty extension point, here
---                                  counting its calls and returning `false`;
---   `ChatEdit_GetActiveWindow`     returns the edit box `SetActiveEditBox` set;
---   `ChatTypeInfo`                 two chat types, `SAY` (`/s`, `/say`) and
---                                  `GUILD` (`/g`, `/guild`), as `SLASH_<TYPE><n>`;
---   `EMOTE<n>_CMD<m>`              two emotes, `/dance` and `/wave` (`/greet`);
---   `RunSlash(text)`               what the client does with a typed line:
---                                  find the key whose `SLASH_<key><n>` matches
---                                  and call `SlashCmdList[key](rest, editBox)`.
---
--- These globals are installed by `NewPackage` and removed again by `Reset`,
--- because they are not among the globals the shared fixture owns, together
--- with every `SLASH_*` and `EMOTE*_CMD*` global.
---
--- OptionsKit, LocaleKit and ClientKit are optional dependencies of
--- CommandKit, declared under `optionalDependencies`, so the test runner puts
--- them on `LUA_PATH`; `NewPackage` loads OptionsKit (and SignalKit, which it
--- needs), `NewPackageWithLocaleKit` adds LocaleKit, `NewPackageWithClientKit`
--- adds ClientKit, and `NewPackageAlone` models an addon that embeds only
--- Registry, SchemaKit and CommandKit.
local FrameworkTestEnv = require("FrameworkTestEnv")

local CommandKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "SchemaKit", "OptionsKit", "CommandKit" },
})

--- The chat globals this environment installs and removes.
local CHAT_GLOBALS = {
    "SlashCmdList",
    "SecureCmdList",
    "DEFAULT_CHAT_FRAME",
    "ChatEdit_CustomTabPressed",
    "ChatEdit_GetActiveWindow",
    "ChatTypeInfo",
    "MAXEMOTEINDEX",
}

--- Every module a variant of `NewPackage` may load, cleared by `Reset`.
local EXTRA_MODULES = { "LocaleKit", "ClientKit" }

local chatLines = {}
local originalTabCalls = 0
local activeEditBox = nil

---Write a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

---Read a host global the same way.
---@param name string
---@return any
local function getGlobal(name)
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---The client's own `ChatEdit_CustomTabPressed`: an empty extension point.
---@return boolean
local function originalTabPressed()
    originalTabCalls = originalTabCalls + 1
    return false
end

---Install the chat host globals. Must run before a spec registers anything.
function CommandKitTestEnv.InstallChatApi()
    setGlobal("SlashCmdList", {})
    setGlobal("DEFAULT_CHAT_FRAME", {
        AddMessage = function(_, text)
            chatLines[#chatLines + 1] = text
        end,
    })
    setGlobal("ChatEdit_CustomTabPressed", originalTabPressed)
    setGlobal("ChatEdit_GetActiveWindow", function()
        return activeEditBox
    end)
    setGlobal("ChatTypeInfo", { SAY = {}, GUILD = {} })
    setGlobal("SLASH_SAY1", "/s")
    setGlobal("SLASH_SAY2", "/say")
    setGlobal("SLASH_GUILD1", "/g")
    setGlobal("SLASH_GUILD2", "/guild")
    setGlobal("EMOTE1_CMD1", "/dance")
    setGlobal("EMOTE2_CMD1", "/wave")
    setGlobal("EMOTE2_CMD2", "/greet")
end

local sharedReset = CommandKitTestEnv.Reset

---Clear every module, global and stub this environment owns, including the
---chat globals and every `SLASH_*` global.
function CommandKitTestEnv.Reset()
    sharedReset()
    for index = 1, #EXTRA_MODULES do
        package.loaded[EXTRA_MODULES[index]] = nil
    end
    for index = 1, #CHAT_GLOBALS do
        setGlobal(CHAT_GLOBALS[index], nil)
    end
    local slashNames = {}
    -- selene: allow(global_usage)
    for name in pairs(_G) do
        if type(name) == "string" and (name:find("^SLASH_") or name:find("^EMOTE%d+_CMD%d+$")) then
            slashNames[#slashNames + 1] = name
        end
    end
    for index = 1, #slashNames do
        setGlobal(slashNames[index], nil)
    end
    chatLines = {}
    originalTabCalls = 0
    activeEditBox = nil
end

---Reset, install the host stubs and the chat globals, then load Registry,
---SignalKit, SchemaKit, OptionsKit and CommandKit.
---@return table CommandKit
---@return table Registry
---@return table SignalKit
---@return table SchemaKit
---@return table OptionsKit
function CommandKitTestEnv.NewPackage()
    CommandKitTestEnv.Reset()
    CommandKitTestEnv.InstallWowApi()
    CommandKitTestEnv.InstallChatApi()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    local SchemaKit = require("SchemaKit")
    local OptionsKit = require("OptionsKit")
    local CommandKit = require("CommandKit")
    return CommandKit, Registry, SignalKit, SchemaKit, OptionsKit
end

---As `NewPackage`, with LocaleKit loaded too.
---@return table CommandKit
---@return table SchemaKit
---@return table LocaleKit
function CommandKitTestEnv.NewPackageWithLocaleKit()
    local CommandKit, _, _, SchemaKit = CommandKitTestEnv.NewPackage()
    local LocaleKit = require("LocaleKit")
    return CommandKit, SchemaKit, LocaleKit
end

---As `NewPackage`, with ClientKit loaded too.
---@return table CommandKit
---@return table ClientKit
function CommandKitTestEnv.NewPackageWithClientKit()
    local CommandKit = CommandKitTestEnv.NewPackage()
    local ClientKit = require("ClientKit")
    return CommandKit, ClientKit
end

---Load Registry, SchemaKit and CommandKit only, as an addon that embeds
---neither OptionsKit nor LocaleKit does.
---@return table CommandKit
---@return table Registry
---@return table SchemaKit
function CommandKitTestEnv.NewPackageAlone()
    CommandKitTestEnv.Reset()
    CommandKitTestEnv.InstallWowApi()
    CommandKitTestEnv.InstallChatApi()
    local Registry = require("Registry")
    local SchemaKit = require("SchemaKit")
    local CommandKit = require("CommandKit")
    return CommandKit, Registry, SchemaKit
end

---Read a global, for specs that inspect the slash tables.
---@param name string
---@return any
function CommandKitTestEnv.GetGlobal(name)
    return getGlobal(name)
end

---Write a global, for specs that model another addon or a missing host table.
---@param name string
---@param value any
function CommandKitTestEnv.SetGlobal(name, value)
    setGlobal(name, value)
end

---Every line `DEFAULT_CHAT_FRAME` received, in order.
---@return string[]
function CommandKitTestEnv.ChatLines()
    local copy = {}
    for index = 1, #chatLines do
        copy[index] = chatLines[index]
    end
    return copy
end

---How often the client's own `ChatEdit_CustomTabPressed` ran.
---@return integer
function CommandKitTestEnv.OriginalTabCalls()
    return originalTabCalls
end

---The client's own `ChatEdit_CustomTabPressed`, for identity checks.
---@return function
function CommandKitTestEnv.OriginalTabPressed()
    return originalTabPressed
end

---Find the slash-table key whose `SLASH_<key><n>` globals include `slash`,
---ignoring case, as the client does.
---@param slash string `"/name"`
---@return string|nil key
function CommandKitTestEnv.FindSlashKey(slash)
    local list = getGlobal("SlashCmdList")
    local upper = slash:upper()
    for key in pairs(list) do
        local index = 1
        while true do
            local value = getGlobal("SLASH_" .. key .. index)
            if value == nil then
                break
            end
            if value:upper() == upper then
                return key
            end
            index = index + 1
        end
    end
    return nil
end

---Run a typed chat line the way the client does: split off `/name`, find its
---key and call the slash function with the rest of the line.
---@param line string
---@param editBox table?
function CommandKitTestEnv.RunSlash(line, editBox)
    local slash, rest = line:match("^(/%S+)%s*(.*)$")
    if slash == nil then
        error("CommandKitTestEnv.RunSlash expects a line starting with /name", 2)
    end
    local key = CommandKitTestEnv.FindSlashKey(slash)
    if key == nil then
        error("CommandKitTestEnv.RunSlash found no slash command " .. slash, 2)
    end
    getGlobal("SlashCmdList")[key](rest, editBox)
end

---Build a fake chat edit box holding `text`, with the cursor at the end.
---@param text string
---@return table editBox
function CommandKitTestEnv.NewEditBox(text)
    local editBox = { text = text }
    function editBox:GetText()
        return self.text
    end
    function editBox:SetText(value)
        self.text = value
    end
    function editBox:GetCursorPosition()
        return #self.text
    end
    return editBox
end

---Make `ChatEdit_GetActiveWindow` return `editBox`.
---@param editBox table|nil
function CommandKitTestEnv.SetActiveEditBox(editBox)
    activeEditBox = editBox
end

---Press Tab in `editBox` the way the client does: call the current
---`ChatEdit_CustomTabPressed` and return what it answered.
---@param editBox table|nil
---@return any
function CommandKitTestEnv.PressTab(editBox)
    return getGlobal("ChatEdit_CustomTabPressed")(editBox)
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function CommandKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the CommandKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table CommandKit
function CommandKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "CommandKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("CommandKitTestEnv.LoadRevision could not find CommandKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("CommandKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return CommandKitTestEnv

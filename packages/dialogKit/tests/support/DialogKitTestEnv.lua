--- Package-specific test environment for the DialogKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`;
--- its `FrameStub` models frames, scroll frames, textures and font strings,
--- measuring a text at 6 pixels a character and 12 a line. What stays here is
--- this package's module load order and the helpers only its specs need:
---
---   the screen       `UIParent`, 1920 x 1080 at the origin;
---   the cursor       `SetMouseOver(frame, over)` gives a frame an
---                    `IsMouseOver` answering `over`, which the shared stub
---                    does not model;
---   secret values    `InstallSecretProbe` and `NewSecret`;
---   upgrades         `LoadRevision`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local DialogKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "DialogKit" },
})

local secrets = setmetatable({}, { __mode = "k" })
local clock = 0
local sharedNewPackage = DialogKitTestEnv.NewPackage

---Read a host global.
---@param name string
---@return any
function DialogKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function DialogKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Reset, install the host stubs, load the module chain and create the screen.
---@return table DialogKit
---@return table Registry
function DialogKitTestEnv.NewPackage()
  local DialogKit, Registry = sharedNewPackage()
  local uiParent = DialogKitTestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  clock = 100
  DialogKitTestEnv.SetGlobal("GetTime", function()
    return clock
  end)
  DialogKitTestEnv.SetGlobal("UISpecialFrames", { "ItemRefTooltip" })
  return DialogKit, Registry
end

---Hide every shown frame `UISpecialFrames` names, as the client's Escape does.
function DialogKitTestEnv.PressEscape()
  for _, name in ipairs(DialogKitTestEnv.GetGlobal("UISpecialFrames")) do
    local frame = DialogKitTestEnv.GetGlobal(name)
    if type(frame) == "table" and frame:IsShown() then
      frame:Hide()
    end
  end
end

---Set the client's time.
---@param seconds number
function DialogKitTestEnv.SetTime(seconds)
  clock = seconds
end

---Move the client's time on by `seconds` and run `frame`'s `OnUpdate` once,
---as the next frame would.
---@param frame table
---@param seconds number
function DialogKitTestEnv.Advance(frame, seconds)
  clock = clock + seconds
  local onUpdate = frame:GetScript("OnUpdate")
  if onUpdate then
    onUpdate(frame, seconds)
  end
end

---Clear everything the shared fixture clears, plus `GetTime`.
local sharedReset = DialogKitTestEnv.Reset
function DialogKitTestEnv.Reset()
  sharedReset()
  DialogKitTestEnv.SetGlobal("GetTime", nil)
  DialogKitTestEnv.SetGlobal("UISpecialFrames", nil)
end

---Run one of `frame`'s scripts as the client would.
---@param frame table
---@param scriptName string
---@param ... any
function DialogKitTestEnv.Run(frame, scriptName, ...)
  local script = frame:GetScript(scriptName)
  assert(type(script) == "function", "the frame has no " .. scriptName .. " script")
  script(frame, ...)
end

---The values the host error handler received since the last call.
---@return any[]
function DialogKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(DialogKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function DialogKitTestEnv.InstallSecretProbe()
  DialogKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function DialogKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Load the DialogKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table DialogKit
function DialogKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "DialogKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("DialogKitTestEnv.LoadRevision could not find DialogKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("DialogKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return DialogKitTestEnv

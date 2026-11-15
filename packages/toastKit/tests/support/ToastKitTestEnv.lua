--- Package-specific test environment for the ToastKit suite.
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

local ToastKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit", "ToastKit" },
})

local secrets = setmetatable({}, { __mode = "k" })
local sharedNewPackage = ToastKitTestEnv.NewPackage

---Read a host global.
---@param name string
---@return any
function ToastKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function ToastKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Reset, install the host stubs, load the module chain and create the screen.
---@return table ToastKit
---@return table PoolKit
---@return table Registry
function ToastKitTestEnv.NewPackage()
  local ToastKit, Registry, PoolKit = sharedNewPackage()
  local uiParent = ToastKitTestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  return ToastKit, PoolKit, Registry
end

---A frame at `x`, `y` (its bottom-left corner) on the screen, 40 x 20.
---@param x number
---@param y number
---@return table frame
function ToastKitTestEnv.FrameAt(x, y)
  local frame =
    ToastKitTestEnv.GetGlobal("CreateFrame")("Frame", nil, ToastKitTestEnv.GetGlobal("UIParent"))
  frame:SetSize(40, 20)
  frame:SetPoint("BOTTOMLEFT", ToastKitTestEnv.GetGlobal("UIParent"), "BOTTOMLEFT", x, y)
  return frame
end

---Make `frame:IsMouseOver()` answer `over`.
---@param frame table
---@param over any
function ToastKitTestEnv.SetMouseOver(frame, over)
  frame.IsMouseOver = function()
    return over
  end
end

---Run one of `frame`'s scripts as the client would.
---@param frame table
---@param scriptName string
---@param ... any
function ToastKitTestEnv.Run(frame, scriptName, ...)
  local script = frame:GetScript(scriptName)
  assert(type(script) == "function", "the frame has no " .. scriptName .. " script")
  script(frame, ...)
end

---The values the host error handler received since the last call.
---@return any[]
function ToastKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(ToastKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function ToastKitTestEnv.InstallSecretProbe()
  ToastKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function ToastKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Load the ToastKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table ToastKit
function ToastKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "ToastKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("ToastKitTestEnv.LoadRevision could not find ToastKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("ToastKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return ToastKitTestEnv

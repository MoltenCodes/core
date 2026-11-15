--- Package-specific test environment for the TooltipKit suite.
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

local TooltipKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit", "TooltipKit" },
})

local secrets = setmetatable({}, { __mode = "k" })
local sharedNewPackage = TooltipKitTestEnv.NewPackage

---Read a host global.
---@param name string
---@return any
function TooltipKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function TooltipKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Reset, install the host stubs, load the module chain and create the screen.
---@return table TooltipKit
---@return table PoolKit
---@return table Registry
function TooltipKitTestEnv.NewPackage()
  local TooltipKit, Registry, PoolKit = sharedNewPackage()
  local uiParent = TooltipKitTestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  return TooltipKit, PoolKit, Registry
end

---A frame at `x`, `y` (its bottom-left corner) on the screen, 40 x 20.
---@param x number
---@param y number
---@return table frame
function TooltipKitTestEnv.FrameAt(x, y)
  local frame = TooltipKitTestEnv.GetGlobal("CreateFrame")(
    "Frame",
    nil,
    TooltipKitTestEnv.GetGlobal("UIParent")
  )
  frame:SetSize(40, 20)
  frame:SetPoint("BOTTOMLEFT", TooltipKitTestEnv.GetGlobal("UIParent"), "BOTTOMLEFT", x, y)
  return frame
end

---Make `frame:IsMouseOver()` answer `over`.
---@param frame table
---@param over any
function TooltipKitTestEnv.SetMouseOver(frame, over)
  frame.IsMouseOver = function()
    return over
  end
end

---Run one of `frame`'s scripts as the client would.
---@param frame table
---@param scriptName string
---@param ... any
function TooltipKitTestEnv.Run(frame, scriptName, ...)
  local script = frame:GetScript(scriptName)
  assert(type(script) == "function", "the frame has no " .. scriptName .. " script")
  script(frame, ...)
end

---The values the host error handler received since the last call.
---@return any[]
function TooltipKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(TooltipKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function TooltipKitTestEnv.InstallSecretProbe()
  TooltipKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function TooltipKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Load the TooltipKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table TooltipKit
function TooltipKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "TooltipKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("TooltipKitTestEnv.LoadRevision could not find TooltipKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("TooltipKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return TooltipKitTestEnv

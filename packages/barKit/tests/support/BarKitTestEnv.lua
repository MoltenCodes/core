--- Package-specific test environment for the BarKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`;
--- its `FrameStub` models frames, scroll frames, textures and font strings,
--- measuring a text at 6 pixels a character and 12 a line. What stays here is
--- this package's module load order and the helpers only its specs need:
---
---   the screen       `UIParent`, 1920 x 1080 at the origin;
---   the clock        `GetTime`, set with `SetTime` and moved on with
---                    `Advance`, which also runs a frame's `OnUpdate` once;
---   scripts          `Run(frame, scriptName, ...)`;
---   reports          `TakeReportedValues`;
---   secret values    `InstallSecretProbe`, `NewSecret` and
---                    `ModelSecretTextAspect`;
---   upgrades         `LoadRevision`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local BarKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit", "BarKit" },
})

local secrets = setmetatable({}, { __mode = "k" })
local clock = 0
local sharedNewPackage = BarKitTestEnv.NewPackage

---Read a host global.
---@param name string
---@return any
function BarKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function BarKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Reset, install the host stubs, load the module chain and create the screen.
---@return table BarKit
---@return table PoolKit
---@return table Registry
function BarKitTestEnv.NewPackage()
  local BarKit, Registry, PoolKit = sharedNewPackage()
  local uiParent = BarKitTestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  clock = 100
  BarKitTestEnv.SetGlobal("GetTime", function()
    return clock
  end)
  return BarKit, PoolKit, Registry
end

---Set the client's time.
---@param seconds number
function BarKitTestEnv.SetTime(seconds)
  clock = seconds
end

---Move the client's time on by `seconds` and run `frame`'s `OnUpdate` once,
---as the next frame would.
---@param frame table
---@param seconds number
function BarKitTestEnv.Advance(frame, seconds)
  clock = clock + seconds
  local onUpdate = frame:GetScript("OnUpdate")
  if onUpdate then
    onUpdate(frame, seconds)
  end
end

---Clear everything the shared fixture clears, plus `GetTime`.
local sharedReset = BarKitTestEnv.Reset
function BarKitTestEnv.Reset()
  sharedReset()
  BarKitTestEnv.SetGlobal("GetTime", nil)
end

---Run one of `frame`'s scripts as the client would.
---@param frame table
---@param scriptName string
---@param ... any
function BarKitTestEnv.Run(frame, scriptName, ...)
  local script = frame:GetScript(scriptName)
  assert(type(script) == "function", "the frame has no " .. scriptName .. " script")
  script(frame, ...)
end

---The values the host error handler received since the last call.
---@return any[]
function BarKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(BarKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function BarKitTestEnv.InstallSecretProbe()
  BarKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function BarKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Give `fontString` the secret text aspect the client gives a font string
---(measured on Retail 12.1.0 b69933, 2026-09-25, recorded in widgetKit's
---docs/API.md "Secret values"): once it showed a secret, `GetText` answers a
---secret even for a plain text set later, until `ClearText` empties it and
---removes the aspect. The shared frame stub does not model aspects.
---@param fontString table
function BarKitTestEnv.ModelSecretTextAspect(fontString)
  local setText, getText = fontString.SetText, fontString.GetText
  function fontString:SetText(text)
    if secrets[text] then
      self.secretTextAspect = true
    end
    setText(self, text)
  end
  function fontString:GetText()
    local text = getText(self)
    if self.secretTextAspect and not secrets[text] then
      return BarKitTestEnv.NewSecret()
    end
    return text
  end
  function fontString:ClearText()
    self.secretTextAspect = false
    setText(self, nil)
  end
end

---Load the BarKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table BarKit
function BarKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "BarKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("BarKitTestEnv.LoadRevision could not find BarKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("BarKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return BarKitTestEnv

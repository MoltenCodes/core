--- Client rules the shared `FrameStub` does not model, measured in the Retail
--- 12.1.0 b69933 client by `tests/client/MoltenCodesTest_WidgetKit`
--- (2026-09-25), applied to every frame `CreateFrame` makes once installed.
---
--- The shared stub stores whatever a setter is given and answers every getter
--- with what it stored. The client does not, and WidgetKit met each of these
--- differences there first:
---
---   untainted-only arguments   `SetWidth`, `SetHeight`, `SetSize` and
---                              `SetPoint` of every frame and font string,
---                              and `SetText` of an edit box, raise when an
---                              argument is a value `issecretvalue` reports
---                              secret: addon code is tainted, and the client
---                              takes a secret there only from untainted code.
---                              The message is the client's (measured for
---                              `SetHeight`, `SetWidth` and `EditBox:SetText`),
---                              raised at the caller's line;
---   empty text is `nil`        a font string's and a button's `GetText()`
---                              answer `nil` for an empty text, after
---                              `SetText("")` and `SetText(nil)` alike; an edit
---                              box answers `""`;
---   the secret aspect          a font string given a secret text keeps a secret
---                              aspect after `SetText("")`: `GetText`,
---                              `GetStringWidth` and `GetStringHeight` answer
---                              secret values until `ClearText` removes it. The
---                              client test inferred this from a reused `Label`
---                              whose `GetStringHeight` reached `SetHeight` as a
---                              secret after a plain `SetText("")`; `ClearText`
---                              is documented as removing secret aspects;
---   strata follow the parent   `SetParent` gives a frame its new parent's
---                              strata unless `SetFixedFrameStrata(true)` was
---                              called on it.
---
--- The rules override methods on each frame and font string itself, so the
--- stub's shared method tables stay untouched and the next `Reset`, which
--- installs a fresh `CreateFrame`, removes them.

local WidgetKitClientRules = {}

--- The sentence the client puts in every untainted-only refusal.
local UNTAINTED_ONLY =
  "Secret values are only allowed during untainted execution for this argument."

--- The usage text the client quotes for each guarded setter.
local USAGE = {
  SetWidth = "self:SetWidth(width)",
  SetHeight = "self:SetHeight(height)",
  SetSize = "self:SetSize(width, height)",
  SetPoint = "self:SetPoint(point [, relativeTo [, relativePoint]] [, offsetX, offsetY])",
  SetText = "self:SetText(text)",
}

--- Setters guarded on every frame and font string.
local GEOMETRY_SETTERS = { "SetWidth", "SetHeight", "SetSize", "SetPoint" }

---Read a host global: the fixture stands in for the client, whose API only
---exists in the global table.
---@param name string
---@return any
local function readGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Whether the installed `issecretvalue` reports `value` as secret.
---@param value any
---@return boolean
local function isSecret(value)
  local isSecretValue = readGlobal("issecretvalue")
  return type(isSecretValue) == "function" and isSecretValue(value) == true
end

---Replace `methodName` on `region` with a version that raises the client's
---refusal when any argument is secret, and otherwise calls the original.
---@param region table
---@param methodName string
local function guardArguments(region, methodName)
  local original = region[methodName]
  if type(original) ~= "function" then
    return
  end
  region[methodName] = function(self, ...)
    for index = 1, select("#", ...) do
      if isSecret((select(index, ...))) then
        error(
          ("bad argument #%d to '%s' (Usage: %s. %s)"):format(
            index,
            methodName,
            USAGE[methodName],
            UNTAINTED_ONLY
          ),
          2
        )
      end
    end
    return original(self, ...)
  end
end

---Make `GetText` answer `nil` for an empty text, as the client's font strings
---and buttons do.
---@param region table
local function emptyTextIsNil(region)
  local original = region.GetText
  region.GetText = function(self)
    local text = original(self)
    if text == "" then
      return nil
    end
    return text
  end
end

---Apply the font-string rules: guarded geometry, the secret aspect with
---`ClearText`, and `nil` for an empty text.
---@param fontString table
local function applyFontStringRules(fontString)
  for index = 1, #GEOMETRY_SETTERS do
    guardArguments(fontString, GEOMETRY_SETTERS[index])
  end

  -- The secret a secret text left behind, or `nil`: the aspect's value is
  -- what the measurements answer while it lasts.
  local aspect = nil
  local setText = fontString.SetText
  local getText = fontString.GetText
  local getStringWidth = fontString.GetStringWidth
  local getStringHeight = fontString.GetStringHeight

  fontString.SetText = function(self, text)
    if isSecret(text) then
      aspect = text
    end
    setText(self, text)
  end
  fontString.GetText = function(self)
    local text = getText(self)
    if aspect ~= nil and not isSecret(text) then
      return aspect
    end
    if text == "" then
      return nil
    end
    return text
  end
  fontString.GetStringWidth = function(self)
    if aspect ~= nil then
      return aspect
    end
    return getStringWidth(self)
  end
  fontString.GetStringHeight = function(self)
    if aspect ~= nil then
      return aspect
    end
    return getStringHeight(self)
  end
  fontString.ClearText = function(self)
    aspect = nil
    setText(self, nil)
  end
end

---Apply the frame rules to one frame made by `CreateFrame`.
---@param frame table
local function applyFrameRules(frame)
  for index = 1, #GEOMETRY_SETTERS do
    guardArguments(frame, GEOMETRY_SETTERS[index])
  end

  local frameType = frame.frameType
  if frameType == "EditBox" then
    guardArguments(frame, "SetText")
  elseif frameType == "Button" or frameType == "CheckButton" then
    emptyTextIsNil(frame)
  end

  local createFontString = frame.CreateFontString
  frame.CreateFontString = function(self, ...)
    local fontString = createFontString(self, ...)
    applyFontStringRules(fontString)
    return fontString
  end

  local fixedStrata = false
  local setParent = frame.SetParent
  frame.SetParent = function(self, parent)
    setParent(self, parent)
    if
      not fixedStrata
      and type(parent) == "table"
      and type(parent.GetFrameStrata) == "function"
    then
      self:SetFrameStrata(parent:GetFrameStrata())
    end
  end
  frame.SetFixedFrameStrata = function(_, fixed)
    fixedStrata = fixed == true
  end
  frame.HasFixedFrameStrata = function()
    return fixedStrata
  end
end

---Wrap the installed `CreateFrame` so every frame made from now on, and every
---font string such a frame creates, follows the rules above. Call it after the
---fixture installed its World of Warcraft API; the next `Reset` removes it.
---@param setGlobal fun(name: string, value: any) the environment's global writer
function WidgetKitClientRules.Install(setGlobal)
  local createFrame = readGlobal("CreateFrame")
  if type(createFrame) ~= "function" then
    error("WidgetKitClientRules.Install needs the fixture's CreateFrame installed first", 2)
  end
  setGlobal("CreateFrame", function(frameType, name, parent, template)
    local frame = createFrame(frameType, name, parent, template)
    applyFrameRules(frame)
    return frame
  end)
end

return WidgetKitClientRules

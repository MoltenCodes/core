-- MoltenCodes Test: EditModeKitSuite.lua
--
-- Real-client suites for the `editModeKit` package. The Busted specs under
-- packages/editModeKit/tests/ prove EditModeKit against stand-ins for
-- `EventRegistry` and `EditModeManagerFrame`; these prove, inside the game
-- client with the installed MoltenCodes addon, what the stand-ins can only
-- assume:
--
--   * the installed facade and its committed revision;
--   * the client's `EditModeManagerFrame` naming the active layout;
--   * a drag's end saving the frame's centre offset under that layout, and
--     `Refresh` putting a saved position back, on the client's own frames;
--   * the client's `EditMode.Enter` showing the overlay when the player opens
--     Edit Mode, and `EditMode.Exit` hiding it.
--
-- The registered frame is a 120 by 40 box above the middle of the screen,
-- shown while the suite runs. Edit Mode is never opened by this code: the
-- last test waits up to 30 seconds for the player to open it. What a run
-- leaves behind: that hidden box and EditModeKit's overlay, unregistered.
-- Positions are saved in a table of this file, never in a saved variable.
--
-- Run with `/mct run editModeKit`;
-- tests/client/MoltenCodesTest_EditModeKit/EXPECTED.md lists what the chat
-- frame should show.

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

local PACKAGE_ID = "editModeKit"

--- Every method docs/API.md of editModeKit lists on the facade.
local FACADE_METHODS = { "Register", "IsEditing", "GetLayoutName", "SetLimits", "GetLimits" }

--- How long the last test waits for the player to open and close Edit Mode.
local PLAYER_WAIT_SECONDS = 30

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- CreateFrame and UIParent are World of Warcraft client globals, reachable
  -- only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- EditModeKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local EditModeKit = Registry:Get(PACKAGE_ID, 1)
if type(EditModeKit) == "nil" then
  error(addonName .. " requires EditModeKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

---`ctx:WaitUntil` through an untyped alias (see CommKitSuite.lua, `waitUntil`).
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return boolean satisfied
local function waitUntil(ctx, predicate, timeoutSeconds)
  ---@type any
  local context = ctx
  return context:WaitUntil(predicate, timeoutSeconds) == true
end

--- The registered box, made once per session, and its registration.
local box, registration = nil, nil

--- The positions EditModeKit saves for the box.
local positions = {}

---The box above the middle of the screen, shown and registered.
---@return table box
---@return table registration
local function registered()
  local uiParent = readHost("UIParent")
  if box == nil then
    box = readHost("CreateFrame")("Frame", nil, uiParent)
    box:SetSize(120, 40)
    local fill = box:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints(box)
    fill:SetColorTexture(0.1, 0.1, 0.1, 0.8)
  end
  if registration == nil then
    box:ClearAllPoints()
    box:SetPoint("CENTER", uiParent, "CENTER", 0, 160)
    registration = EditModeKit:Register(box, positions, { label = "MoltenCodes Test" })
  end
  box:Show()
  return box, registration
end

---Register a suite of this package whose tests end with the box unregistered.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    if registration then
      registration:Unregister()
      registration = nil
    end
    if box then
      box:Hide()
    end
  end)
  return suite
end

-- editModeKit.facade -------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('editModeKit', 1) is the EditModeKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(EditModeKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(EditModeKit[method])):ToBe("function")
    end
  end
)

facade:Test(
  "the installed EditModeKit carries the revision of the committed manifest",
  function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
      ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
      return
    end
    for _, expected in ipairs(expectedPackages) do
      if expected.id == PACKAGE_ID then
        ctx:Expect(rawget(EditModeKit, "REVISION")):ToBe(expected.revision)
        return
      end
    end
    ctx:Fail("Expected.lua does not list editModeKit")
  end
)

-- editModeKit.positions ----------------------------------------------------

local positionSuite = newSuite("positions")

positionSuite:Test("the client's Edit Mode manager names the active layout", function(ctx)
  local name = EditModeKit:GetLayoutName()
  ctx:Expect(type(name)):ToBe("string")
  ctx:Expect(name ~= "default"):ToBe(true)
end)

positionSuite:Test("a drag's end saves the centre offset under the active layout", function(ctx)
  local frame, handle = registered()
  local overlay = rawget(handle, "_record").overlay
  overlay:GetScript("OnDragStart")(overlay)
  overlay:GetScript("OnDragStop")(overlay)
  local saved = positions[EditModeKit:GetLayoutName()]
  ctx:Expect(type(saved)):ToBe("table")
  ctx:Expect(math.abs(saved.x) < 1):ToBe(true)
  ctx
    :Expect(
      math.abs(saved.y - 160 * frame:GetEffectiveScale() / readHost("UIParent"):GetEffectiveScale())
        < 1
    )
    :ToBe(true)
end)

positionSuite:Test("Refresh puts the saved position back", function(ctx)
  local frame, handle = registered()
  positions[EditModeKit:GetLayoutName()] = { x = -200, y = 100 }
  handle:Refresh()
  local point, relativeTo, relativePoint = frame:GetPoint(1)
  ctx:Expect(point):ToBe("CENTER")
  ctx:Expect(relativeTo):ToBe(readHost("UIParent"))
  ctx:Expect(relativePoint):ToBe("CENTER")
end)

-- editModeKit.editMode -----------------------------------------------------

local editModeSuite = newSuite("editMode")

editModeSuite:Test("opening Edit Mode shows the overlay and closing it hides it", function(ctx)
  local _, handle = registered()
  local overlay = rawget(handle, "_record").overlay
  print(
    "MoltenCodes Test: open Edit Mode, then close it, within " .. PLAYER_WAIT_SECONDS .. " seconds."
  )
  ctx
    :Expect(waitUntil(ctx, function()
      return EditModeKit:IsEditing() and overlay:IsShown()
    end, PLAYER_WAIT_SECONDS))
    :ToBe(true)
  ctx
    :Expect(waitUntil(ctx, function()
      return not EditModeKit:IsEditing() and not overlay:IsShown()
    end, PLAYER_WAIT_SECONDS))
    :ToBe(true)
end)

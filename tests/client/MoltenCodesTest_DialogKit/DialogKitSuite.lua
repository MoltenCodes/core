-- MoltenCodes Test: DialogKitSuite.lua
--
-- Real-client suites for the `dialogKit` package. The Busted specs under
-- packages/dialogKit/tests/ prove DialogKit against the shared frame stub;
-- these prove, inside the game client with the installed MoltenCodes addon,
-- what the stub can only assume:
--
--   * the installed facade and its committed revision;
--   * a dialog drawn with the client's button and input-box templates, and
--     accepted through its button with the input line's text;
--   * Escape through the client's own `CloseSpecialWindows`, which hides
--     every frame `UISpecialFrames` names, cancelling the dialog with
--     `"escape"`;
--   * a queued dialog shown when the first ends, and a timeout on the
--     client's clock.
--
-- Each dialog is on screen for at most a second. What a run leaves behind:
-- DialogKit's one dialog frame, hidden, and its name in `UISpecialFrames`.
-- Nothing is written to a saved variable.
--
-- Run with `/mct run dialogKit`; tests/client/MoltenCodesTest_DialogKit/EXPECTED.md
-- lists what the chat frame should show.

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

local PACKAGE_ID = "dialogKit"

--- Every method docs/API.md of dialogKit lists on the facade.
local FACADE_METHODS = { "Show", "HideAll", "SetLimits", "GetLimits" }

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- UISpecialFrames, CloseSpecialWindows and the dialog frame are World of
  -- Warcraft client globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- DialogKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local DialogKit = Registry:Get(PACKAGE_ID, 1)
if type(DialogKit) == "nil" then
  error(addonName .. " requires DialogKit API 1 in the MoltenCodes addon; reinstall it", 0)
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

---Register a suite of this package whose tests end with no dialog left.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    DialogKit:HideAll()
  end)
  return suite
end

---The dialog frame.
---@return any
local function dialogFrame()
  return readHost(DialogKit.FRAME_NAME)
end

-- dialogKit.facade -----------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('dialogKit', 1) is the DialogKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(DialogKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(DialogKit[method])):ToBe("function")
    end
  end
)

facade:Test("the installed DialogKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(DialogKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list dialogKit")
end)

-- dialogKit.dialogs ----------------------------------------------------------

local dialogs = newSuite("dialogs")

dialogs:Test(
  "a dialog with an input line is accepted through its button with the typed text",
  function(ctx)
    local received = nil
    DialogKit:Show({
      text = "MoltenCodes Test: DialogKit",
      input = true,
      inputText = "typed",
      onAccept = function(_, text)
        received = text
      end,
    })
    local frame = dialogFrame()
    ctx:Expect(frame:IsShown()):ToBe(true)
    ctx:Expect(frame.input:IsShown()):ToBe(true)
    frame.acceptButton:Click()
    ctx:Expect(received):ToBe("typed")
    ctx:Expect(frame:IsShown()):ToBe(false)
  end
)

dialogs:Test(
  "the client's CloseSpecialWindows closes the dialog through UISpecialFrames, as Escape does",
  function(ctx)
    local special = readHost("UISpecialFrames")
    local close = readHost("CloseSpecialWindows")
    if type(special) ~= "table" or type(close) ~= "function" then
      Harness:SkipTest(ctx, "the client has no UISpecialFrames or CloseSpecialWindows")
    end
    local reason = nil
    DialogKit:Show({
      text = "MoltenCodes Test: DialogKit",
      onCancel = function(_, why)
        reason = why
      end,
    })
    local listed = false
    for _, name in ipairs(special) do
      listed = listed or name == DialogKit.FRAME_NAME
    end
    ctx:Expect(listed):ToBe(true)
    close()
    ctx:Expect(reason):ToBe("escape")
  end
)

dialogs:Test(
  "a queued dialog is shown when the first ends, and a timeout cancels it on the client's clock",
  function(ctx)
    local reason = nil
    DialogKit:Show({ text = "MoltenCodes Test: first" })
    local second = DialogKit:Show({
      text = "MoltenCodes Test: second",
      timeout = 0.5,
      onCancel = function(_, why)
        reason = why
      end,
    })
    ctx:Expect(second:IsQueued()):ToBe(true)
    dialogFrame().acceptButton:Click()
    ctx:Expect(second:IsShown()):ToBe(true)
    ctx
      :Expect(waitUntil(ctx, function()
        return reason ~= nil
      end, 3))
      :ToBe(true)
    ctx:Expect(reason):ToBe("timeout")
  end
)

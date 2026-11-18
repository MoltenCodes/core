-- The shared helper blocks HookKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 8, whose file is kept verbatim as a fixture.
local TestEnv = require("HookKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 8 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table HookKit
local function loadRevisionEight()
  local path = FIXTURE_DIRECTORY .. "HookKit-revision8.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Install the host stubs and Registry, run `beforeLoad`, then load `loadKit`'s copy.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table HookKit
local function loadWith(beforeLoad, loadKit)
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  TestEnv.InstallHookApi()
  require("Registry")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  return require("HookKit")
end

---A host error handler that itself raises, as an error-display addon with a bug.
local function installRaisingErrorHandler()
  TestEnv.SetGlobal("geterrorhandler", function()
    return function()
      error("the error handler failed")
    end
  end)
end

---A target whose `Method` records that it ran.
---@return table target
local function newTarget()
  local target = { ran = 0 }
  function target:Method()
    self.ran = self.ran + 1
    return "result"
  end
  return target
end

describe("HookKit shared helpers", function()
  local printed
  -- selene: allow(global_usage)
  local hostPrint = _G.print
  before_each(function()
    printed = {}
    -- selene: allow(global_usage)
    rawset(_G, "print", function(value)
      printed[#printed + 1] = value
    end)
  end)
  after_each(function()
    -- selene: allow(global_usage)
    rawset(_G, "print", hostPrint)
    TestEnv.SetGlobal("geterrorhandler", nil)
    TestEnv.Reset()
  end)

  it("completes a hooked call whose handler fails while the error handler raises", function()
    local HookKit = loadWith(nil, requireCurrent)
    local target = newTarget()
    assert.is_true(HookKit:CreateScope():SecureHook(target, "Method", function()
      error("the handler failed")
    end))
    installRaisingErrorHandler()

    assert.are.equal("result", target:Method())
    assert.are.equal(1, target.ran)
    assert.are.equal(1, #printed)
    assert.is_truthy(tostring(printed[1]):find("the handler failed", 1, true))
  end)

  it("still refuses a dot call whose receiver carries an __eq metamethod", function()
    local HookKit = loadWith(nil, requireCurrent)
    local ran = false
    local receiver = setmetatable({}, {
      __eq = function()
        ran = true
        return true
      end,
    })
    TestEnv.expectErrorContaining(
      "HookKit:CreateScope must be called on the HookKit facade; use HookKit:CreateScope(...)",
      function()
        HookKit.CreateScope(receiver)
      end
    )
    assert.is_false(ran)
  end)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local secret = "SecretMethodName"
    local HookKit = loadWith(function()
      TestEnv.SetGlobal("issecretvalue", function(value)
        return rawequal(value, secret)
      end)
    end, requireCurrent)
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    local scope = HookKit:CreateScope()
    TestEnv.expectErrorContaining("method must not be a secret value", function()
      scope:SecureHook(newTarget(), secret, function() end)
    end)
  end)

  it(
    "upgrades in place over revision 8: hooks keep running and report through the new code",
    function()
      local older = loadWith(nil, loadRevisionEight)
      assert.are.equal(8, older.REVISION)
      local target = newTarget()
      local failing = true
      assert.is_true(older:CreateScope():SecureHook(target, "Method", function()
        if failing then
          error("the handler failed")
        end
      end))

      local HookKit = require("HookKit")
      assert.are.equal(older, HookKit)
      assert.are.equal(9, HookKit.REVISION)

      installRaisingErrorHandler()
      assert.are.equal("result", target:Method())
      assert.are.equal(1, #printed)
      failing = false
      assert.are.equal("result", target:Method())
      assert.are.equal(2, target.ran)
    end
  )
end)

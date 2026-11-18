-- The shared helper blocks BridgeKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 8, whose file is kept verbatim as a fixture.
local Env = require("BridgeKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 8 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table BridgeKit
local function loadRevisionEight()
  local path = FIXTURE_DIRECTORY .. "BridgeKit-revision8.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load Registry, run `beforeLoad`, then load `loadKit`'s copy of BridgeKit.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table BridgeKit
local function loadWith(beforeLoad, loadKit)
  Env.NewPackageWithout("BridgeKit")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  package.loaded["BridgeKit"] = nil
  return require("BridgeKit")
end

---Convert a one-option AceConfig tree whose multiselect `get` answers what
---`answer` returns, and return the converted option.
---@param BridgeKit table
---@param answer fun(): any
---@return table option
local function convertMultiselect(BridgeKit, answer)
  local conversion = BridgeKit:ConvertAceConfig("MyAddon", {
    type = "group",
    args = {
      parts = {
        type = "multiselect",
        name = "Parts",
        values = { a = "A" },
        get = answer,
        set = function() end,
      },
    },
  })
  return conversion.tree.args.parts
end

describe("BridgeKit shared helpers", function()
  after_each(Env.Reset)

  it("reads a nil multiselect state as unset with the test probe installed", function()
    local BridgeKit = loadWith(nil, requireCurrent)
    Env.MarkSecret({})
    local parts = convertMultiselect(BridgeKit, function()
      return nil
    end)
    assert.is_false(parts.get({}).a)
  end)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local secret = {}
    local BridgeKit = loadWith(function()
      Env.MarkSecret(secret)
    end, requireCurrent)
    Env.MarkSecret()
    local parts = convertMultiselect(BridgeKit, function()
      return secret
    end)
    assert.are.equal(secret, parts.get({}).a)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local BridgeKit = loadWith(nil, requireCurrent)
    Env.expectErrorContaining(
      "BridgeKit:GetLimits must be called on the BridgeKit facade; use BridgeKit:GetLimits(...)",
      function()
        BridgeKit.GetLimits({})
      end
    )
  end)

  it("upgrades in place over revision 8: limits kept, the same text written", function()
    local older = loadWith(nil, loadRevisionEight)
    assert.are.equal(8, older.REVISION)
    older:SetLimits({ maxDepth = 7 })
    local value = { name = "kept", list = { 1, 2.5, true } }
    local _, text = older:AceSerialize(value)

    local BridgeKit = requireCurrent()
    assert.are.equal(older, BridgeKit)
    assert.are.equal(9, BridgeKit.REVISION)
    assert.are.equal(7, BridgeKit:GetLimits().maxDepth)
    assert.are.same({ true, text }, { BridgeKit:AceSerialize(value) })
    assert.are.same({ true, value }, { BridgeKit:AceDeserialize(text) })
  end)
end)

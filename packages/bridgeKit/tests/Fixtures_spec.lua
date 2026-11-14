-- BridgeKit against AceSerializer-3.0 itself: every case recorded from Ace3 at
-- the pinned commit (`tests/fixtures/AceSerializerFixtures.lua`, written by
-- `python3 -m tooling.fixtures.ace_serializer`) is reproduced here. Encoding
-- cases must give Ace's bytes; decoding cases Ace's values, or the BridgeKit
-- reason that stands for Ace's error message.
local Env = require("BridgeKitTestEnv")

--- The BridgeKit reason for each kind of message Ace3's reader fails with
--- (docs/BRIDGE_KIT_DESIGN.md, section 8.2), matched by a plain substring.
local REASON_FOR_ACE_MESSAGE = {
  { "is not AceSerializer data", "notAceSerializer" },
  { "misses AceSerializer terminator", "missingTerminator" },
  { "Invalid serialized number", "invalidNumber" },
  { "Invalid serialized floating-point number", "invalidFloat" },
  { "Invalid AceSerializer control code", "unknownControl" },
  { "Invalid AceSerializer table format", "tableFormat" },
  { "table index is NaN", "invalidKey" },
  -- Ace fails inside `string.char` for an escape below the byte range, and
  -- with an internal assertion for `~~`; both are escapes it cannot read.
  { "'strchar'", "invalidEscape" },
  { "DeserializeStringHelper", "invalidEscape" },
}

---@param message string
---@return string
local function reasonForAceMessage(message)
  for _, row in ipairs(REASON_FOR_ACE_MESSAGE) do
    if message:find(row[1], 1, true) then
      return row[2]
    end
  end
  error("no BridgeKit reason is mapped for Ace3's message: " .. message)
end

---Whether two decoded values are the same, NaN equal to NaN and tables
---compared entry by entry.
---@param expected any
---@param actual any
---@return boolean
local function same(expected, actual)
  if type(expected) == "number" and expected ~= expected then
    return type(actual) == "number" and actual ~= actual
  end
  if type(expected) ~= "table" then
    return expected == actual
  end
  if type(actual) ~= "table" then
    return false
  end
  for key, value in pairs(expected) do
    if not same(value, actual[key]) then
      return false
    end
  end
  for key in pairs(actual) do
    if expected[key] == nil then
      return false
    end
  end
  return true
end

---Pack every value with its count.
local function pack(...)
  local packed = { ... }
  packed.n = select("#", ...)
  return packed
end

describe("BridgeKit and the recorded AceSerializer fixtures", function()
  local BridgeKit
  local fixtures = Env.AceSerializerFixtures()
  before_each(function()
    BridgeKit = Env.NewPackage()
  end)
  after_each(Env.Reset)

  it("were recorded from the Ace3 commit and library revision BridgeKit names", function()
    assert.are.equal(BridgeKit.ACE_BASELINE.commit, fixtures.provenance.commit)
    assert.are.equal(BridgeKit.ACE_BASELINE.AceSerializer, fixtures.provenance.minor)
    assert.are.equal("AceSerializer-3.0", fixtures.provenance.library)
  end)

  for _, case in ipairs(fixtures.encode) do
    it("writes Ace's bytes for " .. case.label, function()
      assert.is_true(case.ok, "every encoding fixture is one Ace3 accepted")
      local values = pack(assert(loadstring("return " .. case.source))())
      local ok, text = BridgeKit:AceSerialize(unpack(values, 1, values.n))
      assert.is_true(ok, tostring(text))
      assert.are.equal(case.text, text)
    end)
  end

  for _, case in ipairs(fixtures.decode) do
    if case.ok then
      it("reads what Ace reads from " .. case.label, function()
        local results = pack(BridgeKit:AceDeserialize(case.text))
        assert.is_true(results[1], tostring(results[2]))
        assert.are.equal(case.values.n, results.n - 1)
        for index = 1, case.values.n do
          assert.is_true(same(case.values[index], results[index + 1]), "value " .. index)
        end
      end)
    else
      it("refuses what Ace refuses in " .. case.label, function()
        local ok, reason = BridgeKit:AceDeserialize(case.text)
        assert.is_false(ok)
        assert.are.equal(reasonForAceMessage(case.message), reason)
      end)
    end
  end
end)

local TestEnv = require("CodecKitTestEnv")

-- Revision 9 fixes two refusals that built their message with `tostring(key)`:
-- a table key with `__tostring` ran the caller's code inside CodecKit. Each
-- key is now named without running anything, and a secret key is refused
-- before it is used to index the table of known names.

describe("CodecKit key descriptions", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---A table key whose `__tostring` records that it ran, then raises.
  ---@return table key
  ---@return fun(): integer runs
  local function trappedKey()
    local runs = 0
    local key = setmetatable({}, {
      __tostring = function()
        runs = runs + 1
        error("__tostring must not run inside CodecKit")
      end,
    })
    return key, function()
      return runs
    end
  end

  it("names a table option key by type without running its __tostring", function()
    local key, runs = trappedKey()
    TestEnv.expectErrorContaining(
      "CodecKit:Encode options.<table> is not a recognised option",
      function()
        CodecKit:Encode(1, { [key] = true })
      end
    )
    TestEnv.expectErrorContaining(
      "CodecKit:Decode options.<table> is not a recognised option",
      function()
        CodecKit:Decode("x", { [key] = true })
      end
    )
    assert.are.equal(0, runs())
  end)

  it("names a table limit key by type without running its __tostring", function()
    local key, runs = trappedKey()
    TestEnv.expectErrorContaining(
      "CodecKit:SetLimits limits.<table> is not a recognised limit",
      function()
        CodecKit:SetLimits({ [key] = 1 })
      end
    )
    assert.are.equal(0, runs())
  end)

  it("names a function key by type and keeps numbers, booleans and strings as written", function()
    TestEnv.expectErrorContaining("options.<function> is not a recognised option", function()
      CodecKit:Encode(1, { [print] = true })
    end)
    TestEnv.expectErrorContaining("options.7 is not a recognised option", function()
      CodecKit:Encode(1, { [7] = true })
    end)
    TestEnv.expectErrorContaining("options.true is not a recognised option", function()
      CodecKit:Encode(1, { [true] = true })
    end)
    TestEnv.expectErrorContaining("limits.maxNothing is not a recognised limit", function()
      CodecKit:SetLimits({ maxNothing = 1 })
    end)
  end)

  it("refuses a secret option or limit key at the caller", function()
    TestEnv.InstallSecretProbe({ hiddenKey = true })
    local source = debug.getinfo(1, "S").short_src
    local ok, message = pcall(function()
      CodecKit:Encode(1, { hiddenKey = true })
    end)
    assert.is_false(ok)
    -- Raised at this file's line, not inside CodecKit.
    assert.are.equal(1, string.find(message, source, 1, true))
    assert.is_not_nil(
      string.find(message, "CodecKit:Encode options must not have a secret key", 1, true)
    )
    TestEnv.expectErrorContaining("CodecKit:SetLimits limits must not have a secret key", function()
      CodecKit:SetLimits({ hiddenKey = 1 })
    end)
  end)
end)

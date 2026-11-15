local TestEnv = require("CodecKitTestEnv")

-- Revision 9 builds the byte text, the print tables and the DEFLATE tables on
-- first use instead of at load, caches short strings known to need no escape,
-- scans for addon-channel bytes with plain finds, and resolves the secret
-- probe once at load. These specs pin that none of it changes what CodecKit
-- writes or refuses.

---Find a named upvalue reachable from `root` through the upvalues of nested
---functions: the internal flags live in file-local functions the facade calls.
---@param root function
---@param wanted string
---@return any value
---@return boolean found
local function findUpvalue(root, wanted)
  local queue, seen, head = { root }, { [root] = true }, 1
  while queue[head] ~= nil do
    local fn = queue[head]
    head = head + 1
    local index = 1
    while true do
      local name, value = debug.getupvalue(fn, index)
      if name == nil then
        break
      end
      if name == wanted then
        return value, true
      end
      if type(value) == "function" and not seen[value] then
        seen[value] = true
        queue[#queue + 1] = value
      end
      index = index + 1
    end
  end
  return nil, false
end

describe("CodecKit load cost", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---The current value of one of CodecKit's internal flags.
  ---@param method string facade method the flag is reachable from
  ---@param name string
  ---@return any
  local function flag(method, name)
    -- The compression stage is the Compression part's, reached through the
    -- entries it fills in the core's state.
    local root = CodecKit[method]
    if method == "Compress" then
      root = CodecKit._state.compression.compress
    elseif method == "Decompress" then
      root = CodecKit._state.compression.decompress
    end
    local value, found = findUpvalue(root, name)
    assert.is_true(found, name .. " not reachable from " .. method)
    return value
  end

  it("builds the byte text on the first encode, not at load", function()
    assert.is_false(flag("Encode", "byteTextFilled"))
    local ok, text = CodecKit:Encode({ "a", 1 })
    assert.is_true(ok)
    assert.is_true(flag("Encode", "byteTextFilled"))
    assert.are.same({ "a", 1 }, select(2, CodecKit:Decode(text)))
  end)

  it("builds the print tables on the first print-safe call only", function()
    local ok, text = CodecKit:Encode({ "a" }, { channel = "addon" })
    assert.is_true(ok)
    assert.is_true((CodecKit:Decode(text)))
    assert.is_false(flag("Encode", "printTablesBuilt"))
    local printed
    ok, printed = CodecKit:Encode({ "a" }, { channel = "print" })
    assert.is_true(ok)
    assert.is_true(flag("Encode", "printTablesBuilt"))
    assert.are.same({ "a" }, select(2, CodecKit:Decode(printed)))
  end)

  it("decodes a print frame first in a session, building the tables then", function()
    local ok, printed = CodecKit:Encode({ "first" }, { channel = "print" })
    assert.is_true(ok)
    TestEnv.Reset()
    CodecKit = TestEnv.NewPackage()
    assert.is_false(flag("Decode", "printTablesBuilt"))
    assert.are.same({ "first" }, select(2, CodecKit:Decode(printed)))
    assert.is_true(flag("Decode", "printTablesBuilt"))
  end)

  it("builds the DEFLATE tables on the first Lua compression or decompression", function()
    assert.is_false(flag("Compress", "tablesBuilt"))
    local input = string.rep("compress me, compress me again; ", 20)
    local ok, compressed = CodecKit:Compress(input)
    assert.is_true(ok)
    assert.is_true(flag("Compress", "tablesBuilt"))
    assert.are.equal(input, select(2, CodecKit:Decompress(compressed)))
  end)

  it("decompresses first in a session, building the tables then", function()
    local input = string.rep("only decompressed here; ", 20)
    local _, compressed = CodecKit:Compress(input)
    TestEnv.Reset()
    CodecKit = TestEnv.NewPackage()
    assert.is_false(flag("Decompress", "tablesBuilt"))
    assert.are.equal(input, select(2, CodecKit:Decompress(compressed)))
  end)

  it("records clean short strings once, never strings that need escaping or long ones", function()
    local value = { "plain", "line\nbreak", string.rep("x", 33), "pipe|", "plain" }
    local ok, text = CodecKit:Encode(value, { channel = "addon" })
    assert.is_true(ok)
    local cache = flag("Encode", "cleanText")
    assert.is_true(cache.plain)
    assert.is_nil(cache["line\nbreak"])
    assert.is_nil(cache["pipe|"])
    assert.is_nil(cache[string.rep("x", 33)])
    assert.are.same(value, select(2, CodecKit:Decode(text)))
    -- The cached string is still written exactly as before.
    local _, again = CodecKit:Encode(value, { channel = "addon" })
    assert.are.equal(text, again)
  end)

  it("stops recording at the cap", function()
    local many = {}
    for index = 1, 300 do
      many[index] = "k" .. index
    end
    assert.is_true((CodecKit:Encode(many, { channel = "addon" })))
    assert.are.equal(256, flag("Encode", "cleanTextCount"))
    local cache = flag("Encode", "cleanText")
    local count = 0
    for _ in pairs(cache) do
      count = count + 1
    end
    assert.are.equal(256, count)
  end)

  it("refuses a secret string before the cache is asked about it", function()
    local secret = TestEnv.NewSecret()
    TestEnv.InstallSecretProbe({ [secret] = true })
    TestEnv.expectErrorContaining(
      "CodecKit:Encode value must not contain a secret value",
      function()
        CodecKit:Encode({ secret }, { channel = "addon" })
      end
    )
  end)

  it(
    "escapes and refuses each addon-channel byte at the first, middle and last position",
    function()
      for _, special in ipairs({ "\0", "\n", "\r", "|", "\255" }) do
        for _, text in ipairs({ special .. "ab", "a" .. special .. "b", "ab" .. special }) do
          local ok, frame = CodecKit:Encode(text, { channel = "addon" })
          assert.is_true(ok)
          assert.is_nil(string.find(frame, "[%z\n\r|]"))
          assert.are.equal(text, select(2, CodecKit:Decode(frame)))
        end
      end
      local ok, frame = CodecKit:Encode("abc", { channel = "addon" })
      assert.is_true(ok)
      for _, forbidden in ipairs({ "\0", "\n", "\r", "|" }) do
        local damaged = frame:sub(1, 3) .. forbidden .. frame:sub(4)
        local decoded, reason = CodecKit:Decode(damaged)
        assert.is_false(decoded)
        assert.are.equal("forbiddenByte", reason)
      end
    end
  )

  it("keeps the probe it resolved at load", function()
    TestEnv.Reset()
    TestEnv.InstallSecretProbe({ hiddenKey = true })
    package.loaded["Registry"] = nil
    package.loaded["PoolKit"] = nil
    package.loaded["CodecKit"] = nil
    require("Registry")
    require("PoolKit")
    local loaded = require("CodecKit")
    -- issecretvalue is a World of Warcraft client global; the fixture owns and clears it.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)
    TestEnv.expectErrorContaining("options must not have a secret key", function()
      loaded:Encode(1, { hiddenKey = true })
    end)
  end)

  it("honours a probe installed after load when none existed then", function()
    TestEnv.InstallSecretProbe({ hiddenKey = true })
    TestEnv.expectErrorContaining("options must not have a secret key", function()
      CodecKit:Encode(1, { hiddenKey = true })
    end)
  end)
end)

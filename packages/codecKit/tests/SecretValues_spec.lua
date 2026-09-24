local TestEnv = require("CodecKitTestEnv")

describe("CodecKit and secret values", function()
  local CodecKit, secret
  before_each(function()
    CodecKit = TestEnv.NewPackage()
    secret = TestEnv.NewSecret()
    -- Installed after CodecKit loaded: the probe is looked up per call.
    TestEnv.InstallSecretProbe({ [secret] = true })
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret anywhere in the value at the caller, before touching it", function()
    local values = {
      secret,
      { secret },
      { name = secret },
      { [secret] = true },
      { 1, { 2, { three = secret } } },
    }
    for index = 1, #values do
      TestEnv.expectErrorContaining(
        "CodecKit:Encode value must not contain a secret value",
        function()
          CodecKit:Encode(values[index])
        end
      )
      TestEnv.expectErrorContaining(
        "CodecKit:Serialize value must not contain a secret value",
        function()
          CodecKit:Serialize(values[index])
        end
      )
    end
    TestEnv.expectErrorContaining(
      "CodecKit:EncodeMany value must not contain a secret value",
      function()
        CodecKit:EncodeMany(nil, 1, nil, secret)
      end
    )
  end)

  it("refuses a secret string handed to a decoding or stage method", function()
    local secretText = "secret text"
    TestEnv.InstallSecretProbe({ [secretText] = true })
    local methods = {
      "Decode",
      "DecodeMany",
      "Deserialize",
      "Compress",
      "Decompress",
      "EncodeForAddon",
      "DecodeForAddon",
      "EncodeForPrint",
      "DecodeForPrint",
    }
    for index = 1, #methods do
      TestEnv.expectErrorContaining("must not be a secret value", function()
        CodecKit[methods[index]](CodecKit, secretText)
      end)
    end
  end)

  it("leaves the pool balanced after a refusal, wherever the secret sits", function()
    -- The array-part scan tests elements with `type`, never with `~= nil`,
    -- so a secret element is first touched by the secret probe. Lua 5.1
    -- cannot trap a comparison with nil, so that rule is held by review;
    -- this spec pins its observable half: every refusal raises our message
    -- at the caller and returns every leased table.
    local pool = CodecKit._state.pool
    local function shapes(position)
      local array = { 1, 2, 3, 4, 5 }
      array[position] = secret
      local tail = { 1, 2, 3, 4, 5, 6 }
      tail[position + 1] = secret
      return {
        array,
        tail,
        { name = "x", [position] = secret },
        { [secret] = position },
        { { { array } } },
        { list = { 1, 2 }, map = { deep = { position, secret } } },
      }
    end
    for position = 1, 5 do
      local values = shapes(position)
      for index = 1, #values do
        for _, channel in ipairs({ "none", "addon", "print" }) do
          local ok, message = pcall(CodecKit.Encode, CodecKit, values[index], { channel = channel })
          assert.is_false(ok)
          assert.is_not_nil(
            tostring(message):find("value must not contain a secret value", 1, true)
          )
          assert.are.equal(0, pool:GetActiveCount())
        end
      end
    end
  end)

  it("treats nothing as secret on a client without issecretvalue", function()
    TestEnv.Reset()
    CodecKit = TestEnv.NewPackage()
    local ok, text = CodecKit:Encode({ "plain", 1 })
    assert.is_true(ok)
    local decoded, value = CodecKit:Decode(text)
    assert.is_true(decoded)
    assert.are.same({ "plain", 1 }, value)
  end)
end)

local TestEnv = require("CodecKitTestEnv")
local Async = TestEnv.Async

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into CodecKit. A wrong `error` level shows up either as
---a different line number or as a message with no `file:line` prefix at all.
---
---`action` receives a `mark` function; calling `mark()` records the line of the
---statement on the line after it, which must be the call into CodecKit.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

local FACADE_METHODS = {
  "Encode",
  "Decode",
  "EncodeMany",
  "DecodeMany",
  "Serialize",
  "Deserialize",
  "Compress",
  "Decompress",
  "EncodeForAddon",
  "DecodeForAddon",
  "EncodeForPrint",
  "DecodeForPrint",
  "EncodeAsync",
  "DecodeAsync",
  "SetLimits",
  "GetLimits",
}

describe("CodecKit error levels", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("points every receiver error at the caller", function()
    for _, method in ipairs(FACADE_METHODS) do
      local label = "CodecKit:" .. method
      assertReportedAtCaller(
        label .. " must be called on the CodecKit facade; use " .. label .. "(...)",
        function(mark)
          mark()
          CodecKit[method]({}, "", nil)
        end
      )
    end
  end)

  it("points encode option errors at the caller", function()
    for _, method in ipairs({ "Encode", "EncodeMany" }) do
      local label = "CodecKit:" .. method
      local cases = {
        { "x", label .. " options must be a table or nil" },
        { { bogus = true }, label .. " options.bogus is not a recognised option" },
        { { compress = "zip" }, label .. ' options.compress must be "none" or "deflate"' },
        {
          { channel = "chat" },
          label .. ' options.channel must be "none", "addon" or "print"',
        },
        { { level = 0 }, label .. " options.level must be an integer from 1 to 9" },
        { { level = 10 }, label .. " options.level must be an integer from 1 to 9" },
        { { level = 1.5 }, label .. " options.level must be an integer from 1 to 9" },
      }
      for index = 1, #cases do
        local options = cases[index][1]
        assertReportedAtCaller(cases[index][2], function(mark)
          if method == "Encode" then
            mark()
            CodecKit:Encode(1, options)
          else
            mark()
            CodecKit:EncodeMany(options, 1)
          end
        end)
      end
    end
  end)

  it("points decode argument and option errors at the caller", function()
    for _, method in ipairs({ "Decode", "DecodeMany" }) do
      local label = "CodecKit:" .. method
      assertReportedAtCaller(label .. " text must be a string", function(mark)
        mark()
        CodecKit[method](CodecKit, nil)
      end)
      assertReportedAtCaller(label .. " options must be a table or nil", function(mark)
        mark()
        CodecKit[method](CodecKit, "", 1)
      end)
      assertReportedAtCaller(label .. " options.level is not a recognised option", function(mark)
        mark()
        CodecKit[method](CodecKit, "", { level = 1 })
      end)
      assertReportedAtCaller(
        label .. ' options.channel must be "none", "addon" or "print"',
        function(mark)
          mark()
          CodecKit[method](CodecKit, "", { channel = 1 })
        end
      )
    end
  end)

  it("points stage argument errors at the caller", function()
    local stages = {
      { "Deserialize", "bytes" },
      { "Compress", "bytes" },
      { "Decompress", "bytes" },
      { "EncodeForAddon", "bytes" },
      { "DecodeForAddon", "text" },
      { "EncodeForPrint", "bytes" },
      { "DecodeForPrint", "text" },
    }
    for index = 1, #stages do
      local method, argument = stages[index][1], stages[index][2]
      assertReportedAtCaller(
        "CodecKit:" .. method .. " " .. argument .. " must be a string",
        function(mark)
          mark()
          CodecKit[method](CodecKit, 42)
        end
      )
    end
    assertReportedAtCaller("CodecKit:Compress options must be a table or nil", function(mark)
      mark()
      CodecKit:Compress("", 6)
    end)
    assertReportedAtCaller(
      "CodecKit:Compress options.channel is not a recognised option",
      function(mark)
        mark()
        CodecKit:Compress("", { channel = "print" })
      end
    )
    assertReportedAtCaller(
      "CodecKit:Compress options.level must be an integer from 1 to 9",
      function(mark)
        mark()
        CodecKit:Compress("", { level = 12 })
      end
    )
  end)

  it("points secret refusals at the caller", function()
    local secret = TestEnv.NewSecret()
    TestEnv.InstallSecretProbe({ [secret] = true, ["hidden"] = true })
    assertReportedAtCaller("CodecKit:Encode value must not contain a secret value", function(mark)
      mark()
      CodecKit:Encode({ { secret } })
    end)
    assertReportedAtCaller(
      "CodecKit:EncodeMany value must not contain a secret value",
      function(mark)
        mark()
        CodecKit:EncodeMany(nil, 1, secret)
      end
    )
    assertReportedAtCaller(
      "CodecKit:Serialize value must not contain a secret value",
      function(mark)
        mark()
        CodecKit:Serialize(secret)
      end
    )
    assertReportedAtCaller("CodecKit:Decode text must not be a secret value", function(mark)
      mark()
      CodecKit:Decode("hidden")
    end)
  end)

  it("refuses a secret option or limit value at the caller before comparing it", function()
    -- Plain values the probe calls secret: a secret may not even be
    -- compared with nil, so each is refused before its option is read.
    TestEnv.InstallSecretProbe({ [7] = true, ["deflate"] = true, ["print"] = true, [99] = true })
    assertReportedAtCaller(
      "CodecKit:Encode options.compress must not be a secret value",
      function(mark)
        mark()
        CodecKit:Encode(1, { compress = "deflate" })
      end
    )
    assertReportedAtCaller(
      "CodecKit:EncodeMany options.channel must not be a secret value",
      function(mark)
        mark()
        CodecKit:EncodeMany({ channel = "print" }, 1)
      end
    )
    assertReportedAtCaller(
      "CodecKit:Encode options.level must not be a secret value",
      function(mark)
        mark()
        CodecKit:Encode(1, { level = 7 })
      end
    )
    assertReportedAtCaller(
      "CodecKit:Compress options.level must not be a secret value",
      function(mark)
        mark()
        CodecKit:Compress("bytes", { level = 7 })
      end
    )
    assertReportedAtCaller(
      "CodecKit:Decode options.channel must not be a secret value",
      function(mark)
        mark()
        CodecKit:Decode("\1\1\1", { channel = "print" })
      end
    )
    assertReportedAtCaller(
      "CodecKit:SetLimits limits.maxDepth must not be a secret value",
      function(mark)
        mark()
        CodecKit:SetLimits({ maxDepth = 99 })
      end
    )
    assert.are.equal(16, CodecKit:GetLimits().maxDepth)
  end)

  it("refuses a secret receiver or options argument at the caller", function()
    -- A secret may not even be compared with nil or with the facade, so
    -- each argument is tested with `type` before anything compares it.
    TestEnv.InstallSecretProbe({ ["hidden"] = true })
    assertReportedAtCaller(
      "CodecKit:Encode must be called on the CodecKit facade; use CodecKit:Encode(...)",
      function(mark)
        mark()
        CodecKit.Encode("hidden")
      end
    )
    assertReportedAtCaller("CodecKit:Encode options must be a table or nil", function(mark)
      mark()
      CodecKit:Encode(1, "hidden")
    end)
    assertReportedAtCaller("CodecKit:DecodeMany options must be a table or nil", function(mark)
      mark()
      CodecKit:DecodeMany("\1\1\1", "hidden")
    end)
    assertReportedAtCaller("CodecKit:Compress options must be a table or nil", function(mark)
      mark()
      CodecKit:Compress("bytes", "hidden")
    end)
  end)

  it("points limit errors at the caller", function()
    local cases = {
      { 5, "CodecKit:SetLimits limits must be a table" },
      { { depth = 3 }, "CodecKit:SetLimits limits.depth is not a recognised limit" },
      {
        { maxDepth = 0 },
        "CodecKit:SetLimits limits.maxDepth must be an integer from 1 to 128",
      },
      {
        { maxValues = 2 ^ 25 },
        "CodecKit:SetLimits limits.maxValues must be an integer from 1 to 16777216 or CodecKit.UNBOUNDED",
      },
      {
        { maxListValues = 7901 },
        "CodecKit:SetLimits limits.maxListValues must be an integer from 1 to 7900",
      },
      {
        { maxDepth = CodecKit.UNBOUNDED },
        "CodecKit:SetLimits limits.maxDepth cannot be CodecKit.UNBOUNDED because the reader and writer recurse on the Lua call stack; use an integer from 1 to 128",
      },
      {
        { maxOutputBytes = 0.5 },
        "CodecKit:SetLimits limits.maxOutputBytes must be an integer from 1 to 67108864",
      },
    }
    for index = 1, #cases do
      assertReportedAtCaller(cases[index][2], function(mark)
        mark()
        CodecKit:SetLimits(cases[index][1])
      end)
    end
  end)

  it("points a missing SchedulerKit at the caller", function()
    assertReportedAtCaller(
      "CodecKit:EncodeAsync requires SchedulerKit API 1, which is not loaded (absent)",
      function(mark)
        mark()
        CodecKit:EncodeAsync(1, nil, {}, print)
      end
    )
    assertReportedAtCaller(
      "CodecKit:DecodeAsync requires SchedulerKit API 1, which is not loaded (absent)",
      function(mark)
        mark()
        CodecKit:DecodeAsync("", nil, {}, print)
      end
    )
  end)

  it("points asynchronous argument errors at the caller", function()
    TestEnv.Reset()
    local AsyncCodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    assertReportedAtCaller("CodecKit:EncodeAsync scope must be a SchedulerKit scope", function(mark)
      mark()
      AsyncCodecKit:EncodeAsync(1, nil, {}, print)
    end)
    assertReportedAtCaller("CodecKit:EncodeAsync callback must be a function", function(mark)
      mark()
      AsyncCodecKit:EncodeAsync(1, nil, scope, "print")
    end)
    assertReportedAtCaller("CodecKit:DecodeAsync text must be a string", function(mark)
      mark()
      AsyncCodecKit:DecodeAsync(1, nil, scope, print)
    end)
    assertReportedAtCaller(
      'CodecKit:EncodeAsync options.compress must be "none" or "deflate"',
      function(mark)
        mark()
        AsyncCodecKit:EncodeAsync(1, { compress = true }, scope, print)
      end
    )
    scope:Close()
    assertReportedAtCaller("CodecKit:DecodeAsync scope is closed", function(mark)
      mark()
      AsyncCodecKit:DecodeAsync("", nil, scope, print)
    end)
    local secret = TestEnv.NewSecret()
    TestEnv.InstallSecretProbe({ [secret] = true })
    assertReportedAtCaller(
      "CodecKit:EncodeAsync value must not contain a secret value",
      function(mark)
        mark()
        AsyncCodecKit:EncodeAsync({ secret }, nil, SchedulerKit:CreateScope(), print)
      end
    )
    Async.Reset()
  end)
end)

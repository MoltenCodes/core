local Env = require("LogKitTestEnv")

describe("LogKit formatting", function()
  local LogKit, logger, delivered

  before_each(function()
    LogKit = Env.NewPackage()
    logger = LogKit:ForAddon("MyAddon")
    delivered = {}
    LogKit:AddSink(function(record)
      delivered[#delivered + 1] = record.message
    end)
  end)
  after_each(function()
    Env.Reset()
  end)

  ---A value whose every observable use is recorded, so a spec can prove the
  ---arguments were never touched.
  ---@return table probe
  ---@return table touches
  local function newProbe()
    local touches = {}
    local probe = setmetatable({}, {
      __tostring = function()
        touches[#touches + 1] = "tostring"
        return "probe"
      end,
      __concat = function()
        touches[#touches + 1] = "concat"
        return "probe"
      end,
      __index = function(_, key)
        touches[#touches + 1] = "index " .. tostring(key)
        return nil
      end,
      __call = function()
        touches[#touches + 1] = "call"
      end,
      __len = function()
        touches[#touches + 1] = "len"
        return 0
      end,
    })
    return probe, touches
  end

  it("never formats or touches the arguments while the level is disabled", function()
    local probe, touches = newProbe()
    logger:Debug("value %s", probe)
    logger:Trace("value %s and %s", probe, probe)
    logger:Log("info", "value %s", probe)
    assert.are.same({}, touches)
    assert.are.same({}, delivered)
  end)

  it("formats once per enabled message with string.format", function()
    logger:Warn("%s has %d items (%.1f%%)", "bag", 12, 37.5)
    assert.are.same({ "bag has 12 items (37.5%)" }, delivered)
  end)

  it("formats a table argument through its __tostring, once, only when enabled", function()
    local probe, touches = newProbe()
    logger:Debug("value %s", probe)
    assert.are.same({}, touches)
    logger:Error("value %s", probe)
    assert.are.same({ "value probe" }, delivered)
    assert.are.same({ "tostring" }, touches)
  end)

  it("formats nil, booleans and plain tables with %s as Lua 5.2 would", function()
    logger:Warn("%s %s %s", nil, true, false)
    logger:Warn("%s", {})
    assert.are.equal("nil true false", delivered[1])
    assert.is_not_nil(delivered[2]:match("^table: "))
    assert.are.same({}, Env.TakeReportedErrors())
  end)

  it("delivers a bare message unchanged, so a percent sign in it is safe", function()
    logger:Warn("100% done, %d and %s stay literal")
    assert.are.same({ "100% done, %d and %s stay literal" }, delivered)
  end)

  it("reports a bad format string through the host error handler and delivers nothing", function()
    logger:Warn("%d items", "twelve")
    assert.are.same({}, delivered)
    local reported = Env.TakeReportedErrors()
    assert.are.equal(1, #reported)
    local message = tostring(reported[1].value)
    assert.is_not_nil(
      message:find("LogKit.Logger:Warn could not format a message for addon MyAddon: ", 1, true)
    )
    -- Nothing was recorded either: the journal is fed after formatting.
    local count = 0
    for _ in LogKit:History() do
      count = count + 1
    end
    assert.are.equal(0, count)
  end)

  it("does not raise into the caller on a bad format string", function()
    assert.has_no.errors(function()
      logger:Error("%q %z", 1)
    end)
  end)

  it("refuses more than MAX_FORMAT_ARGUMENTS format arguments at the caller", function()
    assert.are.equal(16, LogKit.MAX_FORMAT_ARGUMENTS)
    local arguments = {}
    for index = 1, 17 do
      arguments[index] = index
    end
    Env.expectErrorContaining(
      "LogKit.Logger:Warn accepts at most 16 format arguments; received 17",
      function()
        logger:Warn(string.rep("%d ", 17), unpack(arguments))
      end
    )
    assert.are.same({}, delivered)
  end)

  it("accepts exactly MAX_FORMAT_ARGUMENTS arguments, explicit nils counted", function()
    local arguments = {}
    local specifiers = {}
    for index = 1, 16 do
      arguments[index] = index
      specifiers[index] = "%d"
    end
    logger:Warn(table.concat(specifiers, ","), unpack(arguments))
    assert.are.same({ "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16" }, delivered)
  end)

  it("checks the message only when the level is enabled", function()
    assert.has_no.errors(function()
      logger:Debug(42)
    end)
    Env.expectErrorContaining("LogKit.Logger:Warn message must be a string", function()
      logger:Warn(42)
    end)
    Env.expectErrorContaining("LogKit.Logger:Log message must be a string", function()
      logger:Log("error", nil)
    end)
  end)

  it("stamps each record with the host clock", function()
    local seen
    LogKit:AddSink(function(record)
      seen = record.time
    end)
    Env.AdvanceWallMs(12500)
    logger:Warn("now")
    assert.are.equal(12.5, seen)
  end)

  it("stamps false on a host without GetTimePreciseSec", function()
    local ClocklessLogKit = Env.NewPackageWithoutClock()
    local seen = "unset"
    ClocklessLogKit:AddSink(function(record)
      seen = record.time
    end)
    ClocklessLogKit:ForAddon("MyAddon"):Warn("now")
    assert.is_false(seen)
    for _, _, _, _, time in ClocklessLogKit:History() do
      assert.is_false(time)
    end
  end)
end)

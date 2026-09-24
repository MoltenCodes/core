local TestEnv = require("MediaKitTestEnv")

describe("MediaKit:Register", function()
  local MediaKit
  before_each(function()
    MediaKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("accepts every media type", function()
    local mediaTypes = { "background", "border", "font", "icon", "sound", "statusbar", "texture" }
    for _, mediaType in ipairs(mediaTypes) do
      assert.is_true(MediaKit:Register(mediaType, "Pack Entry", "Interface\\Pack\\Entry"))
      assert.are.equal("Interface\\Pack\\Entry", MediaKit:Fetch(mediaType, "Pack Entry"))
    end
  end)

  it("refuses an unknown media type at the caller", function()
    TestEnv.expectErrorContaining('MediaKit:Register type must be one of "background"', function()
      MediaKit:Register("statusBar", "Name", "path")
    end)
    TestEnv.expectErrorContaining("type must be one of", function()
      MediaKit:Register(nil, "Name", "path")
    end)
  end)

  it("keeps a path a string and a FileDataID a number", function()
    assert.is_true(MediaKit:Register("sound", "Path Sound", "Interface\\Pack\\Ding.ogg"))
    assert.is_true(MediaKit:Register("sound", "Id Sound", 554003))

    local pathData = MediaKit:Fetch("sound", "Path Sound")
    local idData = MediaKit:Fetch("sound", "Id Sound")
    assert.are.equal("string", type(pathData))
    assert.are.equal("number", type(idData))
    assert.are.equal(554003, idData)
    assert.is_false(MediaKit:IsFileDataID(pathData))
    assert.is_true(MediaKit:IsFileDataID(idData))
  end)

  it("refuses data that is neither a path nor a FileDataID", function()
    local refused = { "", 0, -5, 1.5, math.huge, 0 / 0, true, {}, print }
    for _, data in ipairs(refused) do
      TestEnv.expectErrorContaining(
        "MediaKit:Register data must be a non-empty file path or a FileDataID (a positive integer)",
        function()
          MediaKit:Register("sound", "Bad", data)
        end
      )
    end
    assert.is_nil(MediaKit:Fetch("sound", "Bad"))
  end)

  it("refuses an empty or non-string name", function()
    TestEnv.expectErrorContaining("MediaKit:Register name must be a non-empty string", function()
      MediaKit:Register("sound", "", "path")
    end)
    TestEnv.expectErrorContaining("MediaKit:Register name must be a non-empty string", function()
      MediaKit:Register("sound", 1, "path")
    end)
  end)

  it("refuses a taken name holding different data", function()
    assert.is_true(MediaKit:Register("statusbar", "Smooth", "Interface\\Pack\\Smooth"))
    local registered, reason = MediaKit:Register("statusbar", "Smooth", "Interface\\Other\\Smooth")
    assert.is_nil(registered)
    assert.are.equal("taken", reason)
    assert.are.equal("Interface\\Pack\\Smooth", MediaKit:Fetch("statusbar", "Smooth"))
  end)

  it("refuses a built-in name holding different data", function()
    local registered, reason = MediaKit:Register("statusbar", "Blizzard", "Interface\\Pack\\Bar")
    assert.is_nil(registered)
    assert.are.equal("taken", reason)
  end)

  it("treats the same name with the same data as a no-op", function()
    local fired = 0
    MediaKit:OnRegistered("statusbar", function()
      fired = fired + 1
    end)
    assert.is_true(MediaKit:Register("statusbar", "Smooth", "Interface\\Pack\\Smooth"))
    local list = MediaKit:List("statusbar")
    assert.is_true(MediaKit:Register("statusbar", "Smooth", "Interface\\Pack\\Smooth"))
    assert.are.equal(1, fired)
    assert.are.equal(list, MediaKit:List("statusbar"))
  end)

  it("treats a path and a FileDataID as different data", function()
    assert.is_true(MediaKit:Register("sound", "Ding", 554003))
    local registered, reason = MediaKit:Register("sound", "Ding", "554003")
    assert.is_nil(registered)
    assert.are.equal("taken", reason)
  end)

  it("keeps one namespace per media type", function()
    assert.is_true(MediaKit:Register("statusbar", "Shared", "Interface\\Pack\\Bar"))
    assert.is_true(MediaKit:Register("background", "Shared", "Interface\\Pack\\Background"))
    assert.are.equal("Interface\\Pack\\Bar", MediaKit:Fetch("statusbar", "Shared"))
    assert.are.equal("Interface\\Pack\\Background", MediaKit:Fetch("background", "Shared"))
  end)

  it("refuses entries past MAX_ENTRIES_PER_TYPE with full, counting built-ins", function()
    assert.are.equal(1024, MediaKit.MAX_ENTRIES_PER_TYPE)
    local builtins = #MediaKit:List("statusbar")
    for index = 1, MediaKit.MAX_ENTRIES_PER_TYPE - builtins do
      assert.is_true(MediaKit:Register("statusbar", "Bar " .. index, index))
    end
    assert.are.equal(MediaKit.MAX_ENTRIES_PER_TYPE, #MediaKit:List("statusbar"))

    local registered, reason = MediaKit:Register("statusbar", "One Too Many", 99999)
    assert.is_nil(registered)
    assert.are.equal("full", reason)
    assert.is_nil(MediaKit:Fetch("statusbar", "One Too Many"))

    -- An identical re-registration is still accepted, and other types are
    -- not affected.
    assert.is_true(MediaKit:Register("statusbar", "Bar 1", 1))
    assert.is_true(MediaKit:Register("background", "Room", "Interface\\Pack\\Room"))
  end)

  it("accepts scripts for fonts only", function()
    assert.is_true(
      MediaKit:Register("font", "Latin Font", "Fonts\\Latin.ttf", { scripts = { "latin" } })
    )
    TestEnv.expectErrorContaining("MediaKit:Register scripts applies to fonts only", function()
      MediaKit:Register("statusbar", "Bar", "path", { scripts = { "latin" } })
    end)
  end)

  it("refuses an empty, malformed or unknown script list", function()
    TestEnv.expectErrorContaining("scripts must be a non-empty array of script names", function()
      MediaKit:Register("font", "Font", "path", { scripts = {} })
    end)
    TestEnv.expectErrorContaining("scripts must be a non-empty array of script names", function()
      MediaKit:Register("font", "Font", "path", { scripts = "latin" })
    end)
    TestEnv.expectErrorContaining('scripts contains unknown script "arabic"', function()
      MediaKit:Register("font", "Font", "path", { scripts = { "latin", "arabic" } })
    end)
    TestEnv.expectErrorContaining("scripts contains unknown script <number>", function()
      MediaKit:Register("font", "Font", "path", { scripts = { 1 } })
    end)
    TestEnv.expectErrorContaining('options contains unknown field "script"', function()
      MediaKit:Register("font", "Font", "path", { script = { "latin" } })
    end)
    assert.is_nil(MediaKit:Fetch("font", "Font", { anyScript = true }))
  end)

  it("compares scripts when deciding whether a font re-registration is identical", function()
    assert.is_true(
      MediaKit:Register("font", "Font", "Fonts\\A.ttf", { scripts = { "latin", "cyrillic" } })
    )
    -- The same set in another order, with a repeat, is the same entry.
    assert.is_true(
      MediaKit:Register(
        "font",
        "Font",
        "Fonts\\A.ttf",
        { scripts = { "cyrillic", "latin", "latin" } }
      )
    )
    local registered, reason =
      MediaKit:Register("font", "Font", "Fonts\\A.ttf", { scripts = { "latin" } })
    assert.is_nil(registered)
    assert.are.equal("taken", reason)
  end)
end)

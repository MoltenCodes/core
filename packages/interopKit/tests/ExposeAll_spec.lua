local Env = require("InteropKitTestEnv").Kits

describe("InteropKit:ExposeAll", function()
  after_each(function()
    Env.Reset()
  end)

  it("exposes every active package under its default major", function()
    local InteropKit, Registry, libStub, EventKit = Env.NewPackageWithKits()

    local exposed, skipped, refused = InteropKit:ExposeAll()
    assert.are.equal(3, exposed)
    assert.are.equal(0, skipped)
    assert.are.equal(0, refused)

    assert.are.equal(EventKit, libStub("MoltenCodes-EventKit-1"))
    assert.are.equal(Registry:Get("signalKit", 1), libStub("MoltenCodes-SignalKit-1"))
    assert.are.equal(InteropKit, libStub("MoltenCodes-InteropKit-1"))
    assert.are.equal(EventKit.REVISION, libStub.minors["MoltenCodes-EventKit-1"])
  end)

  it("returns the EventKit facade through LibStub's call form", function()
    local InteropKit, _, libStub, EventKit = Env.NewPackageWithKits()
    assert.is_true(InteropKit:ExposeToLibStub("eventKit", 1))

    local library, minor = libStub("MoltenCodes-EventKit-1")
    assert.are.equal(EventKit, library)
    assert.are.equal(EventKit.REVISION, minor)
    assert.are.equal("function", type(library.Connect))
  end)

  it("skips the packages named in options.except", function()
    local InteropKit, _, libStub = Env.NewPackageWithKits()

    local exposed, skipped, refused = InteropKit:ExposeAll({
      except = { "signalKit", "interopKit" },
    })
    assert.are.equal(1, exposed)
    assert.are.equal(2, skipped)
    assert.are.equal(0, refused)
    assert.is_nil(libStub:GetLibrary("MoltenCodes-SignalKit-1", true))
    assert.is_not_nil(libStub:GetLibrary("MoltenCodes-EventKit-1", true))
  end)

  it("counts a major held by a foreign library as refused", function()
    local InteropKit, _, libStub = Env.NewPackageWithKits()
    local foreign = libStub:NewLibrary("MoltenCodes-SignalKit-1", 1)

    local exposed, skipped, refused = InteropKit:ExposeAll()
    assert.are.equal(2, exposed)
    assert.are.equal(0, skipped)
    assert.are.equal(1, refused)
    assert.are.equal(foreign, libStub("MoltenCodes-SignalKit-1"))
  end)

  it("is idempotent", function()
    local InteropKit = Env.NewPackageWithKits()
    InteropKit:ExposeAll()
    local exposed, skipped, refused = InteropKit:ExposeAll()
    assert.are.equal(3, exposed)
    assert.are.equal(0, skipped)
    assert.are.equal(0, refused)
  end)

  it("refuses every package when LibStub is absent", function()
    local InteropKit = Env.NewPackageWithKits()
    Env.RemoveLibStub()

    local exposed, skipped, refused = InteropKit:ExposeAll({ except = { "interopKit" } })
    assert.are.equal(0, exposed)
    assert.are.equal(1, skipped)
    assert.are.equal(2, refused)
  end)

  it("re-exposes a Kit with a higher minor after its in-place upgrade", function()
    local InteropKit, _, libStub, EventKit = Env.NewPackageWithKits()
    InteropKit:ExposeAll()
    local before = libStub.minors["MoltenCodes-EventKit-1"]

    local upgraded = Env.LoadKitAtRevision("EventKit", EventKit.REVISION + 1)
    assert.are.equal(EventKit, upgraded)

    assert.is_true(InteropKit:ExposeToLibStub("eventKit", 1))
    assert.are.equal(before + 1, libStub.minors["MoltenCodes-EventKit-1"])
    assert.are.equal(EventKit, libStub("MoltenCodes-EventKit-1"))
  end)
end)

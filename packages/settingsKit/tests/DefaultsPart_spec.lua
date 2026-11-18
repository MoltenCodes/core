local TestEnv = require("SettingsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that a protected call failed with `message` at `expectedLine`.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

-- AddonKit's inference (`AddonKit-Database.lua`, "Inference"), written here
-- with SchemaKit: the schema a plain defaults table stands for. The Defaults
-- part must accept and refuse exactly what this schema does, with the same
-- messages.
local Inferred = {}

function Inferred.keys(S)
  return S.oneOf({ S.string({ max = 256 }), S.number() })
end

function Inferred.primitive(S, value)
  if type(value) == "boolean" then
    return S.boolean()
  elseif type(value) == "number" then
    return S.number()
  end
  return S.string({ max = math.max(4096, #value) })
end

function Inferred.array(S, value)
  local longest = 0
  for index = 1, #value do
    if type(value[index]) == "string" then
      longest = math.max(longest, #value[index])
    end
  end
  local element = type(value[1]) == "string" and S.string({ max = math.max(4096, longest) })
    or Inferred.primitive(S, value[1])
  local copy = {}
  for index = 1, #value do
    copy[index] = value[index]
  end
  return S.optional(S.array({ of = element, max = math.max(1024, #value) }), copy)
end

function Inferred.record(S, defaults)
  local fields = {}
  for key, value in pairs(defaults) do
    if key ~= "*" then
      fields[key] = Inferred.node(S, value)
    end
  end
  if defaults["*"] == nil then
    return S.table({ fields = fields })
  end
  return S.map({ keys = Inferred.keys(S), values = Inferred.node(S, defaults["*"]), max = 1024 })
end

function Inferred.node(S, value)
  if type(value) ~= "table" then
    return S.optional(Inferred.primitive(S, value), value)
  end
  local tag = getmetatable(value)
  if tag == "SchemaKit.Node" or tag == "SchemaKit.Schema" then
    local ok, optional = pcall(S.optional, value)
    return ok and optional or value
  end
  if next(value) == nil then
    return S.optional(S.map({ keys = Inferred.keys(S), values = S.any(), max = 1024 }), {})
  end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  if count == #value then
    return Inferred.array(S, value)
  end
  return S.optional(Inferred.record(S, value), {})
end

function Inferred.schema(S, defaults)
  local schema = {}
  for scope, scopeDefaults in pairs(defaults) do
    schema[scope] = Inferred.record(S, scopeDefaults)
  end
  return schema
end

describe("SettingsKit Defaults part", function()
  local SettingsKit, S

  before_each(function()
    local loaded = { TestEnv.NewPackage() }
    SettingsKit, S = loaded[1], loaded[5]
    TestEnv.LoadDefaults()
  end)

  after_each(TestEnv.Reset)

  ---The defaults of the differential corpus, built fresh for each database.
  local function corpus()
    return {
      profile = {
        enabled = true,
        scale = 1,
        name = "text",
        frame = { x = 0, y = 0, point = "CENTER" },
        bag = {},
        units = { ["*"] = { shown = true, alpha = 1 } },
        list = { 1, 2, 3 },
        names = { "a", "bb" },
        deep = { a = { b = { c = 1 } } },
        level = S.optional(S.number({ min = 0, max = 10 }), 5),
        mode = S.enum({ "a", "b" }),
      },
      global = { count = 0 },
    }
  end

  ---Open one database from plain defaults and one from the inferred schema.
  ---@return table plain, table inferred
  local function openPair()
    local plain = SettingsKit:Open("PlainDB", corpus())
    local inferred = SettingsKit:Open("InferredDB", Inferred.schema(S, corpus()))
    return plain, inferred
  end

  ---Run `write` on both databases from one line and compare the outcomes.
  ---@param plain table
  ---@param inferred table
  ---@param write fun(db: table)
  ---@return boolean accepted
  local function compareWrite(plain, inferred, write)
    local plainOk, plainMessage = pcall(write, plain)
    local inferredOk, inferredMessage = pcall(write, inferred)
    assert.are.equal(inferredOk, plainOk)
    if not plainOk then
      local normalised = tostring(plainMessage):gsub("PlainDB", "InferredDB")
      assert.are.equal(tostring(inferredMessage), normalised)
    end
    return plainOk
  end

  it("accepts and refuses every write exactly as the inferred SchemaKit schema does", function()
    local plain, inferred = openPair()
    local secret = TestEnv.NewSecret()
    TestEnv.InstallSecretProbe()
    local big = {}
    for index = 1, 1025 do
      big[index] = index
    end
    local wide = {}
    for index = 1, 1025 do
      wide["k" .. index] = true
    end
    local nested = {}
    for _ = 1, 20 do
      nested = { inner = nested }
    end
    local accepted = {
      function(db)
        db.profile.enabled = false
      end,
      function(db)
        db.profile.scale = 1.5
      end,
      function(db)
        db.profile.name = "other"
      end,
      function(db)
        db.profile.frame = { x = 1 }
      end,
      function(db)
        db.profile.frame.point = "TOP"
      end,
      function(db)
        db.profile.bag = { a = 1, [2] = true, nested = { any = "thing" } }
      end,
      function(db)
        db.profile.units.foo.shown = false
      end,
      function(db)
        db.profile.units[7] = { alpha = 0.5 }
      end,
      function(db)
        db.profile.list = { 4, 5 }
      end,
      function(db)
        db.profile.deep.a.b.c = 2
      end,
      function(db)
        db.profile.level = 3
      end,
      function(db)
        db.profile.mode = "b"
      end,
      function(db)
        db.profile.mode = nil
      end,
      function(db)
        db.global.count = 4
      end,
    }
    local refused = {
      function(db)
        db.profile.enabled = "no"
      end,
      function(db)
        db.profile.scale = "x"
      end,
      function(db)
        db.profile.scale = 0 / 0
      end,
      function(db)
        db.profile.name = string.rep("a", 5000)
      end,
      function(db)
        db.profile.names = { string.rep("n", 5000) }
      end,
      function(db)
        db.profile.name = 5
      end,
      function(db)
        db.profile.frame = { z = 1 }
      end,
      function(db)
        db.profile.frame.x = "a"
      end,
      function(db)
        db.profile.frame = 5
      end,
      function(db)
        db.profile.bag = { [string.rep("k", 300)] = 1 }
      end,
      function(db)
        db.profile.bag = { [true] = 1 }
      end,
      function(db)
        db.profile.bag = wide
      end,
      function(db)
        db.profile.units.foo.alpha = "x"
      end,
      function(db)
        db.profile.units = { foo = { shown = 1 } }
      end,
      function(db)
        db.profile.units = { [string.rep("u", 300)] = {} }
      end,
      function(db)
        db.profile.list = { 1, "a" }
      end,
      function(db)
        db.profile.list = { [1] = 1, [3] = 3 }
      end,
      function(db)
        db.profile.list = big
      end,
      function(db)
        db.profile.deep.a.b.c = "x"
      end,
      function(db)
        db.profile.deep = { a = { b = { c = true } } }
      end,
      function(db)
        db.profile.bag = nested
      end,
      function(db)
        db.profile.level = 11
      end,
      function(db)
        db.profile.level = "x"
      end,
      function(db)
        db.profile.mode = "c"
      end,
      function(db)
        db.profile.nope = 1
      end,
      function(db)
        db.profile.scale = secret
      end,
      function(db)
        db.global.count = {}
      end,
    }
    for index, write in ipairs(accepted) do
      assert.is_true(compareWrite(plain, inferred, write), "accepted write " .. index)
    end
    for index, write in ipairs(refused) do
      assert.is_false(compareWrite(plain, inferred, write), "refused write " .. index)
    end
    -- The saved data agrees too.
    assert.are.same(TestEnv.GetGlobal("InferredDB").profiles, TestEnv.GetGlobal("PlainDB").profiles)
  end)

  it("reads the same defaults and validates as the inferred schema", function()
    local plain, inferred = openPair()
    for _, db in ipairs({ plain, inferred }) do
      assert.is_true(db.profile.enabled)
      assert.are.equal("CENTER", db.profile.frame.point)
      assert.is_true(db.profile.units.anything.shown)
      assert.are.same({ 1, 2, 3 }, db.profile.list)
      assert.are.equal(5, db.profile.level)
      assert.is_nil(db.profile.mode)
      assert.are.equal(0, db.global.count)
    end
    local plainAnswer = { plain:Validate("profile", "frame.x", "a") }
    local inferredAnswer = { inferred:Validate("profile", "frame.x", "a") }
    assert.are.same(
      { inferredAnswer[1], (inferredAnswer[2]:gsub("InferredDB", "PlainDB")) },
      plainAnswer
    )
    assert.are.same({ true }, { plain:Validate("profile", "units.x.alpha", 0) })
  end)

  it("serves Pairs, Getter and Compact as a database opened from the inferred schema", function()
    local plain, inferred = openPair()
    for _, db in ipairs({ plain, inferred }) do
      db.profile.scale = 2
      db.profile.enabled = true
      db.profile.frame.x = 0
      db.profile.units.foo.shown = true
      local getter = db:Getter("profile", "scale")
      assert.are.equal(2, getter())
      local seen = {}
      for key in db:Pairs(db.profile) do
        seen[key] = true
      end
      assert.is_true(seen.scale)
      db:Compact()
    end
    assert.are.same(TestEnv.GetGlobal("InferredDB").profiles, TestEnv.GetGlobal("PlainDB").profiles)
    assert.are.equal(2, TestEnv.GetGlobal("PlainDB").profiles.Default.scale)
  end)

  it("refuses defaults that have no SettingsKit form at the caller's line", function()
    local cases = {
      { { profile = { ["**"] = { a = 1 } } }, 'defaults profile uses ["**"]' },
      { { profile = { ["*"] = 1, named = 2 } }, 'defaults profile puts ["*"] beside named keys' },
      { { profile = { [1] = true, named = 2 } }, "defaults profile has a number key" },
      {
        { profile = { list = { 1, "a" } } },
        "defaults profile.list is a list of mixed or table values",
      },
      {
        { profile = { list = { {}, {} } } },
        "defaults profile.list is a list of mixed or table values",
      },
      { { profile = { callback = print } }, "defaults profile.callback is a function" },
    }
    for _, case in ipairs(cases) do
      local line
      local ok, failure = pcall(function()
        line = currentLine() + 1
        SettingsKit:Open("RefusedDB", case[1])
      end)
      assert.is_false(ok)
      local expected = SOURCE .. ":" .. line .. ": SettingsKit:Open " .. case[2]
      assert.are.equal(expected, tostring(failure):sub(1, #expected))
    end
    local deep = { leaf = 1 }
    for _ = 1, 17 do
      deep = { inner = deep }
    end
    local ok, failure = pcall(SettingsKit.Open, SettingsKit, "DeepDB", { profile = deep })
    assert.is_false(ok)
    assert.is_truthy(tostring(failure):find("nest deeper than 16 tables", 1, true))
    assert.is_nil(TestEnv.GetGlobal("RefusedDB"))
  end)

  it("keeps a SchemaKit leaf's own message, with the path prefixed", function()
    local db = SettingsKit:Open("PlainDB", {
      profile = { frame = { size = S.optional(S.number({ min = 1, max = 64 }), 8) } },
    })
    assert.are.equal(8, db.profile.frame.size)
    local line
    local ok, failure = pcall(function()
      line = currentLine() + 1
      db.profile.frame.size = 100
    end)
    assertReportedAt(
      line,
      "SettingsKit (PlainDB) profile.frame.size: expected number <= 64, found larger number",
      ok,
      failure
    )
  end)

  it("shares one plan per defaults table", function()
    local defaults = { profile = { scale = 1 } }
    local first = SettingsKit:Open("FirstDB", defaults)
    local second = SettingsKit:Open("SecondDB", defaults)
    assert.are.equal(first._scopes.profile.plan, second._scopes.profile.plan)
    assert.are.equal(first._scopes.profile.schema, second._scopes.profile.schema)
  end)

  it("registers a namespace from plain defaults", function()
    TestEnv.LoadNamespaces()
    local db = SettingsKit:Open("PlainDB", { profile = { scale = 1 } })
    local child = db:RegisterNamespace("Module", { profile = { shown = true } })
    assert.is_true(child.profile.shown)
    local ok = pcall(function()
      child.profile.shown = 1
    end)
    assert.is_false(ok)
  end)

  it("answers HasPart", function()
    assert.is_true(SettingsKit:HasPart("Defaults"))
  end)

  it("allocates nothing for a read or a scalar write of a plain database #allocation", function()
    local db = SettingsKit:Open("PlainDB", { profile = { scale = 1, frame = { x = 0 } } })
    db.profile.scale = 2
    db.profile.frame.x = 1
    local profile = db.profile
    local frame = profile.frame
    local allocated = TestEnv.AllocatedKilobytes(function()
      for index = 1, 200 do
        profile.scale = index
        frame.x = index
        local _ = profile.scale + frame.x
      end
    end)
    assert.are.equal(0, allocated)
  end)
end)

describe("SettingsKit plain defaults without the Defaults part", function()
  after_each(TestEnv.Reset)

  it("raises the not-loaded message at the caller's line", function()
    local SettingsKit = TestEnv.NewCore()
    local line
    local ok, failure = pcall(function()
      line = currentLine() + 1
      SettingsKit:Open("PlainDB", { profile = { scale = 1 } })
    end)
    assertReportedAt(
      line,
      "SettingsKit:Open plain defaults are in SettingsKit's Defaults part, which is not loaded:"
        .. " add settingsKit\\parts\\SettingsKit-Defaults.lua",
      ok,
      failure
    )
    assert.is_false(SettingsKit:HasPart("Defaults"))
  end)

  it("opens a SchemaKit schema without the part", function()
    local loaded = { TestEnv.NewCore() }
    local SettingsKit, S = loaded[1], loaded[5]
    local db = SettingsKit:Open("SchemaDB", {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
    assert.are.equal(1, db.profile.scale)
  end)

  it("opens plain defaults with no SchemaKit loaded at all", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    local SettingsKit = require("SettingsKit")
    TestEnv.LoadDefaults()
    TestEnv.SetPlayer()
    assert.is_nil(Registry:Find("schemaKit", 1))
    local db = SettingsKit:Open("PlainDB", { profile = { scale = 1, names = { "a" }, bag = {} } })
    db.profile.scale = 2
    db.profile.bag.anything = { deeper = true }
    local ok, failure = pcall(function()
      db.profile.scale = "x"
    end)
    assert.is_false(ok)
    assert.is_truthy(
      tostring(failure):find("profile.scale: expected number, found string", 1, true)
    )
    assert.are.equal(2, db.profile.scale)
  end)

  it(
    "keeps a schema database revision 15 opened, and serves plain defaults after the upgrade",
    function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      require("SignalKit")
      require("EventKit")
      local S = require("SchemaKit")
      local previous = TestEnv.LoadRevision(15)
      TestEnv.SetPlayer()
      local db = previous:Open("SchemaDB", {
        profile = S.table({ fields = { scale = S.optional(S.number({ max = 2 }), 1) } }),
      })
      db.profile.scale = 2

      local current = TestEnv.ReloadPackage()
      assert.are.equal(previous, current)
      assert.are.equal(16, current.REVISION)
      db.profile.scale = 1.5
      assert.are.equal(1.5, db.profile.scale)
      local ok = pcall(function()
        db.profile.scale = 3
      end)
      assert.is_false(ok)

      TestEnv.LoadDefaults()
      local plain = current:Open("PlainDB", { profile = { scale = 1 } })
      plain.profile.scale = 3
      assert.are.equal(3, plain.profile.scale)
    end
  )

  it("refuses to load the part without the core", function()
    TestEnv.Reset()
    require("Registry")
    local ok, failure = pcall(TestEnv.LoadDefaults)
    assert.is_false(ok)
    assert.is_truthy(
      tostring(failure):find(
        "MoltenCodes SettingsKit part Defaults requires SettingsKit API 1 to be loaded first",
        1,
        true
      )
    )
  end)
end)

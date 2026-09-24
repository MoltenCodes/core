-- The `implements` option: what a provided value, or a module, must carry.
-- Every check either passes silently or raises at the line of the call that
-- produced the value: the `Provide*` or `CreateModule` line for a value that
-- exists at registration, the resolving line for a lazy provider's value.

local TestEnv = require("ModuleKitTestEnv")

local expectCallerError = TestEnv.expectCallerError

---A class whose instances inherit their methods through a metatable, the
---shape a provided object usually has.
local Database = {}
Database.__index = Database

---@return table
function Database.New()
  return setmetatable({ rows = {} }, Database)
end

function Database:Save() end

function Database:Load() end

---The contract every spec below declares for a database-like value.
local DATABASE_CONTRACT = { implements = { "Save", "Load" } }

describe("ModuleKit implements on providers", function()
  local ModuleKit, addon

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
    addon = ModuleKit:ForAddon("MyAddon")
  end)

  after_each(TestEnv.Reset)

  it("accepts a value whose methods are inherited", function()
    local database = Database.New()

    addon:ProvideValue("Database", database, DATABASE_CONTRACT)

    assert.are.equal(database, addon:Resolve("Database"))
  end)

  it("refuses a value missing a method at the caller's line and leaves the name free", function()
    expectCallerError(
      'ModuleKit provider "Database" must implement "Load": no such member',
      function()
        addon:ProvideValue("Database", { Save = function() end }, DATABASE_CONTRACT)
      end
    )

    assert.has_error(function()
      addon:Resolve("Database")
    end)
    addon:ProvideValue("Database", Database.New(), DATABASE_CONTRACT)
  end)

  it("refuses a member that is not a function", function()
    expectCallerError(
      'ModuleKit provider "Database" must implement "Save": member "Save" is a string, not a function',
      function()
        addon:ProvideValue("Database", { Save = "yes", Load = function() end }, DATABASE_CONTRACT)
      end
    )
  end)

  it("refuses a value that is not a table", function()
    expectCallerError(
      'ModuleKit provider "Database" must implement "Save": the value is a number, not a table',
      function()
        addon:ProvideValue("Database", 42, DATABASE_CONTRACT)
      end
    )
  end)

  it("checks a singleton when its factory first runs and caches only a conforming value", function()
    local calls = 0
    local conforming = false
    addon:ProvideSingleton("Database", function()
      calls = calls + 1
      if conforming then
        return Database.New()
      end
      return { Save = function() end }
    end, DATABASE_CONTRACT)

    expectCallerError(
      'ModuleKit provider "Database" must implement "Load": no such member',
      function()
        addon:Resolve("Database")
      end
    )
    assert.are.equal(1, calls)

    conforming = true
    local value = addon:Resolve("Database")
    assert.are.equal(value, addon:Resolve("Database"))
    assert.are.equal(2, calls)
  end)

  it("looks a singleton's members up once, not on every resolution", function()
    local lookups = 0
    local value = setmetatable({}, {
      __index = function(_, key)
        lookups = lookups + 1
        return Database[key]
      end,
    })
    addon:ProvideSingleton("Database", function()
      return value
    end, DATABASE_CONTRACT)

    addon:Resolve("Database")
    addon:Resolve("Database")
    addon:Resolve("Database")

    assert.are.equal(2, lookups)
  end)

  it("checks a module-scoped provider per requesting module and names the module", function()
    addon:ProvideModule("Logger", function(_, module)
      if module:GetName() == "Quiet" then
        return {}
      end
      return { Log = function() end }
    end, { implements = { "Log" } })
    local talkative = addon:CreateModule("Talkative")
    local quiet = addon:CreateModule("Quiet")

    assert.is_table(talkative:Resolve("Logger"))
    expectCallerError(
      'ModuleKit provider "Logger[Quiet]" must implement "Log": no such member',
      function()
        quiet:Resolve("Logger")
      end
    )
  end)

  it("checks a transient provider on every resolution", function()
    local calls = 0
    addon:ProvideTransient("Request", function()
      calls = calls + 1
      if calls == 1 then
        return { Send = function() end }
      end
      return { Send = true }
    end, { implements = { "Send" } })

    assert.is_table(addon:Resolve("Request"))
    expectCallerError(
      'ModuleKit provider "Request" must implement "Send": member "Send" is a boolean, not a function',
      function()
        addon:Resolve("Request")
      end
    )
  end)

  it("records a refused injected value as the module's failure", function()
    addon:ProvideSingleton("Database", function()
      return {}
    end, DATABASE_CONTRACT)
    local module = addon:CreateModule("UI")
    module:Inject("database", "Database")

    TestEnv.expectErrorContaining('provider "Database" must implement "Save"', function()
      module:Initialize()
    end)

    assert.is_true(module:HasLastError())
    assert.are.equal("created", module:GetState())
  end)

  it("does not check a provider registered without options", function()
    addon:ProvideValue("Anything", {})
    addon:ProvideSingleton("Lazy", function()
      return 7
    end)

    assert.are.same({}, addon:Resolve("Anything"))
    assert.are.equal(7, addon:Resolve("Lazy"))
  end)

  it("copies the list, so editing it afterwards changes nothing", function()
    local names = { "Save" }
    addon:ProvideSingleton("Database", function()
      return { Save = function() end }
    end, { implements = names })
    names[2] = "Load"

    assert.is_table(addon:Resolve("Database"))
  end)

  it("refuses options that are not a table", function()
    expectCallerError(
      "ModuleKit.Addon:ProvideSingleton options must be a table when provided",
      function()
        addon:ProvideSingleton("Database", Database.New, "Save")
      end
    )
  end)

  it("refuses an unknown option", function()
    expectCallerError(
      'ModuleKit.Addon:ProvideValue options contains unknown field "implement"',
      function()
        addon:ProvideValue("Database", Database.New(), { implement = { "Save" } })
      end
    )
  end)

  it("refuses an empty list", function()
    expectCallerError(
      "ModuleKit.Addon:ProvideValue options.implements must name at least one method",
      function()
        addon:ProvideValue("Database", Database.New(), { implements = {} })
      end
    )
  end)

  it("refuses a name listed twice", function()
    expectCallerError(
      'ModuleKit.Addon:ProvideModule options.implements names "Save" twice',
      function()
        addon:ProvideModule("Database", Database.New, { implements = { "Save", "Load", "Save" } })
      end
    )
  end)

  it("refuses an entry that is not a non-empty string", function()
    expectCallerError(
      "ModuleKit.Addon:ProvideTransient options.implements entries must be non-empty strings",
      function()
        addon:ProvideTransient("Database", Database.New, { implements = { "Save", "" } })
      end
    )
  end)

  it("refuses a sparse list, a list without index 1, a keyed table and a string", function()
    local label = "ModuleKit.Addon:ProvideValue options.implements"
    local expected = label .. " must be a dense array of method names or a SchemaKit schema"
    expectCallerError(expected, function()
      addon:ProvideValue("Database", Database.New(), { implements = { "Save", nil, "Load" } })
    end)
    expectCallerError(expected, function()
      addon:ProvideValue("Database", Database.New(), { implements = { Save = true } })
    end)
    -- Two positive-integer keys, but no index 1: a hole at the start is a
    -- density failure, not a bad entry.
    expectCallerError(expected, function()
      addon:ProvideValue(
        "Database",
        Database.New(),
        { implements = { [2] = "Save", [3] = "Load" } }
      )
    end)
    expectCallerError(expected, function()
      addon:ProvideValue("Database", Database.New(), { implements = "Save" })
    end)
  end)
end)

describe("ModuleKit implements on module definitions", function()
  local ModuleKit, addon

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
    addon = ModuleKit:ForAddon("MyAddon")
  end)

  after_each(TestEnv.Reset)

  it("accepts a definition whose hooks and ModuleKit methods satisfy the list", function()
    local module = addon:CreateModule("Inventory", {
      implements = { "OnEnable", "OnDisable", "GetName" },
      onEnable = function() end,
      onDisable = function() end,
    })

    assert.are.equal("Inventory", module:GetName())
    assert.is_true(addon:HasModule("Inventory"))
  end)

  it(
    "refuses a definition missing a member at the caller's line and does not create the module",
    function()
      expectCallerError(
        'ModuleKit module "Inventory" must implement "OnEnable": no such member',
        function()
          addon:CreateModule(
            "Inventory",
            { implements = { "OnEnable" }, onDisable = function() end }
          )
        end
      )

      assert.is_false(addon:HasModule("Inventory"))
    end
  )

  it("refuses a member that is not a function", function()
    expectCallerError(
      'ModuleKit module "Inventory" must implement "scope": member "scope" is a table, not a function',
      function()
        addon:CreateModule("Inventory", { implements = { "scope" } })
      end
    )
  end)

  it("refuses an empty list, a name listed twice and a non-table value", function()
    local label = "ModuleKit module definition implements"
    expectCallerError(label .. " must name at least one method", function()
      addon:CreateModule("Inventory", { implements = {} })
    end)
    expectCallerError(label .. ' names "OnEnable" twice', function()
      addon:CreateModule("Inventory", { implements = { "OnEnable", "OnEnable" } })
    end)
    expectCallerError(
      label .. " must be a dense array of method names or a SchemaKit schema",
      function()
        addon:CreateModule("Inventory", { implements = true })
      end
    )
    assert.is_false(addon:HasModule("Inventory"))
  end)
end)

describe("ModuleKit implements with SchemaKit loaded", function()
  local ModuleKit, addon, SchemaKit

  ---Whether `value` is a function; SchemaKit has no builder for functions.
  ---@param value any
  ---@return boolean
  local function isFunction(value)
    return type(value) == "function"
  end

  ---A schema that requires a `Save` method and accepts every other field.
  ---@return table node an unsealed SchemaKit node
  local function saveNode()
    return SchemaKit.table({
      fields = { Save = SchemaKit.custom(isFunction, "function") },
      open = true,
    })
  end

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
    SchemaKit = require("SchemaKit")
    addon = ModuleKit:ForAddon("MyAddon")
  end)

  after_each(TestEnv.Reset)

  it("accepts a value matching a sealed schema", function()
    local database = { rows = {}, Save = function() end }

    addon:ProvideValue("Database", database, { implements = SchemaKit:Seal(saveNode()) })

    assert.are.equal(database, addon:Resolve("Database"))
  end)

  it("accepts an unsealed node", function()
    addon:ProvideValue("Database", { Save = function() end }, { implements = saveNode() })

    assert.is_table(addon:Resolve("Database"))
  end)

  -- SchemaKit reads table fields with `rawget`, by its own contract, so a
  -- method a value inherits through its metatable satisfies the list form
  -- but not a table schema.
  it("does not see a method inherited through a metatable, unlike the list form", function()
    addon:ProvideValue("Listed", Database.New(), DATABASE_CONTRACT)

    expectCallerError(
      'ModuleKit provider "Database" does not match its implements schema: at Save, expected function, found nil',
      function()
        addon:ProvideValue("Database", Database.New(), { implements = saveNode() })
      end
    )
  end)

  it("refuses a value the schema rejects, naming the path", function()
    expectCallerError(
      'ModuleKit provider "Database" does not match its implements schema: at Save, expected function, found string',
      function()
        addon:ProvideValue("Database", { Save = "yes" }, { implements = saveNode() })
      end
    )
  end)

  it("reports a failure at the root without a path", function()
    expectCallerError(
      'ModuleKit provider "Database" does not match its implements schema: expected table, found number',
      function()
        addon:ProvideValue("Database", 42, { implements = saveNode() })
      end
    )
  end)

  it("checks a lazy provider's value with the schema at the resolving line", function()
    addon:ProvideSingleton("Database", function()
      return { Save = function() end }
    end, { implements = saveNode() })
    addon:ProvideTransient("Broken", function()
      return {}
    end, { implements = saveNode() })

    assert.is_table(addon:Resolve("Database"))
    expectCallerError(
      'ModuleKit provider "Broken" does not match its implements schema: at Save, expected function, found nil',
      function()
        addon:Resolve("Broken")
      end
    )
  end)

  it("checks a module definition against an open table schema", function()
    local hookNode = SchemaKit.table({
      fields = { OnEnable = SchemaKit.custom(isFunction, "function") },
      open = true,
    })

    local module = addon:CreateModule("Inventory", {
      implements = hookNode,
      onEnable = function() end,
    })
    assert.is_true(module:IsInitialized() == false)

    expectCallerError(
      'ModuleKit module "Forgotten" does not match its implements schema: at OnEnable, expected function, found nil',
      function()
        addon:CreateModule("Forgotten", { implements = hookNode })
      end
    )
    assert.is_false(addon:HasModule("Forgotten"))
  end)

  it("refuses a table that only looks like a schema", function()
    local impostor = setmetatable({}, { __metatable = "SchemaKit.Schema" })

    expectCallerError(
      "ModuleKit.Addon:ProvideValue options.implements must be a SchemaKit node or sealed schema",
      function()
        addon:ProvideValue("Database", Database.New(), { implements = impostor })
      end
    )
  end)
end)

describe("ModuleKit implements without SchemaKit", function()
  local ModuleKit, addon

  ---What a SchemaKit schema looks like from outside: an empty proxy whose
  ---metatable is protected under SchemaKit's published name.
  ---@return table
  local function schemaLike()
    return setmetatable({}, { __metatable = "SchemaKit.Schema" })
  end

  before_each(function()
    ModuleKit = TestEnv.NewPackageWithoutOptionalKits()
    addon = ModuleKit:ForAddon("MyAddon")
  end)

  after_each(TestEnv.Reset)

  it("refuses the schema form on a provider at the caller's line", function()
    expectCallerError(
      "ModuleKit.Addon:ProvideValue options.implements is a SchemaKit schema, but SchemaKit API 1 is not loaded",
      function()
        addon:ProvideValue("Database", Database.New(), { implements = schemaLike() })
      end
    )
    expectCallerError(
      "ModuleKit.Addon:ProvideSingleton options.implements is a SchemaKit schema, but SchemaKit API 1 is not loaded",
      function()
        addon:ProvideSingleton("Lazy", Database.New, { implements = schemaLike() })
      end
    )
  end)

  it("refuses the schema form on a module definition and does not create the module", function()
    expectCallerError(
      "ModuleKit module definition implements is a SchemaKit schema, but SchemaKit API 1 is not loaded",
      function()
        addon:CreateModule("Inventory", { implements = schemaLike() })
      end
    )
    assert.is_false(addon:HasModule("Inventory"))
  end)

  it("still accepts the list form", function()
    addon:ProvideValue("Database", Database.New(), DATABASE_CONTRACT)
    local module = addon:CreateModule("Inventory", {
      implements = { "OnEnable" },
      onEnable = function() end,
    })

    assert.is_table(addon:Resolve("Database"))
    assert.are.equal("Inventory", module:GetName())
  end)
end)

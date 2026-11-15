--- The Kit conformance suite: the rules every Kit keeps, tested the same way
--- for each.
---
--- Every Kit bounds its work with `SetLimits`/`GetLimits`, raises argument
--- errors at the caller's line, refuses secret values before comparing them,
--- upgrades in place over an older embedded copy, and agrees with its manifest.
--- Each package used to test these by hand, under different names and to
--- different depth; the bodies of its checks legitimately differ, so only a
--- behaviour test can hold them to one rule. A package opts in with one spec,
--- `tests/Conformance_spec.lua`:
---
---     local KitConformance = require("KitConformance")
---     local GlowKitTestEnv = require("GlowKitTestEnv")
---
---     KitConformance.Register({ describe = describe, it = it, pending = pending }, {
---       environment = GlowKitTestEnv,
---       packageId = "glowKit",
---       limits = { maxGlows = { default = 64, ceiling = 1024 } },
---       arguments = {
---         {
---           name = "Start frame",
---           call = function(kit, value)
---             kit:Start(value) -- no `return`: a tail call loses the caller's line
---           end,
---         },
---       },
---       upgrade = {
---         seed = function(kit) return kit:Start(frame) end,
---         verify = function(kit, glow) assert.is_true(glow:IsActive()) end,
---       },
---     })
---
--- Busted hands `describe`, `it` and `pending` to spec chunks only, so the spec
--- passes them in. Each field the description leaves out turns its group into
--- one pending case that names the field. docs/TESTING.md, "The conformance
--- suite", describes every field and what each group proves.
---
--- The groups:
---
---   manifest   `API` and `REVISION` equal the manifest's `api` and `revision`;
---              `Registry:Get(packageId, api)` is the facade; each part's
---              `PART_REVISION` equals its manifest entry; loading without each
---              required dependency fails naming that dependency.
---   limits     `GetLimits` returns a fresh table of exactly the described
---              names and defaults; `SetLimits` refuses every malformed update
---              at the caller's line and changes nothing when it refuses; every
---              limit name appears in the "Limits" section of `docs/API.md`.
---   receivers  every facade method called on something other than the facade
---              raises at the caller's line.
---   arguments  each listed argument refuses a secret value at the caller's
---              line (ADR 0002: only arguments the Kit compares, tests or
---              stores as a key).
---   upgrade    an older revision loaded first, then this one: the facade keeps
---              its identity and the state the older one made survives. Run
---              with the same source under `REVISION - 1`, and also with the
---              true previous revision when the test runner provides it.

local assert = require("luassert")

local KitConformance = {}

--- The environment variable `python3 -m tooling.test.run` sets to a directory
--- holding the previous revision's runtime files (`<Facade>.lua` and parts),
--- taken from the commit whose manifest declared `REVISION - 1`.
KitConformance.PREVIOUS_REVISION_VARIABLE = "MOLTENCODES_PREVIOUS_REVISION_DIR"

-- Reading the repository --------------------------------------------------------------

---Return a file's text, or `nil` when it cannot be read.
---@param path string
---@return string?
local function readFile(path)
  local file = io.open(path, "r")
  if file == nil then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

---Decode the JSON subset manifests use: objects, arrays, strings without
---escapes other than `\"` and `\\`, numbers, `true`, `false` and `null`.
---@param text string
---@return any
local function decodeJson(text)
  local position = 1

  local function fail(message)
    error("KitConformance: manifest JSON " .. message .. " at character " .. position, 0)
  end

  local function skipSpace()
    position = text:find("[^ \t\r\n]", position) or #text + 1
  end

  local readValue

  local function readString()
    local parts = {}
    position = position + 1
    while true do
      local character = text:sub(position, position)
      if character == "" then
        fail("has an unterminated string")
      elseif character == '"' then
        position = position + 1
        return table.concat(parts)
      elseif character == "\\" then
        parts[#parts + 1] = text:sub(position + 1, position + 1)
        position = position + 2
      else
        parts[#parts + 1] = character
        position = position + 1
      end
    end
  end

  local function readContainer(closing, readEntry)
    position = position + 1
    skipSpace()
    if text:sub(position, position) == closing then
      position = position + 1
      return
    end
    while true do
      readEntry()
      skipSpace()
      local character = text:sub(position, position)
      position = position + 1
      if character == closing then
        return
      elseif character ~= "," then
        fail("expected ',' or '" .. closing .. "'")
      end
      skipSpace()
    end
  end

  readValue = function()
    skipSpace()
    local character = text:sub(position, position)
    if character == "{" then
      local object = {}
      readContainer("}", function()
        if text:sub(position, position) ~= '"' then
          fail("expected a key")
        end
        local key = readString()
        skipSpace()
        if text:sub(position, position) ~= ":" then
          fail("expected ':'")
        end
        position = position + 1
        object[key] = readValue()
      end)
      return object
    elseif character == "[" then
      local array = {}
      readContainer("]", function()
        array[#array + 1] = readValue()
      end)
      return array
    elseif character == '"' then
      return readString()
    end
    for word, value in pairs({ ["true"] = true, ["false"] = false, ["null"] = false }) do
      if text:sub(position, position + #word - 1) == word then
        position = position + #word
        return value
      end
    end
    local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", position)
    if number == nil or number == "" then
      fail("has an unexpected character")
    end
    position = position + #number
    return tonumber(number)
  end

  local value = readValue()
  skipSpace()
  if position <= #text then
    fail("has text after the value")
  end
  return value
end

KitConformance.decodeJson = decodeJson

---The text of one `## <heading>` section of a Markdown document, or `nil`.
---@param text string
---@param heading string
---@return string?
local function markdownSection(text, heading)
  local start = text:find("\n## " .. heading .. "\n", 1, true)
  if start == nil then
    return nil
  end
  local body = text:sub(start + #heading + 5)
  local finish = body:find("\n## ", 1, true)
  return finish and body:sub(1, finish) or body
end

KitConformance.markdownSection = markdownSection

-- Checking where an error was raised ------------------------------------------------------

---Call `callback(...)` and assert it raises inside `callback` itself, at one of
---its own lines, with `expected` in the message.
---
---A Kit raises an argument error at the line that called its public method,
---so an error raised from `callback`'s call must name a line of `callback`,
---never a line inside the Kit. The callback should call one method.
---@param callback function
---@param label string what is called, for the failure message
---@param expected string? text the message must contain
---@param ... any arguments for `callback`
local function expectErrorAtCallSite(callback, label, expected, ...)
  local info = debug.getinfo(callback, "S")
  local ok, message = pcall(callback, ...)
  assert.is_false(ok, label .. " did not raise")
  message = tostring(message)
  local prefix = info.short_src .. ":"
  local line = message:sub(1, #prefix) == prefix and tonumber(message:match("^:(%d+):", #prefix))
    or nil
  assert.is_truthy(
    line ~= nil and line >= info.linedefined and line <= info.lastlinedefined,
    (
      "%s raised at the wrong place (want %s lines %d to %d; a tail call such as "
      .. "`return kit:Method(value)` drops that line, so call without `return`): %s"
    ):format(label, info.short_src, info.linedefined, info.lastlinedefined, message)
  )
  if expected ~= nil then
    assert.is_truthy(
      message:find(expected, 1, true),
      label .. ": expected '" .. expected .. "' in: " .. message
    )
  end
end

KitConformance.expectErrorAtCallSite = expectErrorAtCallSite

-- Reading the description -----------------------------------------------------------------

---@class KitConformance.LimitRule
---@field default number|table the value `GetLimits` answers after load (`UNBOUNDED` allowed)
---@field ceiling number the largest value `SetLimits` accepts
---@field minimum number? the smallest value it accepts (default 1)
---@field integer boolean? whether fractions are refused (default true)
---@field unbounded boolean? whether `UNBOUNDED` is accepted (default false)

---@class KitConformance.Argument
---@field name string what is passed, for the case name: "Start frame"
---@field call fun(kit: table, value: any) passes `value` to one method of the Kit, not as a tail call

---@class KitConformance.Upgrade
---@field seed fun(kit: table): any make state with the older revision; the result goes to `verify`
---@field verify fun(kit: table, seeded: any) assert the state survived the upgrade

---@class KitConformance.Options
---@field environment table a `FrameworkTestEnv` environment whose last module is the Kit
---@field packageId string the package ID, `glowKit`
---@field limits table<string, KitConformance.LimitRule>?
---@field arguments KitConformance.Argument[]?
---@field upgrade KitConformance.Upgrade?
---@field receiverExempt string[]? facade functions that take no receiver (documented as such)
---@field root string? the repository root the manifest and docs are read from (default ".")

---Validate the description and fill in what is derived from the repository.
---@param options any
---@return table
local function readOptions(options)
  if type(options) ~= "table" then
    error("KitConformance: the description must be a table", 3)
  end
  if type(options.environment) ~= "table" or type(options.environment.NewPackage) ~= "function" then
    error("KitConformance: environment must be a FrameworkTestEnv environment", 3)
  end
  if type(options.packageId) ~= "string" or not options.packageId:match("^[a-z][A-Za-z0-9]*$") then
    error("KitConformance: packageId must be a package ID such as glowKit", 3)
  end
  local root = options.root or "."
  local packageDirectory = root .. "/packages/" .. options.packageId
  local manifestText = readFile(packageDirectory .. "/package.manifest.json")
  if manifestText == nil then
    error("KitConformance: no manifest at " .. packageDirectory .. "/package.manifest.json", 3)
  end
  local modules = options.environment.Modules and options.environment.Modules() or {}
  return {
    environment = options.environment,
    packageId = options.packageId,
    manifest = decodeJson(manifestText),
    apiText = readFile(packageDirectory .. "/docs/API.md"),
    modules = modules,
    subject = modules[#modules],
    limits = options.limits,
    arguments = options.arguments,
    upgrade = options.upgrade,
    receiverExempt = options.receiverExempt or {},
  }
end

-- The groups ------------------------------------------------------------------------------

---A value the environment's `issecretvalue` reports as secret; fails with
---guidance when the environment has no secret values.
---@param environment table
---@return any
local function newSecret(environment)
  assert.are.equal(
    "function",
    type(environment.NewSecretValue),
    "the environment makes secret values (FrameworkTestEnv's NewSecretValue)"
  )
  local secret = environment.NewSecretValue()
  -- selene: allow(global_usage)
  local probe = rawget(_G, "issecretvalue")
  assert.is_true(
    type(probe) == "function" and probe(secret) == true,
    "issecretvalue must report NewSecretValue() as secret: build the environment with "
      .. 'a client profile that has secret values (wowProfile = "mainline")'
  )
  return secret
end

---The module name a dependency loads as: its facade name, `poolKit` -> `PoolKit`.
---@param packageId string
---@return string
local function facadeOf(packageId)
  return packageId:sub(1, 1):upper() .. packageId:sub(2)
end

---@param description table
---@return table[] cases `{ name, run }` or `{ name, pending }`
local function manifestCases(description)
  local manifest = description.manifest
  local cases = {
    {
      name = "API and REVISION equal the manifest's api and revision",
      run = function()
        local kit = description.environment.NewPackage()
        assert.are.equal(manifest.api, kit.API)
        assert.are.equal(manifest.revision, kit.REVISION)
      end,
    },
    {
      name = "Registry:Get(packageId, api) answers the facade",
      run = function()
        local kit = description.environment.NewPackage()
        local registry = package.loaded["Registry"]
        assert.are.equal("table", type(registry), "the module chain loads Registry")
        assert.are.equal(kit, registry:Get(description.packageId, manifest.api))
      end,
    },
  }
  if type(manifest.parts) == "table" then
    for partName, entry in pairs(manifest.parts) do
      cases[#cases + 1] = {
        name = "part " .. partName .. " carries the manifest's revision",
        run = function()
          description.environment.NewPackage()
          local moduleName = description.subject .. "-" .. partName
          local path = require("FrameworkTestEnv").findModuleFile(moduleName)
          assert.is_not_nil(path, moduleName .. " is on package.path")
          local text = readFile(path) or ""
          assert.are.equal(entry.revision, tonumber(text:match("PART_REVISION = (%d+)")))
        end,
      }
    end
  end
  local dependencies = {}
  for packageId in pairs(manifest.dependencies or {}) do
    dependencies[#dependencies + 1] = packageId
  end
  table.sort(dependencies)
  for _, packageId in ipairs(dependencies) do
    local moduleName = facadeOf(packageId)
    local inChain = false
    for _, name in ipairs(description.modules) do
      inChain = inChain or name == moduleName
    end
    if inChain then
      cases[#cases + 1] = {
        name = "refuses to load without its dependency " .. packageId,
        run = function()
          local loaded, failure = description.environment.NewPackageWithout(moduleName)
          assert.is_false(loaded, "loaded without " .. moduleName)
          assert.is_truthy(
            tostring(failure):find(moduleName, 1, true),
            "the error names " .. moduleName .. ": " .. tostring(failure)
          )
        end,
      }
    end
  end
  return cases
end

---Every way `SetLimits` must refuse an update, as `{ label, update, expected }`.
---@param name string a limit name
---@param rule KitConformance.LimitRule
---@param secret any
---@param unbounded any the Kit's `UNBOUNDED`, or nil
---@return table[]
local function refusedUpdates(name, rule, secret, unbounded)
  local minimum = rule.minimum or 1
  local refused = {
    { "a secret value", { [name] = secret }, "secret" },
    { "a value above the ceiling", { [name] = rule.ceiling + 1 }, name },
    { "a value below the minimum", { [name] = minimum - 1 }, name },
    { "a string", { [name] = tostring(rule.ceiling) }, name },
  }
  if rule.integer ~= false then
    refused[#refused + 1] = { "a fraction", { [name] = minimum + 0.5 }, name }
  end
  if unbounded ~= nil and not rule.unbounded then
    refused[#refused + 1] = { "UNBOUNDED", { [name] = unbounded }, name }
  end
  return refused
end

---@param description table
---@return table[]
local function limitCases(description)
  local limits = description.limits
  if limits == nil then
    return { { name = "limits", pending = "describe `limits` to test SetLimits and GetLimits" } }
  end
  local names = {}
  for name in pairs(limits) do
    names[#names + 1] = name
  end
  table.sort(names)

  local function newKit()
    return description.environment.NewPackage()
  end

  local cases = {
    {
      name = "GetLimits answers a fresh table of exactly the described limits and defaults",
      run = function()
        local kit = newKit()
        local first, second = kit:GetLimits(), kit:GetLimits()
        assert.are_not.equal(first, second)
        local answered = {}
        for name, value in pairs(first) do
          answered[#answered + 1] = name
          local expected = limits[name] and limits[name].default
          if expected == "UNBOUNDED" then
            expected = kit.UNBOUNDED
          end
          assert.are.equal(expected, value, "default of " .. tostring(name))
        end
        table.sort(answered)
        assert.are.same(names, answered)
      end,
    },
    {
      name = "SetLimits refuses a non-table, an unknown name and a key whose __tostring would run, at the caller's line",
      run = function()
        local kit = newKit()
        local before = kit:GetLimits()
        expectErrorAtCallSite(function(value)
          kit:SetLimits(value)
        end, "SetLimits(42)", "limits", 42)
        local unknown = { notALimit = 1 }
        expectErrorAtCallSite(function(value)
          kit:SetLimits(value)
        end, "SetLimits(unknown)", "notALimit", unknown)
        local ran = false
        local hostile = setmetatable({}, {
          __tostring = function()
            ran = true
            error("caller code ran inside the Kit")
          end,
        })
        expectErrorAtCallSite(function(value)
          kit:SetLimits(value)
        end, "SetLimits(table key)", nil, { [hostile] = 1 })
        assert.is_false(ran, "the key's __tostring ran")
        expectErrorAtCallSite(function(value)
          kit:SetLimits(value)
        end, "SetLimits(number key)", nil, { [1] = 1 })
        assert.are.same(before, kit:GetLimits())
      end,
    },
  }

  for _, name in ipairs(names) do
    local rule = limits[name]
    cases[#cases + 1] = {
      name = "SetLimits accepts " .. name .. " at its minimum and its ceiling",
      run = function()
        local kit = newKit()
        kit:SetLimits({ [name] = rule.minimum or 1 })
        assert.are.equal(rule.minimum or 1, kit:GetLimits()[name])
        kit:SetLimits({ [name] = rule.ceiling })
        assert.are.equal(rule.ceiling, kit:GetLimits()[name])
        if rule.unbounded then
          kit:SetLimits({ [name] = kit.UNBOUNDED })
          assert.are.equal(kit.UNBOUNDED, kit:GetLimits()[name])
        end
      end,
    }
    cases[#cases + 1] = {
      name = "SetLimits refuses every malformed "
        .. name
        .. " at the caller's line and changes nothing",
      run = function()
        local kit = newKit()
        local before = kit:GetLimits()
        local secret = newSecret(description.environment)
        for _, refused in ipairs(refusedUpdates(name, rule, secret, kit.UNBOUNDED)) do
          -- A good entry beside the bad one proves the refusal writes nothing.
          local update = refused[2]
          for _, other in ipairs(names) do
            if other ~= name then
              update[other] = limits[other].ceiling
            end
          end
          expectErrorAtCallSite(function(value)
            kit:SetLimits(value)
          end, "SetLimits(" .. name .. " = " .. refused[1] .. ")", refused[3], update)
        end
        assert.are.same(before, kit:GetLimits())
      end,
    }
  end

  cases[#cases + 1] = {
    name = "every limit is named in the Limits section of docs/API.md",
    run = function()
      local section = description.apiText and markdownSection(description.apiText, "Limits")
      assert.is_not_nil(section, "docs/API.md has a ## Limits section")
      for _, name in ipairs(names) do
        assert.is_truthy(section:find("`" .. name .. "`", 1, true), name .. " is in ## Limits")
      end
    end,
  }
  return cases
end

---@param description table
---@return table[]
local function receiverCases(description)
  return {
    {
      name = "every facade method called on another receiver raises at the caller's line",
      run = function()
        local kit = description.environment.NewPackage()
        local exempt = {}
        for _, name in ipairs(description.receiverExempt) do
          exempt[name] = true
        end
        local methods = {}
        for name, value in pairs(kit) do
          if type(value) == "function" and name:match("^%u") and not exempt[name] then
            methods[#methods + 1] = name
          end
        end
        table.sort(methods)
        assert.is_true(#methods > 0, "the facade has methods")
        for _, name in ipairs(methods) do
          local method = kit[name]
          expectErrorAtCallSite(function(value)
            method(value)
          end, name .. " on a table", nil, {})
          expectErrorAtCallSite(function(value)
            method(value)
          end, name .. " on a string", nil, "x")
        end
      end,
    },
  }
end

---@param description table
---@return table[]
local function argumentCases(description)
  if description.arguments == nil then
    return {
      {
        name = "arguments",
        pending = "describe `arguments` to test secret values at the caller's line",
      },
    }
  end
  local cases = {}
  for _, argument in ipairs(description.arguments) do
    cases[#cases + 1] = {
      name = argument.name .. " refuses a secret value at the caller's line",
      run = function()
        local kit = description.environment.NewPackage()
        local secret = newSecret(description.environment)
        expectErrorAtCallSite(argument.call, argument.name, "secret", kit, secret)
      end,
    }
  end
  return cases
end

---Load the older copy `loadOlder` returns over the dependencies, seed it, load
---the current revision, and verify.
---@param description table
---@param loadOlder fun(): table
local function runUpgrade(description, loadOlder)
  local environment = description.environment
  environment.NewPackageWithout(description.subject)
  local older = loadOlder()
  assert.are.equal("table", type(older), "the older revision returned its facade")
  local seeded = description.upgrade.seed(older)
  package.loaded[description.subject] = nil
  local current = require(description.subject)
  assert.are.equal(older, current, "the facade kept its identity")
  assert.are.equal(description.manifest.revision, current.REVISION)
  description.upgrade.verify(current, seeded)
end

---@param description table
---@return table[]
local function upgradeCases(description)
  if description.upgrade == nil then
    return {
      {
        name = "upgrade",
        pending = "describe `upgrade` (seed, verify) to test the in-place upgrade",
      },
    }
  end
  local revision = description.manifest.revision
  local cases = {
    {
      name = "an older revision's state survives the upgrade (same source as revision "
        .. (revision - 1)
        .. ")",
      run = function()
        runUpgrade(description, function()
          return description.environment.LoadSourceWithRevision(description.subject, revision - 1)
        end)
      end,
    },
  }
  local directory = os.getenv(KitConformance.PREVIOUS_REVISION_VARIABLE)
  local previousFile = directory and (directory .. "/" .. description.subject .. ".lua")
  if previousFile ~= nil and readFile(previousFile) ~= nil then
    cases[#cases + 1] = {
      name = "the committed revision " .. (revision - 1) .. "'s state survives the upgrade",
      run = function()
        runUpgrade(description, function()
          local chunk = assert(loadfile(previousFile))
          return chunk()
        end)
      end,
    }
  else
    cases[#cases + 1] = {
      name = "the committed previous revision",
      pending = "no previous revision was provided: run through python3 -m tooling.test.run in a "
        .. "checkout with history, where the manifest once declared revision "
        .. (revision - 1),
    }
  end
  return cases
end

-- Public --------------------------------------------------------------------------------

---Return every conformance case for a description, as `{ group, name, run }`
---or `{ group, name, pending }`. `Register` is the usual way to use them.
---@param options KitConformance.Options
---@return table[]
function KitConformance.Cases(options)
  local description = readOptions(options)
  local groups = {
    { "manifest", manifestCases(description) },
    { "limits", limitCases(description) },
    { "receivers", receiverCases(description) },
    { "arguments", argumentCases(description) },
    { "upgrade", upgradeCases(description) },
  }
  local cases = {}
  for _, group in ipairs(groups) do
    for _, case in ipairs(group[2]) do
      case.group = group[1]
      cases[#cases + 1] = case
    end
  end
  return cases
end

---Register the conformance suite of one Kit with Busted.
---@param busted { describe: function, it: function, pending: function }
---@param options KitConformance.Options
function KitConformance.Register(busted, options)
  if
    type(busted) ~= "table"
    or type(busted.describe) ~= "function"
    or type(busted.it) ~= "function"
  then
    error("KitConformance.Register needs { describe = describe, it = it, pending = pending }", 2)
  end
  local cases = KitConformance.Cases(options)
  local environment = options.environment
  local facade = options.packageId:sub(1, 1):upper() .. options.packageId:sub(2)
  busted.describe(facade .. " conformance", function()
    for _, case in ipairs(cases) do
      local title = case.group .. ": " .. case.name
      if case.pending ~= nil then
        busted.pending(title .. " (" .. case.pending .. ")")
      else
        busted.it(title, function()
          local ok, failure = pcall(case.run)
          if type(environment.Reset) == "function" then
            environment.Reset()
          end
          if not ok then
            error(failure, 0)
          end
        end)
      end
    end
  end)
end

return KitConformance

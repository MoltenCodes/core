-- MoltenCodes Test: BridgeKitSuite.lua
--
-- Real-client suites for the `bridgeKit` package (docs/BRIDGE_KIT_DESIGN.md,
-- section 13.2). The Busted specs under packages/bridgeKit/tests/ prove
-- BridgeKit against recorded Ace3 output and a CommKit stand-in; these prove,
-- inside the game client with the installed MoltenCodes addon:
--
--   * the installed facade and its committed revision;
--   * AceSerializer text written and read by the client's own Lua (its
--     `tostring`, `string.format` and `frexp`): every byte in a string and
--     numbers at the edges of the double range round-trip;
--   * the AceComm channel through the real CommKit: texts at every framing
--     boundary whispered to the player's own character come back whole and
--     byte-identical, and a text holding every byte 01-FF records what the
--     client carries;
--   * with real Ace3 loaded (the benchmark's `MoltenCodesBench_Ace3` side
--     addon, when installed): AceSerializer-3.0 writes the same bytes as
--     BridgeKit and each reads the other's text, and AceComm-3.0 and a
--     BridgeKit channel understand each other in both directions;
--   * an AceConfig table converted, defined in OptionsKit, rendered by
--     WidgetKit, and a write through the tree reaching the Ace handler with
--     the Ace `info` shape;
--   * secret values refused at this file's line.
--
-- The AceDB import across `/reload` (design 13.2, item 3) is not run here: it
-- needs an AceDB saved variable written by a first session, and is covered on
-- the host by the round trip through SettingsKit in AceDB_spec.lua. It is
-- registered as skipped with that reason, so the gap shows in the matrix.
--
-- What leaves the client. Every message a run sends is a WHISPER addon message
-- to the player's own character; nothing is sent to any other player or
-- channel. A run sends at most 19 addon messages in all, over a few seconds.
-- When the client gives no plain player name, the round-trip tests are
-- skipped with the reason.
--
-- Run with `/mct run bridgeKit`; tests/client/MoltenCodesTest_BridgeKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind: the three test prefixes registered with the client
-- (a prefix cannot be unregistered; later runs reuse them), BridgeKit's
-- counters, and, when the Ace3 side addon was loaded, Ace3's libraries in the
-- session until `/reload`. Every CommKit scope, channel, widget and OptionsKit
-- definition a test creates is released by the After hook of its suite.
-- Nothing is written to a saved variable.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
  error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local PACKAGE_ID = "bridgeKit"

--- The test prefixes: the channel's own round trips, BridgeKit to AceComm,
--- and AceComm to BridgeKit. Each is at most 16 bytes.
local PREFIX = { own = "MCTBridgeComm", toAce = "MCTBridgeToAce", fromAce = "MCTBridgeFromAce" }

--- The benchmark's load-on-demand addon that carries the pinned Ace3 files
--- (python3 -m tooling.bench.client_install).
local ACE3_ADDON = "MoltenCodesBench_Ace3"

--- How long a test waits for whispers to come back.
local DELIVERY_TIMEOUT_SECONDS = 10
local ROUND_TRIP_SUITE_TIMEOUT_SECONDS = 40

--- Every method docs/API.md of bridgeKit lists on the facade.
local FACADE_METHODS = {
  "AceSerialize",
  "AceDeserialize",
  "ConvertAceConfig",
  "DefineAceConfig",
  "FormatReport",
  "PreviewAceDB",
  "ImportAceDB",
  "AceDBMigration",
  "OpenAceComm",
  "GetStatistics",
  "SetLimits",
  "GetLimits",
}

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- Client functions and Ace3's LibStub are reachable only through the
  -- global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- The Kits below are not in the language-server workspace of tests/client,
-- so their facades are typed `any` here.
---@type any
local BridgeKit = Registry:Get(PACKAGE_ID, 1)
if type(BridgeKit) == "nil" then
  error(addonName .. " requires BridgeKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
---@type any
local CommKit = Registry:Find("commKit", 1)
---@type any
local OptionsKit = Registry:Find("optionsKit", 1)
---@type any
local WidgetKit = Registry:Find("widgetKit", 1)

local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")

---Whether `value` is a secret. `false` on a client without `issecretvalue`.
---@param value any
---@return boolean
local function isSecret(value)
  return type(isSecretValue) == "function" and isSecretValue(value) == true
end

-- Helpers ---------------------------------------------------------------------

local pendingReleases = {}

---Release everything the test created, last first; raise the first problem.
local function cleanUp()
  local firstProblem = nil
  for index = #pendingReleases, 1, -1 do
    local action = pendingReleases[index]
    pendingReleases[index] = nil
    local succeeded, problem = pcall(action)
    if not succeeded and type(firstProblem) == "nil" then
      firstProblem = problem
    end
  end
  if type(firstProblem) ~= "nil" then
    error(firstProblem, 0)
  end
end

---Run `action` in the After hook of the current test.
---@param action fun()
local function atCleanUp(action)
  pendingReleases[#pendingReleases + 1] = action
end

---Register a suite of this package whose tests all end released.
---@param part string
---@param options MoltenCodesTest.SuiteOptions|nil
---@return TestKit.Suite
local function newSuite(part, options)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName, options)
  suite:After(cleanUp)
  return suite
end

---`ctx:WaitUntil` through an untyped alias (see CommKitSuite.lua, `waitUntil`).
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return boolean satisfied
local function waitUntil(ctx, predicate, timeoutSeconds)
  ---@type any
  local context = ctx
  return context:WaitUntil(predicate, timeoutSeconds) == true
end

---The player's own `Name-Realm`, or a skipped test naming why.
---@param ctx TestKit.Context
---@return string fullName
local function requirePlayerName(ctx)
  local unitName = readHost("UnitName")
  local realmName = readHost("GetNormalizedRealmName")
  local name = type(unitName) == "function" and unitName("player") or nil
  local realm = type(realmName) == "function" and realmName() or nil
  if
    type(name) ~= "string"
    or isSecret(name)
    or name == ""
    or type(realm) ~= "string"
    or isSecret(realm)
    or realm == ""
  then
    Harness:SkipTest(
      ctx,
      "the client gave no plain player name, so there was nobody safe to whisper"
    )
  end
  return name .. "-" .. realm
end

---The first byte position where two strings differ, or `nil` when equal.
---@param expected string
---@param actual string
---@return integer|nil
local function firstDifference(expected, actual)
  for index = 1, math.max(#expected, #actual) do
    if expected:byte(index) ~= actual:byte(index) then
      return index
    end
  end
  return nil
end

---Whether two values are equal, tables compared by content.
---@param left any
---@param right any
---@return boolean
local function deepEqual(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not deepEqual(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

---Every byte from `first` to `last`, in order.
---@param first integer
---@param last integer
---@return string
local function byteRange(first, last)
  local bytes = {}
  for byte = first, last do
    bytes[#bytes + 1] = string.char(byte)
  end
  return table.concat(bytes)
end

---Ace3's libraries, loading the benchmark's side addon once; `nil` and why
---when it is not installed or does not load.
---@return table|nil LibStub
---@return string|nil reason
local function loadAce3()
  local LibStub = readHost("LibStub")
  if type(LibStub) == "table" and LibStub("AceComm-3.0", true) ~= nil then
    return LibStub, nil
  end
  local addOns = readHost("C_AddOns")
  local load = type(addOns) == "table" and addOns.LoadAddOn or nil
  if type(load) ~= "function" then
    return nil, "the client has no C_AddOns.LoadAddOn"
  end
  local loaded, reason = load(ACE3_ADDON)
  LibStub = readHost("LibStub")
  if not loaded or type(LibStub) ~= "table" then
    return nil,
      ACE3_ADDON
        .. " is not installed ("
        .. tostring(reason)
        .. "); install it with python3 -m tooling.bench.client_install to compare with real Ace3"
  end
  return LibStub, nil
end

---Ace3's LibStub, or a skipped test naming why.
---@param ctx TestKit.Context
---@return table LibStub
local function requireAce3(ctx)
  local LibStub, reason = loadAce3()
  if LibStub == nil then
    Harness:SkipTest(ctx, reason or "Ace3 did not load")
  end
  ---@cast LibStub table
  return LibStub
end

---Open a BridgeKit channel on `prefix` in a fresh CommKit scope that collects
---every message; both are closed by the After hook.
---@param ctx TestKit.Context
---@param prefix string
---@return any channel
---@return table[] received
local function openCollectingChannel(ctx, prefix)
  local scope = CommKit:CreateScope()
  atCleanUp(function()
    scope:Close()
  end)
  local received = {}
  local channel, reason = BridgeKit:OpenAceComm(
    scope,
    prefix,
    function(_, message, distribution, sender)
      received[#received + 1] = { message = message, distribution = distribution, sender = sender }
    end
  )
  if channel == nil then
    ctx:Fail("OpenAceComm(" .. prefix .. ") was refused: " .. tostring(reason))
  end
  return channel, received
end

---Wait until `received` holds `count` messages, or fail the test.
---@param ctx TestKit.Context
---@param received table[]
---@param count integer
local function awaitMessages(ctx, received, count)
  local arrived = waitUntil(ctx, function()
    return #received >= count
  end, DELIVERY_TIMEOUT_SECONDS)
  if not arrived then
    ctx:Fail(
      ("only %d of %d messages came back within %d seconds"):format(
        #received,
        count,
        DELIVERY_TIMEOUT_SECONDS
      )
    )
  end
end

---Expect `actual` to equal `expected` byte for byte, logging where it differs.
---@param ctx TestKit.Context
---@param label string
---@param expected string
---@param actual any
local function expectSameBytes(ctx, label, expected, actual)
  if type(actual) ~= "string" then
    ctx:Fail(label .. ": received " .. type(actual) .. ", not a string")
    return
  end
  local difference = firstDifference(expected, actual)
  if difference ~= nil then
    ctx:Log(
      ("%s: %d bytes sent, %d received, first difference at byte %d (sent %s, received %s)"):format(
        label,
        #expected,
        #actual,
        difference,
        tostring(expected:byte(difference)),
        tostring(actual:byte(difference))
      )
    )
  end
  ctx:Expect(difference):ToBeNil()
end

-- bridgeKit.facade -----------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('bridgeKit', 1) is the BridgeKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(BridgeKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(BridgeKit[method])):ToBe("function")
    end
    ctx:Expect(BridgeKit.ACE_WIRE_VERSION):ToBe(1)
    ctx:Log("ACE_BASELINE.commit " .. tostring(BridgeKit.ACE_BASELINE.commit))
  end
)

facade:Test("the installed BridgeKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(BridgeKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list bridgeKit")
end)

-- bridgeKit.serializer -------------------------------------------------------

local serializer = newSuite("serializer")

serializer:Test(
  "AceSerialize and AceDeserialize round-trip every byte 00-FF in a string, the edges of the double range and a nested table on the client's Lua",
  function(ctx)
    local tiny = 2 ^ -1074
    local values = {
      byteRange(0, 255),
      0,
      -0.5,
      2 ^ 53 + 2,
      1 / 3,
      tiny,
      1.7976931348623157e308,
      math.huge,
      -math.huge,
      { list = { 1, "two", false }, [1.5] = { nested = true } },
    }
    for index, value in ipairs(values) do
      local written, text = BridgeKit:AceSerialize(value)
      ctx:Expect(written):ToBe(true)
      local ok, decoded = BridgeKit:AceDeserialize(text)
      ctx:Expect(ok):ToBe(true)
      if not deepEqual(decoded, value) then
        ctx:Fail("value " .. index .. " did not read back equal: " .. tostring(text):sub(1, 80))
      end
    end
  end
)

serializer:Test(
  "with Ace3 loaded, AceSerializer-3.0 writes the same bytes as BridgeKit for scalars and one-entry tables, and each reads the other's text to equal values",
  function(ctx)
    local LibStub = requireAce3(ctx)
    local AceSerializer = LibStub("AceSerializer-3.0")
    ctx:Log("AceSerializer-3.0 minor " .. tostring(select(2, LibStub("AceSerializer-3.0"))))
    local scalars =
      { "plain", "a^b~c\n" .. byteRange(1, 31), 42, -7.25, 1 / 3, 2 ^ -1074, true, false }
    for index, value in ipairs(scalars) do
      local _, ours = BridgeKit:AceSerialize("kind", value, { one = value })
      local theirs = AceSerializer:Serialize("kind", value, { one = value })
      ctx:Expect(ours == theirs):ToBe(true)
      if ours ~= theirs then
        ctx:Log("value " .. index .. " differs at byte " .. tostring(firstDifference(theirs, ours)))
      end
    end
    local payload = { name = "Tester", list = { 1, 2, 3 }, ready = true, ratio = 0.125 }
    local _, ours = BridgeKit:AceSerialize("export", payload)
    local aceOk, aceKind, acePayload = AceSerializer:Deserialize(ours)
    ctx:Expect(aceOk):ToBe(true)
    ctx:Expect(aceKind):ToBe("export")
    ctx:Expect(deepEqual(acePayload, payload)):ToBe(true)
    local ok, kind, decoded = BridgeKit:AceDeserialize(AceSerializer:Serialize("export", payload))
    ctx:Expect(ok):ToBe(true)
    ctx:Expect(kind):ToBe("export")
    ctx:Expect(deepEqual(decoded, payload)):ToBe(true)
  end
)

-- bridgeKit.aceComm ----------------------------------------------------------

local aceComm = newSuite("aceComm", { timeoutSeconds = ROUND_TRIP_SUITE_TIMEOUT_SECONDS })

--- Texts at every framing boundary (design 8.3): one message, the escape byte
--- while it fits, and 254-byte parts with a short and a full last part.
local BOUNDARY_TEXTS = {
  { label = "10 bytes, one message", text = "hello Ace3" },
  {
    label = "254 bytes starting with 01, escaped in one message",
    text = "\1" .. string.rep("e", 253),
  },
  { label = "255 bytes starting with 01, two parts", text = "\1" .. string.rep("f", 254) },
  { label = "256 bytes, two parts", text = string.rep("g", 256) },
  { label = "509 bytes, three parts with a one-byte last part", text = string.rep("h", 509) },
}

aceComm:Test(
  "a channel whispers texts at every framing boundary to the player's own character through CommKit and reassembles each whole and byte-identical",
  function(ctx)
    local target = requirePlayerName(ctx)
    local channel, received = openCollectingChannel(ctx, PREFIX.own)
    for _, case in ipairs(BOUNDARY_TEXTS) do
      local handle, reason =
        channel:Send({ text = case.text, distribution = "WHISPER", target = target })
      if handle == nil then
        ctx:Fail(case.label .. ": Send answered nil, " .. tostring(reason))
      end
    end
    awaitMessages(ctx, received, #BOUNDARY_TEXTS)
    for index, case in ipairs(BOUNDARY_TEXTS) do
      expectSameBytes(ctx, case.label, case.text, received[index] and received[index].message)
    end
    local statistics = BridgeKit:GetStatistics()
    ctx:Log(
      ("parts sent %d, streams completed %d, open streams %d"):format(
        statistics.acePartsSent,
        statistics.aceStreamsCompleted,
        statistics.openStreams
      )
    )
    ctx:Expect(statistics.openStreams):ToBe(0)
  end
)

aceComm:Test(
  "a text holding every byte 01-FF (| LF CR and 80-FF included) is sent without a refusal and reassembled at most once; what the client carries back is logged, not judged",
  function(ctx)
    local target = requirePlayerName(ctx)
    local channel, received = openCollectingChannel(ctx, PREFIX.own)
    local text = byteRange(1, 255)
    local handle, reason = channel:Send({ text = text, distribution = "WHISPER", target = target })
    ctx:Log("Send answered " .. (handle ~= nil and "a handle" or ("nil, " .. tostring(reason))))
    ctx:Expect(handle).Not:ToBeNil()
    local arrived = waitUntil(ctx, function()
      return #received >= 1
    end, DELIVERY_TIMEOUT_SECONDS)
    if not arrived then
      ctx:Log("nothing came back: the client did not carry the text")
    elseif received[1].message == text then
      ctx:Log("carried unchanged: every byte 01-FF")
    else
      local message = received[1].message
      ctx:Log(
        ("carried changed: %d bytes back of %d, first difference at byte %s"):format(
          #message,
          #text,
          tostring(firstDifference(text, message))
        )
      )
    end
    ctx:Expect(#received <= 1):ToBe(true)
  end
)

aceComm:Test(
  "with Ace3 loaded, AceComm-3.0 receives what a BridgeKit channel sends, and a BridgeKit channel receives what AceComm-3.0 sends, multipart and escaped",
  function(ctx)
    local target = requirePlayerName(ctx)
    local LibStub = requireAce3(ctx)
    local AceComm = LibStub("AceComm-3.0")
    ctx:Log("AceComm-3.0 minor " .. tostring(select(2, LibStub("AceComm-3.0"))))
    -- `|` is left out: whether the client carries it is the previous test's
    -- measurement, not the two libraries' agreement.
    local texts = {
      "\2escaped by both",
      string.rep("a", 300) .. byteRange(32, 123) .. byteRange(125, 126) .. string.rep("z", 200),
    }

    local aceSide = {}
    AceComm:Embed(aceSide)
    local aceReceived = {}
    aceSide:RegisterComm(PREFIX.toAce, function(_, message)
      aceReceived[#aceReceived + 1] = message
    end)
    atCleanUp(function()
      aceSide:UnregisterAllComm()
    end)
    local toAce = openCollectingChannel(ctx, PREFIX.toAce)
    local _, fromAce = openCollectingChannel(ctx, PREFIX.fromAce)
    for _, text in ipairs(texts) do
      toAce:Send({ text = text, distribution = "WHISPER", target = target })
      aceSide:SendCommMessage(PREFIX.fromAce, text, "WHISPER", target)
    end
    awaitMessages(ctx, aceReceived, #texts)
    awaitMessages(ctx, fromAce, #texts)
    for index, text in ipairs(texts) do
      expectSameBytes(ctx, "BridgeKit to AceComm " .. index, text, aceReceived[index])
      expectSameBytes(
        ctx,
        "AceComm to BridgeKit " .. index,
        text,
        fromAce[index] and fromAce[index].message
      )
    end
  end
)

-- bridgeKit.aceDB ------------------------------------------------------------

local aceDB = newSuite("aceDB")

aceDB:Skip(
  "an AceDB saved variable written by a first session imports after /reload in both modes, with its backup in WTF and every field read as before",
  "not run: it needs an AceDB saved variable from an earlier session; packages/bridgeKit/tests/AceDB_spec.lua covers the import through SettingsKit itself on the host"
)

---Whether a BridgeKit report holds an entry for `path` with `reason`.
---@param report table
---@param path string
---@param reason string
---@return boolean
local function reportHolds(report, path, reason)
  for _, entry in ipairs(report.entries) do
    if entry.path == path and entry.reason == reason then
      return true
    end
  end
  return false
end

aceDB:Test(
  "the AceDB preview names the current character under the key UnitNameUnmodified gives, the key AceDB saved and SettingsKit opens",
  function(ctx)
    local SchemaKit = Registry:Find("schemaKit", 1)
    if type(SchemaKit) == "nil" then
      Harness:SkipTest(ctx, "SchemaKit is not loaded, so no schema could declare the char scope")
      return
    end
    local unmodified, unitName = readHost("UnitNameUnmodified"), readHost("UnitName")
    local realmName = readHost("GetRealmName")
    local name = type(unmodified) == "function" and unmodified("player") or nil
    if type(name) ~= "string" or isSecret(name) or name == "" then
      name = type(unitName) == "function" and unitName("player") or nil
    end
    local realm = type(realmName) == "function" and realmName() or nil
    if
      type(name) ~= "string"
      or isSecret(name)
      or name == ""
      or type(realm) ~= "string"
      or isSecret(realm)
    then
      Harness:SkipTest(ctx, "the client gave no plain player name or realm")
      return
    end
    local key = name .. " - " .. realm
    local path = 'char["' .. key .. '"]'
    ctx:Log("current character key: " .. key)
    local schema = { char = SchemaKit.table({ fields = {}, open = true }) }

    local missing = BridgeKit:PreviewAceDB(
      { char = { ["Nobody - Nowhere"] = { seen = true } } },
      { schema = schema, aceDefaults = {} }
    )
    ctx:Expect(reportHolds(missing, path, "currentCharacterMissing")):ToBe(true)

    local present = BridgeKit:PreviewAceDB(
      { char = { [key] = { seen = true } } },
      { schema = schema, aceDefaults = {} }
    )
    ctx:Expect(reportHolds(present, path, "currentCharacterMissing")):ToBe(false)
    ctx:Expect(reportHolds(present, path, "characterKeyMismatch")):ToBe(false)
  end
)

-- bridgeKit.aceConfig --------------------------------------------------------

local aceConfig = newSuite("aceConfig")

aceConfig:Test(
  "an AceConfig table converted by DefineAceConfig is rendered by WidgetKit, and a write through the tree reaches the Ace handler with the Ace info shape",
  function(ctx)
    if OptionsKit == nil or WidgetKit == nil then
      Harness:SkipTest(ctx, "the MoltenCodes addon carries no OptionsKit or WidgetKit API 1")
    end
    local appName = "MoltenCodesTest_BridgeKitOptions"
    local store = { scale = 1 }
    local seen = {}
    local handler = {
      Get = function(_, info)
        return store[info[#info]]
      end,
      Set = function(_, info, value)
        seen.appName, seen.option, seen.last = info.appName, info.option, info[#info]
        store[info[#info]] = value
      end,
    }
    local tree = BridgeKit:DefineAceConfig(appName, {
      type = "group",
      handler = handler,
      get = "Get",
      set = "Set",
      args = { scale = { type = "range", name = "Scale", min = 0.5, max = 2, step = 0.1 } },
    })
    atCleanUp(function()
      OptionsKit:Undefine(appName)
    end)
    local container = WidgetKit:Create("Group")
    atCleanUp(function()
      WidgetKit:Release(container)
    end)
    local rendering = WidgetKit:RenderOptions(tree, container)
    ctx:Expect(rendering:IsReleased()):ToBe(false)
    ctx:Expect(tree:Set("scale", 1.5)):ToBe(true)
    ctx:Expect(store.scale):ToBe(1.5)
    ctx:Expect(seen.appName):ToBe(appName)
    ctx:Expect(seen.last):ToBe("scale")
    ctx:Expect(type(seen.option)):ToBe("table")
  end
)

-- bridgeKit.secrets ----------------------------------------------------------

local secrets = newSuite("secrets")

local SECRET_TEST =
  "AceSerialize refuses a secret value and OpenAceComm a secret prefix, each at this file's line"

if type(isSecretValue) ~= "function" or type(secretWrap) ~= "function" then
  secrets:Skip(
    SECRET_TEST,
    "the client has no issecretvalue and secretwrap; the secret path was not exercised"
  )
elseif not Harness:CanMakeSecrets() then
  secrets:Skip(SECRET_TEST, Harness.NO_SECRETS_REASON)
else
  secrets:Test(SECRET_TEST, function(ctx)
    local secret = secretWrap("hidden")
    local scope = CommKit:CreateScope()
    atCleanUp(function()
      scope:Close()
    end)
    local cases = {
      {
        call = function()
          return BridgeKit:AceSerialize("kind", secret)
        end,
        expected = "BridgeKit:AceSerialize",
      },
      {
        call = function()
          return BridgeKit:OpenAceComm(scope, secret, function() end)
        end,
        expected = "BridgeKit:OpenAceComm prefix must be",
      },
    }
    for _, case in ipairs(cases) do
      local succeeded, message = pcall(case.call)
      ctx:Expect(succeeded):ToBe(false)
      ctx:Log("client message: " .. tostring(message))
      ctx
        :Expect(type(message) == "string" and message:find("BridgeKitSuite.lua:", 1, true) ~= nil)
        :ToBe(true)
      ctx
        :Expect(type(message) == "string" and message:find(case.expected, 1, true) ~= nil)
        :ToBe(true)
    end
  end)
end

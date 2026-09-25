-- MoltenCodes Test: MediaKitSuite.lua
--
-- Real-client suites for the `mediaKit` package. The Busted specs under
-- packages/mediaKit/tests/ prove MediaKit on a stock Lua 5.1 with a scripted
-- `GetLocale`, a stand-in LibStub and LibSharedMedia and a stand-in secret;
-- these prove, inside the game client with the installed MoltenCodes addon,
-- what that fixture can only simulate:
--
--   * the installed facade and its committed revision, and the host facilities
--     MediaKit reads: `GetLocale` (the one it filters fonts by), `issecretvalue`
--     and `LibStub` with LibSharedMedia-3.0 (logged);
--   * that the built-in media are real client files: every built-in font loads
--     into a hidden FontString (`SetFont(path, 12)` answers true, while a
--     missing file raises), every texture-backed built-in loads into a hidden
--     Texture (`SetTexture` answers true and `GetTextureFileID` equals
--     `GetFileIDFromPath`), and every texture path resolves through
--     `GetFileIDFromPath`. Font and sound paths are only logged there: on
--     Retail 12.1.0 b69933 the client's `GetFileIDFromPath` answered nil for
--     `Fonts\ARIALN.TTF` and for three shipped interface sounds, while it
--     resolved every texture path. No sound is ever played;
--   * the font script filter against the client's own `GetLocale()`;
--   * sorted, cached lists, registration results and `OnRegistered`;
--   * per-consumer defaults and their built-in fallbacks on this client;
--   * the LibSharedMedia "absent" path, a read-only comparison with a real
--     LibSharedMedia-3.0 when one is loaded, and adoption and mirroring
--     against a stand-in LibSharedMedia installed only while one test body
--     runs, and only when no real one exists;
--   * the allocation-free lookups docs/API.md promises, on the client's
--     collector;
--   * argument errors, and secret values made by the client's `secretwrap`
--     refused at the calling line in this file as the client names it.
--
-- Nothing here needs combat, a group or an instance. Nothing is visible and
-- nothing plays: the probe Frame is hidden, at alpha 0, with no size and no
-- anchor, and no sound function is ever called. No client setting changes.
--
-- Run with `/mct run mediaKit`; tests/client/MoltenCodesTest_MediaKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. MediaKit never removes an entry, so every entry a
-- test registers stays in MediaKit for the rest of the session, under a name
-- that starts with "MoltenCodesTest " and ends with a sequence number, so a
-- second run in the same session registers new names instead of meeting its
-- own; each one names a file the client ships (`Interface\Buttons\WHITE8X8`,
-- `Interface\TargetingFrame\UI-StatusBar`, `Fonts\FRIZQT__.TTF`). An addon
-- listing MediaKit media in this session shows them. Entries adopted from the
-- stand-in LibSharedMedia stay the same way. The two defaults objects `MoltenCodesTest_MediaKit A` and
-- `MoltenCodesTest_MediaKit B` stay (MediaKit keeps a consumer for the
-- session); the After hook of every suite clears their choices. The After hook
-- also disconnects every `OnRegistered` connection a test made. The stand-in
-- LibStub global and MediaKit's LibSharedMedia bridge pointers are put back
-- before the test body returns, pass or fail, so no other code sees them. The
-- one probe Frame with its Texture and FontString stays hidden for the session
-- (the client never frees a Frame). MediaKit's shared limits are never changed:
-- every `SetLimits` call here is a refusal the tests check. Nothing is written
-- to a saved variable.

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

local REGISTRY_API = 2
local MEDIA_KIT_API = 1
local PACKAGE_ID = "mediaKit"

--- The file name the client puts in front of every error raised at a line of
--- this file.
local THIS_FILE = "MediaKitSuite.lua"

--- The two consumers whose defaults objects the tests use. MediaKit keeps a
--- consumer for the session, so the names are fixed rather than per run; the
--- After hook clears their choices.
local CONSUMER_A = "MoltenCodesTest_MediaKit A"
local CONSUMER_B = "MoltenCodesTest_MediaKit B"

--- Every media type, sorted, as docs/API.md ("Media types") lists them.
local MEDIA_TYPES = { "background", "border", "font", "icon", "sound", "statusbar", "texture" }

--- The five types LibSharedMedia shares with MediaKit.
local LIBSHAREDMEDIA_TYPES = { "background", "border", "font", "sound", "statusbar" }
local LIBSHAREDMEDIA_MAJOR = "LibSharedMedia-3.0"
local LIBSHAREDMEDIA_EVENT = "LibSharedMedia_Registered"

--- The script each client locale writes (docs/API.md, "Scripts"). A locale not
--- listed writes Latin.
local LOCALE_SCRIPTS = {
  enUS = "latin",
  enGB = "latin",
  deDE = "latin",
  frFR = "latin",
  esES = "latin",
  esMX = "latin",
  itIT = "latin",
  ptBR = "latin",
  ptPT = "latin",
  ruRU = "cyrillic",
  zhCN = "cjkSimplified",
  zhTW = "cjkTraditional",
  koKR = "korean",
}

--- LibSharedMedia's locale bit of each client locale; every Western locale
--- shares one bit. The stand-in refuses a font whose mask lacks the client's.
local LIBSHAREDMEDIA_LOCALE_BITS = { koKR = 1, ruRU = 2, zhCN = 4, zhTW = 8 }
local LIBSHAREDMEDIA_WESTERN_BIT = 128
local LIBSHAREDMEDIA_CYRILLIC_BIT = 2

--- The texture-backed built-ins of docs/API.md ("Built-in media"), with the
--- data MediaKit registers for them. `placeholder` marks the two names
--- LibSharedMedia uses for "no media", which are logged rather than loaded.
local BUILTIN_MEDIA = {
  {
    mediaType = "background",
    name = "Blizzard Dialog Background",
    data = [[Interface\DialogFrame\UI-DialogBox-Background]],
  },
  {
    mediaType = "background",
    name = "Blizzard Tooltip",
    data = [[Interface\Tooltips\UI-Tooltip-Background]],
  },
  { mediaType = "background", name = "Solid", data = [[Interface\Buttons\WHITE8X8]] },
  {
    mediaType = "border",
    name = "Blizzard Dialog",
    data = [[Interface\DialogFrame\UI-DialogBox-Border]],
  },
  {
    mediaType = "border",
    name = "Blizzard Tooltip",
    data = [[Interface\Tooltips\UI-Tooltip-Border]],
  },
  { mediaType = "border", name = "None", data = [[Interface\None]], placeholder = true },
  { mediaType = "icon", name = "Question Mark", data = [[Interface\Icons\INV_Misc_QuestionMark]] },
  { mediaType = "sound", name = "None", data = [[Interface\Quiet.ogg]], placeholder = true },
  {
    mediaType = "statusbar",
    name = "Blizzard",
    data = [[Interface\TargetingFrame\UI-StatusBar]],
  },
  { mediaType = "statusbar", name = "Solid", data = [[Interface\Buttons\WHITE8X8]] },
  { mediaType = "texture", name = "Solid", data = [[Interface\Buttons\WHITE8X8]] },
}

--- The built-in fonts: the Western file every client but ruRU gets, and the
--- Cyrillic file a ruRU client gets.
local BUILTIN_FONTS = {
  { name = "Arial Narrow", western = [[Fonts\ARIALN.TTF]], cyrillic = [[Fonts\ARIALN.TTF]] },
  {
    name = "Friz Quadrata TT",
    western = [[Fonts\FRIZQT__.TTF]],
    cyrillic = [[Fonts\FRIZQT___CYR.TTF]],
  },
  { name = "Morpheus", western = [[Fonts\MORPHEUS.TTF]], cyrillic = [[Fonts\MORPHEUS_CYR.TTF]] },
  { name = "Skurri", western = [[Fonts\SKURRI.TTF]], cyrillic = [[Fonts\SKURRI_CYR.TTF]] },
}

--- What `defaults:Get(type)` falls back to (docs/API.md, "Built-in media").
local BUILTIN_FALLBACKS = {
  background = "Blizzard Dialog Background",
  border = "Blizzard Tooltip",
  font = "Friz Quadrata TT",
  icon = "Question Mark",
  sound = "None",
  statusbar = "Blizzard",
  texture = "Solid",
}

--- Client files the test entries point at, so any entry that stays for the
--- session names something the client really has.
local SOLID_TEXTURE = [[Interface\Buttons\WHITE8X8]]
local BAR_TEXTURE = [[Interface\TargetingFrame\UI-StatusBar]]
local TEST_FONT = [[Fonts\FRIZQT__.TTF]]

--- Why the sound FileDataID test is registered as skipped. A sound's
--- FileDataID can only be proven to name a shipped file through
--- `GetFileIDFromPath`, and on Retail 12.1.0 b69933 (run of 2026-09-25) it
--- answered nil for `Sound\Interface\RaidWarning.ogg`, `ReadyCheck.ogg` and
--- `LevelUp.ogg`. The `SOUNDKIT` constants are SoundKit ids for `PlaySound`,
--- not FileDataIDs, and no client function maps one to the other without
--- playing it.
local SOUND_FILE_DATA_ID_SKIP_REASON =
  "GetFileIDFromPath answered nil for Sound\\Interface\\RaidWarning.ogg, ReadyCheck.ogg and LevelUp.ogg on Retail 12.1.0 b69933, and SOUNDKIT holds SoundKit ids, not FileDataIDs; the Busted specs cover a sound FileDataID"

--- Files the client does not ship: the controls of the file probes.
local MISSING_FONT = [[Interface\AddOns\MoltenCodesTest_MediaKit\Missing.ttf]]
local MISSING_TEXTURE = [[Interface\AddOns\MoltenCodesTest_MediaKit\Missing.tga]]

--- The font height every font probe uses.
local PROBE_FONT_HEIGHT = 12

--- How many calls each allocation guard measures, and the kilobytes it
--- tolerates. One table per call would cost well over a hundred kilobytes; the
--- tolerance absorbs a stray allocation by the client between two readings.
local ALLOCATION_CALLS = 2000
local ALLOCATION_TOLERANCE_KB = 1

--- The lookup options that switch the font filter off, built once so the
--- allocation guards do not measure an options table.
local ANY_SCRIPT = { anyScript = true }

--- Why the stand-in tests do not run when a real LibSharedMedia is loaded.
local REAL_LIBSHAREDMEDIA_SKIP_REASON =
  "a real LibSharedMedia-3.0 is loaded; the stand-in is installed only when none exists"

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- GetLocale, CreateFrame, GetFileIDFromPath, LibStub and the secret-value
  -- functions are World of Warcraft client globals, reachable only through
  -- the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a client global. Used only for `LibStub`, which the stand-in replaces
---while one test body runs and which is put back before that body returns.
---@param name string
---@param value any
local function writeHost(name, value)
  -- The stand-in LibSharedMedia is reachable to MediaKit only through the
  -- `LibStub` global, which MediaKit reads with rawget at every call.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- MediaKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade, its
-- defaults objects and the client's regions are typed `any` here.

---@type any
local MediaKit = Registry:Get(PACKAGE_ID, MEDIA_KIT_API)
if type(MediaKit) == "nil" then
  error(addonName .. " requires MediaKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

local createFrame = readHost("CreateFrame")
local getLocale = readHost("GetLocale")
if type(createFrame) ~= "function" or type(getLocale) ~= "function" then
  error(addonName .. " requires the client's CreateFrame and GetLocale", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

---Whether `value` is a secret, asked before any comparison of a client answer.
---@param value any
---@return boolean
local function isSecret(value)
  return type(isSecretValue) == "function" and isSecretValue(value) == true
end

-- The client's locale ------------------------------------------------------------------

---The client's locale, as MediaKit reads it.
---@return string
local function clientLocale()
  local locale = getLocale()
  if type(locale) ~= "string" or isSecret(locale) then
    return "?"
  end
  return locale
end

---The script docs/API.md maps the client's locale to.
---@return string
local function clientScript()
  return LOCALE_SCRIPTS[clientLocale()] or "latin"
end

---Whether the built-in fonts render the client's script: on a Latin client
---and on a ruRU client (docs/API.md, "Built-in media").
---@return boolean
local function builtinFontsRenderHere()
  local script = clientScript()
  return script == "latin" or script == "cyrillic"
end

---LibSharedMedia's locale bit for this client.
---@return integer
local function clientLocaleBit()
  return LIBSHAREDMEDIA_LOCALE_BITS[clientLocale()] or LIBSHAREDMEDIA_WESTERN_BIT
end

---Whether `mask` holds `bitValue`, with arithmetic, as MediaKit computes it.
---@param mask integer
---@param bitValue integer
---@return boolean
local function hasBit(mask, bitValue)
  return math.floor(mask / bitValue) % 2 == 1
end

-- Names ----------------------------------------------------------------------------------

--- Entries are never removed, so every name a test registers carries a number
--- that grows for the session: a second run registers new names.
local nameSequence = 0

---A name nobody else registered: "MoltenCodesTest <label> <n>".
---@param label string
---@return string
local function uniqueName(label)
  nameSequence = nameSequence + 1
  return ("MoltenCodesTest %s %d"):format(label, nameSequence)
end

---Whether `list` holds `name`.
---@param list string[]
---@param name string
---@return boolean
local function listContains(list, name)
  for index = 1, #list do
    if list[index] == name then
      return true
    end
  end
  return false
end

---Whether every name of `list` sorts before the next with `<`.
---@param list string[]
---@return boolean sorted
---@return integer|nil position the first index whose name does not sort before the next
local function isSortedByBytes(list)
  for index = 1, #list - 1 do
    if not (list[index] < list[index + 1]) then
      return false, index
    end
  end
  return true, nil
end

---A file path in one spelling for comparison: lower case with backslashes.
---@param path string
---@return string
local function normalisePath(path)
  return (path:lower():gsub("/", "\\"))
end

---The entry record MediaKit keeps for `name` of `mediaType`, or an empty table
---when there is none, so a missing entry fails the assertion on its field
---rather than raising. The records are `MediaKit._state.types[type].entries`
---(docs/INTERNALS.md, "Type records"); the tests read `origin` and `data`.
---@param mediaType string
---@param name string
---@return { data: any, origin: string|nil }
local function entryRecord(mediaType, name)
  local state = rawget(MediaKit, "_state")
  local record = state.types[mediaType].entries[name]
  if type(record) == "nil" then
    return {}
  end
  return record
end

-- Cleanup of the running test ----------------------------------------------------------

--- `OnRegistered` connections the running test made; the After hook
--- disconnects them.
---@type table[]
local trackedConnections = {}

---Remember `connection` for the After hook and hand it back.
---@param connection table a SignalKit connection
---@return table connection
local function trackConnection(connection)
  trackedConnections[#trackedConnections + 1] = connection
  return connection
end

---Disconnect every connection the running test made and clear the choices of
---both test consumers. The After hook of every suite.
local function cleanUp()
  for index = #trackedConnections, 1, -1 do
    local connection = trackedConnections[index]
    trackedConnections[index] = nil
    pcall(connection.Disconnect, connection)
  end
  for _, consumerName in ipairs({ CONSUMER_A, CONSUMER_B }) do
    local defaults = MediaKit:Defaults(consumerName)
    for _, mediaType in ipairs(MEDIA_TYPES) do
      defaults:Set(mediaType, nil)
    end
  end
end

---Register a suite of this package whose tests all end cleaned up.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

-- Positions and errors ------------------------------------------------------------------------

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
  local file, line = position:match("^(.-):(%d+): ")
  return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
---@return integer
local function currentLine()
  local _, position = pcall(error, "", 3)
  local _, line = splitPosition(position or "")
  return line or 0
end

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" then
    return nil
  end
  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#THIS_FILE)):ToBe(THIS_FILE)
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(lineBox.start + 1)
end

-- Allocation ----------------------------------------------------------------------------------

---Collect in a step of its own, run one unmeasured warm-up call, then run
---`operation` `ALLOCATION_CALLS` times, log how far the heap grew and hold it
---to the tolerance.
---
---The collection gets a step of its own so the measurement starts far from the
---next collector cycle, which would otherwise shrink the count mid-measurement
---and hide an allocation. The warm-up comes after the collection because the
---first call after a full collection can regrow the coroutine stack, which is
---not the per-call cost docs/API.md promises is zero.
---@param ctx TestKit.Context
---@param label string what `operation` does, for the log
---@param operation fun()
local function expectNoAllocation(ctx, label, operation)
  collectgarbage("collect")
  ctx:Yield()
  operation()
  local before = collectgarbage("count")
  for _ = 1, ALLOCATION_CALLS do
    operation()
  end
  local grownKilobytes = collectgarbage("count") - before
  ctx:Log(
    ("memory delta over %d calls of %s: %.3f KB"):format(ALLOCATION_CALLS, label, grownKilobytes)
  )
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- The client's files ------------------------------------------------------------------

--- The hidden probe: one Frame with one Texture and one FontString, created
--- the first time a test needs them and kept for the session.
---@type any
local probeFrame = nil
---@type any
local probeTexture = nil
---@type any
local probeFontString = nil

---The probe Texture and FontString, on a Frame that is hidden, at alpha 0,
---with no size and no anchor, so nothing it loads can be seen.
---@return any texture
---@return any fontString
local function probeRegions()
  if type(probeFrame) == "nil" then
    probeFrame = createFrame("Frame")
    probeFrame:Hide()
    probeFrame:SetAlpha(0)
    probeTexture = probeFrame:CreateTexture()
    probeFontString = probeFrame:CreateFontString()
  end
  return probeTexture, probeFontString
end

---The FileDataID the client's `GetFileIDFromPath` answers for `path`, or `nil`
---when it has none (or answers something that is not a positive number).
---@param path string
---@return integer|nil fileID
---@return string answer the raw answer, for the log
local function fileIDFromPath(path)
  local getFileIDFromPath = readHost("GetFileIDFromPath")
  if type(getFileIDFromPath) ~= "function" then
    return nil, "GetFileIDFromPath absent"
  end
  local succeeded, answer = pcall(getFileIDFromPath, path)
  if not succeeded then
    return nil, "raised: " .. tostring(answer)
  end
  if isSecret(answer) then
    return nil, "a secret value"
  end
  if type(answer) == "number" and answer >= 1 then
    return answer, tostring(answer)
  end
  return nil, type(answer) .. " " .. tostring(answer)
end

---Load `path` into the probe FontString and say what the client answered.
---@param path string
---@return boolean loaded whether `SetFont` returned true without raising
---@return string description for the log
local function probeFont(path)
  local _, fontString = probeRegions()
  local succeeded, answer = pcall(fontString.SetFont, fontString, path, PROBE_FONT_HEIGHT)
  if not succeeded then
    return false, "SetFont raised: " .. tostring(answer)
  end
  if isSecret(answer) then
    return false, "SetFont answered a secret value"
  end
  local fontFile = fontString:GetFont()
  return answer == true,
    ("SetFont %s, GetFont %s"):format(
      tostring(answer),
      isSecret(fontFile) and "<secret>" or tostring(fontFile)
    )
end

---Load `path` into the probe Texture and say what the client answered.
---@param path string
---@return boolean loaded whether `SetTexture` returned true without raising
---@return any texture what `GetTexture` answered
---@return any fileID what `GetTextureFileID` answered
---@return string description for the log
local function probeTexturePath(path)
  local texture = probeRegions()
  local succeeded, answer = pcall(texture.SetTexture, texture, path)
  if not succeeded then
    return false, nil, nil, "SetTexture raised: " .. tostring(answer)
  end
  if isSecret(answer) then
    return false, nil, nil, "SetTexture answered a secret value"
  end
  local current = texture:GetTexture()
  local fileID = texture:GetTextureFileID()
  return answer == true,
    current,
    fileID,
    ("SetTexture %s, GetTexture %s, GetTextureFileID %s"):format(
      tostring(answer),
      isSecret(current) and "<secret>" or tostring(current),
      isSecret(fileID) and "<secret>" or tostring(fileID)
    )
end

-- LibSharedMedia ---------------------------------------------------------------------

---A real LibSharedMedia-3.0 from the real LibStub, or `nil`. Asked with
---`silent`, the way MediaKit asks, so an absent library does not raise.
---@return table|nil library
---@return any minor
local function findRealLibSharedMedia()
  local libStub = readHost("LibStub")
  if type(libStub) ~= "table" then
    return nil, nil
  end
  local getLibrary = rawget(libStub, "GetLibrary")
  if type(getLibrary) ~= "function" then
    return nil, nil
  end
  local succeeded, library, minor = pcall(getLibrary, libStub, LIBSHAREDMEDIA_MAJOR, true)
  if not succeeded or type(library) ~= "table" then
    return nil, nil
  end
  return library, minor
end

---MediaKit's LibSharedMedia bridge state (docs/INTERNALS.md, "LibSharedMedia
---bridge"): `adoptSource`, `subscribed` and `mirrorTarget`.
---@return table
local function bridgeState()
  return rawget(rawget(MediaKit, "_state"), "libSharedMedia")
end

---Options of the stand-in LibSharedMedia.
---@class MoltenCodesTest.MediaKit.StandInOptions
---@field media table<string, table<string, any>>|nil entries present before MediaKit sees it
---@field secretAnswer boolean|nil answer every accepted `Register` with `secretwrap(true)`
---@field secretWesternBit boolean|nil publish `LOCALE_BIT_western` as `secretwrap(128)`

---A stand-in LibSharedMedia-3.0 with the surface MediaKit uses: `Register`
---with LibSharedMedia's font rule (a font whose `langmask` lacks the client's
---locale bit is refused, and so is a font without a mask on a non-Western
---client), `HashTable`, CallbackHandler's `RegisterCallback` and the
---`LOCALE_BIT_*` fields. It records every `Register` for the assertions:
---`langmasks[type][name]`, `accepted` (calls it accepted) and
---`registered[type][name]` (names it was asked to register).
---@param options MoltenCodesTest.MediaKit.StandInOptions
---@return table library
local function newStandInLibSharedMedia(options)
  local library = {
    LOCALE_BIT_koKR = 1,
    LOCALE_BIT_ruRU = 2,
    LOCALE_BIT_zhCN = 4,
    LOCALE_BIT_zhTW = 8,
    LOCALE_BIT_western = LIBSHAREDMEDIA_WESTERN_BIT,
    accepted = 0,
    langmasks = {},
    registered = {},
  }
  if options.secretWesternBit == true then
    library.LOCALE_BIT_western = secretWrap(LIBSHAREDMEDIA_WESTERN_BIT)
  end
  local mediaTables = {}
  for _, mediaType in ipairs(LIBSHAREDMEDIA_TYPES) do
    mediaTables[mediaType] = {}
    library.langmasks[mediaType] = {}
    library.registered[mediaType] = {}
  end
  if type(options.media) ~= "nil" then
    for mediaType, entries in pairs(options.media) do
      for key, data in pairs(entries) do
        mediaTables[mediaType][key] = data
      end
    end
  end
  local callbacks = {}
  local western = clientLocaleBit() == LIBSHAREDMEDIA_WESTERN_BIT

  ---Call every registered callback as CallbackHandler does: `method(event, ...)`.
  ---@param mediaType any
  ---@param key any
  function library.FireRegistered(mediaType, key)
    for index = 1, #callbacks do
      callbacks[index](LIBSHAREDMEDIA_EVENT, mediaType, key)
    end
  end

  ---@param _ table the library
  ---@param mediaType string
  ---@param key string
  ---@param data any
  ---@param langmask integer|nil
  ---@return any registered
  function library.Register(_, mediaType, key, data, langmask)
    mediaType = mediaType:lower()
    library.registered[mediaType][key] = true
    library.langmasks[mediaType][key] = langmask or false
    if mediaType == "font" then
      if type(langmask) == "nil" then
        if not western then
          return false
        end
      elseif not hasBit(langmask, clientLocaleBit()) then
        return false
      end
    end
    if type(mediaTables[mediaType][key]) ~= "nil" then
      return false
    end
    mediaTables[mediaType][key] = data
    library.accepted = library.accepted + 1
    library.FireRegistered(mediaType, key)
    if options.secretAnswer == true then
      return secretWrap(true)
    end
    return true
  end

  ---@param _ table the library
  ---@param mediaType string
  ---@return table|nil
  function library.HashTable(_, mediaType)
    return mediaTables[mediaType]
  end

  ---CallbackHandler-1.0's shape: one registration per owner and event, and a
  ---refusal when the owner is the library itself.
  ---@param owner table
  ---@param eventName string
  ---@param method function
  function library.RegisterCallback(owner, eventName, method)
    if owner == library then
      error("stand-in RegisterCallback: do not register on the library itself", 2)
    end
    if eventName == LIBSHAREDMEDIA_EVENT and type(method) == "function" then
      callbacks[#callbacks + 1] = method
    end
  end

  ---How many callbacks are registered.
  ---@return integer
  function library.CallbackCount()
    return #callbacks
  end

  return library
end

---A stand-in LibStub that hands out `library` for LibSharedMedia-3.0 and
---passes every other library to the real LibStub when there is one.
---@param library table
---@param realLibStub any
---@return table
local function newStandInLibStub(library, realLibStub)
  local standIn = {}

  ---@param _ table
  ---@param major string
  ---@param silent boolean|nil
  ---@return any library
  ---@return any minor
  function standIn.GetLibrary(_, major, silent)
    if major == LIBSHAREDMEDIA_MAJOR then
      return library, 1
    end
    if type(realLibStub) == "table" then
      return realLibStub:GetLibrary(major, silent)
    end
    if silent ~= true then
      error('stand-in LibStub: cannot find a library instance of "' .. tostring(major) .. '"', 2)
    end
    return nil, nil
  end

  if type(realLibStub) == "table" then
    setmetatable(standIn, {
      __index = realLibStub,
      __call = function(_, major, silent)
        return standIn:GetLibrary(major, silent)
      end,
    })
  end
  return standIn
end

---Run `body(library)` with a stand-in LibSharedMedia reachable through the
---`LibStub` global, and put everything back before returning, pass or fail:
---the `LibStub` global and MediaKit's three bridge pointers. The body must not
---yield, so no other code runs while the stand-in is installed. Skips the test
---when a real LibSharedMedia-3.0 is loaded.
---@param ctx TestKit.Context
---@param options MoltenCodesTest.MediaKit.StandInOptions
---@param body fun(library: table)
local function withStandIn(ctx, options, body)
  if type(findRealLibSharedMedia()) ~= "nil" then
    Harness:SkipTest(ctx, REAL_LIBSHAREDMEDIA_SKIP_REASON)
    return
  end
  local bridge = bridgeState()
  local savedAdoptSource = rawget(bridge, "adoptSource")
  local savedSubscribed = rawget(bridge, "subscribed")
  local savedMirrorTarget = rawget(bridge, "mirrorTarget")
  local realLibStub = readHost("LibStub")
  local library = newStandInLibSharedMedia(options)

  writeHost("LibStub", newStandInLibStub(library, realLibStub))
  local succeeded, problem = pcall(body, library)
  writeHost("LibStub", realLibStub)
  rawset(bridge, "adoptSource", savedAdoptSource)
  rawset(bridge, "subscribed", savedSubscribed)
  rawset(bridge, "mirrorTarget", savedMirrorTarget)

  if not succeeded then
    error(problem, 0)
  end
end

-- mediaKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('mediaKit', 1) is the MediaKit facade with API 1, its eleven methods, MAX_ENTRIES_PER_TYPE 1024 and the UNBOUNDED sentinel",
  function(ctx)
    ctx:Expect(type(MediaKit)):ToBe("table")
    ctx:Expect(rawget(MediaKit, "API")):ToBe(MEDIA_KIT_API)
    for _, methodName in ipairs({
      "Register",
      "Fetch",
      "Has",
      "List",
      "OnRegistered",
      "Defaults",
      "AdoptLibSharedMedia",
      "MirrorToLibSharedMedia",
      "IsFileDataID",
      "SetLimits",
      "GetLimits",
    }) do
      ctx:Expect(type(MediaKit[methodName])):ToBe("function")
    end
    ctx:Expect(MediaKit.MAX_ENTRIES_PER_TYPE):ToBe(1024)
    ctx:Expect(type(MediaKit.UNBOUNDED)):ToBe("table")
    local limits = MediaKit:GetLimits()
    ctx:Log(
      ("limits in this session: maxEntriesPerType %s, maxConsumers %s"):format(
        tostring(limits.maxEntriesPerType),
        limits.maxConsumers == MediaKit.UNBOUNDED and "UNBOUNDED" or tostring(limits.maxConsumers)
      )
    )
  end
)

facade:Test("the installed MediaKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, MEDIA_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(MediaKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list mediaKit")
end)

facade:Test(
  "the client's GetLocale answers a locale string MediaKit maps to a script; issecretvalue, LibStub, LibSharedMedia-3.0, GetFileIDFromPath and CreateFrame are logged",
  function(ctx)
    local locale = getLocale()
    ctx:Expect(type(locale)):ToBe("string")
    ctx:Log(
      ("GetLocale: %s, documented script: %s%s"):format(
        clientLocale(),
        clientScript(),
        LOCALE_SCRIPTS[clientLocale()] and "" or " (a locale docs/API.md does not list: Latin)"
      )
    )
    ctx:Log("issecretvalue: " .. type(isSecretValue) .. ", secretwrap: " .. type(secretWrap))
    local libStub = readHost("LibStub")
    local library, minor = findRealLibSharedMedia()
    ctx:Log(
      ("LibStub: %s, LibSharedMedia-3.0: %s"):format(
        type(libStub) == "nil" and "absent" or type(libStub),
        type(library) == "nil" and "absent" or ("minor " .. tostring(minor))
      )
    )
    ctx:Log(
      "GetFileIDFromPath: "
        .. type(readHost("GetFileIDFromPath"))
        .. ", CreateFrame: "
        .. type(createFrame)
    )
  end
)

-- mediaKit.builtins ----------------------------------------------------------------------------

local builtins = newSuite("builtins")

---The built-in font data MediaKit registered on this client for `font`.
---@param font { name: string, western: string, cyrillic: string }
---@return string
local function expectedFontPath(font)
  if clientScript() == "cyrillic" then
    return font.cyrillic
  end
  return font.western
end

builtins:Test(
  "every built-in entry of docs/API.md's table holds its documented data for this client's locale, and each type's Get fallback is one of them",
  function(ctx)
    for _, builtin in ipairs(BUILTIN_MEDIA) do
      ctx:Expect(MediaKit:Fetch(builtin.mediaType, builtin.name)):ToBe(builtin.data)
    end
    for _, font in ipairs(BUILTIN_FONTS) do
      ctx:Expect(MediaKit:Fetch("font", font.name, ANY_SCRIPT)):ToBe(expectedFontPath(font))
    end
    for _, mediaType in ipairs(MEDIA_TYPES) do
      local fallback = BUILTIN_FALLBACKS[mediaType]
      ctx:Expect(MediaKit:Has(mediaType, fallback, ANY_SCRIPT)):ToBe(true)
      ctx:Expect(entryRecord(mediaType, fallback).origin):ToBe("builtin")
    end
    ctx:Log(
      ("the built-in fonts on this %s client use the %s files"):format(
        clientLocale(),
        clientScript() == "cyrillic" and "Cyrillic (_CYR)" or "Western"
      )
    )
  end
)

builtins:Test(
  "the four built-in fonts load into a hidden FontString: SetFont(path, 12) returns true for each and GetFont names the file; a missing font file is logged as the control",
  function(ctx)
    for _, font in ipairs(BUILTIN_FONTS) do
      local path = MediaKit:Fetch("font", font.name, ANY_SCRIPT)
      local loaded, description = probeFont(path)
      ctx:Log(("%s (%s): %s"):format(font.name, tostring(path), description))
      ctx:Expect(loaded):ToBe(true)
      if clientScript() ~= "cyrillic" and font.cyrillic ~= font.western then
        local _, otherDescription = probeFont(font.cyrillic)
        ctx:Log(("  the ruRU file %s on this client: %s"):format(font.cyrillic, otherDescription))
      end
    end
    local controlLoaded, controlDescription = probeFont(MISSING_FONT)
    ctx:Log(
      ("control, a file the client does not ship (%s): %s"):format(MISSING_FONT, controlDescription)
    )
    if controlLoaded then
      ctx:Log(
        "SetFont accepted a missing file, so this probe cannot tell a missing font; GetFileIDFromPath answered nil for Fonts\\ARIALN.TTF on Retail 12.1"
      )
    end
    -- Leave the probe on a shipped font rather than on the control's answer.
    probeFont(TEST_FONT)
  end
)

builtins:Test(
  "the nine texture-backed built-ins (backgrounds, borders but 'None', the icon, the status bars and the texture) load into a hidden Texture: SetTexture returns true, GetTexture answers and GetTextureFileID equals GetFileIDFromPath",
  function(ctx)
    local probed = 0
    for _, builtin in ipairs(BUILTIN_MEDIA) do
      if builtin.mediaType ~= "sound" and builtin.placeholder ~= true then
        probed = probed + 1
        local path = MediaKit:Fetch(builtin.mediaType, builtin.name)
        local loaded, current, textureFileID, description = probeTexturePath(path)
        local fileID = fileIDFromPath(path)
        ctx:Log(
          ("%s %s (%s): %s, GetFileIDFromPath %s"):format(
            builtin.mediaType,
            builtin.name,
            tostring(path),
            description,
            tostring(fileID)
          )
        )
        ctx:Expect(loaded):ToBe(true)
        ctx:Expect(type(current) == "string" or type(current) == "number"):ToBe(true)
        ctx:Expect(type(fileID)):ToBe("number")
        if not isSecret(textureFileID) then
          ctx:Expect(textureFileID):ToBe(fileID)
        end
      end
    end
    ctx:Expect(probed):ToBe(9)
    local _, _, _, controlDescription = probeTexturePath(MISSING_TEXTURE)
    ctx:Log(
      ("control, a file the client does not ship (%s): %s"):format(
        MISSING_TEXTURE,
        controlDescription
      )
    )
    probeRegions():SetTexture(nil)
  end
)

builtins:Test(
  "GetFileIDFromPath resolves every texture-backed built-in path to a FileDataID; the font paths and the 'None' border and sound placeholders are logged, not asserted, and nothing is played",
  function(ctx)
    local resolved = 0
    for _, builtin in ipairs(BUILTIN_MEDIA) do
      local fileID, answer = fileIDFromPath(builtin.data)
      ctx:Log(("%s %s (%s): %s"):format(builtin.mediaType, builtin.name, builtin.data, answer))
      if builtin.mediaType ~= "sound" and builtin.placeholder ~= true then
        resolved = resolved + 1
        ctx:Expect(type(fileID)):ToBe("number")
      end
    end
    ctx:Expect(resolved):ToBe(9)
    -- Retail 12.1.0 b69933 answered nil for Fonts\ARIALN.TTF; the font test
    -- above proves the files through SetFont instead, so these are logged.
    for _, font in ipairs(BUILTIN_FONTS) do
      local path = expectedFontPath(font)
      local _, answer = fileIDFromPath(path)
      ctx:Log(("font %s (%s): %s (not asserted)"):format(font.name, path, answer))
    end
    local _, controlAnswer = fileIDFromPath(MISSING_TEXTURE)
    ctx:Log("control, a file the client does not ship: " .. controlAnswer)
  end
)

builtins:Skip(
  "a sound registered by a FileDataID of a shipped interface sound is a FileDataID to IsFileDataID, and Fetch hands back that number; nothing is played",
  SOUND_FILE_DATA_ID_SKIP_REASON
)

-- mediaKit.scripts ----------------------------------------------------------------------------

local scripts = newSuite("scripts")

scripts:Test(
  "GetLocale() maps to the documented script, and a font declaring that script is fetched, listed and Has true while a font declaring only greek is hidden unless anyScript",
  function(ctx)
    local script = clientScript()
    ctx:Log(("locale %s, script %s"):format(clientLocale(), script))
    local ownName = uniqueName("Font " .. script)
    local greekName = uniqueName("Font greek")
    ctx:Expect(MediaKit:Register("font", ownName, TEST_FONT, { scripts = { script } })):ToBe(true)
    ctx
      :Expect(MediaKit:Register("font", greekName, TEST_FONT, { scripts = { "greek" } }))
      :ToBe(true)

    ctx:Expect(MediaKit:Fetch("font", ownName)):ToBe(TEST_FONT)
    ctx:Expect(MediaKit:Has("font", ownName)):ToBe(true)
    ctx:Expect(listContains(MediaKit:List("font"), ownName)):ToBe(true)

    ctx:Expect(MediaKit:Fetch("font", greekName)):ToBe(nil)
    ctx:Expect(MediaKit:Has("font", greekName)):ToBe(false)
    ctx:Expect(listContains(MediaKit:List("font"), greekName)):ToBe(false)
    ctx:Expect(MediaKit:Fetch("font", greekName, ANY_SCRIPT)):ToBe(TEST_FONT)
    ctx:Expect(MediaKit:Has("font", greekName, ANY_SCRIPT)):ToBe(true)
    ctx:Expect(listContains(MediaKit:List("font", ANY_SCRIPT), greekName)):ToBe(true)
  end
)

scripts:Test(
  "a font registered without scripts is Latin only: offered on a Latin client, hidden on any other, and always reachable with anyScript",
  function(ctx)
    local name = uniqueName("Font undeclared")
    ctx:Expect(MediaKit:Register("font", name, TEST_FONT)):ToBe(true)
    local latinClient = clientScript() == "latin"
    ctx:Log(
      ("script %s: the undeclared font is expected %s"):format(
        clientScript(),
        latinClient and "offered" or "hidden"
      )
    )
    ctx:Expect(MediaKit:Has("font", name)):ToBe(latinClient)
    ctx:Expect(listContains(MediaKit:List("font"), name)):ToBe(latinClient)
    ctx:Expect(MediaKit:Fetch("font", name, ANY_SCRIPT)):ToBe(TEST_FONT)
  end
)

scripts:Test(
  "the built-in fonts are offered without anyScript on a Latin or ruRU client and hidden on a CJK or Korean one, as docs/API.md's built-in table says",
  function(ctx)
    local expected = builtinFontsRenderHere()
    local clientFonts = MediaKit:List("font")
    ctx:Log(
      ("script %s: %d fonts offered to this client, %d in all"):format(
        clientScript(),
        #clientFonts,
        #MediaKit:List("font", ANY_SCRIPT)
      )
    )
    for _, font in ipairs(BUILTIN_FONTS) do
      ctx:Expect(MediaKit:Has("font", font.name)):ToBe(expected)
      ctx:Expect(listContains(clientFonts, font.name)):ToBe(expected)
    end
  end
)

-- mediaKit.lists ----------------------------------------------------------------------------

local lists = newSuite("lists")

lists:Test(
  "List returns every name sorted with < in byte order ('Bar 10' before 'Bar 2', upper case before lower case), whatever order the names were registered in",
  function(ctx)
    local prefix = uniqueName("Sort")
    for _, suffix in ipairs({ " Bar 2", " bar 1", " Bar 10", " Alpha" }) do
      ctx:Expect(MediaKit:Register("statusbar", prefix .. suffix, SOLID_TEXTURE)):ToBe(true)
    end
    local list = MediaKit:List("statusbar")
    local sorted, position = isSortedByBytes(list)
    if not sorted then
      ctx:Log(("names %d and %d are out of order"):format(position or 0, (position or 0) + 1))
    end
    ctx:Expect(sorted):ToBe(true)
    local ours = {}
    for _, name in ipairs(list) do
      if name:sub(1, #prefix) == prefix then
        ours[#ours + 1] = name:sub(#prefix + 1)
      end
    end
    ctx:Expect(ours):ToEqual({ " Alpha", " Bar 10", " Bar 2", " bar 1" })
    ctx:Log(("%d status bars listed"):format(#list))
  end
)

lists:Test(
  "List hands out the same cached array until a registration of its type, then a new one, never changes an array handed out earlier, and keeps its cache through a registration of another type",
  function(ctx)
    local first = MediaKit:List("statusbar")
    ctx:Expect(rawequal(MediaKit:List("statusbar"), first)):ToBe(true)
    local firstLength = #first

    ctx:Expect(MediaKit:Register("background", uniqueName("Background"), SOLID_TEXTURE)):ToBe(true)
    ctx:Expect(rawequal(MediaKit:List("statusbar"), first)):ToBe(true)

    local name = uniqueName("Bar")
    ctx:Expect(MediaKit:Register("statusbar", name, BAR_TEXTURE)):ToBe(true)
    local second = MediaKit:List("statusbar")
    ctx:Expect(rawequal(second, first)):ToBe(false)
    ctx:Expect(#first):ToBe(firstLength)
    ctx:Expect(listContains(first, name)):ToBe(false)
    ctx:Expect(#second):ToBe(firstLength + 1)
    ctx:Expect(listContains(second, name)):ToBe(true)
    ctx:Expect(rawequal(MediaKit:List("statusbar"), second)):ToBe(true)
  end
)

lists:Test(
  "the client's font list and the anyScript font list are cached separately, and a font of another script enters only the anyScript list",
  function(ctx)
    local clientList = MediaKit:List("font")
    local anyList = MediaKit:List("font", ANY_SCRIPT)
    ctx:Expect(rawequal(clientList, anyList)):ToBe(false)
    ctx:Expect(rawequal(MediaKit:List("font"), clientList)):ToBe(true)
    ctx:Expect(rawequal(MediaKit:List("font", ANY_SCRIPT), anyList)):ToBe(true)

    local name = uniqueName("Font greek")
    ctx:Expect(MediaKit:Register("font", name, TEST_FONT, { scripts = { "greek" } })):ToBe(true)
    local newClientList = MediaKit:List("font")
    local newAnyList = MediaKit:List("font", ANY_SCRIPT)
    ctx:Expect(#newClientList):ToBe(#clientList)
    ctx:Expect(listContains(newClientList, name)):ToBe(false)
    ctx:Expect(#newAnyList):ToBe(#anyList + 1)
    ctx:Expect(listContains(newAnyList, name)):ToBe(true)
    ctx:Expect((isSortedByBytes(newAnyList))):ToBe(true)
  end
)

-- mediaKit.registration ----------------------------------------------------------------------

local registration = newSuite("registration")

registration:Test(
  "Register answers true again for the same name and data, nil and 'taken' for other data or other scripts, and treats a script set in another order with repeats as the same",
  function(ctx)
    local name = uniqueName("Bar")
    ctx:Expect(MediaKit:Register("statusbar", name, BAR_TEXTURE)):ToBe(true)
    local list = MediaKit:List("statusbar")
    ctx:Expect(MediaKit:Register("statusbar", name, BAR_TEXTURE)):ToBe(true)
    ctx:Expect(rawequal(MediaKit:List("statusbar"), list)):ToBe(true)
    ctx:Expect({ MediaKit:Register("statusbar", name, SOLID_TEXTURE) }):ToEqual({ nil, "taken" })
    ctx:Expect(MediaKit:Fetch("statusbar", name)):ToBe(BAR_TEXTURE)
    ctx:Expect({ MediaKit:Register("statusbar", "Solid", BAR_TEXTURE) }):ToEqual({ nil, "taken" })
    ctx:Expect(MediaKit:Fetch("statusbar", "Solid")):ToBe(SOLID_TEXTURE)

    local fontName = uniqueName("Font")
    ctx
      :Expect(MediaKit:Register("font", fontName, TEST_FONT, { scripts = { "latin", "cyrillic" } }))
      :ToBe(true)
    ctx
      :Expect(MediaKit:Register("font", fontName, TEST_FONT, {
        scripts = { "cyrillic", "latin", "latin" },
      }))
      :ToBe(true)
    ctx
      :Expect({ MediaKit:Register("font", fontName, TEST_FONT, { scripts = { "latin" } }) })
      :ToEqual({ nil, "taken" })
  end
)

registration:Test(
  "OnRegistered fires once with type, name and data after the entry is stored, not for an identical or refused registration, and not after Disconnect",
  function(ctx)
    local calls = {}
    local connection =
      trackConnection(MediaKit:OnRegistered("statusbar", function(mediaType, name, data)
        calls[#calls + 1] = {
          mediaType = mediaType,
          name = name,
          data = data,
          fetched = MediaKit:Fetch("statusbar", name),
          listed = listContains(MediaKit:List("statusbar"), name),
        }
      end))
    local name = uniqueName("Bar")
    ctx:Expect(MediaKit:Register("statusbar", name, BAR_TEXTURE)):ToBe(true)
    ctx:Expect(calls):ToEqual({
      {
        mediaType = "statusbar",
        name = name,
        data = BAR_TEXTURE,
        fetched = BAR_TEXTURE,
        listed = true,
      },
    })
    MediaKit:Register("statusbar", name, BAR_TEXTURE)
    MediaKit:Register("statusbar", name, SOLID_TEXTURE)
    MediaKit:Register("background", uniqueName("Background"), SOLID_TEXTURE)
    ctx:Expect(#calls):ToBe(1)

    connection:Disconnect()
    ctx:Expect(connection:IsConnected()):ToBe(false)
    ctx:Expect(MediaKit:Register("statusbar", uniqueName("Bar"), BAR_TEXTURE)):ToBe(true)
    ctx:Expect(#calls):ToBe(1)
  end
)

-- mediaKit.defaults ----------------------------------------------------------------------------

local defaultsSuite = newSuite("defaults")

---The name a consumer without choices should get for `mediaType` on this
---client: the built-in fallback, or for fonts on a client whose script no
---built-in renders, the first name of the client's font list (or `nil`).
---@param mediaType string
---@return string|nil
local function expectedFallback(mediaType)
  if mediaType == "font" and not builtinFontsRenderHere() then
    return MediaKit:List("font")[1]
  end
  return BUILTIN_FALLBACKS[mediaType]
end

defaultsSuite:Test(
  "Defaults returns one object per consumer name, and a consumer without choices gets each type's documented built-in fallback on this client",
  function(ctx)
    local defaultsA = MediaKit:Defaults(CONSUMER_A)
    ctx:Expect(rawequal(MediaKit:Defaults(CONSUMER_A), defaultsA)):ToBe(true)
    ctx:Expect(rawequal(MediaKit:Defaults(CONSUMER_B), defaultsA)):ToBe(false)
    for _, mediaType in ipairs(MEDIA_TYPES) do
      local answer = defaultsA:Get(mediaType)
      ctx:Log(("%s: %s"):format(mediaType, tostring(answer)))
      ctx:Expect(answer):ToBe(expectedFallback(mediaType))
    end
  end
)

defaultsSuite:Test(
  "defaults:Set of a registered test status bar is answered by that consumer's Get only, and Set(type, nil) brings the fallback back",
  function(ctx)
    local defaultsA = MediaKit:Defaults(CONSUMER_A)
    local defaultsB = MediaKit:Defaults(CONSUMER_B)
    local name = uniqueName("Bar")
    ctx:Expect(MediaKit:Register("statusbar", name, BAR_TEXTURE)):ToBe(true)
    defaultsA:Set("statusbar", name)
    ctx:Expect(defaultsA:Get("statusbar")):ToBe(name)
    ctx:Expect(defaultsB:Get("statusbar")):ToBe("Blizzard")
    ctx:Expect(MediaKit:Fetch("statusbar", defaultsA:Get("statusbar"))):ToBe(BAR_TEXTURE)
    defaultsA:Set("statusbar", nil)
    ctx:Expect(defaultsA:Get("statusbar")):ToBe("Blizzard")
  end
)

defaultsSuite:Test(
  "a chosen name registered only later is answered as soon as it is registered, and a chosen font of another script yields the fallback",
  function(ctx)
    local defaultsA = MediaKit:Defaults(CONSUMER_A)
    local lateName = uniqueName("Background late")
    defaultsA:Set("background", lateName)
    ctx:Expect(defaultsA:Get("background")):ToBe("Blizzard Dialog Background")
    ctx:Expect(MediaKit:Register("background", lateName, SOLID_TEXTURE)):ToBe(true)
    ctx:Expect(defaultsA:Get("background")):ToBe(lateName)

    local greekName = uniqueName("Font greek")
    ctx
      :Expect(MediaKit:Register("font", greekName, TEST_FONT, { scripts = { "greek" } }))
      :ToBe(true)
    defaultsA:Set("font", greekName)
    ctx:Expect(defaultsA:Get("font")):ToBe(expectedFallback("font"))
    ctx:Log("the greek font chosen on this client yields: " .. tostring(defaultsA:Get("font")))
  end
)

-- mediaKit.libSharedMedia ----------------------------------------------------------------------

local libSharedMedia = newSuite("libSharedMedia")

libSharedMedia:Test(
  "without LibSharedMedia-3.0 AdoptLibSharedMedia and MirrorToLibSharedMedia both answer false and 'absent' and change nothing",
  function(ctx)
    if type(findRealLibSharedMedia()) ~= "nil" then
      Harness:SkipTest(
        ctx,
        "a real LibSharedMedia-3.0 is loaded, so the absent path cannot be reached"
      )
      return
    end
    ctx:Log("LibStub: " .. (type(readHost("LibStub")) == "nil" and "absent" or "present"))
    local bridge = bridgeState()
    local adoptSource = rawget(bridge, "adoptSource")
    local mirrorTarget = rawget(bridge, "mirrorTarget")
    local list = MediaKit:List("statusbar")
    ctx:Expect({ MediaKit:AdoptLibSharedMedia() }):ToEqual({ false, "absent" })
    ctx:Expect({ MediaKit:MirrorToLibSharedMedia() }):ToEqual({ false, "absent" })
    ctx:Expect(rawequal(rawget(bridge, "adoptSource"), adoptSource)):ToBe(true)
    ctx:Expect(rawequal(rawget(bridge, "mirrorTarget"), mirrorTarget)):ToBe(true)
    ctx:Expect(rawequal(MediaKit:List("statusbar"), list)):ToBe(true)
  end
)

libSharedMedia:Test(
  "a real LibSharedMedia-3.0 holds MediaKit's built-in names with the same files (read only; nothing is adopted or mirrored)",
  function(ctx)
    local library, minor = findRealLibSharedMedia()
    if type(library) == "nil" then
      Harness:SkipTest(
        ctx,
        "no real LibSharedMedia-3.0 is loaded; the stand-in tests cover the bridge"
      )
      return
    end
    ctx:Log("LibSharedMedia-3.0 minor " .. tostring(minor))
    local compared = 0
    local entries = {}
    for _, builtin in ipairs(BUILTIN_MEDIA) do
      entries[#entries + 1] = { mediaType = builtin.mediaType, name = builtin.name }
    end
    if builtinFontsRenderHere() then
      for _, font in ipairs(BUILTIN_FONTS) do
        entries[#entries + 1] = { mediaType = "font", name = font.name }
      end
    end
    for _, entry in ipairs(entries) do
      local hash = library:HashTable(entry.mediaType)
      local theirs = type(hash) == "table" and hash[entry.name] or nil
      local ours = MediaKit:Fetch(entry.mediaType, entry.name, ANY_SCRIPT)
      if type(theirs) == "string" and not isSecret(theirs) then
        compared = compared + 1
        ctx:Log(
          ("%s %s: LibSharedMedia %s, MediaKit %s"):format(
            entry.mediaType,
            entry.name,
            theirs,
            tostring(ours)
          )
        )
        ctx:Expect(normalisePath(theirs)):ToBe(normalisePath(ours))
      else
        ctx:Log(
          ("%s %s: LibSharedMedia holds %s"):format(
            entry.mediaType,
            entry.name,
            isSecret(theirs) and "a secret value" or type(theirs)
          )
        )
      end
    end
    ctx:Log(("%d names compared"):format(compared))
    ctx:Expect(compared > 0):ToBe(true)
  end
)

libSharedMedia:Test(
  "AdoptLibSharedMedia adopts a stand-in LibSharedMedia's entries read-only in sorted name order, skips invalid and clashing ones, follows its later registrations and subscribes once",
  function(ctx)
    local prefix = uniqueName("LSM")
    local alpha, mid, zeta = prefix .. " Alpha", prefix .. " Mid", prefix .. " Zeta"
    local fontName = prefix .. " Font"
    local invalidData = prefix .. " Zero"
    local statusbars = {
      [zeta] = SOLID_TEXTURE,
      [alpha] = BAR_TEXTURE,
      [mid] = SOLID_TEXTURE,
      [invalidData] = 0,
      [""] = SOLID_TEXTURE,
      Solid = BAR_TEXTURE,
      Blizzard = BAR_TEXTURE,
    }
    withStandIn(
      ctx,
      { media = { statusbar = statusbars, font = { [fontName] = TEST_FONT } } },
      function(library)
        local adopted = {}
        trackConnection(MediaKit:OnRegistered("statusbar", function(_, name)
          if name:sub(1, #prefix) == prefix then
            adopted[#adopted + 1] = name
          end
        end))

        ctx:Expect({ MediaKit:AdoptLibSharedMedia() }):ToEqual({ true, 4 })
        ctx:Expect(adopted):ToEqual({ alpha, mid, zeta })
        ctx:Expect(entryRecord("statusbar", alpha).origin):ToBe("libSharedMedia")
        ctx:Expect(MediaKit:Fetch("statusbar", alpha)):ToBe(BAR_TEXTURE)
        ctx:Expect(MediaKit:Has("statusbar", invalidData)):ToBe(false)
        ctx:Expect(MediaKit:Fetch("statusbar", "Solid")):ToBe(SOLID_TEXTURE)
        ctx:Expect(entryRecord("statusbar", "Solid").origin):ToBe("builtin")
        -- LibSharedMedia already refused the fonts this client cannot render,
        -- so an adopted font is offered without anyScript on every client.
        ctx:Expect(MediaKit:Fetch("font", fontName)):ToBe(TEST_FONT)

        ctx
          :Expect({ MediaKit:Register("statusbar", alpha, SOLID_TEXTURE) })
          :ToEqual({ nil, "taken" })
        ctx:Expect(MediaKit:Register("statusbar", alpha, BAR_TEXTURE)):ToBe(true)
        ctx:Expect(entryRecord("statusbar", alpha).origin):ToBe("libSharedMedia")

        local late = prefix .. " Late"
        ctx:Expect(library:Register("statusbar", late, SOLID_TEXTURE)):ToBe(true)
        ctx:Expect(MediaKit:Fetch("statusbar", late)):ToBe(SOLID_TEXTURE)
        ctx:Expect(adopted[#adopted]):ToBe(late)

        ctx:Expect({ MediaKit:AdoptLibSharedMedia() }):ToEqual({ true, 0 })
        ctx:Expect(library.CallbackCount()):ToBe(1)
      end
    )
    ctx:Expect(rawget(bridgeState(), "adoptSource")):ToBe(false)
  end
)

libSharedMedia:Test(
  "MirrorToLibSharedMedia registers MediaKit's entries into a stand-in LibSharedMedia with the documented langmask, mirrors a later Register before OnRegistered fires, and nothing echoes with both directions on",
  function(ctx)
    local wideFont = uniqueName("Font wide")
    local plainFont = uniqueName("Font plain")
    local greekFont = uniqueName("Font greek")
    ctx
      :Expect(MediaKit:Register("font", wideFont, TEST_FONT, { scripts = { "latin", "cyrillic" } }))
      :ToBe(true)
    ctx:Expect(MediaKit:Register("font", plainFont, TEST_FONT)):ToBe(true)
    ctx
      :Expect(MediaKit:Register("font", greekFont, TEST_FONT, { scripts = { "greek" } }))
      :ToBe(true)

    withStandIn(ctx, {}, function(library)
      local found, mirrored = MediaKit:MirrorToLibSharedMedia()
      ctx:Expect(found):ToBe(true)
      ctx:Expect(mirrored):ToBe(library.accepted)
      ctx:Log(("mirrored %d entries into the stand-in"):format(mirrored))

      -- Every entry of the five shared types that was not adopted was
      -- offered; the stand-in holds it unless its mask lacks this client.
      local offered, adoptedSkipped = 0, 0
      for _, mediaType in ipairs(LIBSHAREDMEDIA_TYPES) do
        local hash = library:HashTable(mediaType)
        for _, name in ipairs(MediaKit:List(mediaType, ANY_SCRIPT)) do
          local record = entryRecord(mediaType, name)
          if record.origin == "libSharedMedia" then
            adoptedSkipped = adoptedSkipped + 1
            ctx:Expect(library.registered[mediaType][name]):ToBe(nil)
          else
            offered = offered + 1
            ctx:Expect(library.registered[mediaType][name]):ToBe(true)
            local langmask = library.langmasks[mediaType][name]
            if mediaType ~= "font" or hasBit(langmask, clientLocaleBit()) then
              ctx:Expect(hash[name]):ToBe(record.data)
            end
          end
        end
      end
      ctx:Log(
        ("%d entries offered, %d adopted ones not mirrored back"):format(offered, adoptedSkipped)
      )

      ctx
        :Expect(library.langmasks.font[wideFont])
        :ToBe(LIBSHAREDMEDIA_WESTERN_BIT + LIBSHAREDMEDIA_CYRILLIC_BIT)
      ctx:Expect(library.langmasks.font[plainFont]):ToBe(LIBSHAREDMEDIA_WESTERN_BIT)
      ctx:Expect(library.langmasks.font[greekFont]):ToBe(0)
      ctx:Expect(library:HashTable("font")[greekFont]):ToBe(nil)
      local builtinMask = library.langmasks.font["Friz Quadrata TT"]
      ctx:Expect(builtinMask):ToBe(
        clientScript() == "cyrillic" and LIBSHAREDMEDIA_WESTERN_BIT + LIBSHAREDMEDIA_CYRILLIC_BIT
          or LIBSHAREDMEDIA_WESTERN_BIT
      )

      local seenInLibrary = {}
      trackConnection(MediaKit:OnRegistered("statusbar", function(_, name)
        seenInLibrary[#seenInLibrary + 1] = library:HashTable("statusbar")[name]
      end))
      local later = uniqueName("Bar mirrored")
      ctx:Expect(MediaKit:Register("statusbar", later, BAR_TEXTURE)):ToBe(true)
      ctx:Expect(seenInLibrary):ToEqual({ BAR_TEXTURE })

      -- Both directions on: the adoption finds everything present already.
      ctx:Expect({ MediaKit:AdoptLibSharedMedia() }):ToEqual({ true, 0 })
      local both = uniqueName("Bar both")
      ctx:Expect(MediaKit:Register("statusbar", both, SOLID_TEXTURE)):ToBe(true)
      ctx:Expect(#seenInLibrary):ToBe(2)
      ctx:Expect(seenInLibrary[2]):ToBe(SOLID_TEXTURE)
      ctx:Expect(entryRecord("statusbar", both).origin):ToBe("registered")

      ctx:Expect({ MediaKit:MirrorToLibSharedMedia() }):ToEqual({ true, 0 })
    end)
    ctx:Expect(rawget(bridgeState(), "mirrorTarget")):ToBe(false)
  end
)

-- mediaKit.allocation ------------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "Fetch of a status bar and of a font, anyScript Fetch and Has allocate nothing over 2000 calls each",
  function(ctx)
    expectNoAllocation(ctx, "Fetch of the Blizzard status bar", function()
      MediaKit:Fetch("statusbar", "Blizzard")
    end)
    expectNoAllocation(ctx, "Fetch of Friz Quadrata TT", function()
      MediaKit:Fetch("font", "Friz Quadrata TT")
    end)
    expectNoAllocation(ctx, "Fetch of Morpheus with anyScript", function()
      MediaKit:Fetch("font", "Morpheus", ANY_SCRIPT)
    end)
    expectNoAllocation(ctx, "Has of the None border and of a missing name", function()
      MediaKit:Has("border", "None")
      MediaKit:Has("statusbar", "MoltenCodesTest never registered")
    end)
  end
)

allocation:Test(
  "List of an unchanged type, List('font') with and without anyScript and defaults:Get allocate nothing over 2000 calls each",
  function(ctx)
    local defaultsA = MediaKit:Defaults(CONSUMER_A)
    expectNoAllocation(ctx, "List of status bars", function()
      MediaKit:List("statusbar")
    end)
    expectNoAllocation(ctx, "List of fonts, filtered and not", function()
      MediaKit:List("font")
      MediaKit:List("font", ANY_SCRIPT)
    end)
    expectNoAllocation(ctx, "defaults:Get of a font and a status bar", function()
      defaultsA:Get("font")
      defaultsA:Get("statusbar")
    end)
  end
)

-- mediaKit.errors ----------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "Register with the type 'statusBar', an empty name, a zero FileDataID, scripts on a status bar and an unknown script is refused at the calling line with docs/API.md's wording",
  function(ctx)
    local name = uniqueName("Refused")
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        MediaKit:Register("statusBar", name, SOLID_TEXTURE)
      end,
      lines,
      'MediaKit:Register type must be one of "background", "border", "font", "icon", "sound", "statusbar", "texture"'
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Register("statusbar", "", SOLID_TEXTURE)
    end, lines, "MediaKit:Register name must be a non-empty string")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        MediaKit:Register("statusbar", name, 0)
      end,
      lines,
      "MediaKit:Register data must be a non-empty file path or a FileDataID (a positive integer)"
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Register("statusbar", name, SOLID_TEXTURE, { scripts = { "latin" } })
    end, lines, "MediaKit:Register scripts applies to fonts only")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Register("font", name, TEST_FONT, { scripts = { "latin", "klingon" } })
    end, lines, 'MediaKit:Register scripts contains unknown script "klingon"')
    ctx:Expect(MediaKit:Has("statusbar", name, ANY_SCRIPT)):ToBe(false)
    ctx:Expect(MediaKit:Has("font", name, ANY_SCRIPT)):ToBe(false)
  end
)

errors:Test(
  "Fetch of a nil name, List with an unknown option field and Has with anyScript 'yes' are refused at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Fetch("statusbar", nil)
    end, lines, "MediaKit:Fetch name must be a non-empty string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:List("font", { anyscript = true })
    end, lines, 'MediaKit:List options contains unknown field "anyscript"')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Has("font", "Morpheus", { anyScript = "yes" })
    end, lines, "MediaKit:Has anyScript must be a boolean")
  end
)

errors:Test(
  "OnRegistered with a string callback, defaults.Get called with a dot and MediaKit.SetLimits called with a dot are refused at the calling line",
  function(ctx)
    local defaultsA = MediaKit:Defaults(CONSUMER_A)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:OnRegistered("font", "refresh")
    end, lines, "MediaKit:OnRegistered callback must be a function")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      defaultsA.Get("font")
    end, lines, "MediaKit.Defaults:Get must be called on a defaults object; use defaults:Get(...)")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        MediaKit.SetLimits({ maxConsumers = 8 })
      end,
      lines,
      "MediaKit:SetLimits must be called on the MediaKit facade; use MediaKit:SetLimits(...)"
    )
  end
)

errors:Test(
  "SetLimits with UNBOUNDED or 16385 for maxEntriesPerType and an unknown limit is refused at the calling line and the limits stay as they were",
  function(ctx)
    local before = MediaKit:GetLimits()
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        MediaKit:SetLimits({ maxEntriesPerType = MediaKit.UNBOUNDED })
      end,
      lines,
      "MediaKit:SetLimits limits.maxEntriesPerType cannot be MediaKit.UNBOUNDED: entries are never removed and are mirrored into LibSharedMedia"
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:SetLimits({ maxEntriesPerType = 16385 })
    end, lines, "MediaKit:SetLimits limits.maxEntriesPerType must be an integer from 1 to 16384")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:SetLimits({ maxEntries = 2048 })
    end, lines, "MediaKit:SetLimits limits.maxEntries is not a recognised limit")
    ctx:Expect(MediaKit:GetLimits()):ToEqual(before)
  end
)

-- mediaKit.secrets ---------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if SECRETS_AVAILABLE then
    secrets:Test(name, body)
  else
    secrets:Skip(name, SECRETS_SKIP_REASON)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
  local succeeded, secret = pcall(secretWrap, value)
  if not succeeded then
    ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
  end
  if isSecretValue(secret) ~= true then
    ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
  end
  return secret
end

secretTest(
  "Register refuses a secret type, name, data and script name at the calling line and registers nothing",
  function(ctx)
    local name = uniqueName("Secret")
    local lines = { start = 0 }
    local secretType = makeSecret(ctx, "statusbar")
    local secretName = makeSecret(ctx, name)
    local secretData = makeSecret(ctx, SOLID_TEXTURE)
    local secretScript = makeSecret(ctx, "latin")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Register(secretType, name, SOLID_TEXTURE)
    end, lines, "MediaKit:Register type must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Register("statusbar", secretName, SOLID_TEXTURE)
    end, lines, "MediaKit:Register name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Register("statusbar", name, secretData)
    end, lines, "MediaKit:Register data must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Register("font", name, TEST_FONT, { scripts = { "cyrillic", secretScript } })
    end, lines, "MediaKit:Register scripts must not contain a secret value")
    ctx:Expect(MediaKit:Has("statusbar", name)):ToBe(false)
    ctx:Expect(MediaKit:Has("font", name, ANY_SCRIPT)):ToBe(false)
  end
)

secretTest(
  "Fetch, Has and List refuse a secret name or a secret anyScript at the calling line, and OnRegistered a secret type",
  function(ctx)
    local lines = { start = 0 }
    local secretName = makeSecret(ctx, "Blizzard")
    local secretFlag = makeSecret(ctx, true)
    local secretType = makeSecret(ctx, "font")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Fetch("statusbar", secretName)
    end, lines, "MediaKit:Fetch name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Has("statusbar", secretName)
    end, lines, "MediaKit:Has name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Fetch("font", "Morpheus", { anyScript = secretFlag })
    end, lines, "MediaKit:Fetch anyScript must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Has("font", "Morpheus", { anyScript = secretFlag })
    end, lines, "MediaKit:Has anyScript must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:List("font", { anyScript = secretFlag })
    end, lines, "MediaKit:List anyScript must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:OnRegistered(secretType, function() end)
    end, lines, "MediaKit:OnRegistered type must not be a secret value")
  end
)

secretTest(
  "Defaults refuses a secret consumer name, defaults:Set a secret name and defaults:Get a secret type, at the calling line",
  function(ctx)
    local defaultsA = MediaKit:Defaults(CONSUMER_A)
    local lines = { start = 0 }
    local secretConsumer = makeSecret(ctx, CONSUMER_B)
    local secretName = makeSecret(ctx, "Solid")
    local secretType = makeSecret(ctx, "statusbar")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:Defaults(secretConsumer)
    end, lines, "MediaKit:Defaults consumerName must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      defaultsA:Set("statusbar", secretName)
    end, lines, "MediaKit.Defaults:Set name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      defaultsA:Get(secretType)
    end, lines, "MediaKit.Defaults:Get type must not be a secret value")
    ctx:Expect(defaultsA:Get("statusbar")):ToBe("Blizzard")
  end
)

secretTest(
  "SetLimits refuses a secret maxConsumers at the calling line and the limits stay as they were, and IsFileDataID answers false for a secret FileDataID",
  function(ctx)
    local before = MediaKit:GetLimits()
    local lines = { start = 0 }
    local secretCount = makeSecret(ctx, 2048)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      MediaKit:SetLimits({ maxConsumers = secretCount })
    end, lines, "MediaKit:SetLimits limits.maxConsumers must not be a secret value")
    ctx:Expect(MediaKit:GetLimits()):ToEqual(before)
    local secretFileID = makeSecret(ctx, 569593)
    local succeeded, answer = pcall(MediaKit.IsFileDataID, MediaKit, secretFileID)
    ctx:Expect(succeeded):ToBe(true)
    ctx:Expect(answer):ToBe(false)
    ctx:Expect(MediaKit:IsFileDataID(569593)):ToBe(true)
  end
)

secretTest(
  "with a stand-in LibSharedMedia, a secret entry is not adopted, a callback with a secret type and name raises nothing, a secret LOCALE_BIT_western gives way to 128 and a secret Register answer is not counted as mirrored",
  function(ctx)
    local prefix = uniqueName("LSM secret")
    local plain = prefix .. " Plain"
    local hidden = prefix .. " Hidden"
    local fontName = uniqueName("Font undeclared")
    ctx:Expect(MediaKit:Register("font", fontName, TEST_FONT)):ToBe(true)
    local media = {
      statusbar = { [plain] = SOLID_TEXTURE, [hidden] = makeSecret(ctx, SOLID_TEXTURE) },
    }
    withStandIn(
      ctx,
      { media = media, secretAnswer = true, secretWesternBit = true },
      function(library)
        ctx:Expect({ MediaKit:AdoptLibSharedMedia() }):ToEqual({ true, 1 })
        ctx:Expect(MediaKit:Has("statusbar", plain)):ToBe(true)
        ctx:Expect(MediaKit:Has("statusbar", hidden)):ToBe(false)

        local secretType = makeSecret(ctx, "statusbar")
        local secretKey = makeSecret(ctx, prefix .. " Fired")
        local fired, problem = pcall(library.FireRegistered, secretType, secretKey)
        if not fired then
          ctx:Log("the callback raised: " .. tostring(problem))
        end
        ctx:Expect(fired):ToBe(true)

        local found, mirrored = MediaKit:MirrorToLibSharedMedia()
        ctx:Expect(found):ToBe(true)
        ctx:Expect(mirrored):ToBe(0)
        ctx:Log(("the stand-in accepted %d entries, every answer secret"):format(library.accepted))
        ctx:Expect(library.accepted > 0):ToBe(true)
        ctx:Expect(library.langmasks.font[fontName]):ToBe(LIBSHAREDMEDIA_WESTERN_BIT)
      end
    )
  end
)

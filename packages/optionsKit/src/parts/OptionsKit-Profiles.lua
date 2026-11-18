-- MoltenCodes OptionsKit part Profiles
--
-- `OptionsKit:ProfileOptions(db, options?)`: the ready-made group AceDBOptions
-- gives an AceDB database, built over a SettingsKit database from the
-- ordinary option kinds, so every renderer shows it without knowing what a
-- profile is. One group per database and options, cached; with SettingsKit
-- revision 11 and later it also carries one profile choice per
-- specialization. `docs/API.md`, *Profile options*, is the contract.
--
-- The part needs OptionsKit's core loaded first (revision 15 or later). Part
-- revision 2 also holds the links that connect a group to the tree `Define`
-- places it in, which core revision 16 calls through its hooks
-- (`Hints.collectProfileLink`, `Hints.attachLinks`); a revision 15 core still
-- attaches links itself and has no such hooks. The core keeps the group map
-- `state.profileGroups` and a detach for `Undefine`. Without this part,
-- `OptionsKit:ProfileOptions` raises at the caller's line and names this file
-- (ADR 0001, point 5).
--
-- Contents
-- --------
--   Constants ........ identity
--   Dependencies ..... OptionsKit's core, its state and the helpers it lends
--   Profile options .. the group, its strings, choices and spec selects
--   Profile links .... a group's link to its tree: collect, attach
--   Commit ........... the facade member and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Profiles"
local PART_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "optionsKit", 1

-- The option kinds the group is built from.
local KIND_GROUP = "group"
local KIND_SELECT = "select"
local KIND_INPUT = "input"
local KIND_EXECUTE = "execute"
local KIND_DESCRIPTION = "description"

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local OptionsKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  OptionsKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(OptionsKit) == "table" and rawget(OptionsKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes OptionsKit part Profiles requires OptionsKit API 1 to be loaded first", 2)
end
---@cast OptionsKit table

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every addon.
  return OptionsKit
end

-- The core's state the groups live in, taken by `bind`: a core upgrade may
-- create a table an older core lacked (revision 8's group cache).
local profileGroups, profileLinksByDatabase

-- The core's helpers, assigned by `bind` below: at load, and again whenever a
-- newer core revision loads, so this part always runs the newest helpers with
-- no lookup per call.
local isSecret, isDatabaseReadOnly, findSettingsKit
local checkOptionalString, checkNumber, checkOptionalFunction
-- The whole helpers table, for the link functions defined below `bind`.
local linkHelpers
-- The link functions, defined in "Profile links" below and installed by
-- `bind` as the core's hooks.
local collectProfileLink, attachLinks

---Take the core's helpers. Called by this file and by every newer core.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  profileGroups = rawget(state, "profileGroups")
  profileLinksByDatabase = rawget(state, "profileLinksByDatabase")
  isSecret = helpers.isSecret
  isDatabaseReadOnly = helpers.isDatabaseReadOnly
  findSettingsKit = helpers.findSettingsKit
  checkOptionalString = helpers.checkOptionalString
  checkNumber = helpers.checkNumber
  checkOptionalFunction = helpers.checkOptionalFunction
  linkHelpers = helpers
  -- A revision 16 core or later publishes `Hints`; the links are its hooks.
  local Hints = helpers.Hints
  if type(Hints) == "table" then
    Hints.collectProfileLink = collectProfileLink
    Hints.attachLinks = attachLinks
    Hints.detachProfileLink = helpers.detachProfileLink
  end
end

-- Profile options ------------------------------------------------------------
--
-- `OptionsKit:ProfileOptions(db, options)` builds the group AceDBOptions gives
-- an AceDB database, over a SettingsKit database: choose the current profile,
-- create one, copy another one's settings into it, reset it, delete one. It is
-- built from the existing kinds only (`description`, `select`, `input` and
-- `execute`), so every renderer shows it without knowing what a profile is.
--
-- The group's callbacks close over one *link* record: the database, the
-- SettingsKit facade, the translation hook, the profiles chosen for copying
-- and deleting, and — once `Define` has placed the group in a tree — that tree
-- and the group's path in it. While a tree holds the group, the link is
-- connected to the database's four profile signals and fires the tree's
-- `OnChange` on each, so a renderer redraws after a switch made elsewhere;
-- `Undefine` disconnects them. The group table is the key of
-- `state.profileGroups`, which is how `Define` finds the link. Revision 8
-- caches the link, and so the group, per database in
-- `state.profileLinksByDatabase`, as AceDBOptions keeps one group per database;
-- since revision 9 a call with other options replaces the cached link.

-- The methods the group calls on the database. Checked structurally, as
-- `options.db` is: SettingsKit API 1 publishes no predicate for its databases.
local PROFILE_DATABASE_METHODS = {
  "GetProfile",
  "SetProfile",
  "GetProfiles",
  "CopyProfile",
  "ResetProfile",
  "DeleteProfile",
  "OnProfileChanged",
  "OnProfileCopied",
  "OnProfileReset",
  "OnProfileDeleted",
}

-- The complete set of fields `ProfileOptions` options accept.
local PROFILE_OPTION_KEYS = { name = true, order = true, description = true, localize = true }
-- The same fields in a fixed order, so the secret refusal names the same field
-- whatever the hash order of the options table.
local PROFILE_OPTION_FIELDS = { "name", "order", "description", "localize" }

-- Every user-visible string of the profile group, by the key the `localize`
-- hook receives, in English. `%s` stands for the current profile's name in
-- quotes, except in `new.long`, where it is the byte limit.
local PROFILE_STRINGS = {
  ["group.name"] = "Profiles",
  ["group.desc"] = "This character uses the profile %s.",
  ["intro"] = "Profiles keep separate sets of settings. Choose the one this character uses, "
    .. "create a new one, copy another profile's settings into it, reset it, or delete one "
    .. "you no longer need.",
  ["current.name"] = "Current profile",
  ["current.desc"] = "The profile this character uses, now %s. Choosing a name that has no "
    .. "profile yet creates an empty one.",
  ["new.name"] = "New profile",
  ["new.desc"] = "Type a name to create an empty profile and switch to it. The name of an "
    .. "existing profile switches to that profile.",
  ["new.usage"] = "<profile name>",
  ["new.blank"] = "a profile name needs a character other than whitespace",
  ["new.long"] = "a profile name has at most %s bytes",
  ["copySource.name"] = "Copy from",
  ["copySource.desc"] = "The profile whose settings replace those of %s when you copy.",
  ["copy.name"] = "Copy",
  ["copy.desc"] = "Replace every setting of %s with a copy of the profile chosen above.",
  ["copy.confirm"] = "Replace the current profile's settings with a copy of the chosen profile?",
  ["reset.name"] = "Reset profile",
  ["reset.desc"] = "Return every setting of %s to its default.",
  ["reset.confirm"] = "Reset the current profile to its defaults?",
  ["deleteTarget.name"] = "Delete",
  ["deleteTarget.desc"] = "A profile other than %s, to delete.",
  ["delete.name"] = "Delete profile",
  ["delete.desc"] = "Delete the profile chosen above. Characters that used it start on the "
    .. "default profile next time.",
  ["delete.confirm"] = "Delete the chosen profile? Its settings cannot be recovered.",
  -- Revision 11, spec profiles. In `spec.name` and `spec.desc`, `%s` is the
  -- specialization's name or the `spec.specialization` / `spec.talentGroup`
  -- label; in those two, it is the index.
  ["specs.intro"] = "Choose a profile for each specialization. This character switches to it "
    .. "by itself when the specialization changes; None keeps the profile in use.",
  ["spec.name"] = "Profile for %s",
  ["spec.desc"] = "The profile this character switches to in %s.",
  ["spec.none"] = "None",
  ["spec.specialization"] = "specialization %s",
  ["spec.talentGroup"] = "talent group %s",
}

-- Revision 11: the most spec-profile selects the group carries, SettingsKit's
-- highest assignable spec index. Each is hidden unless the character has that
-- many indexes, so a renderer shows exactly one per specialization.
local MAX_SPEC_OPTIONS = 8

-- The `select` key meaning "no assignment". SettingsKit refuses a profile
-- name without a character other than whitespace, so it is never a profile.
local NO_SPEC_PROFILE = ""

-- The keys of the group's options, so the paths built at attach and the
-- messages that name them agree.
local PROFILE_KEY_CURRENT = "current"
local PROFILE_KEY_COPY_SOURCE = "copySource"
local PROFILE_KEY_DELETE_TARGET = "deleteTarget"

---Refuse anything but a table offering every method the group calls.
---@param db any
---@param label string
---@param level integer
local function validateProfileDatabase(db, label, level)
  if type(db) ~= "table" then
    error(label .. " must be a SettingsKit database", level)
  end
  for index = 1, #PROFILE_DATABASE_METHODS do
    if type(db[PROFILE_DATABASE_METHODS[index]]) ~= "function" then
      error(label .. " must be a SettingsKit database", level)
    end
  end
end

---Check the `ProfileOptions` options and return their four values, `false`
---for each one absent. Returns values rather than filling a record, so a call
---answered from the cache allocates nothing.
---@param options any
---@param level integer
---@return string|false name
---@return number|false order
---@return string|false description
---@return function|false localize
local function readProfileOptions(options, level)
  if type(options) == "nil" then
    return false, false, false, false
  end
  if type(options) ~= "table" then
    error("OptionsKit:ProfileOptions options must be a table", level)
  end
  local firstUnknown = nil
  for key in pairs(options) do
    if PROFILE_OPTION_KEYS[key] ~= true then
      local text = type(key) == "string" and key or "<" .. type(key) .. " key>"
      if firstUnknown == nil or text < firstUnknown then
        firstUnknown = text
      end
    end
  end
  if firstUnknown ~= nil then
    error(
      'OptionsKit:ProfileOptions options contains unknown field "' .. firstUnknown .. '"',
      level
    )
  end
  -- Refused before the checks below compare them or test them for truth,
  -- which raises inside OptionsKit for a secret (Retail 12.x).
  for index = 1, #PROFILE_OPTION_FIELDS do
    local field = PROFILE_OPTION_FIELDS[index]
    if isSecret(rawget(options, field)) then
      error("OptionsKit:ProfileOptions options." .. field .. " must not be a secret value", level)
    end
  end
  checkOptionalString(
    rawget(options, "name"),
    "OptionsKit:ProfileOptions options",
    "name",
    level + 1
  )
  local order = rawget(options, "order")
  if type(order) ~= "nil" then
    checkNumber(order, "OptionsKit:ProfileOptions options", "order", level + 1)
  end
  checkOptionalString(
    rawget(options, "description"),
    "OptionsKit:ProfileOptions options",
    "description",
    level + 1
  )
  checkOptionalFunction(
    rawget(options, "localize"),
    "OptionsKit:ProfileOptions options",
    "localize",
    level + 1
  )
  return rawget(options, "name") or false,
    order or false,
    rawget(options, "description") or false,
    rawget(options, "localize") or false
end

---The text for `key`: the hook's answer when it is a string, else the English
---default.
---@param link table
---@param key string
---@return string
local function translate(link, key)
  local default = PROFILE_STRINGS[key]
  local localize = link.localize
  if localize then
    local text = localize(key, default)
    if type(text) == "string" then
      return text
    end
  end
  return default
end

---Put `value` where `template` says `%s`. A function replacement, so a `%` in
---a profile name is never read as a `gsub` capture.
---@param template string
---@param value string
---@return string
local function fill(template, value)
  return (template:gsub("%%s", function()
    return value
  end))
end

---The text for `key` with the current profile's name, quoted, filled in.
---@param link table
---@param key string
---@return string
local function withCurrentProfile(link, key)
  return fill(translate(link, key), '"' .. link.db:GetProfile() .. '"')
end

---The per-character profile name SettingsKit builds, `"<name> - <realm>"`, or
---`false` when the client does not know the player. Read once, at
---`ProfileOptions`, the way SettingsKit reads it once at `Open`.
---@return string|false
local function readCharacterProfile()
  -- UnitName and GetRealmName are World of Warcraft client APIs reachable only through the global table.
  -- selene: allow(global_usage)
  local unitName = rawget(_G, "UnitName")
  -- selene: allow(global_usage)
  local getRealmName = rawget(_G, "GetRealmName")
  if type(unitName) ~= "function" or type(getRealmName) ~= "function" then
    return false
  end
  local name = unitName("player")
  local realm = getRealmName()
  if isSecret(name) or isSecret(realm) then
    return false
  end
  if type(name) ~= "string" or name == "" or type(realm) ~= "string" or realm == "" then
    return false
  end
  return name .. " - " .. realm
end

---The choices of the current-profile select: every profile, the current one
---(which `GetProfiles` always includes, so a fresh database shows the default
---it was opened with) and this character's own profile, which a switch
---creates. SettingsKit's own default profile is not offered by name: a
---database opened with another `defaultProfile` never asked for it. Key and
---label are the name. Allocates, as `GetProfiles`.
---@param link table
---@return table<string, string>
local function currentChoices(link)
  local choices = {}
  local names = link.db:GetProfiles()
  for index = 1, #names do
    choices[names[index]] = names[index]
  end
  local current = link.db:GetProfile()
  choices[current] = current
  if link.characterProfile then
    choices[link.characterProfile] = link.characterProfile
  end
  return choices
end

---Every profile but the current one: what can be copied from or deleted.
---@param link table
---@return table<string, string>
local function otherChoices(link)
  local choices = {}
  local current = link.db:GetProfile()
  local names = link.db:GetProfiles()
  for index = 1, #names do
    local name = names[index]
    if name ~= current then
      choices[name] = name
    end
  end
  return choices
end

---Whether `name` is a profile that exists and is not the current one. Walks
---the name array `GetProfiles` returns rather than building a choice map, so
---the `disabled` predicates and the select getters allocate that array only.
---@param link table
---@param name any a profile name the group stored itself, or `false`
---@return boolean
local function isOtherProfile(link, name)
  if type(name) ~= "string" or name == link.db:GetProfile() then
    return false
  end
  local names = link.db:GetProfiles()
  for index = 1, #names do
    if names[index] == name then
      return true
    end
  end
  return false
end

---Whether the group's database refuses every profile change
---(`isDatabaseReadOnly`).
---@param link table
---@return boolean
local function isReadOnly(link)
  return isDatabaseReadOnly(link.db)
end

---The `disabled` predicate of every option that changes the database: a
---renderer greys them out while the database is read-only instead of offering
---a change SettingsKit would refuse.
---@param link table
---@return fun(): boolean
local function disabledWhileReadOnly(link)
  return function()
    return isReadOnly(link)
  end
end

---Switch the database to `name` without the link's own listener firing the
---tree: `Set` fires `OnChange` for this write itself. The flag is restored to
---what it was, not cleared, so a switch made from a listener of an outer
---switch leaves the outer one suppressed until it returns; it is restored
---even when SettingsKit or one of its listeners raises, and the error then
---propagates as it is.
---@param link table
---@param name string
local function switchProfile(link, name)
  local db = link.db
  local outer = link.suppress
  link.suppress = true
  local switched, failure = pcall(db.SetProfile, db, name)
  link.suppress = outer
  if not switched then
    error(failure, 0)
  end
end

---The check the new-profile input runs: SettingsKit's own rules for a profile
---name, answered as a message instead of an error, so an edit box can show it.
---@param link table
---@param name string
---@return boolean accepted
---@return string|nil message
local function validateNewProfileName(link, name)
  if not name:find("%S") then
    return false, translate(link, "new.blank")
  end
  local maxLength = link.SettingsKit:GetLimits().maxProfileNameLength
  if #name > maxLength then
    return false, fill(translate(link, "new.long"), tostring(maxLength))
  end
  return true, nil
end

---Raise, at the caller of `Execute`, for a button pressed before its select
---was set: a renderer that honours `disabled` never gets here.
---@param info OptionsKit.Info
---@param selectKey string
local function refuseUnchosen(info, selectKey)
  local parentPath = info.path:match("^(.*)%.[^.]+$") or ""
  local selectPath = parentPath == "" and selectKey or parentPath .. "." .. selectKey
  -- refuseUnchosen <- func <- Execute <- the caller
  error(
    "OptionsKit.Tree:Execute " .. info.path .. ' needs "' .. selectPath .. '" to be set first',
    4
  )
end

-- Spec profiles (revision 11) ------------------------------------------------
--
-- The LibDualSpec-1.0 `EnhanceOptions` counterpart: one select per spec index
-- over SettingsKit's `db:SetSpecProfile` and `db:GetSpecProfile`, shown while
-- `SettingsKit:GetSpecIndex()` says the character has more than one index.
-- Added only when the database and the SettingsKit facade offer those methods
-- (SettingsKit revision 11 and later); an older SettingsKit gets the group
-- without them.

---Whether the link's database and SettingsKit support spec profiles.
---@param link table
---@return boolean
local function supportsSpecProfiles(link)
  local db = link.db
  -- Since SettingsKit split spec profiles into its SpecProfiles part, the
  -- facade and the database carry stubs that raise while the part is not
  -- loaded, so the part is asked first (part revision 2). A SettingsKit
  -- without `HasPart` holds spec profiles in its core, when it has them.
  local hasPart = rawget(link.SettingsKit, "HasPart")
  if type(hasPart) == "function" and hasPart(link.SettingsKit, "SpecProfiles") ~= true then
    return false
  end
  return type(rawget(link.SettingsKit, "GetSpecIndex")) == "function"
    and type(db.SetSpecProfile) == "function"
    and type(db.GetSpecProfile) == "function"
end

---The name the client gives specialization `index` of the player's class, or
---`nil`. Read once, when the group is built: class specialization names need
---no player data.
---@param index integer
---@return string|nil
local function readSpecializationName(index)
  -- UnitClass and GetSpecializationInfoForClassID are World of Warcraft client APIs reachable only through the global table.
  -- selene: allow(global_usage)
  local unitClass = rawget(_G, "UnitClass")
  -- selene: allow(global_usage)
  local infoForClass = rawget(_G, "GetSpecializationInfoForClassID")
  if type(unitClass) ~= "function" or type(infoForClass) ~= "function" then
    return nil
  end
  local classID = select(3, unitClass("player"))
  if isSecret(classID) or type(classID) ~= "number" then
    return nil
  end
  local _, name = infoForClass(classID, index)
  if isSecret(name) or type(name) ~= "string" or name == "" then
    return nil
  end
  return name
end

---The label of spec index `index`: the specialization's name, or the
---translated `spec.specialization` / `spec.talentGroup` label with the index.
---@param link table
---@param kind string `SettingsKit:GetSpecIndex()`'s third answer
---@param index integer
---@return string
local function specLabel(link, kind, index)
  if kind == "specialization" then
    local name = readSpecializationName(index)
    if name ~= nil then
      return name
    end
    return fill(translate(link, "spec.specialization"), tostring(index))
  end
  return fill(translate(link, "spec.talentGroup"), tostring(index))
end

---How many spec indexes this character has now; `0` when unknown.
---@param link table
---@return integer
local function specCount(link)
  local _, count = link.SettingsKit:GetSpecIndex()
  if isSecret(count) or type(count) ~= "number" then
    return 0
  end
  return count
end

---Add the spec-profile description and selects to `args`.
---@param link table
---@param args table the group's `args`, typed loosely as `buildProfileArgs` builds it
---@param whileReadOnly fun(): boolean
local function addSpecProfileArgs(link, args, whileReadOnly)
  local db = link.db
  local _, _, kind = link.SettingsKit:GetSpecIndex()
  args.specs = {
    type = KIND_DESCRIPTION,
    name = translate(link, "specs.intro"),
    order = 9,
    hidden = function()
      return specCount(link) < 2
    end,
  }
  for index = 1, MAX_SPEC_OPTIONS do
    local label = specLabel(link, kind, index)
    args["spec" .. index] = {
      type = KIND_SELECT,
      name = fill(translate(link, "spec.name"), label),
      desc = fill(translate(link, "spec.desc"), label),
      order = 9 + index,
      disabled = whileReadOnly,
      hidden = function()
        local count = specCount(link)
        return count < 2 or index > count
      end,
      -- Every profile, the one assigned to this index (which a deletion
      -- elsewhere may have left without a profile table) and None.
      values = function()
        local choices = currentChoices(link)
        local assigned = db:GetSpecProfile(index)
        if assigned ~= nil then
          choices[assigned] = assigned
        end
        choices[NO_SPEC_PROFILE] = translate(link, "spec.none")
        return choices
      end,
      get = function()
        return db:GetSpecProfile(index) or NO_SPEC_PROFILE
      end,
      set = function(_, name)
        if name == NO_SPEC_PROFILE then
          db:SetSpecProfile(index, nil)
        else
          db:SetSpecProfile(index, name)
        end
      end,
    }
  end
end

---Build the group's options. Every callback closes over `link` only, so the
---group works in whichever tree `Define` places it.
---@param link table
---@return table<string, OptionsKit.Option> args
local function buildProfileArgs(link)
  local db = link.db
  -- One predicate for the five options that change the database.
  local whileReadOnly = disabledWhileReadOnly(link)
  -- One values function for the copy and delete selects.
  local function otherProfiles()
    return otherChoices(link)
  end
  local args = {
    intro = {
      type = KIND_DESCRIPTION,
      name = link.description or translate(link, "intro"),
      fontSize = "medium",
      order = 1,
    },
    [PROFILE_KEY_CURRENT] = {
      type = KIND_SELECT,
      name = translate(link, "current.name"),
      desc = function()
        return withCurrentProfile(link, "current.desc")
      end,
      order = 2,
      disabled = whileReadOnly,
      values = function()
        return currentChoices(link)
      end,
      get = function()
        return db:GetProfile()
      end,
      set = function(_, name)
        switchProfile(link, name)
      end,
    },
    new = {
      type = KIND_INPUT,
      name = translate(link, "new.name"),
      desc = translate(link, "new.desc"),
      usage = translate(link, "new.usage"),
      order = 3,
      disabled = whileReadOnly,
      get = function()
        return ""
      end,
      validate = function(_, name)
        return validateNewProfileName(link, name)
      end,
      -- Not suppressed: the current profile changed, so the link fires
      -- `current` as for any other switch, beside `Set`'s own `new`.
      set = function(_, name)
        db:SetProfile(name)
      end,
    },
    [PROFILE_KEY_COPY_SOURCE] = {
      type = KIND_SELECT,
      name = translate(link, "copySource.name"),
      desc = function()
        return withCurrentProfile(link, "copySource.desc")
      end,
      order = 4,
      disabled = whileReadOnly,
      values = otherProfiles,
      get = function()
        return isOtherProfile(link, link.copySource) and link.copySource or nil
      end,
      set = function(_, name)
        link.copySource = name
      end,
    },
    copy = {
      type = KIND_EXECUTE,
      name = translate(link, "copy.name"),
      desc = function()
        return withCurrentProfile(link, "copy.desc")
      end,
      confirm = translate(link, "copy.confirm"),
      order = 5,
      disabled = function()
        return isReadOnly(link) or not isOtherProfile(link, link.copySource)
      end,
      func = function(info)
        local source = link.copySource
        if not isOtherProfile(link, source) then
          refuseUnchosen(info, PROFILE_KEY_COPY_SOURCE)
        end
        db:CopyProfile(source)
      end,
    },
    reset = {
      type = KIND_EXECUTE,
      name = translate(link, "reset.name"),
      desc = function()
        return withCurrentProfile(link, "reset.desc")
      end,
      confirm = translate(link, "reset.confirm"),
      order = 6,
      disabled = whileReadOnly,
      func = function()
        db:ResetProfile()
      end,
    },
    [PROFILE_KEY_DELETE_TARGET] = {
      type = KIND_SELECT,
      name = translate(link, "deleteTarget.name"),
      desc = function()
        return withCurrentProfile(link, "deleteTarget.desc")
      end,
      order = 7,
      disabled = whileReadOnly,
      values = otherProfiles,
      get = function()
        return isOtherProfile(link, link.deleteTarget) and link.deleteTarget or nil
      end,
      set = function(_, name)
        link.deleteTarget = name
      end,
    },
    delete = {
      type = KIND_EXECUTE,
      name = translate(link, "delete.name"),
      desc = translate(link, "delete.desc"),
      confirm = translate(link, "delete.confirm"),
      order = 8,
      disabled = function()
        return isReadOnly(link) or not isOtherProfile(link, link.deleteTarget)
      end,
      func = function(info)
        local target = link.deleteTarget
        if not isOtherProfile(link, target) then
          refuseUnchosen(info, PROFILE_KEY_DELETE_TARGET)
        end
        -- Forgotten first: the deletion fires the tree's `OnChange`,
        -- and a listener may choose the next target.
        link.deleteTarget = false
        db:DeleteProfile(target)
      end,
    },
  }
  if link.specProfiles then
    addSpecProfileArgs(link, args, whileReadOnly)
  end
  return args
end

-- The database methods a link connects to, in connection order.

---The link of the group last built for `db`, when it was built with exactly
---these options, or `nil`. The option values were checked by
---`readProfileOptions` (none is a secret), so comparing them is safe;
---`localize` is compared by identity.
---@param db table
---@param name string|false
---@param order number|false
---@param description string|false
---@param localize function|false
---@return table|nil link
local function findCachedProfileLink(db, name, order, description, localize)
  local link = rawget(profileLinksByDatabase, db)
  if
    link ~= nil
    and link.name == name
    and link.order == order
    and link.description == description
    and link.localize == localize
    -- A link an older revision built has no `specProfiles` field and no spec
    -- selects; it is replaced, as a link with other options is.
    and type(link.specProfiles) == "boolean"
    -- A link built while SettingsKit had no spec profiles is replaced once
    -- an in-place upgrade of SettingsKit added them (revision 12).
    and (link.specProfiles or not supportsSpecProfiles(link))
  then
    return link
  end
  return nil
end

---Build the group for a new link and remember it for `db`, replacing the link
---built there before: one link per database keeps the cache bounded however
---many option sets (or `localize` closures) the calls pass. A replaced group
---keeps working wherever it is still held.
---@param link table
---@return OptionsKit.Option group
local function buildProfileGroup(link)
  local group = {
    type = KIND_GROUP,
    name = link.name or translate(link, "group.name"),
    desc = function()
      return withCurrentProfile(link, "group.desc")
    end,
    args = buildProfileArgs(link),
  }
  if link.order then
    group.order = link.order
  end
  link.group = group
  rawset(profileGroups, group, link)
  rawset(profileLinksByDatabase, link.db, link)
  return group
end

---Return the ready-made options group over the profiles of a SettingsKit
---database, to place in a tree's `args`: one group per database and set of
---options, built on the first call and returned by every later one. See
---`docs/API.md`, *Profile options*.
---
---Every call runs every check (SettingsKit loaded, the database's methods,
---the options) before the cache is asked, so a cached answer never skips a
---refusal; a database that already has a group was checked when the group
---was built, and its methods come from SettingsKit's prototype, so its method
---probes are skipped (revision 13). A call answered from the cache allocates
---nothing.
---@param _ OptionsKit
---@param db table a SettingsKit API 1 database
---@param options OptionsKit.ProfileOptionsOptions?
---@return OptionsKit.Option group
local function profileOptions(_, db, options)
  local SettingsKit = findSettingsKit()
  if SettingsKit == nil then
    error("OptionsKit:ProfileOptions needs SettingsKit API 1 to be loaded", 2)
  end
  if type(db) ~= "table" or rawget(profileLinksByDatabase, db) == nil then
    validateProfileDatabase(db, "OptionsKit:ProfileOptions db", 3)
  end
  local name, order, description, localize = readProfileOptions(options, 3)

  local cached = findCachedProfileLink(db, name, order, description, localize)
  if cached ~= nil then
    -- A group built before the client knew the player learns this
    -- character's profile now, as a fresh group would have. Once known, the
    -- name and realm do not change within a session, so it is not read again.
    if not cached.characterProfile then
      cached.characterProfile = readCharacterProfile()
    end
    return cached.group
  end

  local link = {
    db = db,
    SettingsKit = SettingsKit,
    characterProfile = readCharacterProfile(),
    -- The `ProfileOptions` options, `false` when absent; with `db`, the
    -- key the group is cached under.
    name = name,
    order = order,
    description = description,
    localize = localize,
    -- The group built for this link (revision 8).
    group = false,
    -- The profiles chosen in the copy and delete selects, `false` for none.
    -- Shared by every caller the cached group is returned to; `Undefine`
    -- forgets them.
    copySource = false,
    deleteTarget = false,
    -- `true` while the group's own `Set` switches the profile.
    suppress = false,
    -- Set by `attachProfileLink`, cleared by `detachProfileLink`.
    tree = false,
    connections = false,
    -- Revision 11: whether the group carries the spec-profile selects.
    specProfiles = false,
  }
  link.specProfiles = supportsSpecProfiles(link)
  return buildProfileGroup(link)
end

-- Profile links --------------------------------------------------------------
--
-- Part revision 2 (core revision 16): the links that connect a group to the
-- tree `Define` places it in moved here from the core. The core calls them
-- through three hooks this part fills when it binds (`Hints.collectProfileLink`,
-- `Hints.attachLinks`, `Hints.detachProfileLink`); it keeps a detach of its
-- own for links any revision attached.

-- The database methods a link connects to, in connection order.
local PROFILE_SIGNAL_METHODS =
  { "OnProfileChanged", "OnProfileCopied", "OnProfileReset", "OnProfileDeleted" }

---Disconnect every connection in `connections`.
---@param connections table
local function disconnectAll(connections)
  for index = 1, #connections do
    connections[index]:Disconnect()
  end
end

---Attach `link` to the tree `Define` placed its group in, at `path`: connect
---the database's profile signals, then record the tree. Each signal fires the
---tree's `OnChange` with the current-profile option's path and the current
---profile's name — unless the group's own `current` is switching, which
---fires by itself. A connect that raises (a database that is not SettingsKit's
---after all) undoes the connections made before it and leaves the link free,
---so the error reaches the caller of `Define` without a stuck group.
---@param link table
---@param tree OptionsKit.Tree
---@param path string the group's path, `""` when the group is the root
local function attachProfileLink(link, tree, path)
  local currentPath = path == "" and PROFILE_KEY_CURRENT or path .. "." .. PROFILE_KEY_CURRENT
  local db = link.db
  local function notify()
    if link.suppress then
      return
    end
    rawget(tree, "_changed"):Fire(tree, currentPath, db:GetProfile())
  end
  local connections = {}
  for index = 1, #PROFILE_SIGNAL_METHODS do
    local connected, result = pcall(db[PROFILE_SIGNAL_METHODS[index]], db, notify)
    if not connected then
      disconnectAll(connections)
      error(result, 0)
    end
    connections[index] = result
  end
  link.connections = connections
  link.tree = tree
  -- Revision 15: where the group sits, so `Remove` of a group above it
  -- detaches it. Links an older revision attached have no path.
  link.path = path
end

---When `spec` is a group `ProfileOptions` returned, remember its link and
---the path it lands at, so `define` can attach it once the whole tree is
---built. A group already defined in a tree, or appearing twice in this one,
---is refused: its link carries the chosen profiles and the tree it notifies,
---which cannot be shared.
---@param context table
---@param spec table
---@param path string
---@param record table
---@param level integer
collectProfileLink = function(context, spec, path, record, level)
  local link = rawget(profileGroups, spec)
  if link == nil then
    return
  end
  -- A rebuild or a `Replace` (revision 15) meets the groups its own tree
  -- already holds, which stay attached.
  if link.tree and link.tree ~= context.rebuilding then
    error(
      linkHelpers.labelOf(record)
        .. ' is a profile group already defined in the tree of "'
        .. rawget(link.tree, "_addonName")
        .. '"; Undefine it first',
      level
    )
  end
  local links = context.profileLinks
  for index = 1, #links do
    if links[index] == link then
      error(
        linkHelpers.labelOf(record) .. " is a profile group that already appears in this tree",
        level
      )
    end
  end
  links[#links + 1] = link
  context.profilePaths[#links] = path
end

---Attach every link of `links` (at `paths`) that is not attached to `tree`
---yet. A link that fails to attach detaches the ones this call attached, and
---the error is raised again as it is.
---@param links table[]
---@param paths string[]
---@param tree OptionsKit.Tree
attachLinks = function(links, paths, tree)
  local attached = {}
  for index = 1, #links do
    local link = links[index]
    if link.tree ~= tree then
      local ok, failure = pcall(attachProfileLink, link, tree, paths[index])
      if not ok then
        for previous = 1, #attached do
          linkHelpers.detachProfileLink(attached[previous])
        end
        error(failure, 0)
      end
      attached[#attached + 1] = link
    end
  end
end

-- Commit ---------------------------------------------------------------------

bind(rawget(state, "helpers"))
rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
  members = { ProfileOptions = profileOptions },
})
rawset(OptionsKit, "ProfileOptions", profileOptions)

return OptionsKit

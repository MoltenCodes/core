--- Client identity and the flavour-dependent API surface.
---
--- Most of the fixture models one host: the globals every framework package
--- touches, identical whichever client they stand in for. This stub adds what
--- differs between clients — `WOW_PROJECT_ID`, `GetBuildInfo`, and the calls a
--- flavour has or lacks — as named **profiles**, one per supported flavour plus
--- one for a host that publishes no project id at all.
---
--- No profile is selected by default, and without one this stub installs
--- nothing: every suite that existed before profiles sees exactly the host it
--- always saw. A suite opts in with `FrameworkTestEnv.New{ wowProfile = name }`
--- or, per spec, `environment.SetWowProfile(name)` before `InstallWowApi`.
---
--- A profile is a model of the surface each client exposes, not a transcript
--- of it. It is chosen so that the four flavours between them exercise every
--- path a shim can take: the modern `C_*` call, the legacy global, and neither.
--- The interface numbers match `tooling/validation/supported_clients.json`; the
--- build numbers and dates are placeholders.
---
--- | Profile       | Project | Interface | Surface beyond the shared host |
--- |---------------|---------|-----------|--------------------------------|
--- | `mainline`    | 1       | 120100    | `issecretvalue`; `C_EventUtils`; `C_Spell`, `C_Item`, `C_SpellBook`; `C_AddOns.GetAddOnMetadata`; `UIParent` with `IsForbidden` and `CanBeAccessedInContext` |
--- | `mists`       | 19      | 50504     | as `mainline`, without `issecretvalue` and `CanBeAccessedInContext` |
--- | `tbc`         | 5       | 20506     | `C_EventUtils`; `C_Item`; `C_AddOns.GetAddOnMetadata`; legacy `GetSpellInfo`; `UIParent` with `IsForbidden` |
--- | `classic`     | 2       | 11509     | no `C_AddOns` (legacy `IsAddOnLoaded`, `GetAddOnMetadata`); legacy `GetSpellInfo`, `GetItemInfo`; no `C_EventUtils`; `UIParent` with `IsForbidden` |
--- | `noProjectId` | —       | —         | nothing: no `WOW_PROJECT_*`, no `GetBuildInfo` |
---
--- Every profile that publishes a project id also publishes the four
--- `WOW_PROJECT_*` constants of the supported flavours, as current clients do.
---
--- Host data the stubbed calls answer from — spells, items, addon metadata, the
--- set of valid event names and the set of secret values — is per environment
--- and reset with it. The helpers that change it are attached by `Attach`.

local ClientStub = {}

--- The `WOW_PROJECT_*` constants a profile with a project id publishes.
local PROJECT_CONSTANTS = {
    WOW_PROJECT_MAINLINE = 1,
    WOW_PROJECT_CLASSIC = 2,
    WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5,
    WOW_PROJECT_MISTS_CLASSIC = 19,
}

--- Every profile, by name. Each field names one piece of surface the profile
--- installs; an absent field means the host lacks it.
local PROFILES = {
    mainline = {
        projectId = 1,
        buildInfo = { "12.1.0", "64123", "Sep 23 2026", 120100 },
        secretValues = true,
        eventUtils = true,
        modernSpell = true,
        modernItem = true,
        spellBook = true,
        modernAddOnMetadata = true,
        forbiddenFrames = true,
        restrictedFrames = true,
    },
    mists = {
        projectId = 19,
        buildInfo = { "5.5.4", "64124", "Sep 23 2026", 50504 },
        eventUtils = true,
        modernSpell = true,
        modernItem = true,
        spellBook = true,
        modernAddOnMetadata = true,
        forbiddenFrames = true,
    },
    tbc = {
        projectId = 5,
        buildInfo = { "2.5.6", "64125", "Sep 23 2026", 20506 },
        eventUtils = true,
        modernItem = true,
        legacySpell = true,
        modernAddOnMetadata = true,
        forbiddenFrames = true,
    },
    classic = {
        projectId = 2,
        buildInfo = { "1.15.9", "64126", "Sep 23 2026", 11509 },
        legacyAddOns = true,
        legacySpell = true,
        legacyItem = true,
        forbiddenFrames = true,
    },
    noProjectId = {},
}

--- Profile names in a stable order, for specs that run once per profile.
ClientStub.PROFILE_NAMES = { "mainline", "mists", "tbc", "classic", "noProjectId" }

--- The globals this stub may install. `Constants.OWNED_GLOBALS` lists them too,
--- so `Reset` clears them whether or not the current profile installed them.
ClientStub.GLOBALS = {
    "WOW_PROJECT_ID",
    "WOW_PROJECT_MAINLINE",
    "WOW_PROJECT_CLASSIC",
    "WOW_PROJECT_BURNING_CRUSADE_CLASSIC",
    "WOW_PROJECT_MISTS_CLASSIC",
    "GetBuildInfo",
    "issecretvalue",
    "C_EventUtils",
    "C_Spell",
    "C_Item",
    "C_SpellBook",
    "GetSpellInfo",
    "GetItemInfo",
    "GetAddOnMetadata",
    "UIParent",
}

---Raise a stub precondition error when `name` is not a known profile.
---@param name any
---@param level integer stack level the failure is reported at
function ClientStub.ValidateProfileName(name, level)
    if name ~= nil and PROFILES[name] == nil then
        error("the client stub has no profile named " .. tostring(name), level)
    end
end

---The spell every profile knows unless a spec replaces the spell table.
---@return table<any, table>
local function defaultSpells()
    local frostbolt = {
        name = "Frostbolt",
        iconID = 135846,
        castTime = 2500,
        minRange = 0,
        maxRange = 40,
        spellID = 116,
    }
    return { [116] = frostbolt, Frostbolt = frostbolt }
end

---The item every profile knows unless a spec replaces the item table.
---@return table<any, any[]>
local function defaultItems()
    local hearthstone = {
        "Hearthstone",
        "|cffffffff|Hitem:6948::::::::1:::::::::|h[Hearthstone]|h|r",
        1,
        1,
        0,
        "Miscellaneous",
        "Junk",
        1,
        "",
        134414,
        0,
        15,
        0,
        1,
        0,
    }
    return { [6948] = hearthstone, Hearthstone = hearthstone }
end

---Return this stub's state fields to their initial values.
---@param state table shared stub state
function ClientStub.Reset(state)
    state.wowProfile = state.defaultWowProfile
    state.spells = defaultSpells()
    state.items = defaultItems()
    state.addonMetadata = {}
    state.validEvents = {
        ADDON_LOADED = true,
        PLAYER_LOGIN = true,
        PLAYER_LOGOUT = true,
        SPELLS_CHANGED = true,
    }
    state.secretValues = setmetatable({}, { __mode = "k" })
end

---Copy a spell record into a fresh table, as `C_Spell.GetSpellInfo` returns
---a new table per call. `originalIconID` is included because the host's table
---carries it, so a spec can see that the shim passes the host table through.
---@param record table
---@return table
local function copySpellRecord(record)
    return {
        name = record.name,
        iconID = record.iconID,
        originalIconID = record.iconID,
        castTime = record.castTime,
        minRange = record.minRange,
        maxRange = record.maxRange,
        spellID = record.spellID,
    }
end

---Install one global.
---@param name string
---@param value any
local function installGlobal(name, value)
    -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

---Install the project id, its constants and `GetBuildInfo`.
---@param profile table
local function installIdentity(profile)
    if profile.projectId == nil then
        return
    end

    installGlobal("WOW_PROJECT_ID", profile.projectId)
    for name, value in pairs(PROJECT_CONSTANTS) do
        installGlobal(name, value)
    end

    local buildInfo = profile.buildInfo
    installGlobal("GetBuildInfo", function()
        return buildInfo[1], buildInfo[2], buildInfo[3], buildInfo[4]
    end)
end

---Install the taint probes: `issecretvalue`, `C_EventUtils` and `UIParent`.
---@param profile table
---@param state table shared stub state
local function installTaintProbes(profile, state)
    if profile.secretValues then
        installGlobal("issecretvalue", function(value)
            return state.secretValues[value] == true
        end)
    end

    if profile.eventUtils then
        installGlobal("C_EventUtils", {
            IsEventValid = function(eventName)
                return state.validEvents[eventName] == true
            end,
        })
    end

    if profile.forbiddenFrames then
        local uiParent = {}
        function uiParent:IsForbidden()
            return false
        end
        if profile.restrictedFrames then
            function uiParent:CanBeAccessedInContext()
                return true
            end
        end
        installGlobal("UIParent", uiParent)
    end
end

---Install the spell, spellbook and item calls.
---@param profile table
---@param state table shared stub state
local function installSpellsAndItems(profile, state)
    if profile.modernSpell then
        installGlobal("C_Spell", {
            GetSpellInfo = function(spell)
                local record = state.spells[spell]
                return record and copySpellRecord(record) or nil
            end,
        })
    end

    if profile.legacySpell then
        -- Legacy order: name, rank, icon, castTime, minRange, maxRange, spellID, originalIcon.
        installGlobal("GetSpellInfo", function(spell)
            local record = state.spells[spell]
            if record == nil then
                return nil
            end
            return record.name,
                nil,
                record.iconID,
                record.castTime,
                record.minRange,
                record.maxRange,
                record.spellID,
                record.iconID
        end)
    end

    if profile.spellBook then
        installGlobal("C_SpellBook", {
            GetSpellBookItemInfo = function()
                return nil
            end,
        })
    end

    local function getItemInfo(item)
        local record = state.items[item]
        if record == nil then
            return nil
        end
        return unpack(record, 1, 17)
    end

    if profile.modernItem then
        installGlobal("C_Item", { GetItemInfo = getItemInfo })
    end
    if profile.legacyItem then
        installGlobal("GetItemInfo", getItemInfo)
    end
end

---Install addon metadata, and on a legacy profile swap `C_AddOns` for globals.
---
---`AddonStub` installs `C_AddOns.IsAddOnLoaded` for every environment. This
---stub runs after it, so a legacy profile removes that namespace and publishes
---the legacy `IsAddOnLoaded` over the same load state instead.
---@param profile table
---@param state table shared stub state
local function installAddOns(profile, state)
    local function getAddOnMetadata(addon, field)
        local fields = state.addonMetadata[addon]
        return fields and fields[field] or nil
    end

    if profile.modernAddOnMetadata then
        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        local addOns = rawget(_G, "C_AddOns")
        if type(addOns) == "table" then
            addOns.GetAddOnMetadata = getAddOnMetadata
        end
    end

    if profile.legacyAddOns then
        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        local addOns = rawget(_G, "C_AddOns")
        local modernIsAddOnLoaded = type(addOns) == "table" and addOns.IsAddOnLoaded or nil
        installGlobal("C_AddOns", nil)
        installGlobal("GetAddOnMetadata", getAddOnMetadata)
        if modernIsAddOnLoaded ~= nil then
            -- Legacy clients answer 1/nil rather than booleans.
            installGlobal("IsAddOnLoaded", function(addonName)
                local loaded, finished = modernIsAddOnLoaded(addonName)
                return loaded and 1 or nil, finished and 1 or nil
            end)
        end
    end
end

---Install the globals of the selected profile, if any.
---@param state table shared stub state
function ClientStub.InstallGlobals(state)
    local profile = state.wowProfile and PROFILES[state.wowProfile] or nil
    if profile == nil then
        return
    end

    installIdentity(profile)
    installTaintProbes(profile, state)
    installSpellsAndItems(profile, state)
    installAddOns(profile, state)
end

---Attach this stub's public helpers to `environment`.
---@param environment table the fixture facade specs call
---@param state table shared stub state
function ClientStub.Attach(environment, state)
    --- Profile names in a stable order, for specs that run once per profile.
    environment.WOW_PROFILES = ClientStub.PROFILE_NAMES

    ---Select the profile the next `InstallWowApi` installs. `nil` selects the
    ---shared host with no client identity. `Reset` restores the environment's
    ---`wowProfile` option.
    ---@param name string?
    function environment.SetWowProfile(name)
        ClientStub.ValidateProfileName(name, 3)
        state.wowProfile = name
    end

    ---@return string? name the selected profile
    function environment.GetWowProfile()
        return state.wowProfile
    end

    ---Return a new value the `issecretvalue` stub reports as secret.
    ---@return table secret
    function environment.NewSecretValue()
        local secret = {}
        state.secretValues[secret] = true
        return secret
    end

    ---Make `C_EventUtils.IsEventValid(eventName)` answer `valid`.
    ---@param eventName string
    ---@param valid boolean
    function environment.SetEventValid(eventName, valid)
        state.validEvents[eventName] = valid == true or nil
    end

    ---Add a spell both spell calls know, by ID and by name.
    ---@param record table `{ name, iconID, castTime, minRange, maxRange, spellID }`
    function environment.AddSpell(record)
        state.spells[record.spellID] = record
        state.spells[record.name] = record
    end

    ---Set one `.toc` field both metadata calls answer.
    ---@param addon string
    ---@param field string
    ---@param value string?
    function environment.SetAddOnMetadata(addon, field, value)
        local fields = state.addonMetadata[addon]
        if fields == nil then
            fields = {}
            state.addonMetadata[addon] = fields
        end
        fields[field] = value
    end
end

return ClientStub

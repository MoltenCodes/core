-- ExampleAddon: Commands.lua
--
-- Shows: CommandKit slash commands registered into a scope the caller owns.
-- The main module passes its own `module.scope.Commands`, so both commands go
-- inert when the module is disabled or the addon logs out.
--
--   /exampleaddon list | get <path> | set <path> <value> | reset <path> | exec <path>
--       `BindOptions`: a command line over the options tree, generated from it.
--   /exampleaddonwindow
--       an ordinary command that opens or closes the settings window.

local ADDON_NAME, ADDON_TABLE = ...
---@cast ADDON_TABLE ExampleAddon.Private

local LocaleKit = ADDON_TABLE.Kits.LocaleKit
local L = LocaleKit:GetLocale(ADDON_NAME)

---Report a command that could not be registered: `"taken"` when another addon
---or a chat type owns the name, `"emote"` when an emote does, `"full"` when the
---scope already holds 64 commands.
---@param name string
---@param registered boolean|nil
---@param reason string|nil
local function reportRegistration(name, registered, reason)
    if not registered then
        print(LocaleKit:Format(L["Could not register /%s: %s."], name, tostring(reason)))
    end
end

---Register the addon's slash commands into `commands`.
---@alias ExampleAddon.RegisterCommands fun(commands: CommandKit.Scope, options: OptionsKit.Tree, window: ExampleAddon.Window)
---@type ExampleAddon.RegisterCommands
local function registerCommands(commands, options, window)
    local bound, boundReason = commands:BindOptions(options, "exampleaddon", {
        description = L["Example Addon settings."],
    })
    reportRegistration("exampleaddon", bound, boundReason)

    local registered, registeredReason = commands:Register("exampleaddonwindow", {
        description = L["Open or close the settings window."],
        handler = function()
            window:Toggle()
        end,
    })
    reportRegistration("exampleaddonwindow", registered, registeredReason)
end

ADDON_TABLE.Modules:ProvideValue("RegisterCommands", registerCommands)

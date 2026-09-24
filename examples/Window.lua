-- ExampleAddon: Window.lua
--
-- Shows: WidgetKit rendering the OptionsKit tree into a `Frame` widget. The
-- renderer picks a widget per option kind, writes through the tree (so every
-- change is validated and lands in the database), and refreshes itself when
-- the tree changes. The window is created when it is opened and released
-- when it is closed: widgets are pooled, so opening it again reuses the same
-- frames instead of creating new ones the client could never free.

local ADDON_NAME, ADDON_TABLE = ...
---@cast ADDON_TABLE ExampleAddon.Private

local WidgetKit = ADDON_TABLE.Kits.WidgetKit
local L = ADDON_TABLE.Kits.LocaleKit:GetLocale(ADDON_NAME)

---The `Frame` widget type's own method this file calls. WidgetKit annotates
---the base widget and container but not each type's methods, so the example
---declares the one it uses.
---@class ExampleAddon.WindowFrame : WidgetKit.Container
---@field SetTitle fun(self: ExampleAddon.WindowFrame, title: string?)

---The settings window. Its only state is the open `Frame` widget and the
---rendering inside it; both are `nil` while the window is closed.
---@class ExampleAddon.Window
---@field Show fun(self: ExampleAddon.Window)
---@field Hide fun(self: ExampleAddon.Window)
---@field Toggle fun(self: ExampleAddon.Window)
---@field IsShown fun(self: ExampleAddon.Window): boolean
---@field GetFrame fun(self: ExampleAddon.Window): ExampleAddon.WindowFrame|nil

---Build the window over the options tree and the database it is bound to.
---@param options OptionsKit.Tree
---@param database SettingsKit.Database
---@return ExampleAddon.Window
local function newWindow(options, database)
    local window = {}
    local frame = nil ---@type ExampleAddon.WindowFrame|nil
    local rendering = nil ---@type WidgetKit.Rendering|nil

    function window:IsShown()
        return frame ~= nil
    end

    function window:GetFrame()
        return frame
    end

    function window:Show()
        if frame ~= nil then
            return
        end
        local created, reason = WidgetKit:Create("Frame")
        if type(created) == "nil" then
            -- "exhausted": every frame this type may create is in use.
            error(ADDON_NAME .. " could not open its window: " .. tostring(reason), 0)
        end
        frame = created --[[@as ExampleAddon.WindowFrame]]
        frame:SetTitle(L["Example Addon"])
        frame:GetFrame():SetScale(database.profile.windowScale)
        -- The close button hides the frame and fires `OnClose`; releasing it
        -- is the owner's job.
        frame:SetCallback("OnClose", function()
            window:Hide()
        end)
        rendering = WidgetKit:RenderOptions(options, frame)
        frame:Show()
    end

    function window:Hide()
        if frame == nil then
            return
        end
        -- The rendering first, so its widgets leave the frame together; then
        -- the frame goes back to WidgetKit's pool.
        if rendering ~= nil then
            rendering:Release()
            rendering = nil
        end
        frame:Release()
        frame = nil
    end

    function window:Toggle()
        if frame == nil then
            window:Show()
        else
            window:Hide()
        end
    end

    return window
end

---Build the window. Called once, by ModuleKit, when the main module
---initializes.
---@param modules ModuleKit.Addon
---@return ExampleAddon.Window
local function provideWindow(modules)
    return newWindow(modules:Resolve("Options"), modules:Resolve("Database"))
end

ADDON_TABLE.Modules:ProvideSingleton("Window", provideWindow)

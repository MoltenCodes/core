---@meta

-- Addon and session state LifecycleKit probes when an addon asks for its
-- lifecycle after the phase it cares about has already passed.

---@class C_AddOns
C_AddOns = {}

---Whether `addonName` is loading and whether its load has finished.
---
---An addon that is mid-load answers `true, false`; only the second return
---confirms that the `ADDON_LOADED` transition completed.
---@param addonName string|integer
---@return boolean loaded
---@return boolean finished
function C_AddOns.IsAddOnLoaded(addonName) end

---Legacy global form of `C_AddOns.IsAddOnLoaded`, kept by older clients.
---@param addonName string|integer
---@return boolean loaded
---@return boolean finished
function IsAddOnLoaded(addonName) end

---Whether the player has finished logging in.
---@return boolean
function IsLoggedIn() end

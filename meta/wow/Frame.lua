---@meta

-- World of Warcraft Frame surface touched by MoltenCodes packages.
--
-- Only the members EventKit and SchedulerKit actually call are declared, plus
-- the two restricted-access checks docs/EMBEDDING.md ("Frames you did not
-- create") tells consumers to make before touching a frame found by
-- enumeration. The client's real Frame API is far larger; adding members here
-- that neither a package nor that documented rule uses would suggest the
-- framework depends on them.

---A World of Warcraft frame widget.
---@class WowFrame
local WowFrame = {}

---Register this frame for a global event.
---@param eventName string
---@return boolean registered `false` when the client rejected the event name.
function WowFrame:RegisterEvent(eventName) end

---Register this frame for an event filtered to one or two unit tokens.
---
---The client provides exactly two filter slots. Registering the same event
---again on the same frame replaces the previous filter set.
---@param eventName string
---@param unit1 string
---@param unit2 string?
---@return boolean registered `false` when the client rejected the event name.
function WowFrame:RegisterUnitEvent(eventName, unit1, unit2) end

---Stop delivering `eventName` to this frame.
---@param eventName string
function WowFrame:UnregisterEvent(eventName) end

---Attach or clear a widget script handler.
---@param scriptName "OnEvent"|"OnUpdate"|string
---@param handler function|nil
function WowFrame:SetScript(scriptName, handler) end

---Whether this object has been explicitly marked forbidden.
---
---The answer does not depend on the execution context. Calling any other method
---on a forbidden frame from insecure code raises, so a frame found by
---enumeration is checked with this first.
---@return boolean isForbidden
function WowFrame:IsForbidden() end

---Whether the current Lua execution context may access this object.
---
---`false` when execution is tainted and the object is forbidden or enforces
---access restrictions. Added by the Retail 12.x client; older clients lack the
---method, so callers test `frame.CanBeAccessedInContext` before calling it.
---@return boolean canAccess
function WowFrame:CanBeAccessedInContext() end

---Create a widget of `frameType`.
---
---MoltenCodes packages only ever create plain `"Frame"` widgets.
---@param frameType "Frame"|string
---@param name string?
---@param parent WowFrame?
---@param template string?
---@param id integer?
---@return WowFrame
function CreateFrame(frameType, name, parent, template, id) end

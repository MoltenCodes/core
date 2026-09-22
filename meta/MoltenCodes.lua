---@meta

-- The one global the MoltenCodes framework creates.
--
-- `Registry.lua` publishes it, every other package reads it, and consumers
-- reach the framework through it. Nothing else in the framework writes a
-- global.

---The shared MoltenCodes namespace.
---@class MoltenCodesNamespace
---@field Registry Registry Alias for the newest Registry API generation loaded.
---@field Registries table<integer, Registry> Every loaded generation, by number.
MoltenCodes = {}

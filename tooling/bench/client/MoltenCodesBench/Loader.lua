-- MoltenCodes Bench: Loader.lua
--
-- A module table for the benchmark's Lua modules inside the client.
--
-- The benchmark's workloads are plain Lua 5.1 modules that `require` each
-- other (`tooling/bench/lua/workloads/`, `tooling/bench/client/lua/`); the host
-- runner loads them with `require`. The client has no `require`, so
-- `python3 -m tooling.bench.client_install` writes every module into this
-- addon's `modules/` folder wrapped in one call on the module's first line:
--
--     local _, private = ...; private.DefineModule("workloads.Dispatch", function(require, ...) <first line>
--     ...the module's source, unchanged...
--     end)
--
-- so each module is defined here without running, keeps its line numbers in
-- error messages, and receives `private.Require` as its `require`. A module
-- runs the first time it is required, once per session, like Lua's own
-- `require`.
--
-- Load order (MoltenCodesBench.toc): Installation.lua (written by the
-- installer), this file, the generated modules, then Harness.lua.

local ADDON_NAME, private = ...

---@type table<string, fun(require: fun(name: string): any): any>
local definitions = {}

---@type table<string, any>
local loaded = {}

---@type table<string, boolean>
local loading = {}

---Record a module's definition without running it.
---@param name string the module name, as `require` spells it
---@param definition fun(require: fun(name: string): any): any the module's body
function private.DefineModule(name, definition)
  if definitions[name] ~= nil then
    error(ADDON_NAME .. ": module " .. name .. " is defined twice; reinstall the addon", 2)
  end
  definitions[name] = definition
end

---Return a module's value, running its definition the first time.
---@param name string
---@return any
function private.Require(name)
  local value = loaded[name]
  if value ~= nil then
    return value
  end
  local definition = definitions[name]
  if definition == nil then
    error(ADDON_NAME .. ": no module " .. tostring(name) .. "; reinstall the addon", 2)
  end
  if loading[name] then
    error(ADDON_NAME .. ": module " .. name .. " requires itself", 2)
  end
  loading[name] = true
  value = definition(private.Require)
  loading[name] = nil
  if value == nil then
    value = true
  end
  loaded[name] = value
  return value
end

---Whether a module is defined.
---@param name string
---@return boolean
function private.HasModule(name)
  return definitions[name] ~= nil
end

--- What loading each side costs an addon at login (client only).
---
--- An addon author pays for a library at every login: the client compiles
--- and runs its files, and the heap keeps what they build. This workload
--- loads one set of a side's libraries as a load-on-demand addon and records
--- the time `C_AddOns.LoadAddOn` took (around `debugprofilestop`) and the
--- addon's memory after a full collection (`UpdateAddOnMemoryUsage`,
--- `GetAddOnMemoryUsage`). The harness does not load the side first for this
--- workload (`loadsSide = false` in the catalogue), so the measured load is
--- the first one of the session. Each case is one set, in a session of its
--- own:
---
--- - `minimum`: the event-and-timer minimum, Registry, SignalKit, EventKit,
---   LifecycleKit and TimerKit against LibStub, CallbackHandler-1.0,
---   AceAddon-3.0, AceEvent-3.0 and AceTimer-3.0;
--- - `typical`: AddonKit's core and what it requires, no parts, against the
---   Ace3 libraries a typical addon embeds (the minimum plus AceDB-3.0,
---   AceConsole-3.0 and AceLocale-3.0);
--- - `full`: the whole release bundle against every pinned Ace3 file,
---   AceGUI-3.0 and AceConfigDialog-3.0 included.
---
--- The installer writes one side addon per set and side
--- (`tooling/bench/client_workloads.py`, `LOGIN_SETS`).

local Login = {}

--- The sets, in the order the cases run.
local SETS = { "minimum", "typical", "full" }

---Build the workload for one side.
---@param _ string `"moltencodes"` or `"ace3"`
---@param host table the client host; `host.SetAddon(name)` names a set's addon
---@return table suite `{ cases, checks, libraries }`
function Login.Build(_, host)
  local clock = host.Global("debugprofilestop")
  local addOns = host.Global("C_AddOns")
  local cases = {}
  for _, setName in ipairs(SETS) do
    cases[#cases + 1] = {
      name = setName,
      kind = "frames",
      operation = "load the " .. setName .. " set as an addon",
      prepare = function()
        local addon = host.SetAddon(setName)
        local measured = {}
        return {
          maximumSeconds = 2,
          start = function()
            local started = clock()
            local loaded, reason = addOns.LoadAddOn(addon)
            measured.loadMilliseconds = clock() - started
            measured.loaded = loaded == true
            measured.reason = loaded and nil or tostring(reason)
          end,
          frame = function()
            return true
          end,
          finish = function()
            collectgarbage("collect")
            host.Global("UpdateAddOnMemoryUsage")()
            measured.addon = addon
            measured.kilobytes = host.Global("GetAddOnMemoryUsage")(addon)
            return measured
          end,
        }
      end,
    }
  end
  return {
    libraries = {},
    cases = cases,
    checks = function()
      return {}
    end,
  }
end

return Login

--- The two independent clocks the framework measures time with.
---
--- `GetTimePreciseSec` is monotonic wall time; `debugprofilestop` is addon CPU
--- time. They are kept separate here because the difference is exactly what
--- SchedulerKit's frame budget depends on: a client hitch moves wall time while
--- CPU time stands still, and a neighbouring addon calling `debugprofilestart()`
--- moves CPU time backwards while wall time does not.

local ClockStub = {}

---Return this stub's state fields to their initial values.
---@param state table shared stub state
function ClockStub.Reset(state)
    state.wallClockMs = 0
    state.profileClockMs = 0
    state.profilingClockAvailable = true
end

---Install the globals this stub owns.
---@param state table shared stub state
function ClockStub.InstallGlobals(state)
    -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "GetTimePreciseSec", function()
        return state.wallClockMs / 1000
    end)

    -- A frame budget is defined in addon CPU milliseconds. The stub keeps
    -- that clock independent from the wall clock so a spec can simulate a
    -- hitch: wall time moves while CPU time does not.
    if state.profilingClockAvailable then
        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "debugprofilestop", function()
            return state.profileClockMs
        end)
    end
end

---Attach this stub's public helpers to `environment`.
---@param environment table the fixture facade specs call
---@param state table shared stub state
function ClockStub.Attach(environment, state)
    ---Advance both clocks, which is what an ordinary busy slice looks like.
    function environment.AdvanceMs(milliseconds)
        state.wallClockMs = state.wallClockMs + milliseconds
        state.profileClockMs = state.profileClockMs + milliseconds
    end

    ---Advance only addon CPU time.
    function environment.AdvanceProfileMs(milliseconds)
        state.profileClockMs = state.profileClockMs + milliseconds
    end

    ---Advance only wall-clock time, as a garbage-collection pause or client
    ---hitch does: the frame stalls without the running job consuming any CPU.
    function environment.AdvanceWallMs(milliseconds)
        state.wallClockMs = state.wallClockMs + milliseconds
    end

    ---Set addon CPU time to an absolute reading, which is what an unrelated
    ---addon calling `debugprofilestart()` does to the one shared timer: the
    ---clock jumps, usually back to zero, in the middle of somebody else's
    ---measurement. A larger value models the opposite jump.
    function environment.SetProfileMs(milliseconds)
        state.profileClockMs = milliseconds
    end

    ---@return number milliseconds Current addon CPU time.
    function environment.NowMs()
        return state.profileClockMs
    end

    ---Withhold `debugprofilestop` from the next `InstallWowApi`, so a spec can
    ---exercise the documented wall-clock fallback. Must be called before the
    ---package is loaded, because the clock is bound once at load.
    function environment.WithoutProfilingClock()
        state.profilingClockAvailable = false
    end
end

return ClockStub

--- Package-specific test environment for the PoolKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
local FrameworkTestEnv = require("FrameworkTestEnv")

local PoolKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "PoolKit" },
    -- PoolKit is pure Lua and stays silent without a host error sink, so its
    -- specs install `geterrorhandler` explicitly through
    -- `InstallHostErrorHandler` rather than having it installed for them.
    wowApi = false,
})

--- Diagnostics PoolKit handed to the host error handler, in order.
---@return any[]
function PoolKitTestEnv.ReportedWarnings()
    return PoolKitTestEnv.ReportedErrors()
end

---A stand-in for a World of Warcraft AnimationGroup, reduced to what
---`Pool:ReleaseAfter` touches: `HookScript("OnFinished", handler)` and
---`IsPlaying()`. `Finish()` ends the animation the way the client does, calling
---every hooked `OnFinished` handler with the group and `requested = false`.
---
---The shared fixture has no animation stubs because only PoolKit needs one.
---@return table group
function PoolKitTestEnv.NewAnimationGroup()
    local group = { playing = true, hooks = {} }

    function group:HookScript(scriptName, handler)
        if scriptName ~= "OnFinished" then
            error(
                "the animation group stub only models OnFinished, got " .. tostring(scriptName),
                2
            )
        end
        self.hooks[#self.hooks + 1] = handler
    end

    function group:IsPlaying()
        return self.playing
    end

    function group:Play()
        self.playing = true
    end

    function group:Finish()
        self.playing = false
        for index = 1, #self.hooks do
            self.hooks[index](self, false)
        end
    end

    return group
end

return PoolKitTestEnv

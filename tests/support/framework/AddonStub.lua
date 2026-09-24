--- Addon load state, login state, and an empty combat-log payload.
---
--- These are the host facts LifecycleKit reads directly rather than receiving
--- as an event payload: whether an addon's files have finished loading and
--- whether the player is logged in. `CombatLogGetCurrentEventInfo` exists and
--- returns nothing, as it does outside a combat-log dispatch; a suite that
--- needs a payload installs its own (EventKit's `SetCombatLogEventInfo`). The
--- helpers that move an addon through its lifecycle live here too, because each
--- of them is a host state change plus the event the client would send with it.

local AddonStub = {}

---Return this stub's state fields to their initial values.
---@param state table shared stub state
function AddonStub.Reset(state)
  state.addonLoaded = {}
  state.loggedIn = false
end

---Install the globals this stub owns.
---@param state table shared stub state
function AddonStub.InstallGlobals(state)
  -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "C_AddOns", {
    -- The real C_AddOns.IsAddOnLoaded returns (loaded, finished). An
    -- addon whose files are executing but whose ADDON_LOADED transition
    -- has not completed answers (true, false), so the stub reports that
    -- state separately from "finished".
    IsAddOnLoaded = function(addonName)
      local status = state.addonLoaded[addonName]
      if status == "loading" then
        return true, false
      end
      local finished = status == true
      return finished, finished
    end,
  })

  -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "IsLoggedIn", function()
    return state.loggedIn
  end)

  -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "CombatLogGetCurrentEventInfo", function() end)
end

---Attach this stub's public helpers to `environment`.
---
---The lifecycle helpers dispatch through `environment.Emit`, which `FrameStub`
---attaches. They resolve it at call time, so the two stubs can be attached in
---either order.
---@param environment table the fixture facade specs call
---@param state table shared stub state
function AddonStub.Attach(environment, state)
  function environment.MarkAddonLoaded(addonName)
    state.addonLoaded[addonName] = true
  end

  ---Mark an addon as loading but not finished: the (true, false) host state.
  function environment.MarkAddonLoading(addonName)
    state.addonLoaded[addonName] = "loading"
  end

  function environment.SetLoggedIn(value)
    state.loggedIn = value == true
  end

  function environment.LoadAddon(addonName)
    environment.MarkAddonLoaded(addonName)
    environment.Emit("ADDON_LOADED", addonName)
  end

  function environment.Login()
    state.loggedIn = true
    environment.Emit("PLAYER_LOGIN")
  end

  function environment.Logout()
    environment.Emit("PLAYER_LOGOUT")
    state.loggedIn = false
  end
end

return AddonStub

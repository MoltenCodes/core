--- The host error sink, and the two ways a spec reads what reached it.
---
--- The framework never lets a consumer's failure escape into the client; it
--- hands the failure to `geterrorhandler()` instead. Capturing that sink is
--- therefore how a spec observes error isolation at all. `securecallfunction`
--- is captured beside it because the modern client routes isolated calls
--- through it and reports their failures the same way.

local ErrorHandlerStub = {}

---Return this stub's state fields to their initial values.
---@param state table shared stub state
function ErrorHandlerStub.Reset(state)
  state.reportedErrors = {}
end

---Finish one `securecallfunction` call the way the client does: a success
---returns the callback's results, a failure reaches the host error sink and
---returns nothing. Taking `pcall`'s results as varargs keeps the stub free of
---allocation on the success path, like the call it stands in for.
---@param state table shared stub state
---@param ok boolean
---@return any ...
local function finishSecureCall(state, ok, ...)
  if ok then
    return ...
  end
  state.reportedErrors[#state.reportedErrors + 1] = { value = (...) }
end

---Attach this stub's public helpers to `environment`.
---
---Installation is deliberately not part of `InstallGlobals`: a pure-Lua package
---stays silent without a host sink, so its specs opt in by calling
---`InstallHostErrorHandler` rather than having diagnostics captured for them.
---@param environment table the fixture facade specs call
---@param state table shared stub state
function ErrorHandlerStub.Attach(environment, state)
  ---Install only the host error sink.
  function environment.InstallHostErrorHandler()
    -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", function()
      return function(value)
        state.reportedErrors[#state.reportedErrors + 1] = { value = value }
      end
    end)
  end

  ---Install a `securecallfunction` stub so a spec can exercise the
  ---modern-client isolation path. Must run before the package loads.
  function environment.InstallSecureCallFunction()
    -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "securecallfunction", function(callback, ...)
      return finishSecureCall(state, pcall(callback, ...))
    end)
  end

  ---Every value the host error handler received, in order.
  ---
  ---Entries are the raw error objects. Use `TakeReportedErrors` when a `nil`
  ---or `false` error object has to stay distinguishable from "nothing was
  ---reported".
  ---@return any[]
  function environment.ReportedErrors()
    local values = {}
    for index = 1, #state.reportedErrors do
      values[index] = state.reportedErrors[index].value
    end
    return values
  end

  ---Return and clear every error reported since the last call.
  ---
  ---Each entry is `{ value = <error object> }`, so `nil` and `false` error
  ---objects stay representable.
  ---@return { value: any }[]
  function environment.TakeReportedErrors()
    local taken = state.reportedErrors
    state.reportedErrors = {}
    return taken
  end
end

return ErrorHandlerStub

-- Shared helper: reportError
--
-- Hand a failure nobody called for (a callback that raised during a dispatch,
-- a logout step) to the host's error handler without raising. The failure is
-- passed on unchanged and never inspected: it may be a secret string built from
-- a secret argument. A missing handler, or one that itself raises (an
-- error-display addon with a bug), falls back to `print`, which is what the
-- client's default handler does, so reporting one failure never becomes a
-- second one.
--
-- shared revision: 1
-- shared requires:
-- shared parameters:
--
-- Everything above `shared:body` stays in this file; the body below it is
-- what `python3 -m tooling.shared.sync` copies between a Kit's markers.
-- shared:body
---Report `failure` through the host error handler, or print it.
---@param failure any
local function reportError(failure)
  -- geterrorhandler is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" and pcall(handler, failure) then
      return
    end
  end
  print(failure)
end
-- shared:exports
-- Not copied: what the host tests of this helper load (tooling/tests/test_shared_sync.py).
return { reportError = reportError }

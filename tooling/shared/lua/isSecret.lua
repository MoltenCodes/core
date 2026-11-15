-- Shared helper: isSecret
--
-- Whether a value is a secret value (Retail 12.0.0 and later), which the
-- client forbids comparing, testing or using as a table key. The probe rule:
-- `issecretvalue` is read once, at load, because every client flavour defines
-- it before any addon runs, so a check reads an upvalue. A host that had none
-- at load (a test environment, or a shim installed later) is asked again on
-- each check, so a probe installed after load is still honoured. A host
-- without the probe has no secret values. ADR 0002 says where a Kit asks.
--
-- shared revision: 1
-- shared requires:
-- shared parameters:
--
-- Everything above `shared:body` stays in this file; the body below it is
-- what `python3 -m tooling.shared.sync` copies between a Kit's markers.
-- shared:body
---Whether `value` is a secret value the host forbids comparing.
---@type fun(value: any): boolean
local isSecret
do
  -- issecretvalue is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local loadedProbe = rawget(_G, "issecretvalue")
  if type(loadedProbe) ~= "function" then
    loadedProbe = nil
  end

  isSecret = function(value)
    local probe = loadedProbe
    if probe == nil then
      -- selene: allow(global_usage)
      probe = rawget(_G, "issecretvalue")
      if type(probe) ~= "function" then
        return false
      end
    end
    return probe(value) == true
  end
end
-- shared:exports
-- Not copied: what the host tests of this helper load (tooling/tests/test_shared_sync.py).
return { isSecret = isSecret }

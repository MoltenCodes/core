-- Shared helper: describeKey
--
-- How an error message names a table key a caller supplied. A string is
-- shown as written and a number or boolean through `tostring`, which runs no
-- caller code for those types. Anything else is named by its type in angle
-- brackets, such as `<table>`: a table's or userdata's `__tostring` is the
-- caller's code, which could raise or answer a secret and so hide the real
-- refusal. A secret is named `<secret>` and never put into the message.
--
-- shared revision: 1
-- shared requires: isSecret
-- shared parameters:
--
-- Everything above `shared:body` stays in this file; the body below it is
-- what `python3 -m tooling.shared.sync` copies between a Kit's markers.

---Stand-in for the `isSecret` block a Kit carries before this one.
---@param _ any
---@return boolean
local function isSecret(_)
  return false
end
-- shared:body
---Name `key` for an error message without running any of the caller's code.
---@param key any
---@return string
local function describeKey(key)
  if isSecret(key) then
    return "<secret>"
  end
  local kind = type(key)
  if kind == "string" then
    return key
  end
  if kind == "number" or kind == "boolean" then
    return tostring(key)
  end
  return "<" .. kind .. ">"
end
-- shared:exports
-- Not copied: what the host tests of this helper load (tooling/tests/test_shared_sync.py).
return { describeKey = describeKey }

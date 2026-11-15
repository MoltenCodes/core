-- Shared helper: validateFacade
--
-- Raise at the caller unless a method was called on the Kit's facade, the
-- mistake `Kit.Method(...)` instead of `Kit:Method(...)` makes. `type` is
-- asked first: a secret receiver is never a table, and only a table is
-- compared. `level` is the value `error` needs inside this function.
--
-- shared revision: 1
-- shared requires:
-- shared parameters: __FACADE__
--
-- Everything above `shared:body` stays in this file; the body below it is
-- what `python3 -m tooling.shared.sync` copies between a Kit's markers, with
-- `__FACADE__` replaced by the Kit's facade name.

---Stand-in for the Kit's facade table.
local __FACADE__ = {}
-- shared:body
---Raise at `level` unless `receiver` is the __FACADE__ facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= __FACADE__ then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the __FACADE__ facade" .. hint, level)
  end
end
-- shared:exports
-- Not copied: what the host tests of this helper load (tooling/tests/test_shared_sync.py).
return { validateFacade = validateFacade }

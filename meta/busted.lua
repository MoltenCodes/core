---@meta

-- Busted and luassert, as the specs in this repository use them.
--
-- Busted injects this vocabulary into spec chunks only. A module under
-- `tests/support/` is loaded through plain `require` and must name luassert
-- explicitly; see docs/TESTING.md.
--
-- luassert's matchers are plain functions reached through nested tables, so
-- they are declared as fields holding `fun(...)`, never as methods: a spec
-- writes `assert.are.equal(expected, actual)`, not `assert.are:equal(...)`.

---Positive equality matchers.
---@class BustedAssertComparator
---@field equal fun(expected: any, actual: any, message: string?)
---@field same fun(expected: any, actual: any, message: string?)

---Negated equality matchers.
---@class BustedAssertNegatedComparator
---@field equal fun(unexpected: any, actual: any, message: string?)
---@field same fun(unexpected: any, actual: any, message: string?)

---luassert, which is also callable as Lua's own `assert`.
---@class BustedAssert
---@field are BustedAssertComparator
---@field are_not BustedAssertNegatedComparator
---@field is_true fun(value: any, message: string?)
---@field is_false fun(value: any, message: string?)
---@field is_nil fun(value: any, message: string?)
---@field is_not_nil fun(value: any, message: string?)
---@field has_error fun(callback: fun(), expected: any?)
---@field has_no_error fun(callback: fun())
---@overload fun(value: any, message: any?): any, any?

---@type BustedAssert
assert = assert

---@param name string
---@param callback fun()
function describe(name, callback) end

---@param name string
---@param callback fun()
function it(name, callback) end

---@param callback fun()
function before_each(callback) end

---@param callback fun()
function after_each(callback) end

---@param callback fun()
function setup(callback) end

---@param callback fun()
function teardown(callback) end

---@param callback fun()
function finally(callback) end

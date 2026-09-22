---@meta

---@class BustedAssertComparator
---@field equal fun(self: BustedAssertComparator, expected: any, actual: any)
---@field same fun(self: BustedAssertComparator, expected: any, actual: any)

---@class BustedAssertNegatedComparator
---@field equal fun(self: BustedAssertNegatedComparator, unexpected: any, actual: any)

---@class BustedAssert
---@field are BustedAssertComparator
---@field are_not BustedAssertNegatedComparator
---@field is_true fun(value: any)
---@field is_false fun(value: any)
---@field is_nil fun(value: any)
---@field is_not_nil fun(value: any)
---@field has_error fun(callback: fun())

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

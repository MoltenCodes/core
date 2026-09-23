-- Where a dependency cycle is reported: at the line that called the public
-- method which started the pass, whichever of the five entry points it was and
-- however deep the recursion found the cycle.

local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit dependency cycles", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    ---Build an addon whose modules `A` and `B` require each other.
    ---@return table addon, table a
    local function cyclicAddon()
        local addon = ModuleKit:ForAddon("MyAddon")
        local a = addon:CreateModule("A")
        local b = addon:CreateModule("B")
        a:DependsOn("B")
        b:DependsOn("A")
        return addon, a
    end

    local source = debug.getinfo(1, "S").short_src

    ---Run `call`, which records the line it calls ModuleKit from, and assert the
    ---cycle error names exactly that line.
    local function assertCycleAtLine(call)
        local line
        local ok, message = pcall(call, function(currentLine)
            line = currentLine + 1
        end)
        message = tostring(message)
        assert.is_false(ok)
        assert.is_not_nil(string.find(message, "dependency cycle detected", 1, true), message)
        assert.are.equal(1, string.find(message, source .. ":" .. line .. ":", 1, true), message)
    end

    it("reports a cycle at the line that called InitializeAll", function()
        local addon = cyclicAddon()
        assertCycleAtLine(function(mark)
            mark(debug.getinfo(1, "l").currentline)
            addon:InitializeAll()
        end)
    end)

    it("reports a cycle at the line that called EnableAll", function()
        local addon = cyclicAddon()
        assertCycleAtLine(function(mark)
            mark(debug.getinfo(1, "l").currentline)
            addon:EnableAll()
        end)
    end)

    it("reports a cycle at the line that called Initialize", function()
        local _, a = cyclicAddon()
        assertCycleAtLine(function(mark)
            mark(debug.getinfo(1, "l").currentline)
            a:Initialize()
        end)
    end)

    it("reports a cycle at the line that called Enable", function()
        local _, a = cyclicAddon()
        assertCycleAtLine(function(mark)
            mark(debug.getinfo(1, "l").currentline)
            a:Enable()
        end)
    end)

    it("reports a cycle at the line that called Activate", function()
        local _, a = cyclicAddon()
        TestEnv.LoadAddon("MyAddon")
        assertCycleAtLine(function(mark)
            mark(debug.getinfo(1, "l").currentline)
            a:Activate()
        end)
    end)

    it("reports an enable from an unexpected state at the line that called Enable", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local a = addon:CreateModule("A")
        addon:CreateModule("B")
        a:DependsOn("B")
        -- No public call leaves a module in this state; it stands for private
        -- state an older or damaged copy could leave behind.
        rawset(a, "_state", "unknown")

        local line
        local ok, message = pcall(function()
            line = debug.getinfo(1, "l").currentline + 1
            a:Enable()
        end)
        message = tostring(message)

        assert.is_false(ok)
        assert.is_not_nil(
            string.find(message, 'cannot be enabled from state "unknown"', 1, true),
            message
        )
        assert.are.equal(1, string.find(message, source .. ":" .. line .. ":", 1, true), message)
    end)
end)

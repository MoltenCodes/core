local Env = require("CompatKitTestEnv")

---Install one global, as a host would.
---@param name string
---@param value any
local function setGlobal(name, value)
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

describe("CompatKit Apply", function()
    local CompatKit

    before_each(function()
        CompatKit = Env.NewPackage()
    end)
    after_each(function()
        setGlobal("MyAddonGlobal", nil)
        Env.Reset()
    end)

    ---The record of the shim `name`.
    ---@param name string
    ---@return table
    local function recordOf(name)
        local rows = CompatKit:GetShims()
        for index = 1, #rows do
            if rows[index].name == name then
                return rows[index]
            end
        end
        error("no shim named " .. name, 2)
    end

    it("runs pending shims once, in name order, and returns the counts", function()
        local ran = {}
        for _, name in ipairs({ "zeta", "alpha", "Mid" }) do
            CompatKit:Shim(name, 1, function()
                ran[#ran + 1] = name
            end)
        end
        assert.are.same({ 3, 0, 0 }, { CompatKit:Apply() })
        assert.are.same({ "Mid", "alpha", "zeta" }, ran)
        assert.are.equal("applied", recordOf("alpha").status)
    end)

    it("is idempotent: a second Apply runs only shims registered since", function()
        local ran = {}
        CompatKit:Shim("first", 1, function()
            ran[#ran + 1] = "first"
        end)
        CompatKit:Apply()
        CompatKit:Shim("second", 1, function()
            ran[#ran + 1] = "second"
        end)
        assert.are.same({ 1, 0, 0 }, { CompatKit:Apply() })
        assert.are.same({ 0, 0, 0 }, { CompatKit:Apply() })
        assert.are.same({ "first", "second" }, ran)
    end)

    it("returns zero counts with nothing registered", function()
        assert.are.same({ 0, 0, 0 }, { CompatKit:Apply() })
    end)

    it("isolates a failing shim, reports it and records the failure", function()
        local ran = {}
        CompatKit:Shim("a-fails", 1, function()
            error("shim broke", 0)
        end)
        CompatKit:Shim("b-runs", 1, function()
            ran[#ran + 1] = "b"
        end)
        assert.are.same({ 1, 0, 1 }, { CompatKit:Apply() })
        assert.are.same({ "b" }, ran)
        assert.are.same({ "shim broke" }, Env.ReportedErrors())

        local record = recordOf("a-fails")
        assert.are.equal("shim broke", record.failed)
        assert.is_false(record.applied)
        assert.are.equal("failed", record.status)
        -- A failed shim is attempted once, like any other.
        assert.are.same({ 0, 0, 0 }, { CompatKit:Apply() })
        assert.are.same({ true, "recorded" }, { CompatKit:Shim("a-fails", 2, function() end) })
    end)

    it("passes the failure to the error handler unchanged", function()
        local failure = { code = 7 }
        CompatKit:Shim("table-error", 1, function()
            error(failure)
        end)
        CompatKit:Apply()
        assert.are.equal(failure, Env.ReportedErrors()[1])
        assert.are.equal(failure, recordOf("table-error").failed)
    end)

    it("prints the failure when the host has no error handler", function()
        setGlobal("geterrorhandler", nil)
        local printed = {}
        local originalPrint = print
        -- `print` is the fallback the client's own default handler uses; the
        -- package reads it from the global table, not from this chunk's environment.
        setGlobal("print", function(value)
            printed[#printed + 1] = value
        end)
        CompatKit:Shim("broken", 1, function()
            error("no handler", 0)
        end)
        CompatKit:Apply()
        setGlobal("print", originalPrint)
        assert.are.same({ "no handler" }, printed)
    end)

    it("survives a host error handler that raises and keeps Apply usable", function()
        setGlobal("geterrorhandler", function()
            return function()
                error("the error display is broken", 0)
            end
        end)
        local printed = {}
        local originalPrint = print
        setGlobal("print", function(value)
            printed[#printed + 1] = value
        end)
        local ran = {}
        CompatKit:Shim("a-fails", 1, function()
            error("shim broke", 0)
        end)
        CompatKit:Shim("b-runs", 1, function()
            ran[#ran + 1] = "b"
        end)
        local ok, applied, skipped, failed = pcall(CompatKit.Apply, CompatKit)
        setGlobal("print", originalPrint)
        assert.is_true(ok)
        assert.are.same({ 1, 0, 1 }, { applied, skipped, failed })
        assert.are.same({ "b" }, ran)
        assert.are.same({ "shim broke" }, printed)
        assert.are.equal("shim broke", recordOf("a-fails").failed)

        -- The guard is released: a later Apply runs later shims.
        CompatKit:Shim("c-later", 1, function()
            ran[#ran + 1] = "c"
        end)
        assert.are.same({ 1, 0, 0 }, { CompatKit:Apply() })
        assert.are.same({ "b", "c" }, ran)
    end)

    it("hands every shim a read-only context with flavour, hasApi and hasGlobal", function()
        setGlobal("MyAddonGlobal", { Nested = { Value = 1 } })
        local seen
        CompatKit:Shim("inspect", 1, function(context)
            seen = {
                flavour = context.flavour,
                hasApiType = type(context.hasApi),
                globalPresent = context.hasGlobal("MyAddonGlobal"),
                nestedPresent = context.hasGlobal("MyAddonGlobal.Nested.Value"),
                nestedAbsent = context.hasGlobal("MyAddonGlobal.Nested.Other"),
                throughNonTable = context.hasGlobal("MyAddonGlobal.Nested.Value.Deeper"),
                absent = context.hasGlobal("NoSuchGlobal"),
                absentThenPresent = context.hasGlobal("NoSuchGlobal.print"),
                writeFailed = not pcall(function()
                    context.flavour = "mainline"
                end),
            }
        end)
        CompatKit:Apply()
        assert.are.same({
            flavour = false,
            hasApiType = "function",
            globalPresent = true,
            nestedPresent = true,
            nestedAbsent = false,
            throughNonTable = false,
            absent = false,
            absentThenPresent = false,
            writeFailed = true,
        }, seen)
    end)

    it("refuses to be re-entered from a shim and keeps running the others", function()
        local ran = {}
        CompatKit:Shim("a-reenters", 1, function()
            CompatKit:Apply()
        end)
        CompatKit:Shim("b-runs", 1, function()
            ran[#ran + 1] = "b"
        end)
        assert.are.same({ 1, 0, 1 }, { CompatKit:Apply() })
        assert.are.same({ "b" }, ran)
        assert.is_truthy(
            tostring(Env.ReportedErrors()[1]):find("cannot be called from inside a shim", 1, true)
        )
        -- The guard is released after the failing shim.
        assert.are.same({ 0, 0, 0 }, { CompatKit:Apply() })
    end)

    it("lets a shim register another shim, which runs on the next Apply", function()
        local ran = {}
        CompatKit:Shim("registrar", 1, function()
            CompatKit:Shim("registered-late", 1, function()
                ran[#ran + 1] = "late"
            end)
        end)
        assert.are.same({ 1, 0, 0 }, { CompatKit:Apply() })
        assert.are.same({}, ran)
        assert.are.same({ 1, 0, 0 }, { CompatKit:Apply() })
        assert.are.same({ "late" }, ran)
    end)
end)

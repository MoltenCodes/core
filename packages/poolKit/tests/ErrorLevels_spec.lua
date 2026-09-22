local Env = require("PoolKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` fails with `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number
---or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local function newFactory()
    return function()
        return {}
    end
end

describe("PoolKit error levels", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("points receiver-type errors at the caller", function()
        local PoolKit = Env.NewPackage()

        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            PoolKit.Pool.Acquire({})
        end)
        assertReportedAt(line, "PoolKit.Pool:Acquire must be called on a PoolKit pool", ok, value)
    end)

    it("points closed-pool errors at the caller", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({ create = newFactory() })
        pool:Close()

        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            pool:Acquire()
        end)
        assertReportedAt(line, "PoolKit.Pool:Acquire cannot use a closed pool", ok, value)

        local prewarmLine
        local prewarmOk, prewarmValue = pcall(function()
            prewarmLine = currentLine() + 1
            pool:Prewarm(1)
        end)
        assertReportedAt(
            prewarmLine,
            "PoolKit.Pool:Prewarm cannot use a closed pool",
            prewarmOk,
            prewarmValue
        )
    end)

    it("points pool-method argument errors at the caller", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({ create = newFactory() })

        local releaseLine
        local releaseOk, releaseValue = pcall(function()
            releaseLine = currentLine() + 1
            pool:Release("not an object")
        end)
        assertReportedAt(
            releaseLine,
            "PoolKit.Pool:Release object must be a table or userdata",
            releaseOk,
            releaseValue
        )

        local countLine
        local countOk, countValue = pcall(function()
            countLine = currentLine() + 1
            pool:Prewarm(-1)
        end)
        assertReportedAt(
            countLine,
            "PoolKit.Pool:Prewarm count must be a non-negative integer",
            countOk,
            countValue
        )

        local trimLine
        local trimOk, trimValue = pcall(function()
            trimLine = currentLine() + 1
            pool:Trim(1.5)
        end)
        assertReportedAt(
            trimLine,
            "PoolKit.Pool:Trim retainCount must be a non-negative integer",
            trimOk,
            trimValue
        )

        local retainedLine
        local retainedOk, retainedValue = pcall(function()
            retainedLine = currentLine() + 1
            pool:SetMaxRetained(-4)
        end)
        assertReportedAt(
            retainedLine,
            "PoolKit.Pool:SetMaxRetained maxRetained must be a non-negative integer"
                .. " or PoolKit.UNBOUNDED",
            retainedOk,
            retainedValue
        )
    end)

    it("points mutation-during-callback errors at the caller", function()
        local PoolKit = Env.NewPackage()
        local pool
        local line
        local ok, value
        pool = PoolKit:New({
            create = newFactory(),
            reset = function()
                ok, value = pcall(function()
                    line = currentLine() + 1
                    pool:Clear()
                end)
            end,
        })

        pool:Release(pool:Acquire())
        assertReportedAt(
            line,
            "PoolKit.Pool:Clear cannot mutate this pool during its reset callback",
            ok,
            value
        )
    end)

    it("points constructor option errors at the caller", function()
        local PoolKit = Env.NewPackage()

        local tableLine
        local tableOk, tableValue = pcall(function()
            tableLine = currentLine() + 1
            PoolKit:New("not a table")
        end)
        assertReportedAt(tableLine, "PoolKit:New options must be a table", tableOk, tableValue)

        local createLine
        local createOk, createValue = pcall(function()
            createLine = currentLine() + 1
            PoolKit:New({})
        end)
        assertReportedAt(createLine, "PoolKit:New create must be a function", createOk, createValue)

        local unknownLine
        local unknownOk, unknownValue = pcall(function()
            unknownLine = currentLine() + 1
            PoolKit:New({ create = newFactory(), zzz = 1, aaa = 1 })
        end)
        assertReportedAt(
            unknownLine,
            'PoolKit:New options contains unknown field "aaa"',
            unknownOk,
            unknownValue
        )

        local strictLine
        local strictOk, strictValue = pcall(function()
            strictLine = currentLine() + 1
            PoolKit:New({ create = newFactory(), strict = "yes" })
        end)
        assertReportedAt(strictLine, "PoolKit:New strict must be a boolean", strictOk, strictValue)

        local prewarmLine
        local prewarmOk, prewarmValue = pcall(function()
            prewarmLine = currentLine() + 1
            PoolKit:New({ create = newFactory(), maxRetained = 2, prewarm = 3 })
        end)
        assertReportedAt(
            prewarmLine,
            "PoolKit:New prewarm cannot exceed maxRetained",
            prewarmOk,
            prewarmValue
        )

        local tablePoolLine
        local tablePoolOk, tablePoolValue = pcall(function()
            tablePoolLine = currentLine() + 1
            PoolKit:NewTablePool({ maxRetained = "lots" })
        end)
        assertReportedAt(
            tablePoolLine,
            "PoolKit:NewTablePool maxRetained must be a non-negative integer"
                .. " or PoolKit.UNBOUNDED",
            tablePoolOk,
            tablePoolValue
        )
    end)

    it("points factory-result errors at the caller of the method that created", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return "not an object"
            end,
        })

        local acquireLine
        local acquireOk, acquireValue = pcall(function()
            acquireLine = currentLine() + 1
            pool:Acquire()
        end)
        assertReportedAt(
            acquireLine,
            "PoolKit.Pool:Acquire factory result must be a table or userdata",
            acquireOk,
            acquireValue
        )

        local prewarmLine
        local prewarmOk, prewarmValue = pcall(function()
            prewarmLine = currentLine() + 1
            pool:Prewarm(1)
        end)
        assertReportedAt(
            prewarmLine,
            "PoolKit.Pool:Prewarm factory result must be a table or userdata",
            prewarmOk,
            prewarmValue
        )
    end)

    it("re-raises a constructor prewarm failure without inventing a position", function()
        local PoolKit = Env.NewPackage()

        -- The failure escapes a protected call, so PoolKit re-raises the object
        -- verbatim rather than attaching a position from inside its own source.
        local ok, value = pcall(function()
            PoolKit:New({
                create = function()
                    return "not an object"
                end,
                prewarm = 1,
            })
        end)
        assert.is_false(ok)
        assert.are.equal("PoolKit.Pool:Prewarm factory result must be a table or userdata", value)
    end)
end)

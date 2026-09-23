local TestEnv = require("CacheKitTestEnv")

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

describe("CacheKit error levels", function()
    local CacheKit
    before_each(function()
        CacheKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("points constructor option errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            CacheKit:NewLru({})
        end)
        assertReportedAt(line, "CacheKit:NewLru maxEntries is required", ok, value)

        local unknownLine
        local unknownOk, unknownValue = pcall(function()
            unknownLine = currentLine() + 1
            CacheKit:NewTtl({ maxEntries = 1, ttlSeconds = 1, zzz = true, aaa = true })
        end)
        assertReportedAt(
            unknownLine,
            'CacheKit:NewTtl options contains unknown field "aaa"',
            unknownOk,
            unknownValue
        )

        local ttlLine
        local ttlOk, ttlValue = pcall(function()
            ttlLine = currentLine() + 1
            CacheKit:NewTtl({ maxEntries = 1, ttlSeconds = 0 })
        end)
        assertReportedAt(
            ttlLine,
            "CacheKit:NewTtl ttlSeconds must be a finite number greater than zero",
            ttlOk,
            ttlValue
        )

        local memoLine
        local memoOk, memoValue = pcall(function()
            memoLine = currentLine() + 1
            CacheKit:Memoize(function() end, { maxEntries = 0 })
        end)
        assertReportedAt(
            memoLine,
            "CacheKit:Memoize maxEntries must be a positive integer",
            memoOk,
            memoValue
        )

        local fnLine
        local fnOk, fnValue = pcall(function()
            fnLine = currentLine() + 1
            CacheKit:Memoize("nope")
        end)
        assertReportedAt(fnLine, "CacheKit:Memoize fn must be a function", fnOk, fnValue)

        local snapshotLine
        local snapshotOk, snapshotValue = pcall(function()
            snapshotLine = currentLine() + 1
            CacheKit:NewSnapshot(function() end, { maxEntries = 1.5 })
        end)
        assertReportedAt(
            snapshotLine,
            "CacheKit:NewSnapshot maxEntries must be a positive integer",
            snapshotOk,
            snapshotValue
        )
    end)

    it("points key errors at the caller", function()
        local cache = CacheKit:NewLru({ maxEntries = 1 })

        local getLine
        local getOk, getValue = pcall(function()
            getLine = currentLine() + 1
            cache:Get(nil)
        end)
        assertReportedAt(getLine, "CacheKit.Cache:Get key must not be nil", getOk, getValue)

        local setLine
        local setOk, setValue = pcall(function()
            setLine = currentLine() + 1
            cache:Set(0 / 0, 1)
        end)
        assertReportedAt(setLine, "CacheKit.Cache:Set key must not be NaN", setOk, setValue)

        local memoized = CacheKit:Memoize(function(key)
            return key
        end)
        local memoLine
        local memoOk, memoValue = pcall(function()
            memoLine = currentLine() + 1
            memoized({})
        end)
        assertReportedAt(
            memoLine,
            "CacheKit memoized function key must be a string or a number",
            memoOk,
            memoValue
        )
    end)

    it("points closed-object errors at the caller", function()
        local cache = CacheKit:NewLru({ maxEntries = 1 })
        cache:Close()

        local setLine
        local setOk, setValue = pcall(function()
            setLine = currentLine() + 1
            cache:Set("a", 1)
        end)
        assertReportedAt(
            setLine,
            "CacheKit.Cache:Set cannot write to a closed cache",
            setOk,
            setValue
        )

        local clearOnLine
        local clearOnOk, clearOnValue = pcall(function()
            clearOnLine = currentLine() + 1
            cache:ClearOn("SPELLS_CHANGED")
        end)
        assertReportedAt(
            clearOnLine,
            "CacheKit.Cache:ClearOn cannot subscribe a closed cache",
            clearOnOk,
            clearOnValue
        )

        local memoized, memoCache = CacheKit:Memoize(function(key)
            return key
        end)
        memoCache:Close()
        local memoLine
        local memoOk, memoValue = pcall(function()
            memoLine = currentLine() + 1
            memoized("a")
        end)
        assertReportedAt(
            memoLine,
            "CacheKit memoized function cannot run after its cache was closed",
            memoOk,
            memoValue
        )

        local snapshot = CacheKit:NewSnapshot(function() end)
        snapshot:Close()
        local refreshLine
        local refreshOk, refreshValue = pcall(function()
            refreshLine = currentLine() + 1
            snapshot:Refresh()
        end)
        assertReportedAt(
            refreshLine,
            "CacheKit.Snapshot:Refresh cannot refresh a closed snapshot",
            refreshOk,
            refreshValue
        )
    end)

    it("points receiver-type errors at the caller", function()
        local cacheLine
        local cacheOk, cacheValue = pcall(function()
            cacheLine = currentLine() + 1
            CacheKit.Cache.Get({}, "a")
        end)
        assertReportedAt(
            cacheLine,
            "CacheKit.Cache:Get must be called on a CacheKit cache",
            cacheOk,
            cacheValue
        )

        local snapshotLine
        local snapshotOk, snapshotValue = pcall(function()
            snapshotLine = currentLine() + 1
            CacheKit.Snapshot.Refresh({})
        end)
        assertReportedAt(
            snapshotLine,
            "CacheKit.Snapshot:Refresh must be called on a CacheKit snapshot",
            snapshotOk,
            snapshotValue
        )
    end)

    it("points ClearOn errors at the caller", function()
        local cache = CacheKit:NewLru({ maxEntries = 1 })
        local nameLine
        local nameOk, nameValue = pcall(function()
            nameLine = currentLine() + 1
            cache:ClearOn("")
        end)
        assertReportedAt(
            nameLine,
            "CacheKit.Cache:ClearOn eventName must be a non-empty string",
            nameOk,
            nameValue
        )

        local Bare = TestEnv.NewPackageWithoutEventKit()
        local bareCache = Bare:NewLru({ maxEntries = 1 })
        local absentLine
        local absentOk, absentValue = pcall(function()
            absentLine = currentLine() + 1
            bareCache:ClearOn("SPELLS_CHANGED")
        end)
        assertReportedAt(
            absentLine,
            "CacheKit.Cache:ClearOn requires EventKit API 1, which is not loaded (absent)",
            absentOk,
            absentValue
        )
    end)

    it("points a refused ClearOn registration at the caller", function()
        local cache = CacheKit:NewLru({ maxEntries = 1 })
        TestEnv.FailNextRegisterEvent()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            cache:ClearOn("SPELLS_CHANGED")
        end)
        assertReportedAt(
            line,
            "CacheKit.Cache:ClearOn could not connect SPELLS_CHANGED: "
                .. "EventKit.Scope:Connect could not register event SPELLS_CHANGED",
            ok,
            value
        )
    end)

    it("points fill errors at the reader line that called fill", function()
        local fillLine
        local snapshot = CacheKit:NewSnapshot(function(fill)
            fillLine = currentLine() + 1
            fill("a", nil)
        end)
        local ok, value = pcall(function()
            snapshot:Refresh()
        end)
        assertReportedAt(fillLine, "CacheKit.Snapshot fill value must not be nil", ok, value)

        local keyLine
        local keyless = CacheKit:NewSnapshot(function(fill)
            keyLine = currentLine() + 1
            fill(nil, 1)
        end)
        local keyOk, keyValue = pcall(function()
            keyless:Refresh()
        end)
        assertReportedAt(keyLine, "CacheKit.Snapshot fill key must not be nil", keyOk, keyValue)
    end)
end)

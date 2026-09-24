local TestEnv = require("TimerKitTestEnv")

describe("TimerKit state properties", function()
    after_each(TestEnv.Reset)

    it("keeps scope active-count consistent across deterministic mixed operations", function()
        local TimerKit = TestEnv.NewPackage()
        local scope = TimerKit:CreateScope()
        local timers = {}
        local seed = 316050595

        local function nextRandom(limit)
            -- Park-Miller generator: every product stays below 2^47, so it is
            -- exact in a Lua 5.1 double. The result is taken from the high bits,
            -- because the low bits of a power-of-two-modulus generator cycle
            -- within a few steps and would exercise only a handful of paths.
            seed = (seed * 48271) % 2147483647
            return (math.floor(seed / 65536) % limit) + 1
        end

        local function verifyActiveCount()
            local running = 0
            for index = 1, #timers do
                if timers[index]:GetState() == "running" then
                    running = running + 1
                end
            end
            assert.are.equal(running, scope:GetActiveCount())
        end

        for _ = 1, 5000 do
            local operation = nextRandom(7)

            if operation <= 2 or #timers == 0 then
                local repeating = nextRandom(2) == 1
                local timer
                if operation == 1 then
                    timer = scope:New({
                        delay = repeating and 0.25 or 0,
                        repeating = repeating,
                        callback = function() end,
                    })
                elseif repeating then
                    timer = scope:Every(0.25, function() end)
                else
                    timer = scope:After(0, function() end)
                end
                timers[#timers + 1] = timer
            else
                local timer = timers[nextRandom(#timers)]
                if operation == 3 then
                    pcall(function()
                        timer:Start()
                    end)
                elseif operation == 4 then
                    pcall(function()
                        timer:Cancel()
                    end)
                elseif operation == 5 then
                    pcall(function()
                        timer:Restart()
                    end)
                else
                    local natives = TestEnv.NativeTimers()
                    if #natives > 0 then
                        local nativeIndex = nextRandom(#natives)
                        if operation == 6 then
                            pcall(TestEnv.FireNative, nativeIndex)
                        else
                            pcall(TestEnv.InvokeRaw, nativeIndex)
                        end
                    end
                end
            end

            verifyActiveCount()
        end

        scope:CancelAll()
        assert.are.equal(0, scope:GetActiveCount())
        verifyActiveCount()
    end)
end)

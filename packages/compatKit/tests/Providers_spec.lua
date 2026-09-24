local Env = require("CompatKitTestEnv")

describe("CompatKit providers", function()
    local CompatKit
    local registry

    before_each(function()
        CompatKit = Env.NewPackage()
        registry = CompatKit:Providers("output")
    end)
    after_each(Env.Reset)

    ---A probe that answers what `state.alive` says and counts its calls.
    ---@param state { alive: boolean, calls: integer }
    ---@return fun(): boolean
    local function probeOf(state)
        return function()
            state.calls = state.calls + 1
            return state.alive
        end
    end

    describe("Providers", function()
        it("returns one registry per kind, the same object on every call", function()
            assert.are.equal(registry, CompatKit:Providers("output"))
            local storage = CompatKit:Providers("storage")
            assert.are_not.equal(registry, storage)
            assert.is_true(registry:Register("chat", "sink"))
            assert.are.same({}, storage:List())
        end)

        it("hides the prototype behind the metatable tag", function()
            assert.are.equal("CompatKit.ProviderRegistry", getmetatable(registry))
        end)
    end)

    describe("Register and Unregister", function()
        it("registers a provider once and refuses the same name with exists", function()
            assert.is_true(registry:Register("chat", "chat-sink"))
            assert.are.same({ false, "exists" }, { registry:Register("chat", "other-sink") })
            assert.are.same({ "chat-sink", "chat" }, { registry:Resolve("chat") })
        end)

        it("accepts any non-nil implementation", function()
            local implementation = function() end
            assert.is_true(registry:Register("callable", implementation))
            assert.is_true(registry:Register("flag", false))
            assert.is_true(registry:Register("number", 0))
            assert.are.equal(implementation, (registry:Resolve("callable")))
            assert.are.equal(false, (registry:Resolve("flag")))
        end)

        it("unregisters by name and reports whether the name existed", function()
            registry:Register("chat", "sink")
            assert.is_true(registry:Unregister("chat"))
            assert.is_false(registry:Unregister("chat"))
            assert.are.same({ nil, "none" }, { registry:Resolve() })
            -- The name is free again.
            assert.is_true(registry:Register("chat", "new-sink"))
            assert.are.same({ "new-sink", "chat" }, { registry:Resolve() })
        end)
    end)

    describe("Resolve", function()
        it("returns nil, none with nothing registered or nothing alive", function()
            assert.are.same({ nil, "none" }, { registry:Resolve() })
            registry:Register("dead", "sink", function()
                return false
            end)
            assert.are.same({ nil, "none" }, { registry:Resolve() })
            assert.are.same({ nil, "none" }, { registry:Resolve("dead") })
        end)

        it("cascades by priority, higher first, whatever the registration order", function()
            registry:Register("low", "low-sink", nil, -5)
            registry:Register("high", "high-sink", nil, 10)
            registry:Register("default", "default-sink")
            assert.are.same({ "high-sink", "high" }, { registry:Resolve() })
            registry:Unregister("high")
            assert.are.same({ "default-sink", "default" }, { registry:Resolve() })
            registry:Unregister("default")
            assert.are.same({ "low-sink", "low" }, { registry:Resolve() })
        end)

        it("breaks a priority tie by name order, deterministically", function()
            registry:Register("zulu", "z-sink", nil, 3)
            registry:Register("alpha", "a-sink", nil, 3)
            registry:Register("Bravo", "b-sink", nil, 3)
            assert.are.same({ "b-sink", "Bravo" }, { registry:Resolve() })
            registry:Unregister("Bravo")
            assert.are.same({ "a-sink", "alpha" }, { registry:Resolve() })
        end)

        it("returns a live preferred provider whatever its priority", function()
            registry:Register("high", "high-sink", nil, 10)
            registry:Register("low", "low-sink", nil, 0)
            assert.are.same({ "low-sink", "low" }, { registry:Resolve("low") })
            -- The cascade answer is untouched by a preferred lookup.
            assert.are.same({ "high-sink", "high" }, { registry:Resolve() })
        end)

        it("falls through to the cascade when the preferred provider is dead or unknown", function()
            local preferredState = { alive = false, calls = 0 }
            registry:Register("preferred", "preferred-sink", probeOf(preferredState), 100)
            registry:Register("fallback", "fallback-sink")
            assert.are.same({ "fallback-sink", "fallback" }, { registry:Resolve("preferred") })
            assert.are.same({ "fallback-sink", "fallback" }, { registry:Resolve("unknown") })
            preferredState.alive = true
            assert.are.same({ "preferred-sink", "preferred" }, { registry:Resolve("preferred") })
        end)

        it("memoises the cascade answer and re-validates it with the probe", function()
            local highState = { alive = true, calls = 0 }
            local lowState = { alive = true, calls = 0 }
            registry:Register("high", "high-sink", probeOf(highState), 10)
            registry:Register("low", "low-sink", probeOf(lowState), 0)

            assert.are.same({ "high-sink", "high" }, { registry:Resolve() })
            assert.are.same({ "high-sink", "high" }, { registry:Resolve() })
            -- Each Resolve asked the memoised provider's probe, and nobody else's.
            assert.are.equal(2, highState.calls)
            assert.are.equal(0, lowState.calls)

            -- The memoised provider dies: the cascade runs again.
            highState.alive = false
            assert.are.same({ "low-sink", "low" }, { registry:Resolve() })
            assert.are.equal(3, highState.calls)
            assert.are.equal(1, lowState.calls)

            -- It comes back: the memo is on "low" now, and low is alive, so
            -- low is still the answer until it dies. This is the memo's
            -- documented contract: stable while alive, not always the best.
            highState.alive = true
            assert.are.same({ "low-sink", "low" }, { registry:Resolve() })
            lowState.alive = false
            assert.are.same({ "high-sink", "high" }, { registry:Resolve() })
        end)

        it("forgets a memoised provider that is unregistered", function()
            registry:Register("high", "high-sink", nil, 10)
            registry:Register("low", "low-sink", nil, 0)
            assert.are.same({ "high-sink", "high" }, { registry:Resolve() })
            registry:Unregister("high")
            assert.are.same({ "low-sink", "low" }, { registry:Resolve() })
        end)

        it("prefers a newly registered higher priority once the memo is invalid", function()
            local lowState = { alive = true, calls = 0 }
            registry:Register("low", "low-sink", probeOf(lowState), 0)
            assert.are.same({ "low-sink", "low" }, { registry:Resolve() })
            registry:Register("high", "high-sink", nil, 10)
            -- The memo still says low, and low is alive.
            assert.are.same({ "low-sink", "low" }, { registry:Resolve() })
            lowState.alive = false
            assert.are.same({ "high-sink", "high" }, { registry:Resolve() })
        end)

        it("treats a probe that raises as dead and reports it", function()
            registry:Register("broken", "broken-sink", function()
                error("probe broke", 0)
            end, 10)
            registry:Register("fallback", "fallback-sink")
            assert.are.same({ "fallback-sink", "fallback" }, { registry:Resolve() })
            assert.are.same({ "probe broke" }, Env.ReportedErrors())
        end)

        it("probes a dead provider once when it is both preferred and memoised", function()
            local state = { alive = true, calls = 0 }
            registry:Register("only", "only-sink", probeOf(state))
            assert.are.same({ "only-sink", "only" }, { registry:Resolve() })
            state.alive = false
            state.calls = 0
            assert.are.same({ nil, "none" }, { registry:Resolve("only") })
            assert.are.equal(1, state.calls)
        end)

        it("reports a raising probe once per Resolve, whichever role it plays", function()
            registry:Register("broken", "broken-sink", function()
                error("probe broke", 0)
            end, 10)
            registry:Register("fallback", "fallback-sink")
            assert.are.same({ "fallback-sink", "fallback" }, { registry:Resolve("broken") })
            assert.are.equal(1, #Env.TakeReportedErrors())
            assert.are.same({ "fallback-sink", "fallback" }, { registry:Resolve("broken") })
            assert.are.equal(1, #Env.TakeReportedErrors())
        end)

        it("treats a probe answering anything but true as dead", function()
            registry:Register("truthy", "truthy-sink", function()
                return 1
            end, 10)
            registry:Register("plain", "plain-sink")
            assert.are.same({ "plain-sink", "plain" }, { registry:Resolve() })
        end)
    end)

    describe("List", function()
        it("returns fresh rows in cascade order with the probe's answer", function()
            registry:Register("low", "low-sink", nil, -1)
            registry:Register("dead", "dead-sink", function()
                return false
            end, 5)
            registry:Register("alive", "alive-sink", function()
                return true
            end, 5)
            local first = registry:List()
            assert.are.same({
                { name = "alive", priority = 5, alive = true },
                { name = "dead", priority = 5, alive = false },
                { name = "low", priority = -1, alive = true },
            }, first)
            first[1].name = "changed"
            local second = registry:List()
            assert.are_not.equal(first, second)
            assert.are.equal("alive", second[1].name)
        end)

        it("reports a provider whose probe raises as dead, and the failure once", function()
            registry:Register("broken", "broken-sink", function()
                error("probe broke", 0)
            end)
            assert.are.same({ { name = "broken", priority = 0, alive = false } }, registry:List())
            assert.are.same({ "probe broke" }, Env.ReportedErrors())
        end)

        it("is empty for a new kind", function()
            assert.are.same({}, CompatKit:Providers("fresh"):List())
        end)
    end)
end)

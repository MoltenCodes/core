local TestEnv = require("RegistryTestEnv")

local expectErrorContaining = TestEnv.expectErrorContaining

---Install an `issecretvalue` probe that reports exactly the listed values as
---secret. `TestEnv.Reset` clears the global again.
---@param ... any values the probe reports as secret
local function installSecretProbe(...)
    local secrets = {}
    for index = 1, select("#", ...) do
        secrets[select(index, ...)] = true
    end
    -- issecretvalue is a World of Warcraft client global; the fixture owns and clears it.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
        return secrets[value] == true
    end)
end

---A `demoKit` request at `revision`, with `fields` merged over the defaults.
---@param revision integer
---@param fields table?
---@return table
local function newRequest(revision, fields)
    local request = {
        package = "demoKit",
        api = 1,
        revision = revision,
        label = "MoltenCodes DemoKit",
        validatePublicSurface = function(implementation)
            return type(rawget(implementation, "Run")) == "function"
        end,
    }
    for key, value in pairs(fields or {}) do
        request[key] = value
    end
    return request
end

---Install revision 1 of `demoKit` with a complete facade.
---@param Registry Registry
---@param fields table?
---@return table implementation
local function installRevisionOne(Registry, fields)
    local implementation = Registry:Bootstrap(newRequest(1, fields))
    implementation.API = 1
    implementation.REVISION = 1
    implementation.Run = function() end
    return implementation
end

describe("Registry secret values", function()
    before_each(TestEnv.Reset)
    after_each(TestEnv.Reset)

    it("refuses a secret package name, api or revision at the caller", function()
        local Registry = TestEnv.NewRegistry()
        installSecretProbe("secretKit", 7)

        expectErrorContaining("Registry:Register packageName must be a non-empty string", function()
            Registry:Register("secretKit", 1, 1)
        end)
        expectErrorContaining("Registry:Get api must be a positive integer up to 2^53", function()
            Registry:Get("demoKit", 7)
        end)
        expectErrorContaining(
            "Registry:Bootstrap revision must be a positive integer up to 2^53",
            function()
                Registry:Bootstrap(newRequest(7))
            end
        )
        assert.are.same({}, Registry:Packages())
    end)

    it("refuses a secret label or optional field at the package's Bootstrap call", function()
        local Registry = TestEnv.NewRegistry()
        installSecretProbe("Secret Label", true)

        expectErrorContaining(
            "Registry:Bootstrap request.label must be a non-empty string",
            function()
                Registry:Bootstrap(newRequest(1, { label = "Secret Label" }))
            end
        )
        expectErrorContaining("Registry:Bootstrap request.sealFacade must be a boolean", function()
            Registry:Bootstrap(newRequest(1, { sealFacade = true }))
        end)
    end)

    it("treats a secret validateState verdict as incomplete", function()
        local Registry = TestEnv.NewRegistry()
        installRevisionOne(Registry)
        installSecretProbe(true)

        expectErrorContaining(
            "MoltenCodes DemoKit package state is corrupted or incomplete",
            function()
                Registry:Bootstrap(newRequest(1, {
                    validateState = function()
                        return true
                    end,
                }))
            end
        )
    end)

    it("refuses a secret revision returned by resume", function()
        local Registry = TestEnv.NewRegistry()
        installRevisionOne(Registry)
        installSecretProbe(0)

        expectErrorContaining("Registry:Bootstrap request.resume must return a revision", function()
            Registry:Bootstrap(newRequest(1, {
                resume = function()
                    return 0
                end,
            }))
        end)
    end)

    it("hands a secret migration result over without comparing it", function()
        local Registry = TestEnv.NewRegistry()
        local secret = {}
        installRevisionOne(Registry)
        installSecretProbe(secret)

        local implementation, previousRevision, _, state = Registry:Bootstrap(newRequest(2, {
            migrations = {
                [2] = function()
                    return secret
                end,
            },
        }))

        assert.is_table(implementation)
        assert.are.equal(1, previousRevision)
        assert.are.equal(secret, state)
    end)
end)

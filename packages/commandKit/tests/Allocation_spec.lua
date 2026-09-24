local TestEnv = require("CommandKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("CommandKit allocation", function()
    local CommandKit, SchemaKit
    before_each(function()
        local _
        CommandKit, _, _, SchemaKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    ---@param label string
    ---@param workload fun()
    local function assertAllocatesNothing(label, workload)
        workload()
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                workload()
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            label .. " allocated " .. allocated .. " KiB"
        )
    end

    it("allocates nothing to parse text it has seen with ParseInto", function()
        local array = {}
        local text = 'set "two words" |cffa335ee|Hitem:1|h[Some Item]|h|r 3'
        assertAllocatesNothing("ParseInto", function()
            CommandKit:ParseInto(text, array)
        end)
    end)

    it("allocates nothing to dispatch a checked sub-command", function()
        local total = 0
        CommandKit:ForAddon("MyAddon"):Register("tool", {
            subcommands = {
                frame = {
                    subcommands = {
                        scale = {
                            handler = function(_, value, shown)
                                if shown then
                                    total = total + value
                                end
                            end,
                            arguments = {
                                SchemaKit.number({ min = 0, max = 10 }),
                                SchemaKit.boolean(),
                            },
                        },
                    },
                },
            },
        })
        local dispatcher = TestEnv.GetGlobal("SlashCmdList")[TestEnv.FindSlashKey("/tool")]
        assertAllocatesNothing("dispatch", function()
            dispatcher("frame scale 2 on")
        end)
        assert.is_true(total > 0)
    end)

    it("does not lower-case the argument of a command without sub-commands", function()
        -- Lower-casing an item link would build a new string on every
        -- dispatch once the collector freed the previous one, which the
        -- allocation guard above cannot see with the collector stopped.
        local link = "|cffa335ee|Hitem:1|h[Some Item]|h|r"
        local received
        CommandKit:CreateScope():Register("watch", {
            handler = function(_, itemLink)
                received = itemLink
            end,
        })
        -- `text:lower()` looks `lower` up in the `string` table at every call,
        -- so a counting stand-in written there sees every call dispatch makes.
        local lowered = {}
        local originalLower = string.lower
        rawset(string, "lower", function(text)
            lowered[#lowered + 1] = text
            return originalLower(text)
        end)
        local ok, failure = pcall(TestEnv.RunSlash, "/watch " .. link)
        rawset(string, "lower", originalLower)
        assert(ok, failure)
        assert.are.equal(link, received)
        assert.are.same({}, lowered)
    end)

    it("allocates nothing in an inert dispatcher", function()
        local scope = CommandKit:CreateScope()
        scope:Register("gone", { handler = function() end })
        local dispatcher = TestEnv.GetGlobal("SlashCmdList")[TestEnv.FindSlashKey("/gone")]
        scope:Close()
        assertAllocatesNothing("inert dispatcher", function()
            dispatcher("anything at all")
        end)
    end)
end)

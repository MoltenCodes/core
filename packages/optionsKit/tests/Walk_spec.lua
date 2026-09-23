local TestEnv = require("OptionsKitTestEnv")

describe("OptionsKit tree Walk", function()
    local OptionsKit
    before_each(function()
        OptionsKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("visits depth-first, siblings by order, then name, then key", function()
        local tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                zeta = { type = "header", name = "Zeta", order = 1 },
                alpha = { type = "header", name = "Alpha", order = 2 },
                beta = {
                    type = "group",
                    name = "Beta",
                    order = 1,
                    args = {
                        second = { type = "header", name = "Same" },
                        first = { type = "header", name = "Same" },
                        early = { type = "header", name = "Zzz", order = -5 },
                    },
                },
                unordered = { type = "header", name = "Aaa" },
            },
        })
        local visited = {}
        local count = tree:Walk(function(path, kind, depth)
            visited[#visited + 1] = path .. ":" .. kind .. ":" .. depth
        end)
        assert.are.same({
            "beta:group:1",
            "beta.early:header:2",
            "beta.first:header:2",
            "beta.second:header:2",
            "zeta:header:1",
            "alpha:header:1",
            "unordered:header:1",
        }, visited)
        assert.are.equal(7, count)
    end)

    it("visits nothing in an empty tree", function()
        local tree = OptionsKit:Define("Addon", { type = "group", args = {} })
        assert.are.equal(
            0,
            tree:Walk(function()
                error("never called")
            end)
        )
    end)

    it("lets a visitor error reach the caller", function()
        local tree = OptionsKit:Define(
            "Addon",
            { type = "group", args = { h = { type = "header", name = "H" } } }
        )
        TestEnv.expectErrorContaining("visitor failed", function()
            tree:Walk(function()
                error("visitor failed")
            end)
        end)
    end)

    it("refuses a visitor that is not a function", function()
        local tree = OptionsKit:Define("Addon", { type = "group", args = {} })
        TestEnv.expectErrorContaining("OptionsKit.Tree:Walk visitor must be a function", function()
            tree:Walk(nil)
        end)
    end)
end)

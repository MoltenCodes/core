local TestEnv = require("ApiKitTestEnv")

--- The flavour table the tooling maintains, `tooling/api/flavours.json`, is the
--- one place the flavours are written by hand. ApiKit carries the same rows in
--- Lua because the client has no JSON reader; this spec holds the two to each
--- other so a flavour added or renamed in one place cannot be missed in the
--- other. Only the fields ApiKit needs are compared.
describe("ApiKit flavour table", function()
    after_each(TestEnv.Reset)

    ---Read the ids, namespaces and detection facts out of the JSON text with
    ---patterns, in file order. The file is small and regular, so a JSON reader
    ---is not needed for this comparison.
    ---@return table[] rows
    local function readToolingTable()
        local file = assert(io.open("tooling/api/flavours.json", "r"))
        local text = file:read("*a")
        file:close()

        local rows = {}
        for entry in text:gmatch('{%s*\n%s*"id":(.-)\n%s*}') do
            local row = {
                id = entry:match('^%s*"([^"]+)"'),
                namespace = entry:match('"namespace":%s*"([^"]+)"'),
                projectId = tonumber(entry:match('"projectId":%s*(%d+)')),
                testBuild = entry:match('"testBuild":%s*(%a+)') == "true",
                betaBuild = entry:match('"betaBuild":%s*(%a+)') == "true",
            }
            rows[#rows + 1] = row
        end
        return rows
    end

    it("lists the same flavours in the same order as the tooling", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local rows = readToolingTable()
        assert.are.equal(ApiKit.SUPPORTED_FLAVOR_COUNT, #rows)
        for index, row in ipairs(rows) do
            assert.are.equal(row.id, ApiKit.SUPPORTED_FLAVORS[index])
        end
        assert.is_nil(ApiKit.SUPPORTED_FLAVORS[#rows + 1])
    end)

    it("publishes every namespace the tooling names", function()
        TestEnv.NewPackageFor("retail")
        -- selene: allow(global_usage)
        local root = rawget(_G, "MoltenCodes").wow
        for _, row in ipairs(readToolingTable()) do
            local node = root
            for segment in row.namespace:gmatch("[^.]+") do
                if segment ~= "wow" then
                    node = node[segment]
                    assert.is_table(node, row.namespace)
                end
            end
        end
    end)

    it("detects every flavour from the facts the tooling records", function()
        for _, row in ipairs(readToolingTable()) do
            TestEnv.Reset()
            TestEnv.InstallWowApi()
            TestEnv.SetClient({
                projectId = row.projectId,
                testBuild = row.testBuild,
                betaBuild = row.betaBuild,
            })
            require("Registry")
            local ApiKit = require("ApiKit")
            assert.are.equal(row.id, ApiKit:GetFlavor())
        end
    end)
end)

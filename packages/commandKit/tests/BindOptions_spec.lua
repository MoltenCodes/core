local TestEnv = require("CommandKitTestEnv")

---Register a SettingsKit API 1 stand-in, so OptionsKit accepts `options.db`.
---@param Registry table
local function installSettingsKitStub(Registry)
    local SettingsKit = Registry:Register("settingsKit", 1, 1)
    rawset(SettingsKit, "API", 1)
    rawset(SettingsKit, "REVISION", 1)
end

---A live table whose absent keys read their default, as SettingsKit's do.
---@param defaults table
---@return table
local function newLiveTable(defaults)
    local live = {}
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            live[key] = newLiveTable(value)
        end
    end
    return setmetatable(live, { __index = defaults })
end

---A SettingsKit-shaped database with a profile scope.
---@param profileDefaults table
---@return table
local function newDatabase(profileDefaults)
    local db = {}
    for _, scope in ipairs({ "global", "char", "realm", "class", "faction" }) do
        db[scope] = {}
    end
    db.profile = newLiveTable(profileDefaults)
    function db:OnChange()
        return nil
    end
    function db:Validate()
        return true
    end
    return db
end

describe("CommandKit BindOptions", function()
    local CommandKit, OptionsKit, tree, sink, values, executed

    before_each(function()
        local Registry
        CommandKit, Registry, _, _, OptionsKit = TestEnv.NewPackage()
        installSettingsKitStub(Registry)
        local db = newDatabase({ enabled = true, frame = { scale = 1, anchor = "CENTER" } })
        values = {
            label = "Main",
            color = { r = 1, g = 0, b = 0, a = 1 },
            channels = { guild = true },
            locked = false,
            hiddenFlag = false,
        }
        executed = {}
        local function getter(info)
            return values[info[#info]]
        end
        local function setter(info, value)
            values[info[#info]] = value
        end
        tree = OptionsKit:Define("MyAddon", {
            type = "group",
            args = {
                enabled = { type = "toggle", name = "Enabled", order = 1, bind = "profile.enabled" },
                frame = {
                    type = "group",
                    name = "Frame",
                    order = 2,
                    args = {
                        scale = {
                            type = "range",
                            name = "Scale",
                            min = 0.5,
                            max = 2,
                            order = 1,
                            bind = "profile.frame.scale",
                        },
                        anchor = {
                            type = "select",
                            name = "Anchor",
                            order = 2,
                            values = { TOP = "Top", CENTER = "Centre" },
                            sorting = { "TOP", "CENTER" },
                            bind = "profile.frame.anchor",
                        },
                        color = {
                            type = "color",
                            name = "Colour",
                            order = 3,
                            hasAlpha = true,
                            get = getter,
                            set = setter,
                        },
                    },
                },
                label = {
                    type = "input",
                    name = "Label",
                    desc = "The frame title.",
                    order = 3,
                    get = getter,
                    set = setter,
                    validate = function(_, value)
                        if value == "bad name" then
                            return false, "that label is taken"
                        end
                        return true
                    end,
                },
                channels = {
                    type = "multiselect",
                    name = "Channels",
                    order = 4,
                    values = { guild = "Guild", party = "Party" },
                    get = getter,
                    set = setter,
                },
                locked = {
                    type = "toggle",
                    name = "Locked",
                    order = 5,
                    disabled = true,
                    get = getter,
                    set = setter,
                },
                hiddenFlag = {
                    type = "toggle",
                    name = "Hidden",
                    order = 6,
                    hidden = true,
                    get = getter,
                    set = setter,
                },
                wipe = {
                    type = "execute",
                    name = "Wipe",
                    order = 7,
                    confirm = "Really wipe everything?",
                    func = function()
                        executed[#executed + 1] = "wipe"
                    end,
                },
                run = {
                    type = "execute",
                    name = "Run",
                    order = 8,
                    func = function()
                        executed[#executed + 1] = "run"
                    end,
                },
            },
        }, { db = db })
        local scope = CommandKit:ForAddon("MyAddon")
        sink = CommandKit:CaptureSink()
        scope:SetSink(sink)
        assert.is_true(scope:BindOptions(tree, "myopts", { description = "My options." }))
    end)
    after_each(TestEnv.Reset)

    local function run(line)
        sink:Clear()
        TestEnv.RunSlash(line)
        return sink:Messages()
    end

    it("prints the generated usage with no sub-command", function()
        assert.are.same({
            "Usage: /myopts <exec|get|list|reset|set>",
            "My options.",
            "  /myopts exec <path> [confirm] - Run a button.",
            "  /myopts get <path> - Print an option's value.",
            "  /myopts list [path] - List the options of a group, or describe one option.",
            "  /myopts reset <path> - Restore an option's default.",
            "  /myopts set <path> <value...> - Change an option.",
        }, run("/myopts"))
    end)

    it("gets values of every kind", function()
        assert.are.same({ "enabled = on" }, run("/myopts get enabled"))
        assert.are.same({ "frame.scale = 1" }, run("/myopts get frame.scale"))
        assert.are.same({ "frame.anchor = CENTER (Centre)" }, run("/myopts get frame.anchor"))
        assert.are.same({ "frame.color = 1.00 0.00 0.00 1.00" }, run("/myopts get frame.color"))
        assert.are.same({ "channels = guild" }, run("/myopts get channels"))
        assert.are.same({ "label = Main" }, run("/myopts get label"))
    end)

    it("sets values parsed per kind", function()
        assert.are.same({ "enabled = off" }, run("/myopts set enabled off"))
        assert.are.same({ "enabled = on" }, run("/myopts set enabled toggle"))
        assert.are.same({ "frame.scale = 1.5" }, run("/myopts set frame.scale 1.5"))
        assert.are.same({ "frame.anchor = TOP (Top)" }, run("/myopts set frame.anchor top"))
        assert.are.same(
            { "frame.anchor = CENTER (Centre)" },
            run("/myopts set frame.anchor CENTER")
        )
        assert.are.same(
            { "frame.color = 0.00 0.50 1.00 1.00" },
            run("/myopts set frame.color 0 0.5 1")
        )
        assert.are.same(
            { "frame.color = 1.00 1.00 1.00 0.00" },
            run("/myopts set frame.color #ffffff00")
        )
        assert.are.same({ "channels = guild, party" }, run("/myopts set channels party on"))
        assert.are.same({ "channels = party" }, run("/myopts set channels Guild off"))
        assert.are.same({ "label = two words here" }, run('/myopts set label two "words here"'))
        assert.are.equal("two words here", values.label)
    end)

    it("prints the validate refusal and writes nothing", function()
        assert.are.same({ "/myopts set: that label is taken" }, run('/myopts set label "bad name"'))
        assert.are.equal("Main", values.label)
    end)

    it("prints the schema refusal of an out-of-range value", function()
        assert.are.same(
            { "/myopts set: expected number <= 2, found larger number" },
            run("/myopts set frame.scale 5")
        )
        assert.are.same({ "/myopts set: expected a number" }, run("/myopts set frame.scale big"))
        assert.are.same(
            { "/myopts set: expected on, off or toggle" },
            run("/myopts set enabled maybe")
        )
        assert.are.same(
            { "/myopts set: expected one of: TOP, CENTER" },
            run("/myopts set frame.anchor LEFT")
        )
        assert.are.same(
            { "/myopts set: expected r g b [a] between 0 and 1, or #rrggbb[aa]" },
            run("/myopts set frame.color red")
        )
    end)

    it("resets a bound option to its default and refuses one without a default", function()
        run("/myopts set frame.scale 2")
        assert.are.same({ "frame.scale = 1" }, run("/myopts reset frame.scale"))
        assert.are.same(
            { '/myopts reset: "label" has no default to reset to' },
            run("/myopts reset label")
        )
    end)

    it("lists a group and describes one option", function()
        assert.are.same({
            "enabled = on - Enabled",
            "frame - Frame (group)",
            "label = Main - Label",
            "channels = guild - Channels",
            "locked = off - Locked (disabled)",
            "wipe - Wipe (exec)",
            "run - Run (exec)",
        }, run("/myopts list"))
        assert.are.same({
            "frame.scale = 1 - Scale",
            "frame.anchor = CENTER (Centre) - Anchor",
            "frame.color = 1.00 0.00 0.00 1.00 - Colour",
        }, run("/myopts list frame"))
        assert.are.same({ "label = Main - Label", "The frame title." }, run("/myopts list label"))
        assert.are.same({
            "frame.anchor = CENTER (Centre) - Anchor",
            "values: TOP, CENTER",
        }, run("/myopts list frame.anchor"))
    end)

    it("runs a button, asking for confirmation when the option says so", function()
        assert.are.same({}, run("/myopts exec run"))
        assert.are.same({
            "Really wipe everything?",
            "Type /myopts exec wipe confirm to run it.",
        }, run("/myopts exec wipe"))
        assert.are.same({}, run("/myopts exec wipe confirm"))
        assert.are.same({ "run", "wipe" }, executed)
        assert.are.same({ '/myopts exec: "label" is not a button' }, run("/myopts exec label"))
    end)

    it("refuses unknown, hidden and disabled options with a message", function()
        assert.are.same({ '/myopts get: unknown option "nope"' }, run("/myopts get nope"))
        assert.are.same(
            { '/myopts get: unknown option "hiddenFlag"' },
            run("/myopts get hiddenFlag")
        )
        assert.are.same({ '/myopts set: "locked" is disabled' }, run("/myopts set locked on"))
        assert.are.same({ '/myopts get: "frame" has no value' }, run("/myopts get frame"))
        assert.are.same({ '/myopts set: "run" is a button; use exec' }, run("/myopts set run 1"))
        assert.are.same({
            "/myopts set: expected an option path",
            "Usage: /myopts set <path> <value...>",
            "Change an option.",
        }, run("/myopts set"))
        assert.is_false(values.locked)
    end)

    it("refuses a tree that is not an OptionsKit tree", function()
        TestEnv.expectErrorContaining(
            "CommandKit.Scope:BindOptions tree must be an OptionsKit tree",
            function()
                CommandKit:CreateScope():BindOptions({}, "x")
            end
        )
        TestEnv.expectErrorContaining('options contains unknown field "desc"', function()
            CommandKit:CreateScope():BindOptions(tree, "x", { desc = "no" })
        end)
    end)

    it("requires OptionsKit", function()
        TestEnv.Reset()
        local Alone = TestEnv.NewPackageAlone()
        TestEnv.expectErrorContaining(
            "CommandKit.Scope:BindOptions requires OptionsKit API 1",
            function()
                Alone:CreateScope():BindOptions({}, "x")
            end
        )
    end)
end)

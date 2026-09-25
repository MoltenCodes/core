local TestEnv = require("CommandKitTestEnv")

local function noop() end

---Install a client-like emote table: `count` emote indexes, every seventh one
---missing (the client's indexes have gaps), each with one to three commands in
---mixed case. Returns the set of upper-case slash texts installed.
---@param count integer
---@return table<string, true>
local function installEmotes(count)
  local installed = {}
  for index = 1, count do
    if index % 7 ~= 0 then
      for command = 1, index % 3 + 1 do
        local text = "/Emote" .. index .. "x" .. command
        TestEnv.SetGlobal("EMOTE" .. index .. "_CMD" .. command, text)
        installed[text:upper()] = true
      end
    end
  end
  return installed
end

describe("CommandKit taken and emote checks", function()
  local CommandKit
  before_each(function()
    CommandKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  describe("the emote index", function()
    it("refuses exactly the names a full scan of the emote globals finds", function()
      local installed = installEmotes(600)
      local scope = CommandKit:CreateScope()
      for index = 1, 610 do
        for command = 1, 4 do
          local name = "emote" .. index .. "x" .. command
          local expectEmote = installed[("/" .. name):upper()] == true
          local registered, reason = scope:Register(name, { handler = noop })
          if expectEmote then
            assert.are.same({ nil, "emote" }, { registered, reason }, name)
          else
            assert.is_true(registered, name)
            scope:Unregister(name)
          end
        end
      end
    end)

    it("scans again when MAXEMOTEINDEX changes after the first scan", function()
      local scope = CommandKit:CreateScope()
      assert.are.same({ nil, "emote" }, { scope:Register("wave", { handler = noop }) })
      TestEnv.SetGlobal("MAXEMOTEINDEX", 1)
      assert.is_true(scope:Register("wave", { handler = noop }))
      assert.are.same({ nil, "emote" }, { scope:Register("dance", { handler = noop }) })
      TestEnv.SetGlobal("MAXEMOTEINDEX", nil)
      assert.are.same({ nil, "emote" }, { scope:Register("greet", { handler = noop }) })
    end)

    it("scans again when maxEmotes is lowered and raised", function()
      local scope = CommandKit:CreateScope()
      assert.are.same({ nil, "emote" }, { scope:Register("greet", { handler = noop }) })
      CommandKit:SetLimits({ maxEmotes = 1 })
      assert.is_true(scope:Register("greet", { handler = noop }))
      assert.is_true(scope:Unregister("greet"))
      CommandKit:SetLimits({ maxEmotes = 1024 })
      assert.are.same({ nil, "emote" }, { scope:Register("greet", { handler = noop }) })
    end)

    it("scans again when the host's issecretvalue appears or changes", function()
      local scope = CommandKit:CreateScope()
      assert.are.same({ nil, "emote" }, { scope:Register("dance", { handler = noop }) })
      TestEnv.SetGlobal("issecretvalue", function(value)
        return value == "/dance"
      end)
      assert.is_true(scope:Register("dance", { handler = noop }))
      assert.is_true(scope:Unregister("dance"))
      TestEnv.SetGlobal("issecretvalue", function()
        return false
      end)
      assert.are.same({ nil, "emote" }, { scope:Register("dance", { handler = noop }) })
    end)

    it("keeps no index from a scan that met a secret, and asks the probe again", function()
      local hidden = true
      TestEnv.SetGlobal("issecretvalue", function(value)
        return hidden and value == "/dance"
      end)
      local scope = CommandKit:CreateScope()
      assert.is_true(scope:Register("dance", { handler = noop }))
      assert.is_true(scope:Unregister("dance"))
      -- The same probe answers differently now; an index kept from the
      -- first scan would still lack /dance.
      hidden = false
      assert.are.same({ nil, "emote" }, { scope:Register("dance", { handler = noop }) })
    end)

    it(
      "reads the emote globals once: one set by an addon after the first scan is not seen",
      function()
        -- The client defines its emote commands in GlobalStrings, before any
        -- addon loads, and never adds one; see docs/API.md, "The taken check".
        local scope = CommandKit:CreateScope()
        assert.is_true(scope:Register("first", { handler = noop }))
        TestEnv.SetGlobal("EMOTE3_CMD1", "/cheer")
        assert.is_true(scope:Register("cheer", { handler = noop }))
        assert.is_true(scope:Unregister("cheer"))
        -- What bounds the scan changed, so the globals are read again.
        TestEnv.SetGlobal("MAXEMOTEINDEX", 3)
        assert.are.same({ nil, "emote" }, { scope:Register("cheer", { handler = noop }) })
      end
    )

    it("still asks hash_EmoteTokenList on every check", function()
      local scope = CommandKit:CreateScope()
      assert.is_true(scope:Register("first", { handler = noop }))
      TestEnv.SetGlobal("hash_EmoteTokenList", { ["/CHEER"] = "CHEER" })
      assert.are.same({ nil, "emote" }, { scope:Register("cheer", { handler = noop }) })
    end)
  end)

  describe("the foreign slash scan", function()
    it("reads every alias live, although it builds each global name once", function()
      local list = TestEnv.GetGlobal("SlashCmdList")
      list.OTHERADDON = noop
      TestEnv.SetGlobal("SLASH_OTHERADDON1", "/other")
      local scope = CommandKit:CreateScope()
      assert.are.same({ nil, "taken" }, { scope:Register("other", { handler = noop }) })
      assert.is_true(scope:Register("second", { handler = noop }))
      assert.is_true(scope:Unregister("second"))

      -- A second alias on a key already scanned.
      TestEnv.SetGlobal("SLASH_OTHERADDON2", "/Second")
      assert.are.same({ nil, "taken" }, { scope:Register("second", { handler = noop }) })
      -- An alias that changes frees the old name and takes the new one.
      TestEnv.SetGlobal("SLASH_OTHERADDON1", "/renamed")
      assert.is_true(scope:Register("other", { handler = noop }))
      assert.are.same({ nil, "taken" }, { scope:Register("RENAMED", { handler = noop }) })
      -- A key that appears later.
      list.LATERADDON = noop
      TestEnv.SetGlobal("SLASH_LATERADDON1", "/later")
      assert.are.same({ nil, "taken" }, { scope:Register("later", { handler = noop }) })
      -- A chat type that appears later.
      TestEnv.GetGlobal("ChatTypeInfo").YELL = {}
      TestEnv.SetGlobal("SLASH_YELL1", "/y")
      assert.are.same({ nil, "taken" }, { scope:Register("y", { handler = noop }) })
    end)

    it("compares without case and never mistakes a longer or shorter alias", function()
      local list = TestEnv.GetGlobal("SlashCmdList")
      list.OTHERADDON = noop
      TestEnv.SetGlobal("SLASH_OTHERADDON1", "/ToGgLe")
      TestEnv.SetGlobal("SLASH_OTHERADDON2", "/toggles")
      local scope = CommandKit:CreateScope()
      assert.are.same({ nil, "taken" }, { scope:Register("toggle", { handler = noop }) })
      assert.are.same({ nil, "taken" }, { scope:Register("TOGGLES", { handler = noop }) })
      assert.is_true(scope:Register("toggl", { handler = noop }))
      assert.is_true(scope:Register("toggless", { handler = noop }))
    end)

    it("allocates only the command's record on Register and Unregister #allocation", function()
      local list = TestEnv.GetGlobal("SlashCmdList")
      for index = 1, 50 do
        list["OTHERADDON" .. index] = noop
        TestEnv.SetGlobal("SLASH_OTHERADDON" .. index .. "1", "/other" .. index)
      end
      installEmotes(600)
      local scope = CommandKit:CreateScope()
      local spec = { handler = noop }
      scope:Register("plain", spec)
      scope:Unregister("plain")
      local allocated = TestEnv.AllocatedKilobytes(function()
        for _ = 1, 100 do
          scope:Register("plain", spec)
          scope:Unregister("plain")
        end
      end)
      -- The record and its usage lines: well under 1 KiB a pair. Revision 6
      -- built every foreign alias and emote global name again on each call.
      assert.is_true(allocated / 100 < 1, "one pair allocated " .. allocated / 100 .. " KiB")
    end)
  end)
end)

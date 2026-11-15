local Env = require("ClientKitTestEnv")

describe("ClientKit:IsSecret", function()
  after_each(function()
    Env.Reset()
  end)

  it("asks issecretvalue on a client with secret values", function()
    local ClientKit = Env.NewPackageFor("mainline")
    local secret = Env.NewSecretValue()

    assert.is_true(ClientKit:IsSecret(secret))
    assert.is_false(ClientKit:IsSecret({}))
    assert.is_false(ClientKit:IsSecret("Player"))
    assert.is_false(ClientKit:IsSecret(nil))
  end)

  for _, profileName in ipairs({ "mists", "tbc", "classic", "noProjectId" }) do
    it("answers false for everything on the " .. profileName .. " host", function()
      local ClientKit = Env.NewPackageFor(profileName)
      assert.is_false(ClientKit:IsSecret(Env.NewSecretValue()))
      assert.is_false(ClientKit:IsSecret(42))
    end)
  end
end)

describe("ClientKit:CanAccessFrame", function()
  local ClientKit

  before_each(function()
    ClientKit = Env.NewPackageFor("mainline")
  end)
  after_each(function()
    Env.Reset()
  end)

  it("refuses a forbidden frame without asking about the context", function()
    local frame = Env.NewFrame({ forbidden = true, accessible = true })
    assert.is_false(ClientKit:CanAccessFrame(frame))
    assert.are.same({ "IsForbidden" }, frame.calls)
  end)

  it("refuses a frame the current context may not access", function()
    local frame = Env.NewFrame({ forbidden = false, accessible = false })
    assert.is_false(ClientKit:CanAccessFrame(frame))
    assert.are.same({ "IsForbidden", "CanBeAccessedInContext" }, frame.calls)
  end)

  it("allows a frame both checks allow", function()
    local frame = Env.NewFrame({ forbidden = false, accessible = true })
    assert.is_true(ClientKit:CanAccessFrame(frame))
  end)

  it("uses IsForbidden alone on a client that predates the context check", function()
    assert.is_true(ClientKit:CanAccessFrame(Env.NewFrame({ forbidden = false })))
    assert.is_false(ClientKit:CanAccessFrame(Env.NewFrame({ forbidden = true })))
  end)

  it("answers true when the host offers no restriction at all", function()
    assert.is_true(ClientKit:CanAccessFrame(Env.NewFrame()))
  end)

  it("rejects a value that is not a frame table", function()
    Env.expectErrorContaining("ClientKit:CanAccessFrame frame must be a frame table", function()
      ClientKit:CanAccessFrame("UIParent")
    end)
  end)
end)

describe("ClientKit:IsEventValid", function()
  after_each(function()
    Env.Reset()
  end)

  it("answers true for an event the client knows", function()
    local ClientKit = Env.NewPackageFor("mainline")
    assert.is_true(ClientKit:IsEventValid("PLAYER_LOGIN"))
  end)

  it("answers false for a name the client does not know", function()
    local ClientKit = Env.NewPackageFor("mainline")
    assert.is_false(ClientKit:IsEventValid("NOT_A_REAL_EVENT"))
  end)

  it("follows the client's answer as it changes", function()
    local ClientKit = Env.NewPackageFor("tbc")
    Env.SetEventValid("LEARNED_SPELL_IN_TAB", true)
    assert.is_true(ClientKit:IsEventValid("LEARNED_SPELL_IN_TAB"))
    Env.SetEventValid("LEARNED_SPELL_IN_TAB", false)
    assert.is_false(ClientKit:IsEventValid("LEARNED_SPELL_IN_TAB"))
  end)

  it("answers nil, meaning unknown, when the client cannot say", function()
    local ClientKit = Env.NewPackageFor("classic")
    assert.is_nil(ClientKit:IsEventValid("PLAYER_LOGIN"))
    assert.is_nil(ClientKit:IsEventValid("NOT_A_REAL_EVENT"))
  end)

  it("rejects an event name that is not a string", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.expectErrorContaining("ClientKit:IsEventValid eventName must be a string", function()
      ClientKit:IsEventValid(42)
    end)
  end)
end)

describe("ClientKit secret probe resolution", function()
  after_each(function()
    Env.Reset()
  end)

  it("honours an issecretvalue installed after load on a client that had none", function()
    local ClientKit = Env.NewPackageFor("mists")
    local secret = Env.NewSecretValue()
    assert.is_false(ClientKit:IsSecret(secret))

    -- The stub stands in for a client API that only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret) or value == "hiddenName"
    end)

    assert.is_true(ClientKit:IsSecret(secret))
    assert.is_false(ClientKit:IsSecret("Player"))
    assert.has_error(function()
      ClientKit:Has("hiddenName")
    end, "ClientKit:Has capability must not be a secret value")
  end)
end)

describe("ClientKit value descriptions", function()
  after_each(function()
    Env.Reset()
  end)

  ---A table whose `__tostring` records that it ran, then raises.
  ---@return table key
  ---@return fun(): integer ran how often `__tostring` ran
  local function trappedKey()
    local runs = 0
    local key = setmetatable({}, {
      __tostring = function()
        runs = runs + 1
        error("__tostring must not run inside ClientKit")
      end,
    })
    return key, function()
      return runs
    end
  end

  it("names a table limit key by type without running its __tostring", function()
    local ClientKit = Env.NewPackageFor("mainline")
    local key, runs = trappedKey()
    assert.has_error(function()
      ClientKit:SetLimits({ [key] = 1 })
    end, "ClientKit:SetLimits does not know limit <table>")
    assert.are.equal(0, runs())
  end)

  it("names a table field written to a manifest by type without running its __tostring", function()
    local ClientKit = Env.NewPackageFor("mainline")
    Env.RegisterAddOn("MyAddon")
    local manifest = ClientKit:GetManifest("MyAddon")
    local key, runs = trappedKey()
    assert.has_error(function()
      manifest[key] = true
    end, 'ClientKit manifest for "MyAddon" is read-only; field <table> cannot be written')
    assert.are.equal(0, runs())
  end)

  it("still shows strings quoted and numbers and booleans as written", function()
    local ClientKit = Env.NewPackageFor("mainline")
    assert.has_error(function()
      ClientKit:Has("nope")
    end, 'ClientKit:Has does not know capability "nope"')
    assert.has_error(function()
      ClientKit:SetLimits({ [7] = 1 })
    end, "ClientKit:SetLimits does not know limit 7")
  end)
end)

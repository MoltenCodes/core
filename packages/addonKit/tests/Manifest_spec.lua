local TestEnv = require("AddonKitTestEnv")

---Read a whole file from the repository root.
---@param path string
---@return string
local function readFile(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

-- The generation every catalogue entry had when it was published. Inside
-- AddonKit API 1 an entry's generation never changes; new Kits only add rows
-- here and to the catalogue.
local PUBLISHED_GENERATIONS = {
  ApiKit = 1,
  BarKit = 1,
  BindingKit = 1,
  BridgeKit = 1,
  BrokerKit = 1,
  CacheKit = 1,
  ClientKit = 1,
  CodecKit = 1,
  CommandKit = 1,
  CommKit = 1,
  CompatKit = 1,
  DialogKit = 1,
  EditModeKit = 1,
  EventKit = 1,
  GlowKit = 1,
  HookKit = 1,
  InteropKit = 1,
  LauncherKit = 1,
  LifecycleKit = 1,
  LocaleKit = 1,
  LogKit = 1,
  MediaKit = 1,
  MenuKit = 1,
  ModuleKit = 1,
  OptionsKit = 1,
  PanelKit = 1,
  PoolKit = 1,
  ProfileKit = 1,
  RangeKit = 1,
  ReadinessKit = 1,
  SchedulerKit = 1,
  SchemaKit = 1,
  SettingsKit = 1,
  SignalKit = 1,
  TestKit = 1,
  TimerKit = 1,
  ToastKit = 1,
  TooltipKit = 1,
  UnitFrameKit = 1,
  WidgetKit = 1,
}

---Every package directory name under `packages/`.
---@return string[]
local function packageDirectories()
  local names = {}
  local listing = assert(io.popen("ls packages"))
  for name in listing:lines() do
    local manifest = io.open("packages/" .. name .. "/package.manifest.json", "r")
    if manifest ~= nil then
      manifest:close()
      names[#names + 1] = name
    end
  end
  listing:close()
  return names
end

describe("AddonKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision, and each part's revision", function()
    local AddonKit = TestEnv.NewPackage()
    TestEnv.LoadParts()
    local text = readFile("packages/addonKit/package.manifest.json")
    assert.are.equal(AddonKit.API, tonumber(text:match('"api"%s*:%s*(%d+)')))
    assert.are.equal(AddonKit.REVISION, tonumber(text:match('"revision"%s*:%s*(%d+)')))
    local parts = rawget(AddonKit, "_state").parts
    for _, part in ipairs({ "Database", "Composition" }) do
      local block = text:match('"' .. part .. '"%s*:%s*(%b{})')
      assert.is_string(block)
      assert.are.equal(parts[part].revision, tonumber(block:match('"revision"%s*:%s*(%d+)')))
      local source = readFile("packages/addonKit/src/parts/AddonKit-" .. part .. ".lua")
      assert.are.equal(parts[part].revision, tonumber(source:match("local PART_REVISION = (%d+)")))
    end
  end)

  it("declares Registry API 2 as its only required dependency", function()
    local text = readFile("packages/addonKit/package.manifest.json")
    assert.is_truthy(
      text:find('"dependencies"%s*:%s*{%s*"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}%s*}')
    )
    assert.is_truthy(text:find('"version"%s*:%s*"%d+%.%d+%.%d+"'))
    assert.is_truthy(text:find('"license"%s*:%s*"MIT"'))
  end)
end)

describe("AddonKit catalogue", function()
  after_each(TestEnv.Reset)

  it("hands out every package of the repository, at a generation that exists", function()
    local AddonKit = TestEnv.NewPackage()
    local catalogue = AddonKit:GetCatalogue()
    local seen = {}
    for _, directory in ipairs(packageDirectories()) do
      local text = readFile("packages/" .. directory .. "/package.manifest.json")
      local name = text:match('"name"%s*:%s*"([^"]+)"')
      local displayName = text:match('"displayName"%s*:%s*"([^"]+)"')
      local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
      if name ~= "registry" and name ~= "addonKit" then
        local entry = catalogue[displayName]
        assert.is_table(entry, displayName .. " is missing from AddonKit's catalogue")
        assert.are.equal(name, entry.packageId)
        assert.are.equal(api, entry.api, displayName .. " is handed out at another generation")
        seen[displayName] = true
      end
    end
    for displayName in pairs(catalogue) do
      assert.is_true(seen[displayName] == true, displayName .. " has no package")
    end
  end)

  it("never changes a published entry's generation", function()
    local AddonKit = TestEnv.NewPackage()
    local catalogue = AddonKit:GetCatalogue()
    for displayName, generation in pairs(PUBLISHED_GENERATIONS) do
      assert.is_table(catalogue[displayName], displayName .. " was removed from the catalogue")
      assert.are.equal(generation, catalogue[displayName].api, displayName .. " changed generation")
    end
  end)

  it("answers a fresh copy on every call", function()
    local AddonKit = TestEnv.NewPackage()
    local first = AddonKit:GetCatalogue()
    first.TimerKit.api = 7
    assert.are.equal(1, AddonKit:GetCatalogue().TimerKit.api)
  end)
end)

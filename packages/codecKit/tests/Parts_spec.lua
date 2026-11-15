local TestEnv = require("CodecKitTestEnv")
local Async = TestEnv.Async
local Core = TestEnv.Core
local CoreAsync = TestEnv.CoreAsync

local SOURCE = debug.getinfo(1, "S").short_src

-- Revision 10 splits CodecKit into a core and the Compression part
-- (ADR 0001). These specs pin the part's bootstrap, the core without it, and
-- the upgrade from revision 9, the last whole file.

local MISSING_TAIL = " is in CodecKit's Compression part, which is not loaded: add "
  .. "codecKit\\parts\\CodecKit-Compression.lua to embeds.xml after codecKit\\CodecKit.lua"

---Run `action` and assert it failed with `message` at the line after the one
---that called `mark()`.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

---Read the package manifest.
---@return string
local function readManifest()
  local file = assert(io.open("packages/codecKit/package.manifest.json", "r"))
  local text = file:read("*a")
  file:close()
  return text
end

---A compressible input of a few hundred bytes.
---@return string
local function compressible()
  return string.rep("a part is loaded only by the addons that use it; ", 12)
end

describe("CodecKit Compression part", function()
  after_each(function()
    TestEnv.Reset()
    Core.Reset()
    Async.Reset()
    CoreAsync.Reset()
  end)

  describe("bootstrap", function()
    it("declares the revision its file carries, last in the manifest", function()
      local text = readManifest()
      local parts = text:match('"parts"%s*:%s*(%b{})')
      assert.is_not_nil(parts)
      local declared = tonumber(parts:match('"Compression"%s*:%s*{.-"revision"%s*:%s*(%d+)'))
      local CodecKit = TestEnv.NewPackage()
      assert.are.equal(CodecKit._state.parts.Compression.revision, declared)
      assert.are.equal(1, declared)
      assert.is_true(text:find('"parts"', 1, true) > text:find('"optionalDependencies"', 1, true))
    end)

    it("needs the core loaded first", function()
      TestEnv.Reset()
      require("Registry")
      require("PoolKit")
      TestEnv.expectErrorContaining(
        "MoltenCodes CodecKit part Compression requires CodecKit API 1 to be loaded first",
        function()
          TestEnv.LoadPart()
        end
      )
    end)

    it("refuses a core that offers no part interface", function()
      TestEnv.Reset()
      require("Registry")
      require("PoolKit")
      -- Revision 9, the last whole file, has no `partInterface`.
      TestEnv.LoadRevision(9)
      TestEnv.expectErrorContaining(
        "MoltenCodes CodecKit part Compression requires CodecKit API 1 to be loaded first",
        function()
          TestEnv.LoadPart()
        end
      )
    end)

    it("fills the core's compression entries and records its revision", function()
      local CodecKit = Core.NewPackage()
      assert.is_false(CodecKit._state.compression.compress)
      assert.is_false(CodecKit:HasPart("Compression"))
      local returned = TestEnv.LoadPart()
      assert.are.equal(CodecKit, returned)
      assert.are.equal("function", type(CodecKit._state.compression.compress))
      assert.are.equal("function", type(CodecKit._state.compression.decompress))
      assert.is_true(CodecKit:HasPart("Compression"))
    end)

    it("leaves an equal or newer installed revision untouched", function()
      local CodecKit = TestEnv.NewPackage()
      local compress = CodecKit._state.compression.compress
      TestEnv.LoadPart()
      assert.are.equal(compress, CodecKit._state.compression.compress)
      TestEnv.LoadPartRevision(0)
      assert.are.equal(compress, CodecKit._state.compression.compress)
      assert.are.equal(1, CodecKit._state.parts.Compression.revision)
    end)

    it("upgrades in place to a newer revision, writing the same bytes", function()
      local CodecKit = TestEnv.NewPackage()
      local input = compressible()
      local _, before = CodecKit:Compress(input)
      local compress = CodecKit._state.compression.compress
      TestEnv.LoadPartRevision(2)
      assert.are_not.equal(compress, CodecKit._state.compression.compress)
      assert.are.equal(2, CodecKit._state.parts.Compression.revision)
      assert.are.same({ true, before }, { CodecKit:Compress(input) })
      assert.are.equal(input, select(2, CodecKit:Decompress(before)))
    end)

    it("is served by a core upgraded after it loaded", function()
      local CodecKit = TestEnv.NewPackage()
      local input = compressible()
      local _, before = CodecKit:Compress(input)
      local openSink = CodecKit._state.helpers.openSink
      TestEnv.LoadRevision(CodecKit.REVISION + 1)
      assert.are_not.equal(openSink, CodecKit._state.helpers.openSink)
      assert.is_true(CodecKit:HasPart("Compression"))
      assert.are.same({ true, before }, { CodecKit:Compress(input) })
      assert.are.equal(0, CodecKit._state.pool:GetActiveCount())
    end)
  end)

  describe("HasPart", function()
    it("answers for the part by name", function()
      local CodecKit = TestEnv.NewPackage()
      assert.is_true(CodecKit:HasPart("Compression"))
      assert.is_false(CodecKit:HasPart("Print"))
      assert.is_false(CodecKit:HasPart(""))
    end)

    it("refuses a wrong receiver, a non-string and a secret at the caller", function()
      local CodecKit = TestEnv.NewPackage()
      assertReportedAtCaller(
        "CodecKit:HasPart must be called on the CodecKit facade; use CodecKit:HasPart(...)",
        function(mark)
          mark()
          CodecKit.HasPart({}, "Compression")
        end
      )
      assertReportedAtCaller("CodecKit:HasPart name must be a string", function(mark)
        mark()
        CodecKit:HasPart(1)
      end)
      local secret = TestEnv.NewSecret()
      TestEnv.InstallSecretProbe({ [secret] = true })
      assertReportedAtCaller("CodecKit:HasPart name must not be a secret value", function(mark)
        mark()
        CodecKit:HasPart(secret)
      end)
    end)
  end)

  describe("without the part", function()
    local CodecKit
    before_each(function()
      CodecKit = Core.NewPackage()
    end)

    it("raises at the caller for every method that compresses, naming the file", function()
      assertReportedAtCaller("CodecKit:Compress" .. MISSING_TAIL, function(mark)
        mark()
        CodecKit:Compress("bytes")
      end)
      assertReportedAtCaller("CodecKit:Decompress" .. MISSING_TAIL, function(mark)
        mark()
        CodecKit:Decompress("bytes")
      end)
      assertReportedAtCaller(
        'CodecKit:Encode options.compress "deflate"' .. MISSING_TAIL,
        function(mark)
          mark()
          CodecKit:Encode({ 1 }, { compress = "deflate" })
        end
      )
      assertReportedAtCaller(
        'CodecKit:EncodeMany options.compress "deflate"' .. MISSING_TAIL,
        function(mark)
          mark()
          CodecKit:EncodeMany({ compress = "deflate", channel = "addon" }, 1, 2)
        end
      )
    end)

    it("keeps the option errors that come first", function()
      TestEnv.expectErrorContaining(
        'CodecKit:Encode options.compress must be "none" or "deflate"',
        function()
          CodecKit:Encode(1, { compress = "zip" })
        end
      )
      TestEnv.expectErrorContaining(
        "CodecKit:Encode options.level must be an integer from 1 to 9",
        function()
          CodecKit:Encode(1, { compress = "deflate", level = 0 })
        end
      )
    end)

    it("serialises and channel-encodes as before", function()
      local value = { "core", 7, { nested = true } }
      for _, channel in ipairs({ "none", "addon", "print" }) do
        local ok, text = CodecKit:Encode(value, { channel = channel, compress = "none" })
        assert.is_true(ok)
        assert.are.same({ true, value }, { CodecKit:Decode(text) })
      end
    end)

    it("decodes a compressed frame to compressionUnavailable, never raising", function()
      local Whole = TestEnv.NewPackage()
      local value = { compressible() }
      local frames = {}
      for _, channel in ipairs({ "none", "addon", "print" }) do
        frames[#frames + 1] =
          select(2, Whole:Encode(value, { compress = "deflate", channel = channel }))
      end
      local many = select(2, Whole:EncodeMany({ compress = "deflate" }, 1, nil, 3))
      TestEnv.Reset()

      CodecKit = Core.NewPackage()
      for index = 1, #frames do
        assert.are.same({ false, "compressionUnavailable" }, { CodecKit:Decode(frames[index]) })
      end
      assert.are.same({ false, "compressionUnavailable" }, { CodecKit:DecodeMany(many) })
      assert.are.equal(0, CodecKit._state.pool:GetActiveCount())
    end)
  end)

  describe("without the part, asynchronously", function()
    it("refuses EncodeAsync with compression at the caller", function()
      local CodecKit, _, _, _, SchedulerKit = CoreAsync.NewPackage()
      local scope = SchedulerKit:CreateScope()
      assertReportedAtCaller(
        'CodecKit:EncodeAsync options.compress "deflate"' .. MISSING_TAIL,
        function(mark)
          mark()
          CodecKit:EncodeAsync({ 1 }, { compress = "deflate" }, scope, function() end)
        end
      )
    end)

    it("calls DecodeAsync back with compressionUnavailable", function()
      local Whole = Async.NewPackage()
      local _, frame = Whole:Encode({ compressible() }, { compress = "deflate" })
      Async.Reset()

      local CodecKit, _, _, _, SchedulerKit = CoreAsync.NewPackage()
      local results = nil
      CodecKit:DecodeAsync(frame, nil, SchedulerKit:CreateScope(), function(ok, reason)
        results = { ok, reason }
      end)
      for _ = 1, 10 do
        CoreAsync.Tick()
      end
      assert.are.same({ false, "compressionUnavailable" }, results)
    end)
  end)

  describe("upgrading from revision 9, the last whole file", function()
    ---A value large enough that an asynchronous compression takes several
    ---frames under the ticking clock.
    local function largeValue()
      local random = TestEnv.NewRandom(41)
      local rows = {}
      for index = 1, 1500 do
        rows[index] = { id = index, name = TestEnv.RandomText(random, 5) }
      end
      return rows
    end

    ---Load the asynchronous chain with revision 9 as CodecKit, start one
    ---compressing EncodeAsync and run it partway.
    ---@return table older the revision 9 facade
    ---@return table SchedulerKit
    ---@return string expected what revision 9 writes synchronously
    ---@return table results filled by the callback
    local function startOlderJob()
      Async.PrepareTickingClock(0.5)
      require("Registry")
      require("PoolKit")
      require("TimerKit")
      local SchedulerKit = require("SchedulerKit")
      local older = TestEnv.LoadRevision(9)
      assert.are.equal(9, older.REVISION)
      local value = largeValue()
      local options = { compress = "deflate", channel = "addon" }
      local _, expected = older:Encode(value, options)
      local results = {}
      older:EncodeAsync(value, options, SchedulerKit:CreateScope(), function(ok, text)
        results[1], results[2] = ok, text
      end)
      Async.Tick()
      Async.Tick()
      assert.is_nil(results[1], "the job finished before the upgrade")
      return older, SchedulerKit, expected, results
    end

    it("upgrades in place with the part and finishes a running compression", function()
      local older, _, expected, results = startOlderJob()
      local state = older._state
      package.loaded["CodecKit"] = nil
      local CodecKit = require("CodecKit")
      TestEnv.LoadPart()
      assert.are.equal(older, CodecKit)
      assert.are.equal(10, CodecKit.REVISION)
      assert.are.equal(state, CodecKit._state)
      assert.is_true(CodecKit:HasPart("Compression"))

      Async.TickUntil(function()
        return results[1] ~= nil
      end, 10000)
      assert.are.same({ true, expected }, results)
      -- The part writes exactly what the whole file wrote.
      assert.are.same({ true, expected }, {
        CodecKit:Encode(largeValue(), { compress = "deflate", channel = "addon" }),
      })
      assert.are.same({}, Async.ReportedErrors())
    end)

    it("upgrades without the part: the running job ends, new compression raises", function()
      local older, _, expected, results = startOlderJob()
      package.loaded["CodecKit"] = nil
      local CodecKit = require("CodecKit")
      assert.are.equal(older, CodecKit)
      assert.is_false(CodecKit:HasPart("Compression"))

      -- The job runs revision 9's own code, which holds its compressor; nothing
      -- of the compression stage outlives a call, so nothing is closed and
      -- nothing is reported.
      Async.TickUntil(function()
        return results[1] ~= nil
      end, 10000)
      assert.are.same({ true, expected }, results)
      assert.are.same({}, Async.ReportedErrors())
      assert.are.same({ false, "compressionUnavailable" }, { CodecKit:Decode(expected) })
      assertReportedAtCaller("CodecKit:Compress" .. MISSING_TAIL, function(mark)
        mark()
        CodecKit:Compress("bytes")
      end)
    end)

    it("lets revision 9 loaded after a core-only revision 10 yield", function()
      local CodecKit = Core.NewPackage()
      local yielded = TestEnv.LoadRevision(9)
      assert.are.equal(CodecKit, yielded)
      assert.are.equal(10, yielded.REVISION)
      assertReportedAtCaller("CodecKit:Compress" .. MISSING_TAIL, function(mark)
        mark()
        yielded:Compress("bytes")
      end)
    end)

    it("passes revision 9's own surface check on a core-only facade", function()
      local CodecKit = Core.NewPackage()
      -- Revision 9 validates the newer facade before yielding to it, and
      -- raises when a member it knows is missing.
      assert.has_no.errors(function()
        TestEnv.LoadRevision(9)
      end)
      assert.are.equal("function", type(rawget(CodecKit, "Compress")))
    end)
  end)
end)

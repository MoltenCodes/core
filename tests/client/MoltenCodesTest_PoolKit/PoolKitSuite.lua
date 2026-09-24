-- MoltenCodes Test: PoolKitSuite.lua
--
-- Real-client suites for the `poolKit` package. The Busted specs under
-- packages/poolKit/tests/ prove PoolKit on a stock Lua 5.1 with plain tables
-- and a scripted stand-in for an animation group; these prove, inside the game
-- client with the installed MoltenCodes addon, what that fixture can only
-- simulate:
--
--   * the installed facade and its committed revision;
--   * pools of real Frames made by `CreateFrame`, with a reset that hides,
--     unanchors and unparents them, under retention bounds, the creation cap,
--     the live limit and its bounded waiting queue;
--   * `ReleaseAfter` with a real AnimationGroup: the client's own `OnFinished`
--     returns the Frame to the pool, `Release` completes it early, `Stop` and a
--     group that is not playing behave as docs/API.md says, and a reset that
--     raises when the animation finishes reaches the client's error handler;
--   * children attached to a parent Frame, released with it;
--   * the `maxActiveWarning` diagnostic through the client's error handler;
--   * the strict refusals (a foreign Frame, a second release, a discarded
--     Frame) and `strictReset`;
--   * that steady-state acquire and release of a Frame, and a request served
--     from the waiting queue, allocate nothing on the client's own collector;
--   * argument errors, and the refusal of genuine secret values made by the
--     client's `secretwrap`, pointing at this file as the client names it.
--
-- Nothing here needs combat, a group or an instance, and nothing is visible:
-- every Frame is anonymous, has no texture, and is shown only by the animation
-- tests, at alpha 0, 1x1 and parented to UIParent for the length of the
-- animation. Every wait is at most two seconds.
--
-- Run with `/mct run poolKit`; tests/client/MoltenCodesTest_PoolKit/EXPECTED.md
-- lists what the chat frame should show and the visible side effects.
--
-- What a run leaves behind. The client never frees a Frame, so this file
-- creates its Frames through one module-level bank (see "The Frame bank"
-- below) that every pool of every test draws from and gives back to. The bank
-- creates a Frame only when it has no spare one and never more than
-- `FRAME_BUDGET` (3) in a session, so a second run, and every run after it,
-- creates none. What stays for the session is those Frames, hidden, unanchored
-- and without a parent, and at most one AnimationGroup with one Alpha
-- animation on each, which PoolKit has hooked once (`OnFinished`); PoolKit
-- keeps no pending release for any of them. Every pool a test builds is
-- released and closed by the After hook of its suite, whatever the test's
-- outcome, and every Frame goes back to the bank. The client's error handler
-- is replaced only while a test waits for a report and is put back by the test
-- or, at the latest, by the After hook. Nothing is written to a global or a
-- saved variable.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
    error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local REGISTRY_API = 2
local POOL_KIT_API = 1
local PACKAGE_ID = "poolKit"

--- The most Frames this file creates in a session. Three is the most any test
--- holds at once (a parent with two children; three borrowed Frames for the
--- leak warning). A Frame is never freed, so the bank refuses to create a
--- fourth: a test that fails to give its Frames back fails the next test that
--- needs one instead of growing the session's Frames.
local FRAME_BUDGET = 3

--- How long the Alpha animation of the animation tests plays.
local ANIMATION_SECONDS = 0.1

--- How long a test waits for the client to finish an animation.
local ANIMATION_WAIT_SECONDS = 2

--- How long a test waits to see that an animation's end changes nothing: well
--- past `ANIMATION_SECONDS`, well under `ANIMATION_WAIT_SECONDS`.
local SETTLE_SECONDS = 0.4

--- How many cycles each allocation guard runs. One table or closure per cycle
--- would cost well over a hundred kilobytes at this count.
local ALLOCATION_CYCLES = 5000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-cycle one.
local ALLOCATION_TOLERANCE_KB = 1

--- Text a deliberately failing reset raises, so a test can recognise its report.
local RESET_FAILURE = "mctPoolKit deliberate reset failure"

--- Part of the diagnostic PoolKit reports when `maxActiveWarning` is reached.
local LEAK_WARNING_TEXT = "at or above its maxActiveWarning threshold of 2"

--- Why a test that needs the client's error handler could not observe it.
local HANDLER_KEPT_REASON =
    "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the report went to that addon"

--- Why an animation test did not run: the client does not play an animation of
--- a Frame that is not visible, and nothing is visible under a hidden UIParent.
local HIDDEN_INTERFACE_REASON =
    "the interface is hidden (Alt+Z); an animation does not play under a hidden UIParent"

-- Client types ----------------------------------------------------------------

-- The language-server stubs in meta/ declare only what the framework packages
-- call on a Frame, so the part of the client's Frame and animation API this
-- file calls is declared here.

---The part of a World of Warcraft Frame this file calls.
---@class MoltenCodesTest.PoolKit.Frame
---@field Show fun(self: MoltenCodesTest.PoolKit.Frame)
---@field Hide fun(self: MoltenCodesTest.PoolKit.Frame)
---@field IsShown fun(self: MoltenCodesTest.PoolKit.Frame): boolean
---@field IsVisible fun(self: MoltenCodesTest.PoolKit.Frame): boolean
---@field SetParent fun(self: MoltenCodesTest.PoolKit.Frame, parent: MoltenCodesTest.PoolKit.Frame|nil)
---@field GetParent fun(self: MoltenCodesTest.PoolKit.Frame): MoltenCodesTest.PoolKit.Frame|nil
---@field SetPoint fun(self: MoltenCodesTest.PoolKit.Frame, point: string)
---@field ClearAllPoints fun(self: MoltenCodesTest.PoolKit.Frame)
---@field GetNumPoints fun(self: MoltenCodesTest.PoolKit.Frame): integer
---@field SetSize fun(self: MoltenCodesTest.PoolKit.Frame, width: number, height: number)
---@field SetAlpha fun(self: MoltenCodesTest.PoolKit.Frame, alpha: number)
---@field CreateAnimationGroup fun(self: MoltenCodesTest.PoolKit.Frame): MoltenCodesTest.PoolKit.AnimationGroup

---The part of a World of Warcraft AnimationGroup this file calls.
---@class MoltenCodesTest.PoolKit.AnimationGroup
---@field Play fun(self: MoltenCodesTest.PoolKit.AnimationGroup)
---@field Stop fun(self: MoltenCodesTest.PoolKit.AnimationGroup)
---@field IsPlaying fun(self: MoltenCodesTest.PoolKit.AnimationGroup): boolean
---@field HookScript fun(self: MoltenCodesTest.PoolKit.AnimationGroup, scriptName: string, handler: function)
---@field CreateAnimation fun(self: MoltenCodesTest.PoolKit.AnimationGroup, animationType: string): MoltenCodesTest.PoolKit.AlphaAnimation

---The part of a World of Warcraft Alpha animation this file calls.
---@class MoltenCodesTest.PoolKit.AlphaAnimation
---@field SetFromAlpha fun(self: MoltenCodesTest.PoolKit.AlphaAnimation, alpha: number)
---@field SetToAlpha fun(self: MoltenCodesTest.PoolKit.AlphaAnimation, alpha: number)
---@field SetDuration fun(self: MoltenCodesTest.PoolKit.AlphaAnimation, seconds: number)

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
    -- CreateFrame, UIParent, GetTime, the error handler and the secret-value
    -- functions are World of Warcraft client globals, reachable only through
    -- the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
    error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- PoolKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade and its
-- pools are typed `any` here.

---@type any
local PoolKit = Registry:Get(PACKAGE_ID, POOL_KIT_API)
if type(PoolKit) == "nil" then
    error(addonName .. " requires PoolKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

local createFrame = readHost("CreateFrame")
---@type MoltenCodesTest.PoolKit.Frame
local uiParent = readHost("UIParent")
local getTime = readHost("GetTime")
if type(createFrame) ~= "function" or type(uiParent) ~= "table" or type(getTime) ~= "function" then
    error(addonName .. " requires the client's CreateFrame, UIParent and GetTime", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- The Frame bank -----------------------------------------------------------------------
--
-- Every pool a test builds creates its Frames by borrowing one from this bank
-- and destroys them by giving them back, so the Frames outlive the pools: a
-- fresh pool per test keeps the tests independent, and the bank keeps the
-- session's Frames at the most any one test needs at once, however many runs.

--- Frames the bank holds for the next pool, used newest first.
---@type MoltenCodesTest.PoolKit.Frame[]
local spareFrames = {}

--- Frames a pool has borrowed from the bank and not given back.
---@type table<MoltenCodesTest.PoolKit.Frame, true>
local lentFrames = {}

--- How many Frames the bank has created this session.
local framesCreated = 0

--- The one fade-out animation group of each Frame an animation test used,
--- created the first time and reused for the session, as a pooled Frame of an
--- addon would reuse its own.
---@type table<MoltenCodesTest.PoolKit.Frame, MoltenCodesTest.PoolKit.AnimationGroup>
local fadeByFrame = {}

---Hide `frame`, clear its anchors and take it off its parent: the reset every
---Frame pool of this file uses, and what the bank does to a Frame it takes back.
---@param frame MoltenCodesTest.PoolKit.Frame
local function stripFrame(frame)
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(nil)
end

---Create one hidden, anonymous, parentless Frame at alpha 0, or raise when the
---session's budget is spent.
---@return MoltenCodesTest.PoolKit.Frame
local function createProbeFrame()
    if framesCreated >= FRAME_BUDGET then
        error(
            ("the Frame bank's budget of %d Frames is spent: an earlier test did not give its Frames back"):format(
                FRAME_BUDGET
            ),
            0
        )
    end
    ---@type MoltenCodesTest.PoolKit.Frame
    local frame = createFrame("Frame")
    frame:Hide()
    frame:SetAlpha(0)
    framesCreated = framesCreated + 1
    return frame
end

---Lend a Frame to a pool: a spare one when there is one, a new one otherwise.
---The `create` callback of every Frame pool of this file.
---@return MoltenCodesTest.PoolKit.Frame
local function borrowBankFrame()
    local count = #spareFrames
    local frame
    if count > 0 then
        frame = spareFrames[count]
        spareFrames[count] = nil
    else
        frame = createProbeFrame()
    end
    lentFrames[frame] = true
    return frame
end

---Take a Frame back from a pool, stopping its animation and stripping it. The
---`destroy` callback of every Frame pool of this file; a Frame the bank did not
---lend is ignored, so a second call for one Frame is harmless.
---@param frame MoltenCodesTest.PoolKit.Frame
local function returnBankFrame(frame)
    if lentFrames[frame] ~= true then
        return
    end
    lentFrames[frame] = nil
    local fade = fadeByFrame[frame]
    if fade ~= nil then
        fade:Stop()
    end
    stripFrame(frame)
    frame:SetAlpha(0)
    spareFrames[#spareFrames + 1] = frame
end

---Whether `frame` is back in the bank, spare.
---@param frame MoltenCodesTest.PoolKit.Frame
---@return boolean
local function isInBank(frame)
    for _, spare in ipairs(spareFrames) do
        if spare == frame then
            return true
        end
    end
    return false
end

---The fade-out animation group of `frame`: an Alpha animation from 0 to 0, so
---nothing is ever drawn, that plays for `ANIMATION_SECONDS`.
---@param frame MoltenCodesTest.PoolKit.Frame
---@return MoltenCodesTest.PoolKit.AnimationGroup
local function fadeOutOf(frame)
    local fade = fadeByFrame[frame]
    if fade == nil then
        fade = frame:CreateAnimationGroup()
        local alpha = fade:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0)
        alpha:SetToAlpha(0)
        alpha:SetDuration(ANIMATION_SECONDS)
        fadeByFrame[frame] = fade
    end
    return fade
end

---Show `frame` where nothing can be seen: 1x1 at the centre of UIParent, at
---alpha 0, with no texture. The client plays an animation only on a visible
---Frame; the pool's reset takes it off UIParent again.
---@param frame MoltenCodesTest.PoolKit.Frame
local function showInvisibly(frame)
    frame:SetParent(uiParent)
    frame:SetSize(1, 1)
    frame:SetPoint("CENTER")
    frame:SetAlpha(0)
    frame:Show()
end

-- Pools of the running test ----------------------------------------------------------------

--- Pools the running test built; the After hook releases and closes them.
---@type any[]
local trackedPools = {}

--- Puts the client's error handler back, while a test has it replaced.
---@type fun()|nil
local restoreHandler = nil

---Build a pool of Frames from the bank and remember it for the After hook.
---`create` and `destroy` default to the bank's; every other option is the
---test's own.
---@param options table PoolKit:New options without `create`
---@return any pool
local function newFramePool(options)
    if type(options.create) == "nil" then
        options.create = borrowBankFrame
    end
    if type(options.destroy) == "nil" then
        options.destroy = returnBankFrame
    end
    local pool = PoolKit:New(options)
    trackedPools[#trackedPools + 1] = pool
    return pool
end

---Put back the client's error handler if a test replaced it.
local function restoreErrorHandler()
    local restore = restoreHandler
    restoreHandler = nil
    if restore ~= nil then
        restore()
    end
end

---Release every Frame the running test still holds, close its pools and take
---every Frame back into the bank, whatever the test's outcome. The After hook
---of every suite.
local function releaseEverything()
    restoreErrorHandler()
    for index = #trackedPools, 1, -1 do
        local pool = trackedPools[index]
        -- A snapshot, because a release may lend or take back a Frame, and
        -- adding a key to a table during `pairs` over it is undefined.
        local lent = {}
        for frame in pairs(lentFrames) do
            lent[#lent + 1] = frame
        end
        for _, frame in ipairs(lent) do
            if pool:IsActive(frame) then
                pcall(pool.Release, pool, frame)
            end
        end
        -- Close completes every parked release and destroys every retained Frame.
        pcall(pool.Close, pool)
        trackedPools[index] = nil
    end
    -- A Frame whose reset raised stays borrowed from its closed pool. Setting
    -- the current key to nil during `pairs`, as `returnBankFrame` does, is
    -- allowed.
    for frame in pairs(lentFrames) do
        returnBankFrame(frame)
    end
end

---Register a suite of this package whose tests all end with every Frame back
---in the bank.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
    local suite = Harness:Suite(PACKAGE_ID, part, addonName)
    suite:After(releaseEverything)
    return suite
end

---End the running test as skipped when UIParent is not visible.
---@param ctx TestKit.Context
local function requireVisibleInterface(ctx)
    if not uiParent:IsVisible() then
        Harness:SkipTest(ctx, HIDDEN_INTERFACE_REASON)
    end
end

---Let the client render frames for `seconds`.
---@param ctx TestKit.Context
---@param seconds number
local function settle(ctx, seconds)
    local deadline = getTime() + seconds
    ctx:WaitUntil(function()
        return getTime() >= deadline
    end, ANIMATION_WAIT_SECONDS)
end

-- Positions and errors ------------------------------------------------------------------------

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
    local file, line = position:match("^(.-):(%d+): ")
    return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
---@return integer
local function currentLine()
    local _, position = pcall(error, "", 3)
    local _, line = splitPosition(position or "")
    return line or 0
end

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
    ctx:Expect(type(message)):ToBe("string")
    if type(message) ~= "string" then
        return nil
    end
    local file, line = splitPosition(message)
    ctx:Expect(type(file)):ToBe("string")
    ctx:Expect((file or ""):sub(-#"PoolKitSuite.lua")):ToBe("PoolKitSuite.lua")
    return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
    local succeeded, message = pcall(raise)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. tostring(message))

    local line = expectThisFile(ctx, message)
    ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
    ctx:Expect(line):ToBe(lineBox.start + 1)
end

---Route every report the client's error handler receives that contains
---`marker` to a list, and every other report to the handler it replaced, until
---`restoreErrorHandler()` runs (the test's, or the After hook's).
---
---PoolKit reports a diagnostic or a failure it cannot raise to anybody by
---calling `geterrorhandler()`, which on the client reads the handler
---`seterrorhandler` installed, so that is the one to swap; replacing the global
---`geterrorhandler` would taint a function Blizzard code calls.
---@param marker string
---@return any[] reported every report that contained `marker`, in order
---@return boolean observed whether the swap took effect
local function interceptReports(marker)
    local reported = {}
    local setErrorHandler = readHost("seterrorhandler")
    local getErrorHandler = readHost("geterrorhandler")
    if type(setErrorHandler) ~= "function" or type(getErrorHandler) ~= "function" then
        return reported, false
    end

    local previous = getErrorHandler()
    ---@param message any
    local function collector(message)
        if type(message) == "string" and message:find(marker, 1, true) ~= nil then
            reported[#reported + 1] = message
        elseif type(previous) == "function" then
            previous(message)
        end
    end

    setErrorHandler(collector)
    restoreHandler = function()
        setErrorHandler(previous)
    end
    -- An error-capturing addon (BugGrabber) may refuse the swap.
    return reported, getErrorHandler() == collector
end

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
    local before = collectgarbage("count")
    work()
    return collectgarbage("count") - before
end

---Run a full collection in a step of its own, so the measurement that follows
---starts far from the next collector cycle, which would otherwise shrink the
---count mid-measurement and hide an allocation.
---@param ctx TestKit.Context
local function collectBeforeMeasuring(ctx)
    collectgarbage("collect")
    ctx:Yield()
end

-- poolKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
    "Registry:Get('poolKit', 1) is the PoolKit facade with API 1, New, NewTablePool, UNBOUNDED and DEFAULT_MAX_RETAINED 128",
    function(ctx)
        ctx:Expect(type(PoolKit)):ToBe("table")
        ctx:Expect(rawget(PoolKit, "API")):ToBe(POOL_KIT_API)
        ctx:Expect(type(PoolKit.New)):ToBe("function")
        ctx:Expect(type(PoolKit.NewTablePool)):ToBe("function")
        ctx:Expect(type(PoolKit.UNBOUNDED)):ToBe("table")
        ctx:Expect(PoolKit.DEFAULT_MAX_RETAINED):ToBe(128)
    end
)

facade:Test("the installed PoolKit carries the revision of the committed manifest", function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
        ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
        return
    end
    for _, expected in ipairs(expectedPackages) do
        if expected.id == PACKAGE_ID then
            local _, revision = Registry:Get(PACKAGE_ID, POOL_KIT_API)
            ctx:Expect(revision):ToBe(expected.revision)
            ctx:Expect(rawget(PoolKit, "REVISION")):ToBe(expected.revision)
            return
        end
    end
    ctx:Fail("Expected.lua does not list poolKit")
end)

-- poolKit.frames ------------------------------------------------------------------------------

local frames = newSuite("frames")

frames:Test(
    "a released Frame comes back from Acquire as the same Frame, hidden, unanchored and without a parent",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local frame = pool:Acquire()
        showInvisibly(frame)
        ctx:Expect(frame:IsShown()):ToBe(true)
        ctx:Expect(frame:GetParent()):ToBe(uiParent)

        ctx:Expect(pool:Release(frame)):ToBe(true)
        ctx:Expect(frame:IsShown()):ToBe(false)
        ctx:Expect(frame:GetNumPoints()):ToBe(0)
        ctx:Expect(frame:GetParent()):ToBeNil()
        ctx:Expect(pool:GetAvailableCount()):ToBe(1)

        ctx:Expect(pool:Acquire()):ToBe(frame)
        ctx:Expect(pool:GetCreatedCount()):ToBe(1)
        ctx:Expect(pool:GetActiveCount()):ToBe(1)
    end
)

frames:Test(
    "a second pool doing the same work draws the Frames the first gave back, so no Frame is created twice",
    function(ctx)
        local first = newFramePool({ reset = stripFrame })
        local one, two = first:Acquire(), first:Acquire()
        first:Release(one)
        first:Release(two)
        ctx:Expect(first:Close()):ToBe(true)
        ctx:Expect(isInBank(one)):ToBe(true)
        ctx:Expect(isInBank(two)):ToBe(true)
        local createdBefore = framesCreated

        local second = newFramePool({ reset = stripFrame })
        local drawn = { [second:Acquire()] = true, [second:Acquire()] = true }
        ctx:Expect(framesCreated):ToBe(createdBefore)
        ctx:Expect(drawn[one]):ToBe(true)
        ctx:Expect(drawn[two]):ToBe(true)
        ctx:Log(("Frames this addon has created this session: %d"):format(framesCreated))
    end
)

frames:Test(
    "maxRetained 1 keeps one released Frame and hands the other to destroy, which gives it back to this file's bank",
    function(ctx)
        local destroyed = {}
        local pool = newFramePool({
            reset = stripFrame,
            maxRetained = 1,
            destroy = function(frame)
                destroyed[#destroyed + 1] = frame
                returnBankFrame(frame)
            end,
        })
        local kept, discarded = pool:Acquire(), pool:Acquire()
        pool:Release(kept)
        pool:Release(discarded)

        ctx:Expect(pool:GetAvailableCount()):ToBe(1)
        ctx:Expect(pool:GetDiscardedCount()):ToBe(1)
        ctx:Expect(destroyed):ToEqual({ discarded })
        ctx:Expect(pool:Owns(kept)):ToBe(true)
        ctx:Expect(pool:Owns(discarded)):ToBe(false)
        ctx:Expect(isInBank(discarded)):ToBe(true)
        ctx:Expect(discarded:IsShown()):ToBe(false)
    end
)

frames:Test(
    "Close hands every retained Frame to destroy, and a Frame borrowed across Close is reset and destroyed on its Release",
    function(ctx)
        local resets = 0
        local destroyed = {}
        local pool = newFramePool({
            reset = function(frame)
                resets = resets + 1
                stripFrame(frame)
            end,
            destroy = function(frame)
                destroyed[#destroyed + 1] = frame
                returnBankFrame(frame)
            end,
        })
        local retained, borrowed = pool:Acquire(), pool:Acquire()
        pool:Release(retained)

        ctx:Expect(pool:Close()):ToBe(true)
        ctx:Expect(pool:IsClosed()):ToBe(true)
        ctx:Expect(destroyed):ToEqual({ retained })
        ctx:Expect(pool:IsActive(borrowed)):ToBe(true)

        ctx:Expect(pool:Release(borrowed)):ToBe(true)
        ctx:Expect(resets):ToBe(2)
        ctx:Expect(destroyed):ToEqual({ retained, borrowed })
        ctx:Expect(pool:GetAvailableCount()):ToBe(0)
        ctx:Expect(pool:GetDiscardedCount()):ToBe(2)
        ctx:Expect(isInBank(borrowed)):ToBe(true)
    end
)

-- poolKit.capacity ---------------------------------------------------------------------------

local capacity = newSuite("capacity")

capacity:Test(
    "maxCreated 2 builds two Frames at most: Acquire then answers exhausted, even after Clear destroyed both, until SetMaxCreated raises the cap",
    function(ctx)
        local sessionFramesBefore = framesCreated
        local pool = newFramePool({ reset = stripFrame, maxCreated = 2 })
        local one, two = pool:Acquire(), pool:Acquire()
        ctx:Expect(type(one)):ToBe("table")
        ctx:Expect(type(two)):ToBe("table")

        local object, reason = pool:Acquire()
        ctx:Expect(object):ToBeNil()
        ctx:Expect(reason):ToBe("exhausted")

        pool:Release(one)
        pool:Release(two)
        ctx:Expect(pool:Clear()):ToBe(2)
        object, reason = pool:Acquire()
        ctx:Expect(object):ToBeNil()
        ctx:Expect(reason):ToBe("exhausted")
        ctx:Expect(pool:GetCreatedCount()):ToBe(2)

        pool:SetMaxCreated(3)
        ctx:Expect(pool:GetMaxCreated()):ToBe(3)
        local third = pool:Acquire()
        ctx:Expect(type(third)):ToBe("table")
        ctx:Expect(pool:GetCreatedCount()):ToBe(3)
        -- The third factory call reused a Frame the bank took back from Clear.
        ctx:Expect(framesCreated - sessionFramesBefore <= 2):ToBe(true)
    end
)

capacity:Test(
    "maxActive 1 with maxWaiting 1 queues one request, refuses the next with queueFull, and hands the released Frame to the queued callback",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame, maxActive = 1, maxWaiting = 1 })
        local held = pool:Acquire()
        local served, servedPool = nil, nil

        local object, reason = pool:Acquire(function(frame, fromPool)
            served, servedPool = frame, fromPool
        end)
        ctx:Expect(object):ToBeNil()
        ctx:Expect(reason):ToBe("waiting")
        ctx:Expect(pool:GetWaitingCount()):ToBe(1)

        object, reason = pool:Acquire(function() end)
        ctx:Expect(object):ToBeNil()
        ctx:Expect(reason):ToBe("queueFull")
        object, reason = pool:Acquire()
        ctx:Expect(object):ToBeNil()
        ctx:Expect(reason):ToBe("exhausted")

        pool:Release(held)
        ctx:Expect(served):ToBe(held)
        ctx:Expect(servedPool):ToBe(pool)
        ctx:Expect(pool:IsActive(held)):ToBe(true)
        ctx:Expect(pool:GetWaitingCount()):ToBe(0)
        ctx:Expect(pool:GetCreatedCount()):ToBe(1)
    end
)

capacity:Test(
    "maxActiveWarning 2 reports once through the client's error handler when two Frames are out, and not again at three",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame, maxActiveWarning = 2 })
        local reported, observed = interceptReports(LEAK_WARNING_TEXT)
        if not observed then
            restoreErrorHandler()
            ctx:Fail(HANDLER_KEPT_REASON)
            return
        end

        pool:Acquire()
        local afterOne = #reported
        pool:Acquire()
        local afterTwo = #reported
        pool:Acquire()
        local afterThree = #reported
        restoreErrorHandler()

        ctx:Expect(afterOne):ToBe(0)
        ctx:Expect(afterTwo):ToBe(1)
        ctx:Expect(afterThree):ToBe(1)
        ctx:Log("reported: " .. tostring(reported[1]))
        ctx:Expect(tostring(reported[1]):find("has 2 objects borrowed at once", 1, true)).Not
            :ToBeNil()
        ctx:Expect(pool:GetActiveCount()):ToBe(3)
    end
)

-- poolKit.strict -------------------------------------------------------------------------------

local strict = newSuite("strict")

strict:Test(
    "Release of a Frame borrowed from another pool is refused at the calling line and changes neither pool",
    function(ctx)
        local owner = newFramePool({ reset = stripFrame })
        local other = newFramePool({ reset = stripFrame })
        local frame = owner:Acquire()

        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            other:Release(frame)
        end, lines, "PoolKit.Pool:Release object was not acquired from this pool")
        ctx:Expect(owner:IsActive(frame)):ToBe(true)
        ctx:Expect(other:Owns(frame)):ToBe(false)
        ctx:Expect(other:GetAvailableCount()):ToBe(0)
    end
)

strict:Test(
    "a second Release of a retained Frame is refused as already released at the calling line",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local frame = pool:Acquire()
        pool:Release(frame)

        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:Release(frame)
        end, lines, "PoolKit.Pool:Release object has already been released")
        ctx:Expect(pool:GetAvailableCount()):ToBe(1)
    end
)

strict:Test(
    "a Frame discarded by maxRetained 0 is refused as already released under strict, and as not acquired from this pool without it",
    function(ctx)
        local strictPool = newFramePool({ reset = stripFrame, maxRetained = 0 })
        local frame = strictPool:Acquire()
        strictPool:Release(frame)
        ctx:Expect(strictPool:GetDiscardedCount()):ToBe(1)

        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            strictPool:Release(frame)
        end, lines, "PoolKit.Pool:Release object has already been released")

        local lenientPool = newFramePool({ reset = stripFrame, maxRetained = 0, strict = false })
        local lenientFrame = lenientPool:Acquire()
        lenientPool:Release(lenientFrame)
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            lenientPool:Release(lenientFrame)
        end, lines, "PoolKit.Pool:Release object was not acquired from this pool")
    end
)

strict:Test("strictReset refuses a Frame pool without a reset at the calling line", function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        PoolKit:New({ create = borrowBankFrame, strictReset = true })
    end, lines, "PoolKit:New strictReset requires a reset callback")
end)

-- poolKit.children -----------------------------------------------------------------------------

local children = newSuite("children")

children:Test(
    "releasing a parent Frame releases its attached child Frames first, most recently attached first, each through its own pool",
    function(ctx)
        local names = {}
        local order = {}
        ---@param frame MoltenCodesTest.PoolKit.Frame
        local function recordingReset(frame)
            order[#order + 1] = names[frame]
            stripFrame(frame)
        end
        local parents = newFramePool({ reset = recordingReset })
        local childPool = newFramePool({ reset = recordingReset })

        local parent = parents:Acquire()
        local firstChild, secondChild = childPool:Acquire(), childPool:Acquire()
        names[parent], names[firstChild], names[secondChild] = "parent", "first", "second"
        firstChild:SetParent(parent)
        secondChild:SetParent(parent)
        parents:AttachChild(parent, firstChild, childPool)
        parents:AttachChild(parent, secondChild, childPool)

        parents:Release(parent)
        ctx:Expect(order):ToEqual({ "second", "first", "parent" })
        ctx:Expect(childPool:GetActiveCount()):ToBe(0)
        ctx:Expect(childPool:GetAvailableCount()):ToBe(2)
        ctx:Expect(parents:GetAvailableCount()):ToBe(1)
        ctx:Expect(firstChild:GetParent()):ToBeNil()
        ctx:Expect(secondChild:GetParent()):ToBeNil()
    end
)

children:Test(
    "a child Frame released on its own is detached, so the parent's later release leaves the re-borrowed child alone",
    function(ctx)
        local parents = newFramePool({ reset = stripFrame })
        local childPool = newFramePool({ reset = stripFrame })
        local parent, child = parents:Acquire(), childPool:Acquire()
        child:SetParent(parent)
        parents:AttachChild(parent, child, childPool)

        childPool:Release(child)
        local again = childPool:Acquire()
        ctx:Expect(again):ToBe(child)

        parents:Release(parent)
        ctx:Expect(childPool:IsActive(child)):ToBe(true)
        ctx:Expect(parents:DetachChild(child)):ToBe(false)
    end
)

-- poolKit.animation ----------------------------------------------------------------------------

local animation = newSuite("animation")

animation:Test(
    "ReleaseAfter a playing Alpha animation parks the Frame, and the client's OnFinished returns it to the pool",
    function(ctx)
        requireVisibleInterface(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local frame = pool:Acquire()
        showInvisibly(frame)
        local fade = fadeOutOf(frame)
        fade:Play()
        local startedAt = getTime()

        ctx:Expect(pool:ReleaseAfter(frame, fade)):ToBe(true)
        ctx:Expect(pool:GetParkedCount()):ToBe(1)
        ctx:Expect(pool:GetActiveCount()):ToBe(0)
        ctx:Expect(pool:Owns(frame)):ToBe(true)
        ctx:Expect(pool:IsActive(frame)):ToBe(false)

        local finished = ctx:WaitUntil(function()
            return pool:GetParkedCount() == 0
        end, ANIMATION_WAIT_SECONDS)
        ctx:Log(("back in the pool %.3f s after Play"):format(getTime() - startedAt))
        ctx:Expect(finished):ToBe(true)
        ctx:Expect(pool:GetAvailableCount()):ToBe(1)
        ctx:Expect(frame:IsShown()):ToBe(false)
        ctx:Expect(frame:GetParent()):ToBeNil()
    end
)

animation:Test(
    "Release before the animation finishes completes the parked release at once, and the animation's end then changes nothing",
    function(ctx)
        requireVisibleInterface(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local frame = pool:Acquire()
        showInvisibly(frame)
        local fade = fadeOutOf(frame)
        fade:Play()
        pool:ReleaseAfter(frame, fade)

        ctx:Expect(pool:Release(frame)):ToBe(true)
        ctx:Expect(pool:GetParkedCount()):ToBe(0)
        ctx:Expect(pool:GetAvailableCount()):ToBe(1)
        ctx:Log("still playing after the early release: " .. tostring(fade:IsPlaying()))

        -- Borrow it again: an animation end that reached PoolKit now would
        -- take the Frame from its new borrower.
        ctx:Expect(pool:Acquire()):ToBe(frame)
        settle(ctx, SETTLE_SECONDS)
        ctx:Expect(pool:IsActive(frame)):ToBe(true)
        ctx:Expect(pool:GetActiveCount()):ToBe(1)
        ctx:Expect(pool:GetAvailableCount()):ToBe(0)
    end
)

animation:Test(
    "ReleaseAfter on an animation group that is not playing releases the Frame at once and returns false",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local frame = pool:Acquire()
        local fade = fadeOutOf(frame)
        ctx:Expect(fade:IsPlaying()):ToBe(false)

        ctx:Expect(pool:ReleaseAfter(frame, fade)):ToBe(false)
        ctx:Expect(pool:GetParkedCount()):ToBe(0)
        ctx:Expect(pool:GetAvailableCount()):ToBe(1)
        ctx:Expect(pool:IsActive(frame)):ToBe(false)
    end
)

animation:Test(
    "an animation stopped with Stop never finishes, so the Frame stays parked until Release completes it",
    function(ctx)
        requireVisibleInterface(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local frame = pool:Acquire()
        showInvisibly(frame)
        local fade = fadeOutOf(frame)
        fade:Play()
        pool:ReleaseAfter(frame, fade)
        fade:Stop()

        settle(ctx, SETTLE_SECONDS)
        ctx:Expect(pool:GetParkedCount()):ToBe(1)
        ctx:Expect(pool:Owns(frame)):ToBe(true)

        ctx:Expect(pool:Release(frame)):ToBe(true)
        ctx:Expect(pool:GetParkedCount()):ToBe(0)
        ctx:Expect(pool:GetAvailableCount()):ToBe(1)
    end
)

animation:Test(
    "one animation group reused for two deferred releases of its pooled Frame returns the Frame both times",
    function(ctx)
        requireVisibleInterface(ctx)
        local pool = newFramePool({ reset = stripFrame })
        for round = 1, 2 do
            local frame = pool:Acquire()
            showInvisibly(frame)
            local fade = fadeOutOf(frame)
            fade:Play()
            ctx:Expect(pool:ReleaseAfter(frame, fade)):ToBe(true)

            local finished = ctx:WaitUntil(function()
                return pool:GetParkedCount() == 0
            end, ANIMATION_WAIT_SECONDS)
            ctx:Log(("round %d finished: %s"):format(round, tostring(finished)))
            ctx:Expect(finished):ToBe(true)
            ctx:Expect(pool:GetAvailableCount()):ToBe(1)
        end
        ctx:Expect(pool:GetCreatedCount()):ToBe(1)
    end
)

animation:Test(
    "a reset that raises when the animation finishes reaches the client's error handler, naming PoolKitSuite.lua, and leaves the Frame borrowed",
    function(ctx)
        requireVisibleInterface(ctx)
        local failNextReset = true
        local failingLine = 0
        local pool = newFramePool({
            reset = function(frame)
                if failNextReset then
                    failNextReset = false
                    failingLine = currentLine()
                    error(RESET_FAILURE)
                end
                stripFrame(frame)
            end,
        })
        local frame = pool:Acquire()
        showInvisibly(frame)
        local fade = fadeOutOf(frame)

        local reported, observed = interceptReports(RESET_FAILURE)
        if not observed then
            restoreErrorHandler()
            ctx:Fail(HANDLER_KEPT_REASON)
            return
        end
        fade:Play()
        pool:ReleaseAfter(frame, fade)
        local finished = ctx:WaitUntil(function()
            return pool:GetParkedCount() == 0
        end, ANIMATION_WAIT_SECONDS)
        restoreErrorHandler()

        ctx:Expect(finished):ToBe(true)
        ctx:Expect(#reported):ToBe(1)
        ctx:Log("reported: " .. tostring(reported[1]))
        local line = expectThisFile(ctx, reported[1])
        ctx:Expect(line):ToBe(failingLine + 1)
        ctx:Expect(pool:IsActive(frame)):ToBe(true)
        ctx:Expect(pool:GetActiveCount()):ToBe(1)

        ctx:Expect(pool:Release(frame)):ToBe(true)
        ctx:Expect(pool:GetAvailableCount()):ToBe(1)
    end
)

animation:Test(
    "ReleaseAfter on a group that already holds a pending release is refused at the calling line and the second Frame stays borrowed",
    function(ctx)
        requireVisibleInterface(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local first, second = pool:Acquire(), pool:Acquire()
        showInvisibly(first)
        local fade = fadeOutOf(first)
        fade:Play()
        ctx:Expect(pool:ReleaseAfter(first, fade)):ToBe(true)

        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:ReleaseAfter(second, fade)
        end, lines, "PoolKit.Pool:ReleaseAfter animationGroup already has a pending release")
        ctx:Expect(pool:IsActive(second)):ToBe(true)
        ctx:Expect(pool:GetParkedCount()):ToBe(1)
    end
)

-- poolKit.allocation ---------------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
    "Acquire and Release of a retained Frame with a Hide, ClearAllPoints and SetParent(nil) reset allocate nothing over 5000 cycles",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame, maxCreated = 1 })
        -- Warm the path once, so the measurement sees steady state only.
        pool:Release(pool:Acquire())
        collectBeforeMeasuring(ctx)

        local grownKilobytes = measureAllocation(function()
            for _ = 1, ALLOCATION_CYCLES do
                local frame = pool:Acquire()
                frame:SetParent(uiParent)
                pool:Release(frame)
            end
        end)

        ctx:Log(("memory delta over %d cycles: %.3f KB"):format(ALLOCATION_CYCLES, grownKilobytes))
        ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
        ctx:Expect(pool:GetCreatedCount()):ToBe(1)
        ctx:Expect(pool:GetAvailableCount()):ToBe(1)
    end
)

allocation:Test(
    "a request queued behind maxActive and served by Release allocates nothing over 5000 cycles",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame, maxActive = 1, maxWaiting = 1 })
        local served = nil
        -- One stable callback: a closure per request would itself allocate.
        ---@param frame MoltenCodesTest.PoolKit.Frame
        local function onServed(frame)
            served = frame
        end
        local servedCount = 0

        local function cycle()
            local held = pool:Acquire()
            pool:Acquire(onServed)
            pool:Release(held)
            if served == held then
                servedCount = servedCount + 1
            end
            pool:Release(served)
        end
        cycle()
        collectBeforeMeasuring(ctx)

        local grownKilobytes = measureAllocation(function()
            for _ = 1, ALLOCATION_CYCLES do
                cycle()
            end
        end)

        ctx:Log(
            ("memory delta over %d served requests: %.3f KB"):format(
                ALLOCATION_CYCLES,
                grownKilobytes
            )
        )
        ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
        ctx:Expect(servedCount):ToBe(ALLOCATION_CYCLES + 1)
        ctx:Expect(pool:GetWaitingCount()):ToBe(0)
        ctx:Expect(pool:GetActiveCount()):ToBe(0)
        ctx:Expect(pool:GetCreatedCount()):ToBe(1)
    end
)

-- poolKit.errors ------------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
    "PoolKit:New with options that are not a table names PoolKitSuite.lua at the calling line",
    function(ctx)
        -- The wrong argument type is the point of the test.
        ---@type any
        local notOptions = "frames"
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            PoolKit:New(notOptions)
        end, lines, "PoolKit:New options must be a table")
    end
)

errors:Test("PoolKit:New with a misspelt option names the field at the calling line", function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        PoolKit:New({ create = borrowBankFrame, reset = stripFrame, maxRetain = 4 })
    end, lines, 'PoolKit:New options contains unknown field "maxRetain"')
end)

errors:Test(
    "a pool method called with UIParent instead of a pool names PoolKitSuite.lua at the calling line",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local acquire = pool.Acquire
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            acquire(uiParent)
        end, lines, "PoolKit.Pool:Acquire must be called on a PoolKit pool")
        ctx:Expect(pool:GetCreatedCount()):ToBe(0)
    end
)

errors:Test(
    "Prewarm with a negative count names PoolKitSuite.lua at the calling line",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:Prewarm(-1)
        end, lines, "PoolKit.Pool:Prewarm count must be a non-negative integer")
    end
)

errors:Test(
    "Prewarm beyond maxCreated is refused at the calling line and builds no Frame",
    function(ctx)
        local sessionFramesBefore = framesCreated
        -- maxRetained above the cap, so the cap is the bound Prewarm meets first.
        local pool = newFramePool({ reset = stripFrame, maxCreated = 2, maxRetained = 4 })
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:Prewarm(3)
        end, lines, "PoolKit.Pool:Prewarm target cannot exceed maxCreated")
        ctx:Expect(pool:GetCreatedCount()):ToBe(0)
        ctx:Expect(framesCreated):ToBe(sessionFramesBefore)
    end
)

errors:Test(
    "ReleaseAfter with a table that is not an animation group is refused at the calling line and the Frame stays borrowed",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame })
        local frame = pool:Acquire()
        local notAGroup = {}
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:ReleaseAfter(frame, notAGroup)
        end, lines, "PoolKit.Pool:ReleaseAfter animationGroup must be an animation group")
        ctx:Expect(pool:IsActive(frame)):ToBe(true)
        ctx:Expect(pool:GetParkedCount()):ToBe(0)
    end
)

-- poolKit.secrets ------------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
    "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
    if SECRETS_AVAILABLE then
        secrets:Test(name, body)
    else
        secrets:Skip(name, SECRETS_SKIP_REASON)
    end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
    local succeeded, secret = pcall(secretWrap, value)
    if not succeeded then
        ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
    end
    if isSecretValue(secret) ~= true then
        ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
    end
    return secret
end

secretTest("a secret maxRetained is refused by PoolKit:New at the calling line", function(ctx)
    local secret = makeSecret(ctx, 4)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        PoolKit:New({ create = borrowBankFrame, reset = stripFrame, maxRetained = secret })
    end, lines, "PoolKit:New maxRetained must not be a secret value")
end)

secretTest("a secret maxCreated is refused by PoolKit:New at the calling line", function(ctx)
    local secret = makeSecret(ctx, 2)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        PoolKit:New({ create = borrowBankFrame, reset = stripFrame, maxCreated = secret })
    end, lines, "PoolKit:New maxCreated must not be a secret value")
end)

secretTest("a secret strictReset is refused by PoolKit:New at the calling line", function(ctx)
    local secret = makeSecret(ctx, true)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        PoolKit:New({ create = borrowBankFrame, reset = stripFrame, strictReset = secret })
    end, lines, "PoolKit:New strictReset must not be a secret value")
end)

secretTest(
    "a secret Prewarm count is refused at the calling line and builds no Frame",
    function(ctx)
        local sessionFramesBefore = framesCreated
        local pool = newFramePool({ reset = stripFrame })
        local secret = makeSecret(ctx, 1)
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:Prewarm(secret)
        end, lines, "PoolKit.Pool:Prewarm count must not be a secret value")
        ctx:Expect(pool:GetCreatedCount()):ToBe(0)
        ctx:Expect(framesCreated):ToBe(sessionFramesBefore)
    end
)

secretTest(
    "secret Trim, SetMaxRetained, SetGeneration and SetMaxCreated arguments are each refused at the calling line",
    function(ctx)
        local pool = newFramePool({ reset = stripFrame, maxCreated = 2 })
        local secret = makeSecret(ctx, 3)
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:Trim(secret)
        end, lines, "PoolKit.Pool:Trim retainCount must not be a secret value")
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:SetMaxRetained(secret)
        end, lines, "PoolKit.Pool:SetMaxRetained maxRetained must not be a secret value")
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:SetGeneration(secret)
        end, lines, "PoolKit.Pool:SetGeneration generation must not be a secret value")
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            pool:SetMaxCreated(secret)
        end, lines, "PoolKit.Pool:SetMaxCreated maxCreated must not be a secret value")

        ctx:Expect(pool:GetMaxRetained()):ToBe(2)
        ctx:Expect(pool:GetGeneration()):ToBe(1)
        ctx:Expect(pool:GetMaxCreated()):ToBe(2)
    end
)

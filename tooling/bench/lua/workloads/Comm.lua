--- Multipart addon messages: CommKit against AceComm-3.0 (with ChatThrottleLib).
---
--- Both sides send the same text to `PARTY` on the same prefix and receive
--- it back from another player through their own wire format:
---
--- - **Send** is the library's whole path from the call to the last chunk
---   reaching `C_ChatInfo.SendAddonMessage` (the host stub records it): for
---   CommKit its queue, bandwidth bucket and SchedulerKit driver, run by
---   ticking frames until every chunk left; for AceComm the split and
---   ChatThrottleLib, which sends at once while bandwidth is available.
--- - **Receive** delivers every chunk of one message to the frame the library
---   registered for `CHAT_MSG_ADDON` and ends when the listener got the text.
---
--- Both throttles are opened to the same rate so that neither waits: CommKit
--- `maxCps = 100000, burst = 1000000` (its ceilings) and ChatThrottleLib
--- `MAX_CPS = 100000, BURST = 1000000`. The simulated clock is advanced 20 s
--- before measuring and after every batch, outside the timed region, so each
--- batch starts with a full bucket on both sides and neither is in its
--- start-up or zoning throttle. HookKit is not loaded, so CommKit does not
--- hook the send functions; ChatThrottleLib always hooks them, and that
--- wrapper is part of its send path in the client too.

local Bench = require("Bench")
local AceObjects = require("workloads.AceObjects")

local Comm = {}

local PREFIX = "BenchComm"
local SENDER = "Friend-Silvermoon"

--- Message lengths in report order, with sends and receives per timed batch.
--- A send batch stays inside one full bucket (1,000,000 bytes, a chunk costing
--- its bytes plus 40 of overhead on both sides); receiving has no such bound.
local SIZES = {
  { length = 200, sends = 3000, receives = 10000 },
  { length = 1000, sends = 700, receives = 2000 },
  { length = 8000, sends = 80, receives = 250 },
}

---A text of `length` printable bytes from a fixed pseudo-random sequence.
---
---Every message a case sends or receives is a different slice of this text
---(`slice`), for two reasons. A periodic text (`ABC...Z` repeated) would make
---chunks identical, and one message sent over and over would make every
---chunk identical to the last; Lua interns identical strings, so the library
---would appear to allocate and hold less than it does. A linear congruential
---sequence gives every run of the benchmark the same text, with no repeats.
---@param length integer
---@return string
local function sourceText(length)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  local parts, state = {}, 12345
  for index = 1, length do
    state = (state * 1103515245 + 12345) % 2147483648
    local position = math.floor(state / 65536) % #alphabet + 1
    parts[index] = alphabet:sub(position, position)
  end
  return table.concat(parts)
end

---Message number `index` of `length` bytes: a slice of `source`.
---@param source string
---@param index integer
---@param length integer
---@return string
local function slice(source, index, length)
  return source:sub(index, index + length - 1)
end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({
    "Registry",
    "SignalKit",
    "EventKit",
    "TimerKit",
    "SchedulerKit",
    "PoolKit",
    "CommKit",
  })
  local CommKit = loaded[7]
  CommKit:SetLimits({ maxCps = 100000, burst = 1000000 })
  local scope = CommKit:CreateScope()
  local adapter = {}

  function adapter.register(callback)
    scope:Register(PREFIX, function(_, text)
      callback(text)
    end)
  end

  function adapter.send(text)
    local handle, reason = scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" })
    if handle == nil then
      error("CommKit refused a benchmark message: " .. tostring(reason), 0)
    end
  end

  return adapter,
    {
      { name = "CommKit", revision = CommKit.REVISION },
      { name = "SchedulerKit", revision = loaded[5].REVISION },
      { name = "TimerKit", revision = loaded[4].REVISION },
      { name = "EventKit", revision = loaded[3].REVISION },
      { name = "SignalKit", revision = loaded[2].REVISION },
      { name = "PoolKit", revision = loaded[6].REVISION },
    }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, {
    "LibStub/LibStub.lua",
    "CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "AceComm-3.0/ChatThrottleLib.lua",
    "AceComm-3.0/AceComm-3.0.lua",
  })
  local LibStub = host.Global("LibStub")
  local ChatThrottleLib = host.Global("ChatThrottleLib")
  ChatThrottleLib.MAX_CPS = 100000
  ChatThrottleLib.BURST = 1000000
  local AceComm, minor = LibStub:GetLibrary("AceComm-3.0")
  local _, callbackHandlerMinor = LibStub:GetLibrary("CallbackHandler-1.0")
  local owner = AceObjects.NewPool(AceComm, 1).Take()
  local adapter = {}

  function adapter.register(callback)
    owner:RegisterComm(PREFIX, function(_, text)
      callback(text)
    end)
  end

  function adapter.send(text)
    owner:SendCommMessage(PREFIX, text, "PARTY")
  end

  return adapter,
    {
      { name = "AceComm-3.0", minor = minor },
      { name = "ChatThrottleLib", minor = ChatThrottleLib.version },
      { name = "CallbackHandler-1.0", minor = callbackHandlerMinor },
    }
end

---Build the shared plumbing: a send that waits for its chunks, and a receive.
---@param adapter table
---@param host table
---@return table link
local function newLink(adapter, host)
  local chat, timers = host.chat, host.timers
  -- `sent` and `ticks` count timed sends and the frames they needed.
  local link = { received = 0, lastText = nil, sent = 0, ticks = 0 }

  adapter.register(function(text)
    link.received = link.received + 1
    link.lastText = text
  end)

  ---Send `text` and tick frames until `chunks` more messages left.
  ---@param text string
  ---@param chunks integer
  function link.send(text, chunks)
    local target = chat.count + chunks
    adapter.send(text)
    local ticks = 0
    while chat.count < target do
      ticks = ticks + 1
      if ticks > 1000 then
        error("Comm workload: the message did not leave within 1000 frames", 0)
      end
      host.Tick()
    end
    link.sent = link.sent + 1
    link.ticks = link.ticks + ticks
  end

  ---Send `text` once, with a full bucket, and return the chunk texts that
  ---left, in order. Frames are ticked until five in a row send nothing.
  ---@param text string
  ---@return string[]
  function link.capture(text)
    link.rest()
    adapter.send(text)
    local idle, seen = 0, chat.count
    while idle < 5 do
      host.Tick()
      if chat.count == seen then
        idle = idle + 1
      else
        idle, seen = 0, chat.count
      end
    end
    local chunks = {}
    for index = 1, chat.count do
      chunks[index] = chat.texts[index]
    end
    chat.Clear()
    return chunks
  end

  local frame, onEvent = host.EventHandler("CHAT_MSG_ADDON")

  ---Deliver chunk texts `first` to `last` from `sender`, as the client would.
  ---@param chunks string[]
  ---@param first integer
  ---@param last integer
  ---@param sender string?
  function link.deliver(chunks, first, last, sender)
    for index = first, last do
      onEvent(
        frame,
        "CHAT_MSG_ADDON",
        PREFIX,
        chunks[index],
        "PARTY",
        sender or SENDER,
        "Tester",
        0,
        0,
        "",
        0
      )
    end
  end

  ---Refill both throttles and let every pending timer run.
  function link.rest()
    chat.Clear()
    timers.Advance(20)
    host.Tick()
  end

  link.rest()
  return link
end

---@param link table
---@return Bench.Case[]
local function cases(link)
  local list = {}
  for _, entry in ipairs(SIZES) do
    local length = entry.length

    list[#list + 1] = {
      name = "send-" .. length,
      iterations = entry.sends,
      operation = "send a " .. length .. "-byte message until every chunk left",
      prepare = function()
        local iterations = entry.sends
        local source = sourceText(length + iterations)
        local chunks = link.capture(slice(source, 1, length))
        local wireBytes = 0
        for index = 1, #chunks do
          wireBytes = wireBytes + #PREFIX + #chunks[index]
        end
        local texts = {}
        for index = 1, iterations do
          texts[index] = slice(source, index, length)
        end
        link.rest()
        return {
          run = function(count)
            for index = 1, count do
              link.send(texts[index], #chunks)
            end
          end,
          afterBatch = link.rest,
          metrics = function()
            return {
              chunks = #chunks,
              wireBytesWithPrefix = wireBytes,
              framesPerMessage = link.ticks / link.sent,
            }
          end,
        }
      end,
    }

    list[#list + 1] = {
      name = "receive-" .. length,
      iterations = entry.receives,
      operation = "receive and reassemble a " .. length .. "-byte message",
      prepare = function()
        local iterations = entry.receives
        -- One more message than a batch, for the mid-stream measurement.
        local source = sourceText(length + iterations + 1)
        local messages = {}
        for index = 1, iterations + 1 do
          messages[index] = link.capture(slice(source, index, length))
        end
        link.rest()
        return {
          run = function(count)
            for index = 1, count do
              local chunks = messages[index]
              link.deliver(chunks, 1, #chunks)
            end
          end,
          -- What an incomplete stream holds: every chunk but the last delivered.
          metrics = function()
            local chunks = messages[iterations + 1]
            if #chunks < 2 then
              return { chunks = #chunks }
            end
            local baseline = Bench.RetainedBytes()
            link.deliver(chunks, 1, #chunks - 1)
            local held = Bench.RetainedBytes() - baseline
            link.deliver(chunks, #chunks, #chunks)
            return {
              chunks = #chunks,
              retainedBytesMidStream = held,
              delivered = link.lastText == slice(source, iterations + 1, length),
            }
          end,
        }
      end,
    }
  end
  return list
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Comm.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  local link = newLink(adapter, host)

  local function checks()
    local results = {}
    for _, entry in ipairs(SIZES) do
      local text = sourceText(entry.length)
      local chunks = link.capture(text)
      local before = link.received
      link.deliver(chunks, 1, #chunks)
      results[#results + 1] = {
        name = "round-trip-" .. entry.length,
        passed = link.received == before + 1 and link.lastText == text,
        detail = #chunks
          .. " chunk(s), delivered "
          .. (link.received - before)
          .. " time(s), text equal: "
          .. tostring(link.lastText == text),
        promised = true,
      }
    end

    -- Two senders' streams interleaved chunk by chunk.
    local text = sourceText(1000)
    local chunks = link.capture(text)
    local before, matches = link.received, 0
    for index = 1, #chunks do
      link.deliver(chunks, index, index, "First-Silvermoon")
      if link.lastText == text and link.received > before + matches then
        matches = matches + 1
      end
      link.deliver(chunks, index, index, "Second-Silvermoon")
      if link.lastText == text and link.received > before + matches then
        matches = matches + 1
      end
    end
    results[#results + 1] = {
      name = "interleaved-senders",
      passed = matches == 2 and link.received == before + 2,
      detail = "complete messages from two interleaved senders: " .. matches,
      promised = true,
    }
    return results
  end

  return { libraries = libraries, cases = cases(link), checks = checks }
end

return Comm

--- A real addon-message round trip: CommKit against AceComm-3.0 with ChatThrottleLib.
---
--- The host's comm rows send into a recording outbox with both throttles
--- opened wide. Here each side whispers an addon message to the player's own
--- character through the client, the server and back, at each library's
--- default rate (800 bytes per second with a 4000-byte burst on both), and
--- waits for the whole text to arrive before sending the next. What is timed
--- is the round trip a player's addon sees: splitting, the throttle, the
--- server, the reassembly and the delivery to the callback.
---
--- Every message is a different slice of one fixed pseudo-random text, with
--- its number first, so a late copy of an earlier message can never be taken
--- for the one in flight. A message that has not arrived after
--- `MESSAGE_TIMEOUT_SECONDS` is counted as lost and the next one is sent.
---
--- The server's own addon-message limits apply as they do to every addon;
--- they are the same for both sides, and a message they drop shows as lost.

local Adapters = require("clientWorkloads.Adapters")
local ClientBench = require("ClientBench")
local FrameStats = require("clientWorkloads.FrameStats")

local Whisper = {}

--- Message lengths, one case each, and the messages sent per case.
local LENGTHS = { 200, 1000, 4000 }
local MESSAGES = 5

--- Seconds a message may take before it counts as lost.
local MESSAGE_TIMEOUT_SECONDS = 60

---A text of `length` printable bytes from a fixed pseudo-random sequence.
---@param length integer
---@return string
local function sourceText(length)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  local parts, state = {}, 54321
  for index = 1, length do
    state = (state * 1103515245 + 12345) % 2147483648
    local position = math.floor(state / 65536) % #alphabet + 1
    parts[index] = alphabet:sub(position, position)
  end
  return table.concat(parts)
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table the client host
---@return table suite `{ cases, checks, libraries }`
function Whisper.Build(side, host)
  local adapter = Adapters.New(side, host)
  local comm = adapter.Comm()
  local preciseTime = host.Global("GetTimePreciseSec")
  local unitName = host.Global("UnitName")
  local source = sourceText(LENGTHS[#LENGTHS] + MESSAGES + 16)

  -- One receive callback for every case; it hands each text to the case in flight.
  local onText = nil
  comm.register(function(text)
    if onText ~= nil then
      onText(text)
    end
  end)

  ---The player's own name, the whisper target.
  ---@return string
  local function playerName()
    local name = type(unitName) == "function" and unitName("player") or nil
    if type(name) ~= "string" or name == "" then
      ClientBench.Unsupported("the player's name from UnitName")
    end
    return name --[[@as string]]
  end

  local cases = {}
  for _, length in ipairs(LENGTHS) do
    cases[#cases + 1] = {
      name = "whisper-" .. length,
      kind = "frames",
      operation = "whisper a "
        .. length
        .. "-byte addon message to the player and wait for all of it; "
        .. MESSAGES
        .. " in a row",
      prepare = function()
        local target = playerName()
        local roundTrips = FrameStats.NewSeries()
        local sent, received, lost, mangled = 0, 0, 0, 0
        local expected, sentAt = nil, 0

        local function sendNext()
          sent = sent + 1
          expected = sent .. ":" .. source:sub(sent, sent + length - #tostring(sent) - 2)
          sentAt = preciseTime()
          comm.whisper(expected, target)
        end

        onText = function(text)
          if expected == nil then
            return
          end
          if text == expected then
            received = received + 1
            roundTrips.Add((preciseTime() - sentAt) * 1000)
            expected = nil
          elseif #text == #expected then
            mangled = mangled + 1
          end
        end

        return {
          maximumSeconds = MESSAGES * MESSAGE_TIMEOUT_SECONDS,
          start = sendNext,
          frame = function()
            if expected ~= nil and preciseTime() - sentAt > MESSAGE_TIMEOUT_SECONDS then
              lost = lost + 1
              expected = nil
            end
            if expected == nil then
              if sent >= MESSAGES then
                return true
              end
              sendNext()
            end
            return false
          end,
          finish = function()
            onText = nil
            return {
              messageBytes = length,
              sent = sent,
              received = received,
              lost = lost,
              differentTextOfSameLength = mangled,
              roundTripMillisecondsP50 = roundTrips.Percentile(50),
              roundTripMillisecondsMin = roundTrips.Percentile(0),
              roundTripMillisecondsMax = roundTrips.Maximum(),
            }
          end,
        }
      end,
    }
  end

  return {
    libraries = adapter.Libraries(),
    cases = cases,
    checks = function()
      return {}
    end,
  }
end

return Whisper

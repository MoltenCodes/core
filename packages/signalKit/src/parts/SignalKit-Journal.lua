-- MoltenCodes SignalKit part Journal
--
-- Journals: `SignalKit:NewJournal(capacity[, options])` creates a signal that
-- also records its last `capacity` firings for explicit pull, `journal:Fire`
-- records and dispatches, and `journal:History()` walks the recorded firings.
-- Without this part `NewJournal` raises at the caller with the file to embed;
-- a journal an older revision created keeps its slots, its `Fire` and
-- `History` raise the same way, and it still fires as a signal through
-- `SignalKit.Fire` (docs/API.md, "Parts"; ADR 0001).
--
-- The part needs SignalKit's core loaded first. It creates the journal
-- prototype and metatable in the core's state when the state has none (a state
-- an older revision created keeps its own, so its journals gain these
-- methods), records itself in `_state.parts.Journal`, and reads the core's
-- signal functions and package-wide limits from the state at call time.
--
-- Contents
-- --------
--   Constants ............. identity, the default capacity, slot sizing
--   Core .................. SignalKit's core, its state and its helpers
--   Journals .............. NewJournal, the firing ring and History
--   Commit ................ the part record and the methods

-- Constants ------------------------------------------------------------------

local PART_NAME = "Journal"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "signalKit", 1
-- The `_state.helpers` entries and part records this part relies on; the core
-- publishes the interface it offers as `_state.partInterface`.
local REQUIRED_PART_INTERFACE = 1

-- The ring a `NewJournal` call without a capacity gets.
local DEFAULT_JOURNAL_CAPACITY = 128

-- Why `NewJournal` refuses `UNBOUNDED` as a capacity.
local UNBOUNDED_CAPACITY_REFUSAL = "the ring is allocated when the journal is created"

-- Values recorded with one multiple assignment; each slot is sized in advance
-- for this many, and wider firings take a `select` loop for the remainder.
local MULTIPLE_ASSIGNMENT_SLOTS = 8

local JOURNAL_RECEIVER_HINT = " must be called on a journal; use journal:"
local JOURNAL_FIRE_RECEIVER_MESSAGE = "SignalKit.Journal:Fire"
  .. JOURNAL_RECEIVER_HINT
  .. "Fire(...)"
local HISTORY_RECEIVER_MESSAGE = "SignalKit.Journal:History" .. JOURNAL_RECEIVER_HINT .. "History()"

-- Core -----------------------------------------------------------------------

local type = type
local rawget = rawget
local rawset = rawset

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local SignalKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  SignalKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(SignalKit) == "table" and rawget(SignalKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes SignalKit part Journal requires SignalKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(rawget(installed, "revision")) == "number"
  and rawget(installed, "revision") >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every copy.
  return SignalKit
end

-- The core's functions, refilled by every core revision; read through this
-- table at each call, never copied, so a newer core serves this part.
local helpers = rawget(state, "helpers")
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")

-- A journal's own methods (`Fire`, `History`) shadow the signal methods it
-- inherits from the facade, so the prototype falls back to `SignalKit`, whose
-- identity Registry preserves. Both tables live in the state so that journals
-- survive an upgrade and gain the newer methods when the prototype is refilled.
local JOURNAL_PROTOTYPE = rawget(state, "journalPrototype")
if type(JOURNAL_PROTOTYPE) ~= "table" then
  JOURNAL_PROTOTYPE = setmetatable({}, { __index = SignalKit })
  rawset(state, "journalPrototype", JOURNAL_PROTOTYPE)
end
local JOURNAL_METATABLE = rawget(state, "journalMetatable")
if type(JOURNAL_METATABLE) ~= "table" then
  JOURNAL_METATABLE = { __index = JOURNAL_PROTOTYPE }
  rawset(state, "journalMetatable", JOURNAL_METATABLE)
end

-- Journals ---------------------------------------------------------------------
--
-- A journal is a signal that also keeps its last `capacity` firings in a ring
-- of slot tables, allocated when the journal is created and reused for ever
-- after: a firing overwrites the oldest slot in place. Nothing is replayed to
-- a listener that connects; a consumer that wants the past pulls it through
-- `History()`, which walks the ring oldest to newest through one shared,
-- stateless iterator function, so the walk allocates nothing either.
--
-- Each slot is sized in advance for `MULTIPLE_ASSIGNMENT_SLOTS` values. A wider
-- firing grows its slot once; after every slot has seen the widest firing the
-- journal allocates nothing per `Fire`. The width is bounded by the
-- package-wide `maxJournalArguments` and refused at the firing line with a
-- message that names the two counts and never a value, which may be secret.
-- The values themselves are only stored and handed back, never compared, so
-- a secret value passes through the ring untouched.

---Build one empty slot sized in advance. The eight `nil` items size the array part
---so the first firing into the slot does not grow it, and the two named
---fields have to be in the same constructor: adding them afterwards would
---rehash a table whose array holds only `nil`s and shrink it back to nothing.
---@return SignalKit.HistoryEntry
local function newJournalSlot()
  -- The entry is documented as this exact mixed shape: `count`, `generation` and the arguments at `1` to `count`.
  -- selene: allow(mixed_table)
  return { nil, nil, nil, nil, nil, nil, nil, nil, count = 0, generation = 0 }
end

---Build the ring of `capacity` slots.
---@param capacity integer
---@return SignalKit.HistoryEntry[]
local function newJournalSlots(capacity)
  local slots = {}
  for index = 1, capacity do
    slots[index] = newJournalSlot()
  end
  return slots
end

---Validate a `NewJournal` capacity: `nil` for the default, otherwise an
---integer from 1 to the package-wide `maxJournalCapacity`. The default is
---checked too, so a session that lowered the limit below it is told to state
---a capacity rather than handed a ring over the limit.
---@param capacity any
---@param level integer stack level the failures are reported at
---@return integer
local function readJournalCapacity(capacity, level)
  local maxCapacity = rawget(sharedLimits, "maxJournalCapacity")
  if type(capacity) == "nil" then
    if DEFAULT_JOURNAL_CAPACITY > maxCapacity then
      error(
        "SignalKit:NewJournal default capacity "
          .. DEFAULT_JOURNAL_CAPACITY
          .. " exceeds maxJournalCapacity "
          .. maxCapacity
          .. "; pass a capacity",
        level
      )
    end
    return DEFAULT_JOURNAL_CAPACITY
  end
  helpers.refuseSecret(capacity, "SignalKit:NewJournal capacity", level + 1)
  if capacity == UNBOUNDED then
    error(
      "SignalKit:NewJournal capacity cannot be SignalKit.UNBOUNDED: " .. UNBOUNDED_CAPACITY_REFUSAL,
      level
    )
  end
  if not helpers.isIntegerUpTo(capacity, maxCapacity) then
    error(
      "SignalKit:NewJournal capacity must be an integer from 1 to "
        .. maxCapacity
        .. " (SignalKit:SetLimits maxJournalCapacity)",
      level
    )
  end
  return capacity
end

---Store `...` into `slot`, clearing what a wider earlier firing left behind.
---
---The multiple assignment writes the first eight positions, `nil` included,
---so only positions past eight can hold stale values.
---@param slot SignalKit.HistoryEntry
---@param count integer
---@param ... any
local function recordArguments(slot, count, ...)
  local previousCount = slot.count
  slot[1], slot[2], slot[3], slot[4], slot[5], slot[6], slot[7], slot[8] = ...
  for index = MULTIPLE_ASSIGNMENT_SLOTS + 1, count do
    slot[index] = select(index, ...)
  end
  local clearFrom = count
  if clearFrom < MULTIPLE_ASSIGNMENT_SLOTS then
    clearFrom = MULTIPLE_ASSIGNMENT_SLOTS
  end
  for index = clearFrom + 1, previousCount do
    slot[index] = nil
  end
  slot.count = count
end

---Record `...` as the newest entry, then dispatch it exactly as `signal:Fire`.
---
---The entry is recorded before any listener runs, so a listener reading
---`History` during the dispatch sees the firing being delivered as the newest
---entry, and a listener error leaves the firing recorded.
---@param self SignalKit.Journal
---@param ... any at most `maxJournalArguments` values (8 by default)
local function journalFire(self, ...)
  if type(self) ~= "table" then
    error(JOURNAL_FIRE_RECEIVER_MESSAGE, 2)
  end
  local slots = rawget(self, "_journalSlots")
  if type(slots) ~= "table" then
    error(JOURNAL_FIRE_RECEIVER_MESSAGE, 2)
  end

  local count = select("#", ...)
  local maxArguments = rawget(sharedLimits, "maxJournalArguments")
  if count > maxArguments then
    error(
      "SignalKit.Journal:Fire records at most "
        .. maxArguments
        .. " arguments per firing; received "
        .. count,
      2
    )
  end

  local head = rawget(self, "_journalHead")
  local slot = slots[head]
  recordArguments(slot, count, ...)
  -- `fire` moves the generation to exactly this value before dispatching.
  slot.generation = (rawget(self, "_generation") or 0) + 1

  local capacity = rawget(self, "_journalCapacity")
  if head == capacity then
    rawset(self, "_journalHead", 1)
  else
    rawset(self, "_journalHead", head + 1)
  end
  local recorded = rawget(self, "_journalRecorded")
  if recorded < capacity then
    rawset(self, "_journalRecorded", recorded + 1)
  end

  helpers.fire(self, ...)
end

---The stateless iterator `History` returns. `position` counts the entries
---already returned, so the next one is the oldest recorded entry moved
---forward by `position`; the oldest sits `recorded` slots behind the write
---position, wrapping around the ring.
---@param journal SignalKit.Journal
---@param position integer
---@return integer|nil nextPosition
---@return SignalKit.HistoryEntry|nil entry
local function nextHistoryEntry(journal, position)
  local recorded = rawget(journal, "_journalRecorded")
  if position >= recorded then
    return nil
  end
  local index = rawget(journal, "_journalHead") - recorded + position
  if index < 1 then
    index = index + rawget(journal, "_journalCapacity")
  end
  return position + 1, rawget(journal, "_journalSlots")[index]
end

---Returns what a generic `for` needs to walk the recorded firings, oldest to
---newest: `for position, entry in journal:History() do`. The iterator
---function is shared, so the call allocates nothing.
---@param self SignalKit.Journal
---@return fun(journal: SignalKit.Journal, position: integer): integer?, SignalKit.HistoryEntry? iterator
---@return SignalKit.Journal journal
---@return integer start
local function journalHistory(self)
  if type(self) ~= "table" or type(rawget(self, "_journalSlots")) ~= "table" then
    error(HISTORY_RECEIVER_MESSAGE, 2)
  end
  return nextHistoryEntry, self, 0
end

---Creates a journal: a signal that also records its last `capacity` firings.
---@param self SignalKit
---@param capacity integer? `1` to `maxJournalCapacity`; default `128`.
---@param options SignalKit.SignalOptions?
---@return SignalKit.Journal journal
local function facadeNewJournal(self, capacity, options)
  helpers.validateFacade(self, "SignalKit:NewJournal", 3)
  local ringCapacity = readJournalCapacity(capacity, 3)
  local onFirst, onLast = helpers.readSignalOptions(options, "SignalKit:NewJournal", 3)

  local journal = helpers.newSignalTable(onFirst, onLast, false)
  rawset(journal, "_journalCapacity", ringCapacity)
  rawset(journal, "_journalSlots", newJournalSlots(ringCapacity))
  -- The slot the next firing writes, and how many slots hold a firing.
  rawset(journal, "_journalHead", 1)
  rawset(journal, "_journalRecorded", 0)
  return setmetatable(journal, JOURNAL_METATABLE)
end

-- Commit -----------------------------------------------------------------------

local facadeMethods = { NewJournal = facadeNewJournal }
local journalMethods = { Fire = journalFire, History = journalHistory }

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  facadeMethods = facadeMethods,
  journalMethods = journalMethods,
})
rawset(SignalKit, "NewJournal", facadeNewJournal)
rawset(JOURNAL_PROTOTYPE, "Fire", journalFire)
rawset(JOURNAL_PROTOTYPE, "History", journalHistory)

return SignalKit

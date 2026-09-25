--- Entry point of one benchmark process: one workload, one side, one mode.
---
---     lua main.lua --workload NAME --side moltencodes|ace3 --mode list|case|checks
---                  [--case NAME] [--ace3 DIRECTORY] [--warmup N] [--repetitions N]
---
--- `python3 -m tooling.bench.run` starts one process per case and side, so no
--- case inherits heap, frames or registrations from another, and the two sides
--- never share a process. The process prints exactly one JSON document on
--- standard output:
---
---   list     `{ "cases": [...names], "libraries": [...] }`
---   case     the result `Bench.MeasureCase` returns, plus `libraries`
---   checks   `{ "checks": [...], "libraries": [...] }`
---
--- Anything else a library prints goes to standard error, so it can never
--- corrupt the document.

local Bench = require("Bench")
local BenchHost = require("BenchHost")

--- The workloads, by the name the runner passes. Each is a module under
--- `workloads/` with `Build(side, host, settings)`; the contract is in
--- `docs/BENCHMARKS.md`, "Adding a workload".
local WORKLOADS = {
  eventDispatch = "workloads.EventDispatch",
  messageDispatch = "workloads.MessageDispatch",
  timers = "workloads.Timers",
  settings = "workloads.Settings",
  codec = "workloads.Codec",
  comm = "workloads.Comm",
}

local SIDES = { moltencodes = true, ace3 = true }
local MODES = { list = true, case = true, checks = true }

---Parse `--name value` pairs.
---@param arguments string[]
---@return table<string, string>
local function parseArguments(arguments)
  local options = {}
  local index = 1
  while index <= #arguments do
    local name = arguments[index]:match("^%-%-(.+)$")
    if name == nil or arguments[index + 1] == nil then
      error("usage: main.lua --workload NAME --side SIDE --mode MODE [--case NAME] ...", 0)
    end
    options[name] = arguments[index + 1]
    index = index + 2
  end
  return options
end

---@param options table<string, string>
---@param name string
---@param default integer
---@return integer
local function readCount(options, name, default)
  local value = tonumber(options[name] or default)
  if value == nil or value < 0 or value ~= math.floor(value) then
    error("--" .. name .. " must be a non-negative integer", 0)
  end
  return value
end

---Send `print` to standard error while a library runs, so only the JSON
---document reaches standard output.
local function redirectPrint()
  -- `print` is a global; replacing it is the only way to redirect what libraries print.
  -- selene: allow(global_usage)
  rawset(_G, "print", function(...)
    local parts = {}
    for index = 1, select("#", ...) do
      parts[index] = tostring((select(index, ...)))
    end
    local standardError = io.stderr
    standardError:write(table.concat(parts, "\t"), "\n")
  end)
end

local function main(arguments)
  local options = parseArguments(arguments)
  local moduleName = WORKLOADS[options.workload or ""]
  if moduleName == nil then
    error("unknown --workload " .. tostring(options.workload), 0)
  end
  if not SIDES[options.side or ""] then
    error("--side must be moltencodes or ace3", 0)
  end
  if not MODES[options.mode or ""] then
    error("--mode must be list, case or checks", 0)
  end
  if options.side == "ace3" and options.ace3 == nil then
    error("--ace3 DIRECTORY is required for the ace3 side", 0)
  end

  redirectPrint()
  local settings = {
    warmup = readCount(options, "warmup", 2),
    repetitions = readCount(options, "repetitions", 7),
    ace3 = options.ace3,
  }
  local host = BenchHost.New()
  local workload = require(moduleName)
  local suite = workload.Build(options.side, host, settings)

  local document
  if options.mode == "list" then
    local names = {}
    for index = 1, #suite.cases do
      names[index] = suite.cases[index].name
    end
    document = { cases = names }
  elseif options.mode == "checks" then
    document = { checks = suite.checks() }
  else
    local selected
    for index = 1, #suite.cases do
      if suite.cases[index].name == options.case then
        selected = suite.cases[index]
      end
    end
    if selected == nil then
      error("unknown --case " .. tostring(options.case), 0)
    end
    document = Bench.MeasureCase(selected, settings)
  end
  document.libraries = suite.libraries
  io.write(Bench.EncodeJson(document), "\n")
end

main({ ... })

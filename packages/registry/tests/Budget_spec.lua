-- The budget of the Registry core (`src/Registry.lua`, its header and
-- docs/records/registry.md): at most 600 code lines, a code line being one that
-- is neither blank nor a comment. Comments cost nothing resident, so they are
-- not counted; the resident figure (at most 24 KB with debug information
-- kept) is measured and reported with each change, as the records do.

local CORE = "packages/registry/src/Registry.lua"
local MAXIMUM_CODE_LINES = 600

---Count the lines of `text` that are neither blank nor inside a comment.
---@param text string
---@return integer
local function countCodeLines(text)
  local count = 0
  local inBlockComment = false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if inBlockComment then
      if trimmed:find("]]", 1, true) then
        inBlockComment = false
      end
    elseif trimmed:find("^%-%-%[%[") then
      inBlockComment = not trimmed:find("]]", 1, true)
    elseif trimmed ~= "" and not trimmed:find("^%-%-") then
      count = count + 1
    end
  end
  return count
end

describe("Registry budget", function()
  it("counts code lines, not blank lines or comments", function()
    local sample = "-- comment\n\nlocal a = 1\n--[[ block\nstill ]]\nreturn a -- trailing\n"
    assert.are.equal(2, countCodeLines(sample))
  end)

  it("keeps the core at or under " .. MAXIMUM_CODE_LINES .. " code lines", function()
    local file = assert(io.open(CORE, "r"))
    local text = file:read("*a")
    file:close()
    local count = countCodeLines(text)
    assert.is_true(
      count <= MAXIMUM_CODE_LINES,
      CORE .. " has " .. count .. " code lines; the budget is " .. MAXIMUM_CODE_LINES
    )
  end)
end)

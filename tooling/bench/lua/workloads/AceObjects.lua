--- A pool of Ace3 embed targets for the dispatch workloads.
---
--- CallbackHandler-1.0 keeps one callback per `self` and event, so N Ace3
--- listeners of one event need N distinct objects, as N addons (or modules)
--- would be. The objects are created and embedded once, before measuring, and
--- handed out from a stack, so a connect in a timed loop costs the library's
--- registration and nothing of the harness's object creation. A Kit
--- connection, by contrast, is created by the Kit on every connect, and that
--- allocation is the Kit's own.

local AceObjects = {}

---Build a pool of `size` objects, each embedded with `library`.
---@param library table an Ace3 library with `Embed`
---@param size integer
---@return table pool with `Take()` and `Give(object)`
function AceObjects.NewPool(library, size)
  local free = {}
  for index = 1, size do
    free[index] = library:Embed({ benchIndex = index })
  end
  local count = size

  local pool = {}

  ---@return table object an embedded object not in use
  function pool.Take()
    if count == 0 then
      error("AceObjects pool exhausted", 2)
    end
    local object = free[count]
    free[count] = nil
    count = count - 1
    return object
  end

  ---@param object table an object `Take` returned
  function pool.Give(object)
    count = count + 1
    free[count] = object
  end

  return pool
end

return AceObjects

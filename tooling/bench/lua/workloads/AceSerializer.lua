--- AceSerializer-3.0 text: BridgeKit against AceSerializer-3.0 itself.
---
--- Both sides write and read the same format, byte for byte (BridgeKit's
--- fixtures prove that; this workload measures it): `BridgeKit:AceSerialize`
--- and `BridgeKit:AceDeserialize` against `AceSerializer:Serialize` and
--- `AceSerializer:Deserialize`, over the payloads, cases and checks of the
--- `codec` workload (`workloads.Codec`).

local Codec = require("workloads.Codec")

local AceSerializer = {}

---@param host table
---@return table adapter, table[] libraries
local function bridgeAdapter(host)
  local loaded = host.RequireAll({ "Registry", "BridgeKit" })
  local BridgeKit = loaded[2]
  local adapter = {}

  function adapter.encode(value)
    local ok, text = BridgeKit:AceSerialize(value)
    if not ok then
      error("BridgeKit:AceSerialize refused a benchmark payload: " .. tostring(text), 0)
    end
    return text
  end

  function adapter.decode(text)
    return BridgeKit:AceDeserialize(text)
  end

  return adapter, { { name = "BridgeKit", revision = BridgeKit.REVISION } }
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function AceSerializer.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = bridgeAdapter(host)
  else
    adapter, libraries = Codec.AceAdapter(host, settings.ace3)
  end
  return Codec.Suite(adapter, libraries)
end

return AceSerializer

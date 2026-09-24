# BrokerKit

BrokerKit is the data-object registry for display addons. An addon creates a named object and writes `text`, `icon`, `OnClick` and the other attributes as plain fields; a display addon (a panel, a minimap bar, a tooltip) reads them as plain fields and is told about every change through a signal. The attribute set and the field-write idiom are those of LibDataBroker-1.1, the contract every existing display addon consumes, so when LibDataBroker is loaded BrokerKit can expose its objects into it (Titan Panel, Bazooka and ChocolateBar then show them) and adopt its objects read-only (an addon written against BrokerKit sees theirs). BrokerKit adds what LibDataBroker lacks: attribute types checked at the caller's line, change notification per object and per attribute, sorted enumeration, and bounded retention.

An addon publishing an object:

```lua
-- MyAddon/Broker.lua
local BrokerKit = MoltenCodes.Registries[2]:Get("brokerKit", 1)

local status = BrokerKit:New("MyAddon", {
    type = "data source",
    text = "0 ms",
    icon = [[Interface\AddOns\MyAddon\Icon]],
    OnClick = function(frame, button)
        if button == "LeftButton" then
            MyAddon:ToggleWindow()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("MyAddon")
        tooltip:AddLine("Click to open the window")
    end,
})

-- Later, as plain fields (the LibDataBroker idiom) or through Set.
status.text = latency .. " ms"
status:Set("value", latency)

-- Let the LibDataBroker displays the player already runs show it.
BrokerKit:ExposeToLibDataBroker()
```

A display addon showing every object:

```lua
local BrokerKit = MoltenCodes.Registries[2]:Get("brokerKit", 1)

-- See the objects other addons registered with LibDataBroker too.
BrokerKit:AdoptFromLibDataBroker()

local function attach(object)
    local button = MyPanel:AddButton(object.name, object.icon, object.text)
    button:SetScript("OnClick", function(frame, mouseButton)
        if object.OnClick then
            object.OnClick(frame, mouseButton)
        end
    end)
    object:OnChange("text", function(_, _, text)
        button:SetText(text)
    end)
end

for _, object in BrokerKit:Iterate() do
    attach(object)
end
BrokerKit:OnObjectAdded(attach)
```

What each piece promises:

- **`New`** creates one object per unique name; `type` defaults to `"data source"`. The fifteen attributes LibDataBroker names are checked for type at the caller's line (`text` must be a string, `OnClick` a function, `icon` a path or a FileDataID); anything else is a custom attribute and holds any value. A duplicate name raises at the caller.
- **Attributes are plain fields.** `object.text` is a table read and `object.text = "..."` fires the change signals, exactly as with a LibDataBroker data object; `object:Set` and `object:Get` are the explicit form with the same checks and cost. `object.name` is read-only. Writing the value an attribute already holds is one comparison and fires nothing.
- **`OnChange`** returns a SignalKit connection fired with `(object, attribute, value, previous)`, for one attribute or for all of them.
- **`Objects`** returns a fresh sorted array of names; **`Iterate`** walks `name, object` in the same order without allocating; **`Get`** finds one; **`OnObjectAdded`** reports each new object, whatever its origin.
- **`ExposeToLibDataBroker`** and **`AdoptFromLibDataBroker`** connect the two registries without echo loops, and return `false, "absent"` when LibStub or LibDataBroker-1.1 is not loaded. Adopted objects are read-only; **`IsForeign`** tells them apart.
- **`SetLimits`** opens the two bounds (256 objects, 32 attributes per object) on purpose, up to `BrokerKit.UNBOUNDED`.

Non-goals: rendering a display, the minimap launcher button (a user-interface Kit), persisting anything (a display's saved variables hold the player's layout).

See [`docs/API.md`](docs/API.md) for the complete contract, including the attribute table and the LibDataBroker mapping field by field, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the layout.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\brokerKit\BrokerKit.lua
```

Minimum footprint: embed 3 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`, `brokerKit/BrokerKit.lua`.

Direct runtime dependencies: Registry API 2, SignalKit API 1.
Every file above is required; omitting one makes this package raise at
load.

LibStub and LibDataBroker-1.1 are optional and found when
`ExposeToLibDataBroker` or `AdoptFromLibDataBroker` is called, so they may load
before or after BrokerKit; call those two after them (on `PLAYER_LOGIN`, say).
BrokerKit reads the host's `issecretvalue` when it needs it; it is optional
(see *Host facilities* in the API).

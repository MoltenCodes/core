# MediaKit

MediaKit is a typed registry of named media for World of Warcraft addons: fonts, status bars, borders, backgrounds, sounds, textures and icons. Each entry is a file path or a FileDataID; a font also says which writing scripts it renders, so a Latin-only font is never offered to a Chinese or Korean client. Lists are sorted and cached, defaults belong to the consumer that chose them, and every new entry fires a signal. When LibSharedMedia-3.0 is loaded, MediaKit can adopt its entries read-only and mirror its own into it, so existing media packs and existing consumers keep working.

A media pack:

```lua
-- MyMediaPack/Media.lua
local MediaKit = MoltenCodes.Registries[2]:Get("mediaKit", 1)
local PATH = [[Interface\AddOns\MyMediaPack\Media\]]

MediaKit:Register("statusbar", "MyPack Smooth", PATH .. "Smooth.tga")
MediaKit:Register("border", "MyPack Thin", PATH .. "Thin.tga")
MediaKit:Register("sound", "MyPack Chime", 569593) -- a FileDataID from the client
MediaKit:Register("font", "MyPack Sans", PATH .. "Sans.ttf", {
    scripts = { "latin", "cyrillic" },
})
```

A consumer:

```lua
local MediaKit = MoltenCodes.Registries[2]:Get("mediaKit", 1)

-- Make the packs made for LibSharedMedia visible, and ours visible to them.
MediaKit:AdoptLibSharedMedia()
MediaKit:MirrorToLibSharedMedia()

local defaults = MediaKit:Defaults("MyAddon")
defaults:Set("statusbar", MyAddonDB.barTexture) -- a name the player picked earlier

bar:SetStatusBarTexture(MediaKit:Fetch("statusbar", defaults:Get("statusbar")))

-- A dropdown: the names, sorted, fonts filtered to what this client can render.
for _, name in ipairs(MediaKit:List("font")) do
    dropdown:AddItem(name)
end

-- Refresh the dropdown when a pack that loads later registers more.
MediaKit:OnRegistered("font", function(_, name)
    dropdown:AddItem(name)
end)
```

What each piece promises:

- **`Register`** takes one of seven fixed types, a name and a path or FileDataID. A name holding different data is refused with `nil, "taken"`; the same name with the same data again returns `true` and changes nothing; past 1024 entries of a type it returns `nil, "full"`.
- **`Fetch`** and **`Has`** are one table read and allocate nothing. A font that does not render the client's script is `nil` unless `anyScript` is asked for. A font registered without `scripts` renders Latin only; declare the scripts of anything wider.
- **`List`** returns a cached sorted array, shared by every caller and read-only, rebuilt only after a registration of its type.
- **`OnRegistered`** returns a SignalKit connection fired with `(type, name, data)` for every new entry, whatever its origin.
- **`Defaults`** gives each consumer its own choices; `Get` falls back to the client's built-in media, registered at load, and then to the first usable listed entry, so a CJK client still gets a font it can render.
- **`AdoptLibSharedMedia`** and **`MirrorToLibSharedMedia`** connect the two registries without echo loops, and return `false, "absent"` when LibStub or LibSharedMedia-3.0 is not loaded.

Non-goals: shipping media files and global user overrides (a consumer's saved variables hold the player's choice).

See [`docs/API.md`](docs/API.md) for the complete contract, including the script table, the built-in media and the mirroring rules, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the layout.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\mediaKit\MediaKit.lua
```

Direct runtime dependencies: Registry API 2, SignalKit API 1.
Every file above is required; omitting one makes this package raise at
load.

LibStub and LibSharedMedia-3.0 are optional and found when
`AdoptLibSharedMedia` or `MirrorToLibSharedMedia` is called, so they may load
before or after MediaKit; call those two after them (on `PLAYER_LOGIN`, say, to
also see packs that load later without LibSharedMedia's callback). MediaKit
reads the host's `GetLocale` and `issecretvalue` when it needs them; each one
is optional (see *Host facilities* in the API).

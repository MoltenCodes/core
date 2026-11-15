--- WidgetKit's parts in the load order the embeds generator writes: `Renderer`
--- after the type parts it draws with. Shared by the package's test
--- environments, which load every part after the core unless a spec asks for
--- the core alone.
return {
  "Containers",
  "Text",
  "Button",
  "CheckBox",
  "Slider",
  "EditBox",
  "Dropdown",
  "ColorPicker",
  "ScrollList",
  "Position",
  "Renderer",
}

--- The fake `CreateFrame` and everything a spec does with the Frames it makes.
---
--- Frames are the framework's whole boundary with the World of Warcraft event
--- system, so this stub models the parts of that boundary a package can get
--- wrong: the two-slot `RegisterUnitEvent` limit, a registration the host
--- refuses, a `SetScript` that raises, and which Frames an emitted event
--- actually reaches.
---
--- It also models the parts of a Frame a widget toolkit touches, so that a
--- layout can be asserted outside the client:
---
---   geometry       sizes, anchors (`SetPoint`, `GetPoint`, `ClearAllPoints`,
---                  `SetAllPoints`), and `GetRect` / `GetCenter` / `GetWidth`
---                  resolved from those anchors the way the client resolves
---                  them: two anchors on opposite edges size a region, one
---                  anchor positions it at its own size;
---   hierarchy      `SetParent` / `GetParent`, named frames published as
---                  globals, visibility through the parent chain, scale;
---   regions        `CreateFontString` and `CreateTexture`, with text,
---                  texture and colour state a spec can read back;
---   frame types    `Button`, `CheckButton`, `Slider`, `EditBox` and
---                  `ScrollFrame` with the state and scripts they carry;
---   interaction    mouse, keyboard, movable and resizable flags, drag
---                  registration, `StartMoving` / `StopMovingOrSizing`;
---   templates      accepted and recorded, otherwise no-ops.
---
--- Every function here takes the environment's shared state table rather than
--- closing over locals, so the stub can be built, reset and inspected without
--- the whole fixture being one function. The methods every Frame shares live
--- in one metatable per frame type, so building a Frame costs what it always
--- did plus a few fields; geometry tables are created on first use.

local FrameStub = {}

local Constants = require("framework.Constants")

---@param values any[]
---@return any[]
local function copyArray(values)
    local copy = {}
    for index = 1, #values do
        copy[index] = values[index]
    end
    return copy
end

---Whether a registration would deliver an event with this payload.
---
---A unit registration only fires for its own filter tokens, which is how a
---spec sees a package that registered the wrong filter set.
---@param registration table
---@return boolean
local function registrationAccepts(registration, ...)
    if registration.kind ~= "unit" then
        return true
    end

    local unit = select(1, ...)
    for index = 1, #registration.units do
        if registration.units[index] == unit then
            return true
        end
    end
    return false
end

---Read a global the way the client's own name lookups do.
---@param name string
---@return any
local function readGlobal(name)
    -- The fixture stands in for the World of Warcraft client, whose named frames only exist in the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Write a global the way the client publishes a named frame.
---@param name string
---@param value any
local function writeGlobal(name, value)
    -- The fixture stands in for the World of Warcraft client, whose named frames only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

-- Geometry ---------------------------------------------------------------------

--- Which horizontal edge each of the nine anchor points sits on.
local HORIZONTAL_EDGE = {
    TOPLEFT = "left",
    LEFT = "left",
    BOTTOMLEFT = "left",
    TOP = "center",
    CENTER = "center",
    BOTTOM = "center",
    TOPRIGHT = "right",
    RIGHT = "right",
    BOTTOMRIGHT = "right",
}

--- Which vertical edge each of the nine anchor points sits on.
local VERTICAL_EDGE = {
    TOPLEFT = "top",
    TOP = "top",
    TOPRIGHT = "top",
    LEFT = "middle",
    CENTER = "middle",
    RIGHT = "middle",
    BOTTOMLEFT = "bottom",
    BOTTOM = "bottom",
    BOTTOMRIGHT = "bottom",
}

--- How many relative regions `resolveRect` follows before it gives up, which
--- only matters for an anchor cycle the client would refuse outright.
local MAXIMUM_RESOLVE_DEPTH = 32

---The horizontal coordinate of `edge` on a span starting at `start`.
---@param start number
---@param size number
---@param edge string "left", "center" or "right"
---@return number
local function horizontalCoordinate(start, size, edge)
    if edge == "left" then
        return start
    elseif edge == "right" then
        return start + size
    end
    return start + size / 2
end

---The vertical coordinate of `edge` on a span starting at `bottom`.
---@param bottom number
---@param size number
---@param edge string "top", "middle" or "bottom"
---@return number
local function verticalCoordinate(bottom, size, edge)
    if edge == "bottom" then
        return bottom
    elseif edge == "top" then
        return bottom + size
    end
    return bottom + size / 2
end

local resolveRect

---The rect of a scroll child, which the client places at its scroll frame's
---top-left corner, moved up by the vertical scroll.
---@param region table the scroll child
---@param scrollFrame table
---@param depth integer
---@return number? left, number bottom, number width, number height
local function resolveScrollChildRect(region, scrollFrame, depth)
    local left, bottom, _, height = resolveRect(scrollFrame, depth + 1)
    if left == nil then
        return nil, 0, 0, 0
    end
    local ownHeight = region._height or 0
    local top = bottom + height + (scrollFrame._verticalScroll or 0)
    return left, top - ownHeight, region._width or 0, ownHeight
end

---Resolve a region's rect from its anchors, allocating nothing.
---
---A region without anchors and without a parent stands for the screen: it
---sits at the origin with its own size. A region without anchors but with a
---parent is not positioned, as in the client, and has no rect. `nil` as an
---anchor's relative region means the parent.
---@param region table
---@param depth integer
---@return number? left, number bottom, number width, number height
function resolveRect(region, depth)
    if depth > MAXIMUM_RESOLVE_DEPTH then
        return nil, 0, 0, 0
    end

    local width = region._width or 0
    local height = region._height or 0
    local points = region._points
    local count = points ~= nil and points.count or 0
    local parent = region.parentFrame

    if count == 0 then
        if parent == nil then
            return 0, 0, width, height
        end
        if parent._scrollChild == region then
            return resolveScrollChildRect(region, parent, depth)
        end
        return nil, 0, 0, 0
    end

    local leftX, rightX, centerX, topY, bottomY, middleY
    for index = 1, count do
        local slot = points[index]
        local relative = slot.relativeTo or parent
        local relativeLeft, relativeBottom, relativeWidth, relativeHeight = 0, 0, 0, 0
        if relative ~= nil then
            relativeLeft, relativeBottom, relativeWidth, relativeHeight =
                resolveRect(relative, depth + 1)
            if relativeLeft == nil then
                return nil, 0, 0, 0
            end
        end

        local x = horizontalCoordinate(
            relativeLeft,
            relativeWidth,
            HORIZONTAL_EDGE[slot.relativePoint]
        ) + slot.x
        local y = verticalCoordinate(
            relativeBottom,
            relativeHeight,
            VERTICAL_EDGE[slot.relativePoint]
        ) + slot.y

        local horizontal = HORIZONTAL_EDGE[slot.point]
        if horizontal == "left" then
            leftX = x
        elseif horizontal == "right" then
            rightX = x
        else
            centerX = x
        end

        local vertical = VERTICAL_EDGE[slot.point]
        if vertical == "top" then
            topY = y
        elseif vertical == "bottom" then
            bottomY = y
        else
            middleY = y
        end
    end

    local left
    if leftX ~= nil and rightX ~= nil then
        width = rightX - leftX
        left = leftX
    elseif leftX ~= nil then
        left = leftX
    elseif rightX ~= nil then
        left = rightX - width
    else
        left = centerX - width / 2
    end

    local bottom
    if topY ~= nil and bottomY ~= nil then
        height = topY - bottomY
        bottom = bottomY
    elseif bottomY ~= nil then
        bottom = bottomY
    elseif topY ~= nil then
        bottom = topY - height
    else
        bottom = middleY - height / 2
    end

    return left, bottom, width, height
end

---Split the client's five `SetPoint` call forms into one shape.
---@return table? relativeTo, string relativePoint, number x, number y
local function readPointArguments(point, first, second, third, fourth)
    if first == nil then
        -- `(point)`, or the full form with the parent written as `nil`.
        if type(second) == "string" then
            return nil, second, third or 0, fourth or 0
        end
        return nil, point, 0, 0
    end
    if type(first) == "number" then
        return nil, point, first, second or 0
    end
    if type(second) == "number" then
        return first, point, second, third or 0
    end
    return first, second or point, third or 0, fourth or 0
end

-- Region methods ---------------------------------------------------------------
--
-- What every Frame, FontString and Texture shares: hierarchy, size, anchors,
-- visibility, alpha and scale.

local RegionMethods = {}

function RegionMethods:GetObjectType()
    return self.frameType
end

function RegionMethods:IsObjectType(objectType)
    return self.frameType == objectType
end

function RegionMethods:GetName()
    return self.name
end

function RegionMethods:GetParent()
    return self.parentFrame
end

function RegionMethods:SetParent(parent)
    if type(parent) == "string" then
        parent = readGlobal(parent)
    end
    self.parentFrame = parent
end

function RegionMethods:SetWidth(width)
    self._width = width
end

function RegionMethods:SetHeight(height)
    self._height = height
end

function RegionMethods:SetSize(width, height)
    self._width = width
    self._height = height
end

function RegionMethods:GetWidth()
    local left, _, width = resolveRect(self, 0)
    if left == nil then
        return self._width or 0
    end
    return width
end

function RegionMethods:GetHeight()
    local left, _, _, height = resolveRect(self, 0)
    if left == nil then
        return self._height or 0
    end
    return height
end

function RegionMethods:GetSize()
    return self:GetWidth(), self:GetHeight()
end

function RegionMethods:GetRect()
    local left, bottom, width, height = resolveRect(self, 0)
    if left == nil then
        return nil
    end
    return left, bottom, width, height
end

function RegionMethods:GetCenter()
    local left, bottom, width, height = resolveRect(self, 0)
    if left == nil then
        return nil
    end
    return left + width / 2, bottom + height / 2
end

function RegionMethods:GetLeft()
    local left = resolveRect(self, 0)
    return left
end

function RegionMethods:GetBottom()
    local left, bottom = resolveRect(self, 0)
    if left == nil then
        return nil
    end
    return bottom
end

function RegionMethods:GetRight()
    local left, _, width = resolveRect(self, 0)
    if left == nil then
        return nil
    end
    return left + width
end

function RegionMethods:GetTop()
    local left, bottom, _, height = resolveRect(self, 0)
    if left == nil then
        return nil
    end
    return bottom + height
end

---Set one anchor. A point that is already set is replaced in place, as in the
---client. Anchor slots are reused, so re-anchoring allocates nothing.
function RegionMethods:SetPoint(point, first, second, third, fourth)
    -- Stub precondition, not a test expectation: the client refuses any other
    -- point name, and a package bug that passes one must surface here.
    if HORIZONTAL_EDGE[point] == nil then
        error("SetPoint stub: unknown point " .. tostring(point), 2)
    end

    local relativeTo, relativePoint, x, y = readPointArguments(point, first, second, third, fourth)
    if type(relativeTo) == "string" then
        local name = relativeTo
        relativeTo = readGlobal(name)
        if type(relativeTo) ~= "table" then
            error("SetPoint stub: could not find a region named " .. name, 2)
        end
    end
    if HORIZONTAL_EDGE[relativePoint] == nil then
        error("SetPoint stub: unknown relative point " .. tostring(relativePoint), 2)
    end

    local points = self._points
    if points == nil then
        points = { count = 0 }
        self._points = points
    end

    local slot = nil
    for index = 1, points.count do
        if points[index].point == point then
            slot = points[index]
            break
        end
    end
    if slot == nil then
        points.count = points.count + 1
        slot = points[points.count]
        if slot == nil then
            slot = {}
            points[points.count] = slot
        end
    end

    slot.point = point
    slot.relativeTo = relativeTo
    slot.relativePoint = relativePoint
    slot.x = x
    slot.y = y
    self.setPointCount = (self.setPointCount or 0) + 1

    local state = self.stubState
    local log = state ~= nil and state.anchorLog or nil
    if log ~= nil then
        log[#log + 1] = {
            region = self,
            point = point,
            relativeTo = relativeTo,
            relativePoint = relativePoint,
            x = x,
            y = y,
        }
    end
end

---@param index integer? defaults to 1
---@return string? point, table? relativeTo, string? relativePoint, number? x, number? y
function RegionMethods:GetPoint(index)
    index = index or 1
    local points = self._points
    if points == nil or index < 1 or index > points.count then
        return nil
    end
    local slot = points[index]
    return slot.point, slot.relativeTo, slot.relativePoint, slot.x, slot.y
end

function RegionMethods:GetNumPoints()
    local points = self._points
    return points ~= nil and points.count or 0
end

function RegionMethods:ClearAllPoints()
    local points = self._points
    if points ~= nil then
        points.count = 0
    end
    self.clearAllPointsCount = (self.clearAllPointsCount or 0) + 1
end

function RegionMethods:SetAllPoints(relativeTo)
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", relativeTo or self.parentFrame, "TOPLEFT", 0, 0)
    self:SetPoint("BOTTOMRIGHT", relativeTo or self.parentFrame, "BOTTOMRIGHT", 0, 0)
end

function RegionMethods:Show()
    self._hidden = nil
end

function RegionMethods:Hide()
    self._hidden = true
end

function RegionMethods:SetShown(shown)
    self._hidden = not shown or nil
end

function RegionMethods:IsShown()
    return self._hidden ~= true
end

---Shown, and every parent shown too.
function RegionMethods:IsVisible()
    local region = self
    for _ = 1, MAXIMUM_RESOLVE_DEPTH do
        if region._hidden == true then
            return false
        end
        region = region.parentFrame
        if region == nil then
            return true
        end
    end
    return false
end

function RegionMethods:SetAlpha(alpha)
    self._alpha = alpha
end

function RegionMethods:GetAlpha()
    return self._alpha or 1
end

function RegionMethods:SetScale(scale)
    self._scale = scale
end

function RegionMethods:GetScale()
    return self._scale or 1
end

---Own scale times every parent's scale.
function RegionMethods:GetEffectiveScale()
    local scale = 1
    local region = self
    for _ = 1, MAXIMUM_RESOLVE_DEPTH do
        scale = scale * (region._scale or 1)
        region = region.parentFrame
        if region == nil then
            break
        end
    end
    return scale
end

function RegionMethods:SetDrawLayer(layer)
    self.drawLayer = layer
end

---Build a method table that falls back to `base`.
---@param base table
---@return table methods
local function extend(base)
    return setmetatable({}, { __index = base })
end

-- FontString and Texture -------------------------------------------------------

local FontStringMethods = extend(RegionMethods)

function FontStringMethods:SetText(text)
    self._text = text
end

function FontStringMethods:GetText()
    return self._text
end

function FontStringMethods:SetFontObject(fontObject)
    self.fontObject = fontObject
end

function FontStringMethods:GetFontObject()
    return self.fontObject
end

function FontStringMethods:SetFont(path, size, flags)
    self.font = path
    self.fontSize = size
    self.fontFlags = flags
end

function FontStringMethods:SetTextColor(red, green, blue, alpha)
    self.textRed, self.textGreen, self.textBlue, self.textAlpha = red, green, blue, alpha
end

function FontStringMethods:GetTextColor()
    return self.textRed or 1, self.textGreen or 1, self.textBlue or 1, self.textAlpha or 1
end

function FontStringMethods:SetJustifyH(justify)
    self.justifyH = justify
end

function FontStringMethods:SetJustifyV(justify)
    self.justifyV = justify
end

function FontStringMethods:SetWordWrap(wrap)
    self.wordWrap = wrap
end

function FontStringMethods:SetNonSpaceWrap(wrap)
    self.nonSpaceWrap = wrap
end

function FontStringMethods:SetMaxLines(lines)
    self.maxLines = lines
end

---Six pixels per byte: a stand-in the stub keeps simple and deterministic.
function FontStringMethods:GetStringWidth()
    local text = self._text
    if type(text) ~= "string" then
        return 0
    end
    return #text * 6
end

---Twelve pixels per line of text.
function FontStringMethods:GetStringHeight()
    local text = self._text
    if type(text) ~= "string" or text == "" then
        return 0
    end
    local _, newlines = text:gsub("\n", "\n")
    return (newlines + 1) * 12
end

local TextureMethods = extend(RegionMethods)

function TextureMethods:SetTexture(texture)
    self._texture = texture
    self.colorRed, self.colorGreen, self.colorBlue, self.colorAlpha = nil, nil, nil, nil
end

function TextureMethods:GetTexture()
    return self._texture
end

function TextureMethods:SetColorTexture(red, green, blue, alpha)
    self._texture = nil
    self.colorRed, self.colorGreen, self.colorBlue, self.colorAlpha = red, green, blue, alpha or 1
end

function TextureMethods:SetVertexColor(red, green, blue, alpha)
    self.vertexRed, self.vertexGreen, self.vertexBlue, self.vertexAlpha = red, green, blue, alpha
end

function TextureMethods:GetVertexColor()
    return self.vertexRed or 1, self.vertexGreen or 1, self.vertexBlue or 1, self.vertexAlpha or 1
end

function TextureMethods:SetTexCoord(...)
    self.texCoordCount = select("#", ...)
end

function TextureMethods:SetBlendMode(mode)
    self.blendMode = mode
end

function TextureMethods:SetDesaturated(desaturated)
    self.desaturated = desaturated
end

-- Frame methods ----------------------------------------------------------------

local FrameMethods = extend(RegionMethods)

---Build a region owned by `frame` and record it on the frame.
---@param frame table
---@param regionType string
---@param methods table
---@param name string?
---@param layer string?
---@return table region
local function newRegion(frame, regionType, methods, name, layer)
    local region = setmetatable({
        frameType = regionType,
        name = name,
        parentFrame = frame,
        drawLayer = layer,
        stubState = frame.stubState,
    }, { __index = methods })
    local regions = frame.regions
    if regions == nil then
        regions = {}
        frame.regions = regions
    end
    regions[#regions + 1] = region
    if name ~= nil then
        writeGlobal(name, region)
        local state = frame.stubState
        state.namedRegions[#state.namedRegions + 1] = name
    end
    return region
end

function FrameMethods:CreateFontString(name, layer, template)
    local region = newRegion(self, "FontString", FontStringMethods, name, layer)
    region.template = template
    return region
end

function FrameMethods:CreateTexture(name, layer, template)
    local region = newRegion(self, "Texture", TextureMethods, name, layer)
    region.template = template
    return region
end

function FrameMethods:GetScript(scriptName)
    return self.scripts[scriptName]
end

function FrameMethods:SetFrameStrata(strata)
    self.strata = strata
end

function FrameMethods:GetFrameStrata()
    return self.strata or "MEDIUM"
end

function FrameMethods:SetFrameLevel(level)
    self.level = level
end

function FrameMethods:GetFrameLevel()
    return self.level or 0
end

function FrameMethods:SetToplevel(toplevel)
    self.toplevel = toplevel
end

function FrameMethods:SetClampedToScreen(clamped)
    self.clampedToScreen = clamped
end

function FrameMethods:EnableMouse(enabled)
    self.mouseEnabled = enabled
end

function FrameMethods:IsMouseEnabled()
    return self.mouseEnabled == true
end

function FrameMethods:EnableMouseWheel(enabled)
    self.mouseWheelEnabled = enabled
end

function FrameMethods:EnableKeyboard(enabled)
    self.keyboardEnabled = enabled
end

function FrameMethods:IsKeyboardEnabled()
    return self.keyboardEnabled == true
end

function FrameMethods:SetMovable(movable)
    self.movable = movable
end

function FrameMethods:IsMovable()
    return self.movable == true
end

function FrameMethods:SetResizable(resizable)
    self.resizable = resizable
end

function FrameMethods:IsResizable()
    return self.resizable == true
end

function FrameMethods:SetResizeBounds(minimumWidth, minimumHeight, maximumWidth, maximumHeight)
    self.minimumWidth, self.minimumHeight = minimumWidth, minimumHeight
    self.maximumWidth, self.maximumHeight = maximumWidth, maximumHeight
end

function FrameMethods:RegisterForDrag(...)
    self.dragButtons = { ... }
end

function FrameMethods:StartMoving()
    self.moving = true
end

function FrameMethods:StartSizing(point)
    self.sizing = point or "BOTTOMRIGHT"
end

function FrameMethods:StopMovingOrSizing()
    self.moving = nil
    self.sizing = nil
end

-- Button and CheckButton --------------------------------------------------------

local ButtonMethods = extend(FrameMethods)

function ButtonMethods:SetText(text)
    self._text = text
end

function ButtonMethods:GetText()
    return self._text
end

function ButtonMethods:GetFontString()
    local fontString = self.fontString
    if fontString == nil then
        fontString = self:CreateFontString()
        self.fontString = fontString
    end
    return fontString
end

function ButtonMethods:Enable()
    self.disabled = nil
end

function ButtonMethods:Disable()
    self.disabled = true
end

function ButtonMethods:SetEnabled(enabled)
    self.disabled = not enabled or nil
end

function ButtonMethods:IsEnabled()
    return self.disabled ~= true
end

function ButtonMethods:RegisterForClicks(...)
    self.clickButtons = { ... }
end

function ButtonMethods:SetNormalFontObject(fontObject)
    self.normalFontObject = fontObject
end

function ButtonMethods:SetHighlightFontObject(fontObject)
    self.highlightFontObject = fontObject
end

function ButtonMethods:SetDisabledFontObject(fontObject)
    self.disabledFontObject = fontObject
end

function ButtonMethods:SetNormalTexture(texture)
    self.normalTexture = texture
end

function ButtonMethods:SetHighlightTexture(texture)
    self.highlightTexture = texture
end

function ButtonMethods:SetPushedTexture(texture)
    self.pushedTexture = texture
end

function ButtonMethods:LockHighlight()
    self.highlightLocked = true
end

function ButtonMethods:UnlockHighlight()
    self.highlightLocked = nil
end

---Click the button as the client does for a user click: nothing while
---disabled, otherwise `OnClick(self, button, down)`.
function ButtonMethods:Click(button)
    if self.disabled == true then
        return
    end
    local onClick = self.scripts.OnClick
    if onClick ~= nil then
        onClick(self, button or "LeftButton", false)
    end
end

local CheckButtonMethods = extend(ButtonMethods)

function CheckButtonMethods:SetChecked(checked)
    self.checked = checked and true or false
end

function CheckButtonMethods:GetChecked()
    return self.checked == true
end

function CheckButtonMethods:SetCheckedTexture(texture)
    self.checkedTexture = texture
end

---A click toggles the checked state before `OnClick` runs, as in the client.
function CheckButtonMethods:Click(button)
    if self.disabled == true then
        return
    end
    self.checked = not self.checked
    local onClick = self.scripts.OnClick
    if onClick ~= nil then
        onClick(self, button or "LeftButton", false)
    end
end

-- Slider -----------------------------------------------------------------------

local SliderMethods = extend(FrameMethods)

function SliderMethods:SetMinMaxValues(minimum, maximum)
    self.minimum, self.maximum = minimum, maximum
    local value = self.value
    if value ~= nil then
        if value < minimum then
            self:SetValue(minimum)
        elseif value > maximum then
            self:SetValue(maximum)
        end
    end
end

function SliderMethods:GetMinMaxValues()
    return self.minimum or 0, self.maximum or 0
end

---Clamp and store the value; a change fires `OnValueChanged(self, value,
---false)`, as a programmatic change does in the client.
function SliderMethods:SetValue(value)
    local minimum, maximum = self.minimum or 0, self.maximum or 0
    if value < minimum then
        value = minimum
    elseif value > maximum then
        value = maximum
    end
    if self.value == value then
        return
    end
    self.value = value
    local onValueChanged = self.scripts.OnValueChanged
    if onValueChanged ~= nil then
        onValueChanged(self, value, false)
    end
end

function SliderMethods:GetValue()
    return self.value or self.minimum or 0
end

function SliderMethods:SetValueStep(step)
    self.valueStep = step
end

function SliderMethods:GetValueStep()
    return self.valueStep or 0
end

function SliderMethods:SetObeyStepOnDrag(obey)
    self.obeyStepOnDrag = obey
end

function SliderMethods:SetOrientation(orientation)
    self.orientation = orientation
end

function SliderMethods:GetOrientation()
    return self.orientation or "HORIZONTAL"
end

function SliderMethods:SetThumbTexture(texture)
    self.thumbTexture = texture
end

function SliderMethods:GetThumbTexture()
    return self.thumbTexture
end

function SliderMethods:Enable()
    self.disabled = nil
end

function SliderMethods:Disable()
    self.disabled = true
end

function SliderMethods:SetEnabled(enabled)
    self.disabled = not enabled or nil
end

function SliderMethods:IsEnabled()
    return self.disabled ~= true
end

-- EditBox ----------------------------------------------------------------------

local EditBoxMethods = extend(FrameMethods)

---Store the text; fires `OnTextChanged(self, false)`, as a programmatic change
---does in the client.
function EditBoxMethods:SetText(text)
    self._text = text
    local onTextChanged = self.scripts.OnTextChanged
    if onTextChanged ~= nil then
        onTextChanged(self, false)
    end
end

function EditBoxMethods:GetText()
    return self._text or ""
end

function EditBoxMethods:Insert(text)
    self:SetText(self:GetText() .. text)
end

function EditBoxMethods:SetMultiLine(multiLine)
    self.multiLine = multiLine
end

function EditBoxMethods:IsMultiLine()
    return self.multiLine == true
end

function EditBoxMethods:SetAutoFocus(autoFocus)
    self.autoFocus = autoFocus
end

function EditBoxMethods:SetFocus()
    self.focused = true
end

function EditBoxMethods:ClearFocus()
    self.focused = nil
end

function EditBoxMethods:HasFocus()
    return self.focused == true
end

function EditBoxMethods:SetMaxLetters(letters)
    self.maxLetters = letters
end

function EditBoxMethods:SetNumeric(numeric)
    self.numeric = numeric
end

function EditBoxMethods:HighlightText() end

function EditBoxMethods:SetCursorPosition(position)
    self.cursorPosition = position
end

function EditBoxMethods:SetFontObject(fontObject)
    self.fontObject = fontObject
end

function EditBoxMethods:SetTextInsets(left, right, top, bottom)
    self.textInsets = { left, right, top, bottom }
end

function EditBoxMethods:SetJustifyH(justify)
    self.justifyH = justify
end

function EditBoxMethods:Enable()
    self.disabled = nil
end

function EditBoxMethods:Disable()
    self.disabled = true
end

function EditBoxMethods:SetEnabled(enabled)
    self.disabled = not enabled or nil
end

function EditBoxMethods:IsEnabled()
    return self.disabled ~= true
end

-- ScrollFrame ------------------------------------------------------------------

local ScrollFrameMethods = extend(FrameMethods)

function ScrollFrameMethods:SetScrollChild(child)
    self._scrollChild = child
    child.parentFrame = self
end

function ScrollFrameMethods:GetScrollChild()
    return self._scrollChild
end

function ScrollFrameMethods:SetVerticalScroll(offset)
    self._verticalScroll = offset
end

function ScrollFrameMethods:GetVerticalScroll()
    return self._verticalScroll or 0
end

function ScrollFrameMethods:SetHorizontalScroll(offset)
    self._horizontalScroll = offset
end

---How far the scroll child reaches below the scroll frame, never negative.
function ScrollFrameMethods:GetVerticalScrollRange()
    local child = self._scrollChild
    if child == nil then
        return 0
    end
    local range = child:GetHeight() - self:GetHeight()
    if range < 0 then
        return 0
    end
    return range
end

function ScrollFrameMethods:UpdateScrollChildRect() end

--- The frame types `CreateFrame` builds, each with its own method table.
local FRAME_METATABLES = {
    Frame = { __index = FrameMethods },
    Button = { __index = ButtonMethods },
    CheckButton = { __index = CheckButtonMethods },
    Slider = { __index = SliderMethods },
    EditBox = { __index = EditBoxMethods },
    ScrollFrame = { __index = ScrollFrameMethods },
}

--- The frame type names, in the order an error message lists them.
local FRAME_TYPE_NAMES = '"Frame", "Button", "CheckButton", "Slider", "EditBox" or "ScrollFrame"'

---Build one Frame and record it in creation order.
---@param state table shared stub state
---@param frameType string
---@param name string?
---@param parent table|string|nil
---@param template string?
---@return table frame
local function newFrame(state, frameType, name, parent, template)
    if type(parent) == "string" then
        parent = readGlobal(parent)
    end

    local frame = setmetatable({
        scripts = {},
        registrations = {},
        registerEventCalls = {},
        registerUnitEventCalls = {},
        unregisterEventCalls = {},
        frameType = frameType,
        name = name,
        parentFrame = parent,
        template = template,
        stubState = state,
    }, FRAME_METATABLES[frameType])

    function frame:SetScript(scriptName, callback)
        if state.failNextSetScript ~= nil then
            local value = state.failNextSetScript
            state.failNextSetScript = nil
            error(value, 0)
        end
        self.scripts[scriptName] = callback
    end

    function frame:RegisterEvent(eventName)
        self.registerEventCalls[#self.registerEventCalls + 1] = eventName
        local result = state.nextRegisterEventResult
        state.nextRegisterEventResult = nil
        if result == false then
            return false
        end
        self.registrations[eventName] = { kind = "event" }
        return result == nil and true or result
    end

    function frame:RegisterUnitEvent(eventName, ...)
        local unitCount = select("#", ...)
        -- Stub precondition, not a test expectation: the real host has two
        -- unit slots. Modelling that faithfully is the only way a suite can
        -- see a package bug that passes a third token.
        if unitCount > Constants.MAXIMUM_UNIT_TOKENS then
            error(
                "RegisterUnitEvent stub accepts at most "
                    .. Constants.MAXIMUM_UNIT_TOKENS
                    .. " unit tokens, received "
                    .. unitCount,
                2
            )
        end

        local units = { ... }
        self.registerUnitEventCalls[#self.registerUnitEventCalls + 1] = {
            eventName = eventName,
            units = copyArray(units),
        }
        local result = state.nextRegisterUnitEventResult
        state.nextRegisterUnitEventResult = nil
        if result == false then
            return false
        end
        self.registrations[eventName] = { kind = "unit", units = copyArray(units) }
        return result == nil and true or result
    end

    function frame:UnregisterEvent(eventName)
        self.unregisterEventCalls[#self.unregisterEventCalls + 1] = eventName
        local existed = self.registrations[eventName] ~= nil
        self.registrations[eventName] = nil
        return existed
    end

    if name ~= nil then
        writeGlobal(name, frame)
        state.namedRegions[#state.namedRegions + 1] = name
    end

    state.frames[#state.frames + 1] = frame
    return frame
end

---Return this stub's state fields to their initial values.
---
---Named frames and regions were published as globals, as the client publishes
---them, so they are removed from the global table here.
---@param state table shared stub state
function FrameStub.Reset(state)
    local named = state.namedRegions
    if named ~= nil then
        for index = 1, #named do
            writeGlobal(named[index], nil)
        end
    end

    state.frames = {}
    state.namedRegions = {}
    state.anchorLog = nil
    state.nextRegisterEventResult = nil
    state.nextRegisterUnitEventResult = nil
    state.failNextSetScript = nil
end

---Install the globals this stub owns.
---@param state table shared stub state
function FrameStub.InstallGlobals(state)
    -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "CreateFrame", function(frameType, name, parent, template)
        -- Stub precondition, not a test expectation: support modules are
        -- plain `require`d modules, so a misuse must surface as an ordinary
        -- Lua error rather than as a failed assertion.
        if FRAME_METATABLES[frameType] == nil then
            error(
                "CreateFrame stub supports only "
                    .. FRAME_TYPE_NAMES
                    .. ", received "
                    .. tostring(frameType),
                2
            )
        end
        return newFrame(state, frameType, name, parent, template)
    end)
end

---Attach this stub's public helpers to `environment`.
---@param environment table the fixture facade specs call
---@param state table shared stub state
function FrameStub.Attach(environment, state)
    ---@return table[] frames Every Frame created, in creation order.
    function environment.Frames()
        return state.frames
    end

    ---Deliver `eventName` to every Frame whose registration accepts it.
    ---
    ---Frames are walked in creation order. That order is an artefact of this
    ---stub, not a guarantee any package makes.
    function environment.Emit(eventName, ...)
        local frames = state.frames
        local frameCount = #frames
        for index = 1, frameCount do
            local frame = frames[index]
            local registration = frame.registrations[eventName]
            if registration ~= nil and registrationAccepts(registration, ...) then
                local onEvent = frame.scripts.OnEvent
                if onEvent ~= nil then
                    onEvent(frame, eventName, ...)
                end
            end
        end
    end

    ---Run every installed `OnUpdate` handler once.
    ---@param elapsed number? seconds since the previous frame
    function environment.Tick(elapsed)
        local frames = state.frames
        local count = #frames
        for index = 1, count do
            local callback = frames[index].scripts.OnUpdate
            if callback ~= nil then
                callback(frames[index], elapsed or 0.016)
            end
        end
    end

    ---@return integer count Frames currently carrying an `OnUpdate` handler.
    function environment.ActiveOnUpdateCount()
        local frames = state.frames
        local count = 0
        for index = 1, #frames do
            if frames[index].scripts.OnUpdate ~= nil then
                count = count + 1
            end
        end
        return count
    end

    function environment.FailNextRegisterEvent()
        state.nextRegisterEventResult = false
    end

    function environment.FailNextRegisterUnitEvent()
        state.nextRegisterUnitEventResult = false
    end

    ---Make the next `Frame:SetScript` raise `value`.
    function environment.FailNextSetScript(value)
        state.failNextSetScript = value
    end

    ---Run one script of `frame` the way the client fires it for user input,
    ---and return what the handler returns. A frame without that script does
    ---nothing and returns nothing.
    ---@param frame table
    ---@param scriptName string
    ---@param ... any the script's arguments after the frame
    ---@return any
    function environment.RunScript(frame, scriptName, ...)
        local handler = frame.scripts[scriptName]
        if handler == nil then
            return nil
        end
        return handler(frame, ...)
    end

    ---Move `frame` the way the client leaves a frame after the user dragged
    ---it: one `BOTTOMLEFT` anchor to its parent, so that its bottom-left
    ---corner sits at (`left`, `bottom`) in screen coordinates.
    ---@param frame table
    ---@param left number
    ---@param bottom number
    function environment.MoveFrame(frame, left, bottom)
        local parent = frame.parentFrame
        local parentLeft, parentBottom = 0, 0
        if parent ~= nil then
            local resolvedLeft, resolvedBottom = resolveRect(parent, 0)
            if resolvedLeft ~= nil then
                parentLeft, parentBottom = resolvedLeft, resolvedBottom
            end
        end
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", left - parentLeft, bottom - parentBottom)
    end

    ---Start recording every `SetPoint` call from now until `Reset`, and return
    ---the log: one `{ region, point, relativeTo, relativePoint, x, y }` row per
    ---call, in call order. Recording allocates, so allocation guards run
    ---without it; `GetPoint` reads the current anchors at no cost.
    ---@return table[] log
    function environment.RecordAnchorCalls()
        local log = {}
        state.anchorLog = log
        return log
    end
end

return FrameStub

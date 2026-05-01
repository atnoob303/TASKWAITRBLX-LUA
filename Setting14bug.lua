-- ============================================================
--  SliderModule  |  ModuleScript
--
--  3 cách gọi:
--    SliderModule.Slider(config)        ← thanh trượt thuần
--    SliderModule.SliderButton(config)  ← thanh trượt + nút bấm
--    SliderModule.New(config)           ← truyền type = "Slider" | "SliderButton"
--
--  Config chung:
--    template  (Frame)     : template frame
--    parent    (Frame)     : frame cha
--    title     (string)    : tên hiển thị
--    min       (number)    : giá trị nhỏ nhất
--    max       (number)    : giá trị lớn nhất
--    step      (number)    : bước nhảy (độc lập với parts)
--    default   (number)    : giá trị mặc định
--    onChange  (function)  : callback(value, info) — info chứa timestamp + title
--
--  Config thêm cho SliderButton:
--    parts     (number)    : số nút chia đều (default 5)
--
--  Config thêm cho .New:
--    type      (string)    : "Slider" | "SliderButton"
--
--  onChange nhận 2 tham số:
--    value  (number)  : giá trị hiện tại
--    info   (table)   : { title, timestamp }
--      info.title     : tên setting
--      info.timestamp : "Last Setting at 7:31PM || 13/06/2025 || SETTING TITLE"
--
--  Ví dụ:
--    onChange = function(value, info)
--        print(value)           -- 1.5
--        print(info.timestamp)  -- Last Setting at 7:31PM || 13/06/2025 || SCALE CHAT
--        print(info.title)      -- SCALE CHAT
--    end
--
--  ButtonDelta:
--    Frame con tên "ButtonDelta" trong template
--    Hover → tween BackgroundTransparency về 0.75
--    Leave → tween về giá trị gốc
-- ============================================================

local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")

local SliderModule = {}
SliderModule.__index = SliderModule

-- ════════════════════════════════════════════════════════════
--  HELPERS
-- ════════════════════════════════════════════════════════════

local function fmt(value, step)
	local str
	if step < 0.01 then
		str = string.format("%.3f", value)
	elseif step < 0.1 then
		str = string.format("%.2f", value)
	elseif step < 1 then
		str = string.format("%.1f", value)
	else
		return tostring(math.floor(value + 0.5))
	end
	str = str:gsub("%.?0+$", "")
	return str
end

local function snap(raw, min, max, step)
	local snapped = math.floor((raw - min) / step + 0.5) * step + min
	return math.clamp(snapped, min, max)
end

local function toRatio(value, min, max)
	if max == min then return 0 end
	return math.clamp((value - min) / (max - min), 0, 1)
end

-- ── Tạo timestamp "Last Setting at 7:31PM || 13/06/2025 || TITLE" ──
local function makeTimestamp(title)
	local t = os.date("*t")
	local hour   = t.hour
	local min    = t.min
	local ampm   = hour >= 12 and "PM" or "AM"
	hour = hour % 12
	if hour == 0 then hour = 12 end
	local timeStr = string.format("%d:%02d%s", hour, min, ampm)
	local dateStr = string.format("%02d/%02d/%d", t.day, t.month, t.year)
	return string.format("Last Setting at %s || %s || %s", timeStr, dateStr, title)
end

-- ── Setup ButtonDelta hover effect ──────────────────────────
local function setupButtonDelta(frame)
	local btn = frame:FindFirstChild("ButtonDelta")
	if not btn then return end

	local originalTrans = btn.BackgroundTransparency

	btn.MouseEnter:Connect(function()
		TweenService:Create(btn.Parent,
			TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0.9 }
		):Play()
	end)

	btn.MouseLeave:Connect(function()
		TweenService:Create(btn.Parent,
			TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = originalTrans }
		):Play()
	end)

	-- Touch support
	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			TweenService:Create(btn,
				TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 0.75 }
			):Play()
		end
	end)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			TweenService:Create(btn,
				TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = originalTrans }
			):Play()
		end
	end)
end

-- ════════════════════════════════════════════════════════════
--  REGISTRY: Lưu tất cả slider đã tạo
-- ════════════════════════════════════════════════════════════

-- Table chứa tất cả instance đã clone
-- Key = frame (clone), Value = slider instance
local createdSliders = {}

-- Truy cập từ ngoài: SliderModule.createdSliders
SliderModule.createdSliders = createdSliders


-- ════════════════════════════════════════════════════════════
--  MODULE FUNCTION: setFrameCorners
--  Set CornerRadius cho UICorner có Attribute "C" trong 1 frame bất kỳ
--  Có thể exclude 1 số frame con nhất định
--
--  Tham số:
--    frame        : Frame bất kỳ (không cần là slider)
--    cornerRadius : number (pixel) hoặc UDim
--    exclude      : table tên frame muốn bỏ qua (optional)
--
--  Cách dùng:
--    -- Không exclude:
--    SliderModule.setFrameCorners(someFrame, 8)
--
--    -- Exclude 1 số frame:
--    SliderModule.setFrameCorners(someFrame, 8, {"SliderButton", "FillFrame"})
-- ════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════
--  OPEN REGISTRY  —  theo dõi frame nào đang mở toàn cục
-- ════════════════════════════════════════════════════════════
local openRegistry = {}  -- { [inst] = true }

-- ════════════════════════════════════════════════════════════
--  KEYBROAD REGISTRY  —  cache keyData theo advanceFrame
--  Tránh double-init khi nhiều instance dùng chung 1 advanceFrame
-- ════════════════════════════════════════════════════════════
local KeyBroadRegistry = {}  -- { [advanceFrame] = sharedBroad }

local function registerOpen(inst)
	-- Đóng tất cả inst khác đang mở
	for other in pairs(openRegistry) do
		if other ~= inst then
			other:_closeListExternal()
			openRegistry[other] = nil
		end
	end
	openRegistry[inst] = true
end

local function registerClose(inst)
	openRegistry[inst] = nil
end

function SliderModule.setFrameCorners(frame, cornerRadius, exclude)
	assert(frame, "[SliderModule.setFrameCorners] Thiếu 'frame'")

	local udim = (type(cornerRadius) == "number")
		and UDim.new(0, cornerRadius)
		or  cornerRadius

	-- Build exclude set để lookup O(1)
	local excludeSet = {}
	if exclude then
		for _, name in ipairs(exclude) do
			excludeSet[name] = true
		end
	end

	-- Kiểm tra obj có nằm bên trong frame bị exclude không (kể cả nested)
	local function isInsideExcluded(obj)
		local current = obj.Parent
		while current and current ~= frame do
			if excludeSet[current.Name] then
				return true
			end
			current = current.Parent
		end
		return false
	end

	for _, obj in ipairs(frame:GetDescendants()) do
		if obj:IsA("UICorner") and obj:GetAttribute("C") ~= nil then
			-- Bỏ qua nếu chính frame cha bị exclude hoặc nằm bên trong frame bị exclude
			if not excludeSet[obj.Parent and obj.Parent.Name or ""]
				and not isInsideExcluded(obj) then
				obj.CornerRadius = udim
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════
--  KEY REGISTRY  —  theo dõi tất cả Key instance + waiting
-- ════════════════════════════════════════════════════════════

-- { [inst] = Enum.KeyCode }  — lưu keyCode hiện tại của mọi Key instance
local keyRegistry = {}

-- inst đang ở trạng thái waiting (chỉ 1 tại 1 thời điểm)
local keyWaitingInst = nil

-- Đăng ký / cập nhật keyCode của 1 inst vào registry
local function keyReg_set(inst, keyCode)
	keyRegistry[inst] = keyCode
end

-- Xóa inst khỏi registry (khi destroy)
local function keyReg_remove(inst)
	keyRegistry[inst] = nil
	if keyWaitingInst == inst then
		keyWaitingInst = nil
	end
end

-- Kiểm tra keyCode đã được dùng bởi inst khác chưa
local function keyReg_isDuplicate(inst, keyCode)
	for other, kc in pairs(keyRegistry) do
		if other ~= inst and kc == keyCode then
			return true
		end
	end
	return false
end

-- Vào waiting: cancel inst khác đang waiting (nếu có)
local function keyReg_enterWaiting(inst)
	if keyWaitingInst and keyWaitingInst ~= inst then
		keyWaitingInst:_cancelWaiting()
	end
	keyWaitingInst = inst
end

-- Thoát waiting
local function keyReg_exitWaiting(inst)
	if keyWaitingInst == inst then
		keyWaitingInst = nil
	end
end

-- ════════════════════════════════════════════════════════════
--  MODULE FUNCTION: setCorners
--  Set CornerRadius cho tất cả UICorner có Attribute "C"
--
--  Tham số:
--    target       : slider instance, "all", hoặc table { slider1, slider2, ... }
--    cornerRadius : number (pixel) hoặc UDim
--
--  Cách dùng:
--    -- 1 slider cụ thể:
--    SliderModule.setCorners(SCALECHAT, 8)
--
--    -- Nhiều slider:
--    SliderModule.setCorners({SCALECHAT, TEXTSTRING}, 8)
--
--    -- Tất cả slider đã tạo:
--    SliderModule.setCorners("all", 8)
--
--  Trong Studio: chọn UICorner → Attributes → thêm "C" (type bất kỳ)
-- ════════════════════════════════════════════════════════════

function SliderModule.setCorners(target, cornerRadius, options)
	-- Chuẩn hoá cornerRadius → UDim
	local udim = (type(cornerRadius) == "number")
		and UDim.new(0, cornerRadius)
		or  cornerRadius

	-- Danh sách frame cần bỏ qua (tên)
	local excludeSet = {}
	if options and options.exclude then
		for _, name in ipairs(options.exclude) do
			excludeSet[name] = true
		end
	end

	-- Hàm apply cho 1 slider instance
	local function applyToSlider(inst)
		if not (inst and inst.Frame) then return end
		for _, obj in ipairs(inst.Frame:GetDescendants()) do
			if obj:IsA("UICorner") and obj:GetAttribute("C") ~= nil then
				-- Bỏ qua nếu frame cha nằm trong exclude
				local parentName = obj.Parent and obj.Parent.Name or ""
				if not excludeSet[parentName] then
					obj.CornerRadius = udim
				end
			end
		end
	end

	if target == "all" then
		for _, inst in pairs(createdSliders) do
			applyToSlider(inst)
		end
	elseif type(target) == "table" and target.Frame == nil then
		for _, inst in ipairs(target) do
			applyToSlider(inst)
		end
	else
		applyToSlider(target)
	end
end

-- ════════════════════════════════════════════════════════════
--  INTERNAL: Drag system (dùng chung)
-- ════════════════════════════════════════════════════════════
local function setupDrag(self, Track, Thumb, applyUI, valueFromInput)
	table.insert(self._conns, RunService.RenderStepped:Connect(function()
		if not self._dragging then return end
		applyUI(valueFromInput(UserInputService:GetMouseLocation().X), true)
	end))
	table.insert(self._conns, Track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self._dragging = true
			applyUI(valueFromInput(input.Position.X), true)
		end
	end))
	table.insert(self._conns, Thumb.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self._dragging = true
		end
	end))
	table.insert(self._conns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self._dragging = false
		end
	end))
	table.insert(self._conns, Track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			self._dragging = true
			applyUI(valueFromInput(input.Position.X), true)
		end
	end))
	table.insert(self._conns, Track.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and self._dragging then
			applyUI(valueFromInput(input.Position.X), true)
		end
	end))
	table.insert(self._conns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			self._dragging = false
		end
	end))
end

-- ════════════════════════════════════════════════════════════
--  INTERNAL: TextBox (dùng chung)
-- ════════════════════════════════════════════════════════════
local function setupTextBox(self, ValueBox, applyUI, min, max, step)
	if not ValueBox then return end
	table.insert(self._conns, ValueBox.FocusLost:Connect(function()
		local num = tonumber(ValueBox.Text)
		if num then
			applyUI(snap(num, min, max, step), true)
		else
			ValueBox.Text = fmt(self._value, step)
		end
	end))
end

-- ════════════════════════════════════════════════════════════
--  1) SliderModule.Slider  |  Thanh trượt thuần
-- ════════════════════════════════════════════════════════════
function SliderModule.Slider(config)
	assert(config.parent, "[SliderModule.Slider] Thiếu 'parent'")

	-- Template fallback: tự tìm trong script nếu không truyền
	local template = config.template
		or (script:FindFirstChild("SliderTemplate"))
	assert(template, "[SliderModule.Slider] Không tìm thấy template — truyền vào hoặc đặt 'SliderTemplate' trong ModuleScript")

	local min     = config.min  or 0
	local max     = config.max  or 1
	local step    = config.step or (max - min) / 100
	local title   = config.title or "Slider"
	local default = snap(config.default or min, min, max, step)

	local frame = template:Clone()
	frame.Name    = "Setting_" .. title
	frame.Visible = true
	frame.Parent  = config.parent

	local Track      = frame:FindFirstChild("SliderFrame")
	local Thumb      = Track and Track:FindFirstChild("SliderButton")
	local FillFrame  = frame.FillCurrentBar:FindFirstChild("FillFrame")
	local ValueBox   = frame.ValueBar:FindFirstChild("ValueChange")
	local TitleLabel = frame.InfoFrame:FindFirstChild("NameSetting")
	local RangeLabel = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")

	assert(Track, "[SliderModule.Slider] Thiếu 'SliderFrame'")
	assert(Thumb, "[SliderModule.Slider] Thiếu 'SliderButton'")

	if TitleLabel then TitleLabel.Text = title end

	-- Setup ButtonDelta
	setupButtonDelta(frame)

	local self = setmetatable({
		Frame     = frame,
		Track     = Track,
		Thumb     = Thumb,
		_fill     = FillFrame,
		_fillBar  = nil,
		ValueBox  = ValueBox,
		_min      = min,
		_max      = max,
		_step     = step,
		_title    = title,
		_tag      = config.tag,  -- tag tùy chỉnh gửi kèm onChange
		_value    = default,
		_onChange = config.onChange,
		_dragging = false,
		_conns    = {},
		_buttons  = nil,
		_parts    = nil,
	}, SliderModule)

	local function applyUI(value, fireEvent)
		self._value = value
		local ratio = toRatio(value, min, max)
		local tp    = Thumb.Position
		Thumb.Position = UDim2.new(ratio, tp.X.Offset, tp.Y.Scale, tp.Y.Offset)
		if FillFrame  then FillFrame.BackgroundTransparency = 1 - ratio end
		if ValueBox   then ValueBox.Text = fmt(value, step) end
		if RangeLabel then
			RangeLabel.Text = "MIN: " .. fmt(min, step)
				.. " || MAX: " .. fmt(max, step)
				.. " || CURRENT: " .. fmt(value, step)
		end
		if fireEvent and self._onChange then
			self._onChange(value, {
				title     = title,
				timestamp = makeTimestamp(title),
			}, self._tag)
		end
	end

	local function valueFromInput(inputX)
		local absX = Track.AbsolutePosition.X
		local absW = Track.AbsoluteSize.X
		if absW <= 0 then return self._value end
		return snap(min + math.clamp((inputX - absX) / absW, 0, 1) * (max - min), min, max, step)
	end

	applyUI(default, false)
	setupDrag(self, Track, Thumb, applyUI, valueFromInput)
	setupTextBox(self, ValueBox, applyUI, min, max, step)

	-- Đăng ký vào registry
	createdSliders[frame] = self

	return self
end

-- ════════════════════════════════════════════════════════════
--  2) SliderModule.SliderButton  |  Thanh trượt + nút bấm
-- ════════════════════════════════════════════════════════════
function SliderModule.SliderButton(config)
	assert(config.parent, "[SliderModule.SliderButton] Thiếu 'parent'")

	-- Template fallback: tự tìm trong script nếu không truyền
	local template = config.template
		or (script:FindFirstChild("SliderButtonTemplate"))
	assert(template, "[SliderModule.SliderButton] Không tìm thấy template — truyền vào hoặc đặt 'SliderButtonTemplate' trong ModuleScript")

	local min     = config.min    or 0
	local max     = config.max    or 1
	local parts   = config.parts  or 5
	local step    = config.step   or (max - min) / 100
	local title   = config.title  or "SliderButton"
	local default = snap(config.default or min, min, max, step)

	local frame = template:Clone()
	frame.Name    = "Setting_" .. title
	frame.Visible = true
	frame.Parent  = config.parent

	local Track       = frame:FindFirstChild("SliderFrame")
	local Thumb       = Track and Track:FindFirstChild("SliderButton")
	local FillBar     = frame.SelectFrame:FindFirstChild("FillFrame")
	local ButtonFrame = frame.SelectFrame:FindFirstChild("SelectButtonFrame")
	local ButtonTpl   = ButtonFrame and ButtonFrame.UIListLayout:FindFirstChild("SClickButtonClone")
	local ValueBox    = frame.ValueBar:FindFirstChild("ValueChange")
	local TitleLabel  = frame.InfoFrame:FindFirstChild("NameSetting")
	local RangeLabel  = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")

	assert(Track,       "[SliderModule.SliderButton] Thiếu 'SliderFrame'")
	assert(Thumb,       "[SliderModule.SliderButton] Thiếu 'SliderButton'")
	assert(ButtonFrame, "[SliderModule.SliderButton] Thiếu 'SelectButtonFrame'")
	assert(ButtonTpl,   "[SliderModule.SliderButton] Thiếu 'SClickButtonClone'")

	ButtonTpl.Visible = false
	if TitleLabel then TitleLabel.Text = title end

	-- Setup ButtonDelta
	setupButtonDelta(frame)

	-- Clone nút theo parts
	local buttons = {}
	for i = 1, parts do
		local btn = ButtonTpl:Clone()
		btn.Name        = "Btn_" .. i
		btn.Size        = UDim2.new(1 / parts, 0, 1, 0)
		btn.LayoutOrder = i
		btn.Visible     = true
		btn.Parent      = ButtonFrame
		buttons[i]      = btn
	end

	local self = setmetatable({
		Frame      = frame,
		Track      = Track,
		Thumb      = Thumb,
		_fill      = nil,
		_fillBar   = FillBar,
		ValueBox   = ValueBox,
		_min       = min,
		_max       = max,
		_step      = step,
		_title     = title,
		_tag       = config.tag,  -- tag tùy chỉnh gửi kèm onChange
		_value     = default,
		_onChange  = config.onChange,
		_dragging  = false,
		_conns     = {},
		_buttons   = buttons,
		_parts     = parts,
		_fillTween = nil,
	}, SliderModule)

	local function tweenFill(ratio)
		if not FillBar then return end
		if self._fillTween then self._fillTween:Cancel() end
		self._fillTween = TweenService:Create(
			FillBar,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.new(ratio, 0, FillBar.Size.Y.Scale, FillBar.Size.Y.Offset) }
		)
		self._fillTween:Play()
	end

	local function updateButtons(value)
		for i, btn in ipairs(buttons) do
			local threshold = min + (i / parts) * (max - min)
			btn.BackgroundTransparency = (value >= threshold - 1e-9) and 0.5 or 1
		end
	end

	local function applyUI(value, fireEvent)
		self._value = value
		local ratio = toRatio(value, min, max)
		local tp    = Thumb.Position
		Thumb.Position = UDim2.new(ratio, tp.X.Offset, tp.Y.Scale, tp.Y.Offset)
		tweenFill(ratio)
		updateButtons(value)
		if ValueBox   then ValueBox.Text = fmt(value, step) end
		if RangeLabel then
			RangeLabel.Text = "MIN: " .. fmt(min, step)
				.. " || MAX: " .. fmt(max, step)
				.. " || CURRENT: " .. fmt(value, step)
		end
		if fireEvent and self._onChange then
			self._onChange(value, {
				title     = title,
				timestamp = makeTimestamp(title),
			}, self._tag)
		end
	end

	local function valueFromInput(inputX)
		local absX = Track.AbsolutePosition.X
		local absW = Track.AbsoluteSize.X
		if absW <= 0 then return self._value end
		return snap(min + math.clamp((inputX - absX) / absW, 0, 1) * (max - min), min, max, step)
	end

	for i, btn in ipairs(buttons) do
		local btnValue = snap(min + (i / parts) * (max - min), min, max, step)
		table.insert(self._conns, btn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				applyUI(btnValue, true)
			end
		end))
	end

	applyUI(default, false)
	setupDrag(self, Track, Thumb, applyUI, valueFromInput)
	setupTextBox(self, ValueBox, applyUI, min, max, step)

	-- Đăng ký vào registry
	createdSliders[frame] = self

	return self
end

-- ════════════════════════════════════════════════════════════
--  4) SliderModule.Enabled  |  Toggle bật/tắt
--
--  Cấu trúc template:
--    EnabledTemplate (Frame)
--    └── InfoFrame
--        ├── NameSetting (TextLabel)
--        │   └── InfoSetting (TextLabel)  ← "CURRENT: OK" / "CURRENT: NOT OK"
--        ├── EnabledButton (Frame)        ← bấm để toggle
--        │   └── SlideFrame (Frame)       ← tween AnchorPoint+Position X
--        └── ButtonDelta (Frame)          ← hover effect
--
--  Config:
--    template  (Frame)    : EnabledTemplate
--    parent    (Frame)    : frame cha
--    title     (string)   : tên hiển thị
--    default   (bool/nil) : true=bật, false=tắt, nil=locked(không chỉnh được)
--    truefalse (table)    : {"chữ khi true", "chữ khi false"} — default {"Enabled","Disabled"}
--    onChange  (function) : callback(value, info, tag) — value là true/false/nil
--    tag       (string)   : tag gửi kèm onChange
-- ════════════════════════════════════════════════════════════

function SliderModule.Enabled(config)
	assert(config.parent, "[SliderModule.Enabled] Thiếu 'parent'")

	local template = config.template
		or (script:FindFirstChild("EnabledTemplate"))
	assert(template, "[SliderModule.Enabled] Không tìm thấy template")

	local title     = config.title    or "Enabled"
	local default   = config.default  -- true / false / nil
	local labels    = config.truefalse or {"Enabled", "Disabled"}
	local trueLabel  = labels[1]
	local falseLabel = labels[2]

	local frame = template:Clone()
	frame.Name    = "Setting_" .. title
	frame.Visible = true
	frame.Parent  = config.parent

	local InfoFrame     = frame:FindFirstChild("InfoFrame")
	local TitleLabel    = InfoFrame and InfoFrame:FindFirstChild("NameSetting")
	local RangeLabel    = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")
	local EnabledButton = InfoFrame and InfoFrame:FindFirstChild("EnabledButton")
	local SlideFrame    = EnabledButton and EnabledButton:FindFirstChild("SlideFrame")

	assert(InfoFrame,     "[SliderModule.Enabled] Thiếu 'InfoFrame'")
	assert(EnabledButton, "[SliderModule.Enabled] Thiếu 'EnabledButton'")
	assert(SlideFrame,    "[SliderModule.Enabled] Thiếu 'SlideFrame'")

	if TitleLabel then TitleLabel.Text = title end

	-- Đảm bảo EnabledButton có thể bấm được
	EnabledButton.Active = true
	EnabledButton.ZIndex = EnabledButton.ZIndex + 10
	SlideFrame.ZIndex    = SlideFrame.ZIndex + 10
	SlideFrame.Active    = false

	-- Icon nằm trong SlideFrame
	local Icon    = SlideFrame:FindFirstChild("Icon")
	local hasIcon = Icon ~= nil

	-- Setup ButtonDelta
	setupButtonDelta(frame)

	-- ── Convert id sang rbxassetid:// (hỗ trợ Decal id số) ──
	local function toAssetId(id)
		if id == nil then return nil end
		if type(id) == "number" then
			return "rbxassetid://" .. tostring(id)
		end
		-- Nếu chỉ là số dạng string
		if tostring(id):match("^%d+$") then
			return "rbxassetid://" .. tostring(id)
		end
		return tostring(id)
	end

	-- ── Icon ids ─────────────────────────────────────────────
	local icons = config.icons or {}
	local rawIconTrue  = icons.iconTrue  or icons.iconFalse or icons.iconNil
	local rawIconFalse = icons.iconFalse or icons.iconTrue  or icons.iconNil
	local rawIconNil   = icons.iconNil   or icons.iconTrue  or icons.iconFalse

	local ICON_TRUE  = toAssetId(rawIconTrue)
	local ICON_FALSE = toAssetId(rawIconFalse)
	local ICON_NIL   = toAssetId(rawIconNil)

	-- ── Màu sắc tùy chỉnh (config.colors) hoặc default ──────
	local colors = config.colors or {}

	-- Màu button luôn có tác dụng
	local COLOR_TRUE_BUTTON  = colors.trueButton  or Color3.fromRGB(100, 220, 100)
	local COLOR_FALSE_BUTTON = colors.falseButton or Color3.fromRGB(220, 80,  80 )
	local COLOR_NIL_BUTTON   = colors.nilButton   or Color3.fromRGB(200, 200, 200)

	-- Màu slide + icon chỉ có tác dụng khi có Icon
	local COLOR_TRUE_SLIDE  = hasIcon and (colors.trueSlide  or Color3.fromRGB(0,   0,   0  )) or nil
	local COLOR_TRUE_ICON   = hasIcon and (colors.trueIcon   or Color3.fromRGB(255, 255, 255)) or nil
	local COLOR_FALSE_SLIDE = hasIcon and (colors.falseSlide or Color3.fromRGB(255, 255, 255)) or nil
	local COLOR_FALSE_ICON  = hasIcon and (colors.falseIcon  or Color3.fromRGB(0,   0,   0  )) or nil
	local COLOR_NIL_SLIDE   = hasIcon and (colors.nilSlide   or Color3.fromRGB(150, 150, 150)) or nil
	local COLOR_NIL_ICON    = hasIcon and (colors.nilIcon    or Color3.fromRGB(100, 100, 100)) or nil

	local self = setmetatable({
		Frame     = frame,
		_title    = title,
		_tag      = config.tag,
		_value    = default,
		_onChange = config.onChange,
		_conns    = {},
		_locked   = (default == nil),
		_labels   = labels,
		_slideTween = nil,
	}, SliderModule)

	-- Tween SlideFrame sang true/false
	local function tweenSlide(state)
		if self._slideTween then self._slideTween:Cancel() end

		local targetAnchor, targetPos
		local targetButtonColor, targetSlideColor, targetIconColor, targetIconId

		if state == nil then
			targetAnchor      = Vector2.new(0.5, 0.5)
			targetPos         = UDim2.new(0.5, 0, 0.5, 0)
			targetButtonColor = COLOR_NIL_BUTTON
			targetSlideColor  = COLOR_NIL_SLIDE
			targetIconColor   = COLOR_NIL_ICON
			targetIconId      = ICON_NIL
		elseif state == true then
			targetAnchor      = Vector2.new(1, 0.5)
			targetPos         = UDim2.new(1, 0, 0.5, 0)
			targetButtonColor = COLOR_TRUE_BUTTON
			targetSlideColor  = COLOR_TRUE_SLIDE
			targetIconColor   = COLOR_TRUE_ICON
			targetIconId      = ICON_TRUE
		else
			targetAnchor      = Vector2.new(0, 0.5)
			targetPos         = UDim2.new(0, 0, 0.5, 0)
			targetButtonColor = COLOR_FALSE_BUTTON
			targetSlideColor  = COLOR_FALSE_SLIDE
			targetIconColor   = COLOR_FALSE_ICON
			targetIconId      = ICON_FALSE
		end

		local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		-- Tween SlideFrame position (không tween màu ở đây, xử lý bên dưới)
		self._slideTween = TweenService:Create(SlideFrame, tweenInfo, {
			Position    = targetPos,
			AnchorPoint = targetAnchor,
		})
		self._slideTween:Play()

		-- Tween EnabledButton màu
		TweenService:Create(EnabledButton, tweenInfo, {
			BackgroundColor3 = targetButtonColor,
		}):Play()

		-- Tween SlideFrame + Icon màu (chỉ khi có Icon)
		if hasIcon then
			if targetSlideColor then
				TweenService:Create(SlideFrame, tweenInfo, {
					BackgroundColor3 = targetSlideColor,
				}):Play()
			end
			if Icon and targetIconColor then
				TweenService:Create(Icon, tweenInfo, {
					ImageColor3 = targetIconColor,
				}):Play()
			end
			-- Đổi hình icon theo state
			if Icon and targetIconId then
				Icon.Image = targetIconId
			end
		end
	end

	-- Cập nhật RangeLabel
	local function updateLabel(state)
		if not RangeLabel then return end
		if state == nil then
			RangeLabel.Text = "CURRENT: LOCKED"
		elseif state == true then
			RangeLabel.Text = "CURRENT: " .. trueLabel
		else
			RangeLabel.Text = "CURRENT: " .. falseLabel
		end
	end

	-- Apply state
	local function applyState(state, fireEvent)
		self._value  = state
		self._locked = (state == nil)
		tweenSlide(state)
		updateLabel(state)
		if fireEvent and self._onChange then
			self._onChange(state, {
				title     = title,
				timestamp = makeTimestamp(title),
			}, self._tag)
		end
	end

	-- Bấm EnabledButton → toggle
	table.insert(self._conns, EnabledButton.MouseButton1Click:Connect(function()
		if self._locked then return end
		applyState(not self._value, true)
	end))

	-- Init
	applyState(default, false)

	-- ── Public API ──────────────────────────────────────────
	function self:setValue(state)
		applyState(state, false)
	end

	function self:getValue()
		return self._value
	end

	function self:setOnChange(fn)
		self._onChange = fn
	end

	function self:setVisible(bool)
		frame.Visible = bool
	end

	function self:destroy()
		for _, conn in ipairs(self._conns) do conn:Disconnect() end
		self._conns = {}
		if self._slideTween then self._slideTween:Cancel() end
		createdSliders[frame] = nil
		if frame.Parent then frame:Destroy() end
	end

	-- Đăng ký vào registry
	createdSliders[frame] = self

	return self
end


-- ============================================================
--  SliderModule.Selected  |  Dán vào SliderModule (trước return)
--
--  Config:
--    wheelFrame (Frame)   : frame cố định ngoài cùng (trong ScreenGui)
--                           chứa sẵn 5 TextLabel tên Label_1..5
--                           và ClipsDescendants = true
--    parent    (Frame)    : frame cha chứa ChonseTemplate
--    template  (Frame)    : ChonseTemplate (clone 1 lần)
--    title     (string)   : tên hiển thị
--    options   (table)    : {"Option A", "Option B", ...}
--    default   (number)   : index mặc định (default 1)
--    onChange  (function) : callback(index, text, info, tag)
--    tag       (any)      : tag gửi kèm onChange
--
--  Cấu trúc ChonseTemplate:
--    ChonseTemplate (Frame)
--    └── InfoFrame
--        ├── NameSetting (TextLabel)
--        │   └── InfoSetting (TextLabel) ← "CURRENT: X || ( N )"
--        ├── ChonseButton (Frame)        ← nhấn giữ để kéo
--        └── ChangeButton (Frame)
--            └── SlotNum (TextBox)       ← nhập số → jump thẳng
--
--  Cấu trúc wheelFrame (frame cố định, đặt trong ScreenGui):
--    WheelFrame (Frame)
--    ├── Chonsel2  (TextLabel)  ← slot l2 (ẩn)
--    ├── Chonsel1  (TextLabel)  ← slot l1
--    ├── Chonse    (TextLabel)  ← slot center
--    ├── Chonser1  (TextLabel)  ← slot r1
--    └── Chonser2  (TextLabel)  ← slot r2 (ẩn)
-- ============================================================

-- ============================================================
--  SliderModule.Selected  |  Dán vào SliderModule (trước return)
--
--  Config:
--    wheelFrame (Frame)   : frame cố định (trong ScreenGui)
--    parent    (Frame)    : frame cha chứa ChonseTemplate
--    template  (Frame)    : ChonseTemplate (clone 1 lần)
--    title     (string)   : tên hiển thị
--    options   (table)    : {"Option A", "Option B", ...}
--    default   (number)   : index mặc định (default 1)
--    onChange  (function) : callback(index, text, info, tag)
--    tag       (any)      : tag gửi kèm onChange
--
--  Cấu trúc ChonseTemplate:
--    ChonseTemplate (Frame)
--    └── InfoFrame
--        ├── NameSetting (TextLabel)
--        │   └── InfoSetting (TextLabel)
--        ├── ChonseButton (Frame)
--        │   ├── ChonseCurrent (TextLabel)
--        │   └── BackgroundFrame (Frame)
--        └── ChangeButton (Frame)
--            └── SlotNum (TextBox)
--
--  Cấu trúc wheelFrame:
--    WheelFrame (Frame)
--    ├── Chonsel2  ← slot l2
--    ├── Chonsel1  ← slot l1
--    ├── Chonse    ← slot center
--    ├── Chonser1  ← slot r1
--    └── Chonser2  ← slot r2
-- ============================================================

-- ════════════════════════════════════════════════════════════
--  WHEEL REGISTRY  —  toàn bộ state bên ngoài, keyed theo wheelFrame
--
--  wheelRegistry[wheelFrame] = {
--    labels     : { [1..5] TextLabel }        ← labels gốc
--    homePos    : { [i] {xScale,xOffset,...} } ← position gốc
--    homeSize   : { [i] {xScale,xOffset,...} } ← size gốc
--    SW_OFFSET  : number
--    SW_SCALE   : number
--    pool       : { {frame,labels,inUse} x2 } ← pre-clone sẵn
--    activeInst : inst | nil                  ← ai đang giữ wheel
--    instState  : { [inst] = iState }         ← state từng instance
--  }
-- ════════════════════════════════════════════════════════════

local SLOT_COUNT  = 5
local LABEL_NAMES = { "Chonsel2", "Chonsel1", "Chonse", "Chonser1", "Chonser2" }
local POOL_SIZE   = 2

-- ════════════════════════════════════════════════════════════
--  CLICK REGISTRY  —  shared state cho clickFrame
--  clickRegistry[clickFrame] = {
--    activeInst : inst | nil   ← ai đang mở list
--  }
-- ════════════════════════════════════════════════════════════
local clickRegistry = {}

local function getClickReg(cf)
	if not clickRegistry[cf] then
		clickRegistry[cf] = { activeInst = nil }
	end
	return clickRegistry[cf]
end
local wheelRegistry = {}

local function getWheelReg(wf)
	if wheelRegistry[wf] then return wheelRegistry[wf] end

	local reg = {
		labels       = {},
		homePos      = {},
		homeSize     = {},
		SW_OFFSET    = 0,
		SW_SCALE     = 0,
		pool         = {},
		activeInst   = nil,
		activeButton = nil,  -- ✅ THÊM DÒNG NÀY
		instState    = {},
	}

	for i = 1, SLOT_COUNT do
		reg.labels[i] = wf:FindFirstChild(LABEL_NAMES[i])
		assert(reg.labels[i],
			"[SliderModule.Selected] Thiếu '" .. LABEL_NAMES[i] .. "' trong wheelFrame")
		local p = reg.labels[i].Position
		local s = reg.labels[i].Size
		reg.homePos[i]  = { xScale=p.X.Scale, xOffset=p.X.Offset, yScale=p.Y.Scale, yOffset=p.Y.Offset }
		reg.homeSize[i] = { xScale=s.X.Scale, xOffset=s.X.Offset, yScale=s.Y.Scale, yOffset=s.Y.Offset }
	end

	reg.SW_OFFSET = reg.homePos[4].xOffset - reg.homePos[3].xOffset
	reg.SW_SCALE  = reg.homePos[4].xScale  - reg.homePos[3].xScale

	for _ = 1, POOL_SIZE do
		local clone = wf:Clone()
		clone.Name    = wf.Name .. "_pool"
		clone.Visible = false
		clone.Parent  = wf.Parent
		local clbls = {}
		for i = 1, SLOT_COUNT do
			clbls[i] = clone:FindFirstChild(LABEL_NAMES[i])
		end
		table.insert(reg.pool, { frame=clone, labels=clbls, inUse=false })
	end

	wheelRegistry[wf] = reg
	return reg
end

-- ── Per-instance state ─────────────────────────────────────
local function newInstState(defaultIndex)
	return {
		currentIndex  = defaultIndex,
		slotState     = {},
		totalOffsetPx = 0,
		isDragging    = false,
		isActive      = false,
		prevMouseX    = 0,
		velocity      = 0,
		velBuffer     = {},
		lastDragTime  = 0,
		physicsConn   = nil,
		snapConn      = nil,
		trackConn     = nil,
		clickTrackConn = nil,
		bgTween       = nil,
		listOpen      = false,
		labelTweens   = {},
		savedPosX     = 0,
		savedPosY     = 0,
		savedSizeX    = 0,
		savedSizeY    = 0,
		conns         = {},
		clickBtnTweens = {},
		clickClosing   = false,
		simpleMode     = false,  -- ✅ THÊM DÒNG NÀY
		_justDragged   = false,  -- ✅ THÊM LUÔN NẾU CHƯA CÓ
	}
end


-- ════════════════════════════════════════════════════════════
--  PURE HELPERS  (không dùng upvalue, nhận reg+iState)
-- ════════════════════════════════════════════════════════════

local function wrapIdx(idx, n) return ((idx-1) % n) + 1 end
local function lerpNum(a, b, t) return a + (b-a)*t end

local function getSlotWidth(reg, iState)
	local sw = reg.SW_OFFSET + reg.SW_SCALE * iState.savedSizeX
	return (sw ~= 0) and math.abs(sw) or (iState.savedSizeX / SLOT_COUNT)
end

local function initSlotState(reg, iState, OPT_COUNT)
	for i = 1, SLOT_COUNT do
		local d = i - 3
		iState.slotState[i] = {
			slotIndex = d,
			optIndex  = wrapIdx(iState.currentIndex + d, OPT_COUNT),
		}
	end
end

local function syncWheelFrame(iState, wheelFrame, ChonseButton)
	if not ChonseButton or not ChonseButton.Parent then return end
	if not wheelFrame   or not wheelFrame.Parent   then return end
	local absPos    = ChonseButton.AbsolutePosition
	local absSize   = ChonseButton.AbsoluteSize
	local parentPos = wheelFrame.Parent.AbsolutePosition
	iState.savedPosX  = absPos.X - parentPos.X
	iState.savedPosY  = absPos.Y - parentPos.Y
	iState.savedSizeX = absSize.X
	iState.savedSizeY = absSize.Y
	wheelFrame.Position = UDim2.new(0, iState.savedPosX,  0, iState.savedPosY)
	wheelFrame.Size     = UDim2.new(0, iState.savedSizeX, 0, iState.savedSizeY)
end

local function tweenLabelTrans(reg, iState, i, target)
	if iState.labelTweens[i] then iState.labelTweens[i]:Cancel() end
	iState.labelTweens[i] = TweenService:Create(
		reg.labels[i],
		TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = target }
	)
	iState.labelTweens[i]:Play()
end

local function render(reg, iState, OPTIONS)
	local sw  = getSlotWidth(reg, iState)
	local hp  = reg.homePos
	local hs  = reg.homeSize
	local sX  = iState.savedSizeX
	local cXp = hp[3].xOffset + hp[3].xScale * sX
	local l1X = hp[2].xOffset + hp[2].xScale * sX
	local r1X = hp[4].xOffset + hp[4].xScale * sX
	local dCL = cXp - l1X
	local dCR = r1X - cXp

	local function si(slot) return math.clamp(slot+3, 1, SLOT_COUNT) end

	for i = 1, SLOT_COUNT do
		local s   = iState.slotState[i]
		local hXp = hp[i].xOffset + hp[i].xScale * sX
		local px  = hXp + (s.slotIndex-(i-3)) * sw + iState.totalOffsetPx

		local fs  = (px-cXp)/sw
		local sA  = math.floor(fs);  local sB = sA+1;  local t = fs-sA
		local hpA, hpB = hp[si(sA)], hp[si(sB)]
		local hsA, hsB = hs[si(sA)], hs[si(sB)]

		reg.labels[i].Position = UDim2.new(
			0, px,
			lerpNum(hpA.yScale, hpB.yScale, t),
			lerpNum(hpA.yOffset,hpB.yOffset,t)
		)
		reg.labels[i].Size = UDim2.new(
			lerpNum(hsA.xScale,  hsB.xScale,  t),
			lerpNum(hsA.xOffset, hsB.xOffset, t),
			lerpNum(hsA.yScale,  hsB.yScale,  t),
			lerpNum(hsA.yOffset, hsB.yOffset, t)
		)
		reg.labels[i].Text = OPTIONS[s.optIndex]

		local dPx = math.abs(px - cXp)
		reg.labels[i].FontFace = Font.new(
			reg.labels[i].FontFace.Family,
			dPx <= 10 and Enum.FontWeight.Bold    or Enum.FontWeight.Regular,
			dPx <= 10 and Enum.FontStyle.Italic   or Enum.FontStyle.Normal
		)

		local trans
		if dPx <= 10 then
			trans = 0
		elseif px <= cXp then
			local past = l1X - px
			if     past >= 20 then trans = 1
			elseif past >= 0  then trans = 0.5 + (past/20)*0.5
			else                   trans = math.clamp((dPx-10)/(dCL-10),0,1)*0.5
			end
		else
			local past = px - r1X
			if     past >= 20 then trans = 1
			elseif past >= 0  then trans = 0.5 + (past/20)*0.5
			else                   trans = math.clamp((dPx-10)/(dCR-10),0,1)*0.5
			end
		end
		tweenLabelTrans(reg, iState, i, math.clamp(trans,0,1))
	end
end

local function recycleLabels(reg, iState, OPT_COUNT)
	local sw = getSlotWidth(reg, iState)
	local sX = iState.savedSizeX
	local hp = reg.homePos
	for i = 1, SLOT_COUNT do
		local s  = iState.slotState[i]
		local px = (hp[i].xOffset+hp[i].xScale*sX) + (s.slotIndex-(i-3))*sw + iState.totalOffsetPx
		if px < -sw then
			local max = -999
			for j=1,SLOT_COUNT do if iState.slotState[j].slotIndex>max then max=iState.slotState[j].slotIndex end end
			s.slotIndex = max+1;  s.optIndex = wrapIdx(iState.currentIndex+s.slotIndex, OPT_COUNT)
		elseif px > sX+sw then
			local min = 999
			for j=1,SLOT_COUNT do if iState.slotState[j].slotIndex<min then min=iState.slotState[j].slotIndex end end
			s.slotIndex = min-1;  s.optIndex = wrapIdx(iState.currentIndex+s.slotIndex, OPT_COUNT)
		end
	end
end

local function updateCenter(reg, iState, OPT_COUNT, onUpdate)
	local sw  = getSlotWidth(reg, iState)
	local sX  = iState.savedSizeX
	local hp  = reg.homePos
	local cXp = hp[3].xOffset + hp[3].xScale*sX
	local min = math.huge
	for i=1,SLOT_COUNT do
		local s  = iState.slotState[i]
		local px = (hp[i].xOffset+hp[i].xScale*sX) + (s.slotIndex-(i-3))*sw + iState.totalOffsetPx
		local d  = math.abs(px-cXp)
		if d < min then min=d; iState.currentIndex=s.optIndex end
	end
	if onUpdate then onUpdate() end
end

local function findSnapTarget(reg, iState)
	local sw  = getSlotWidth(reg, iState)
	local sX  = iState.savedSizeX
	local hp  = reg.homePos
	local cXp = hp[3].xOffset + hp[3].xScale*sX
	local min = math.huge
	local tgt = iState.totalOffsetPx
	for i=1,SLOT_COUNT do
		local s  = iState.slotState[i]
		local px = (hp[i].xOffset+hp[i].xScale*sX) + (s.slotIndex-(i-3))*sw + iState.totalOffsetPx
		local d  = math.abs(px-cXp)
		if d < min then min=d; tgt=iState.totalOffsetPx+(cXp-px) end
	end
	return tgt
end

-- ── Pool helpers ─────────────────────────────────────────────
local function acquireSlot(reg)
	for _,slot in ipairs(reg.pool) do
		if not slot.inUse then slot.inUse=true; return slot end
	end
end

local function releaseSlot(reg, slot)
	slot.frame.Visible = false
	slot.inUse = false
	for i=1,SLOT_COUNT do
		if slot.labels[i] then slot.labels[i].TextTransparency=1 end
	end
end

local function snapshotToPool(reg, iState, wheelFrame)
	if not wheelFrame.Visible then return end
	local slot = acquireSlot(reg)
	if not slot then return end

	slot.frame.Position = wheelFrame.Position
	slot.frame.Size     = wheelFrame.Size
	slot.frame.Visible  = true

	for i=1,SLOT_COUNT do
		local src,dst = reg.labels[i], slot.labels[i]
		if src and dst then
			dst.Text=src.Text; dst.TextTransparency=src.TextTransparency
			dst.Position=src.Position; dst.Size=src.Size; dst.FontFace=src.FontFace
		end
	end

	local done = 0
	for i=1,SLOT_COUNT do
		local dst = slot.labels[i]
		if dst then
			local tw = TweenService:Create(dst,
				TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ TextTransparency=1 }
			)
			tw.Completed:Connect(function()
				done+=1; if done>=SLOT_COUNT then releaseSlot(reg,slot) end
			end)
			tw:Play()
		else
			done+=1; if done>=SLOT_COUNT then releaseSlot(reg,slot) end
		end
	end
end

-- ════════════════════════════════════════════════════════════
--  SliderModule.Selected
-- ════════════════════════════════════════════════════════════
function SliderModule.Selected(config)
	assert(config.parent,     "[SliderModule.Selected] Thiếu 'parent'")
	assert(config.wheelFrame, "[SliderModule.Selected] Thiếu 'wheelFrame'")
	assert(config.options and #config.options >= 2,
		"[SliderModule.Selected] 'options' cần ít nhất 2 phần tử")

	local template = config.template or script:FindFirstChild("ChonseTemplate")
	assert(template, "[SliderModule.Selected] Không tìm thấy ChonseTemplate")

	local OPTIONS      = config.options
	local OPT_COUNT    = #OPTIONS
	local title        = config.title or "Selected"
	local defaultIndex = math.clamp(config.default or 1, 1, OPT_COUNT)

	local FRICTION         = 0.88
	local MIN_VELOCITY     = 0.5
	local MAX_VELOCITY     = 80
	local SPRING_STIFFNESS = 280
	local SPRING_DAMPING   = 18
	local VEL_SAMPLES      = 4

	-- ── Clone template ──────────────────────────────────────
	local settingFrame    = template:Clone()
	settingFrame.Name     = "Setting_" .. title
	settingFrame.Visible  = true
	settingFrame.Parent   = config.parent

	local InfoFrame       = settingFrame:FindFirstChild("InfoFrame")
	local TitleLabel      = InfoFrame  and InfoFrame:FindFirstChild("NameSetting")
	local RangeLabel      = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")
	local ChonseButton    = settingFrame:FindFirstChild("ChonseButton")
	local ChangeButton    = InfoFrame  and InfoFrame:FindFirstChild("ChangeButton")
	local SlotNum         = ChangeButton and ChangeButton:FindFirstChild("SlotNum")
	local ChonseCurrent   = ChonseButton and ChonseButton:FindFirstChild("ChonseCurrent")
	local BackgroundFrame = ChonseButton and ChonseButton:FindFirstChild("BackgroundFrame")

	-- ── SettingOfSetting ─────────────────────────────────────────
	local SettingOfSetting = settingFrame:FindFirstChild("SettingOfSetting")
	local SOS_BG           = SettingOfSetting and SettingOfSetting:FindFirstChild("BackgroundFrame")
	local SOS_Slider       = SettingOfSetting and SettingOfSetting:FindFirstChild("SliderFrame")
	local SOS_Support      = SettingOfSetting and SettingOfSetting:FindFirstChild("SliderSupport")
	local SOS_Context      = SettingOfSetting and SettingOfSetting:FindFirstChild("Context")
	local SOS_Shadow       = SettingOfSetting and SettingOfSetting:FindFirstChild("Shadow")
	local SOS_Gradient     = SOS_Context      and SOS_Context:FindFirstChild("UIGradient")

	--iState.simpleMode = false  -- mặc định tắt



	assert(ChonseButton, "[SliderModule.Selected] Thiếu 'ChonseButton'")
	if TitleLabel then TitleLabel.Text = title end

	setupButtonDelta(settingFrame)

	-- ── Wheel reg + inst state ──────────────────────────────
	local wheelFrame = config.wheelFrame
	wheelFrame.Visible          = false
	wheelFrame.ClipsDescendants = false

	-- ── ChonseFrameClick — khai báo SAU jumpToIndex ──────────
	local clickFrame    = config.clickFrame or script.Parent.Parent.SettingFrame.ChonseFrameClick
	local UIList        = clickFrame and clickFrame:FindFirstChild("UIList")
	local clickTemplate = UIList and UIList:FindFirstChild("CloneClickButton")
	local clickReg = clickFrame and getClickReg(clickFrame)  -- ✅ THÊM DÒNG NÀY

	local reg    = getWheelReg(wheelFrame)
	local iState = newInstState(defaultIndex)
	local inst   -- forward declare

	-- ── UI tween helpers ────────────────────────────────────
	local function tweenBG(target)
		if not BackgroundFrame then return end
		if iState.bgTween then iState.bgTween:Cancel() end
		iState.bgTween = TweenService:Create(BackgroundFrame,
			TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = target }
		)
		iState.bgTween:Play()
	end

	local function tweenCurrent(target)
		if not ChonseCurrent then return end
		TweenService:Create(ChonseCurrent,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextTransparency = target }
		):Play()
	end

	local function updateRangeLabel()
		if RangeLabel then
			RangeLabel.Text = "CURRENT: " .. OPTIONS[iState.currentIndex]
				.. " || ( " .. iState.currentIndex .. " )"
		end
		if ChonseCurrent then
			ChonseCurrent.Text = OPTIONS[iState.currentIndex]
		end
		if SlotNum then SlotNum.Text = tostring(iState.currentIndex) end  -- ✅ THÊM
	end

	local function fireOnChange()
		if config.onChange then
			config.onChange(iState.currentIndex, OPTIONS[iState.currentIndex], {
				title = title, timestamp = makeTimestamp(title),
			}, config.tag)
		end
		if SlotNum then SlotNum.Text = tostring(iState.currentIndex) end
	end

	local function clearClickButtons()
		if not clickFrame then return end
		for _, child in ipairs(clickFrame:GetChildren()) do
			-- Chỉ xóa các button đã clone, giữ lại UIListLayout và template gốc
			if child ~= clickTemplate 
				and not child:IsA("UIListLayout")
				and not child:IsA("UIGridLayout")
				and not child:IsA("UIPageLayout") then
				child:Destroy()
			end
		end
	end


	-- Đóng ngay (dùng khi đổi kênh / forceStop)
	local function closeClickFrameInstant()
		if not clickFrame then return end
		registerClose(inst)  -- ✅

		-- Cancel tất cả tween đang chạy
		for _, tw in pairs(iState.clickBtnTweens) do
			if tw then tw:Cancel() end
		end
		iState.clickBtnTweens = {}
		iState.clickClosing   = false

		clearClickButtons()
		clickFrame.Visible  = false
		iState.listOpen     = false
		if clickReg then clickReg.activeInst = nil end

		if iState.clickTrackConn then
			iState.clickTrackConn:Disconnect()
			iState.clickTrackConn = nil
		end
		if iState.trackConn and not iState.isActive then
			iState.trackConn:Disconnect()
			iState.trackConn = nil
		end
	end


	-- closeClickFrame / openClickFrame / syncClickFrame forward declare
	-- gán thực sau jumpToIndex (vì openClickFrame gọi jumpToIndex)
	local closeClickFrame = function() end
	local openClickFrame  = function() end
	local syncClickFrame  = function() end  -- ← thêm dòng này

	-- ── forceStop ───────────────────────────────────────────
	local function forceStop(usePool)
		if usePool then snapshotToPool(reg, iState, wheelFrame) end

		if clickReg and clickReg.activeInst == inst then
			closeClickFrameInstant()  -- ✅
		end

		iState.isActive = false
		if reg.activeInst == inst then
			reg.activeInst   = nil
			reg.activeButton = nil  -- ✅ THÊM DÒNG NÀY
		end

		if iState.physicsConn then iState.physicsConn:Disconnect(); iState.physicsConn=nil end
		if iState.snapConn    then iState.snapConn:Disconnect();    iState.snapConn=nil    end

		-- ✅ Chỉ disconnect trackConn nếu list cũng không mở
		if iState.trackConn and not iState.listOpen then
			iState.trackConn:Disconnect()
			iState.trackConn = nil
		end

		for i=1,SLOT_COUNT do
			if iState.labelTweens[i] then iState.labelTweens[i]:Cancel(); iState.labelTweens[i]=nil end
			reg.labels[i].TextTransparency = 1
		end
		if iState.bgTween then iState.bgTween:Cancel(); iState.bgTween=nil end

		iState.velocity=0; iState.velBuffer={}; iState.isDragging=false
		wheelFrame.Visible = false
		if ChonseCurrent   then ChonseCurrent.TextTransparency        = 0   end
		if BackgroundFrame then BackgroundFrame.BackgroundTransparency = 0.8 end
	end

	-- ── Tracking: bám AbsolutePosition nút mỗi frame ────────
	-- Chạy suốt khi isActive = true, độc lập với drag/physics/snap
	local function startTracking()
		if iState.trackConn then iState.trackConn:Disconnect() end
		iState.trackConn = RunService.RenderStepped:Connect(function()
			if not iState.isActive then
				iState.trackConn:Disconnect()
				iState.trackConn = nil
				return
			end
			if reg.activeInst == inst then
				syncWheelFrame(iState, wheelFrame, reg.activeButton)
			end
		end)
	end

	-- ── Spring snap ─────────────────────────────────────────
	local function startSpringSnap(initVel, onDone)
		if iState.snapConn then iState.snapConn:Disconnect() end
		local target    = findSnapTarget(reg, iState)
		local springVel = initVel
		local STOP_T    = 0.1

		iState.snapConn = RunService.RenderStepped:Connect(function(dt)
			if not iState.isActive then iState.snapConn:Disconnect(); return end
			dt = math.min(dt, 0.05)
			local disp            = iState.totalOffsetPx - target
			local accel           = (-SPRING_STIFFNESS*disp - SPRING_DAMPING*springVel)*dt
			springVel             = springVel + accel
			iState.totalOffsetPx  = iState.totalOffsetPx + springVel*dt

			updateCenter(reg, iState, OPT_COUNT, updateRangeLabel)
			recycleLabels(reg, iState, OPT_COUNT)
			render(reg, iState, OPTIONS)

			if math.abs(disp)<STOP_T and math.abs(springVel)<STOP_T then
				iState.snapConn:Disconnect()
				iState.totalOffsetPx = target
				updateCenter(reg, iState, OPT_COUNT, updateRangeLabel)
				recycleLabels(reg, iState, OPT_COUNT)
				render(reg, iState, OPTIONS)
				if onDone then onDone() end
			end
		end)
	end

	-- ── Physics ─────────────────────────────────────────────
	local function startPhysics(onDone)
		if iState.physicsConn then iState.physicsConn:Disconnect() end
		iState.physicsConn = RunService.RenderStepped:Connect(function()
			if not iState.isActive then iState.physicsConn:Disconnect(); return end
			iState.velocity      = iState.velocity * FRICTION
			iState.totalOffsetPx = iState.totalOffsetPx + iState.velocity

			local vr = math.clamp(math.abs(iState.velocity)/MAX_VELOCITY,0,1)
			if BackgroundFrame then BackgroundFrame.BackgroundTransparency = 0.8-vr*0.3 end

			updateCenter(reg, iState, OPT_COUNT, updateRangeLabel)
			recycleLabels(reg, iState, OPT_COUNT)
			render(reg, iState, OPTIONS)

			if math.abs(iState.velocity)<MIN_VELOCITY then
				iState.velocity=0; iState.physicsConn:Disconnect()
				startSpringSnap(0, onDone)
			end
		end)
	end

	-- ── Drag ────────────────────────────────────────────────
	local function onDragMove(mouseX)
		local now      = tick()
		local delta    = mouseX - iState.prevMouseX
		local dt       = now - iState.lastDragTime
		local instantV = (dt>0) and math.clamp(delta/dt/60,-MAX_VELOCITY,MAX_VELOCITY) or 0

		table.insert(iState.velBuffer, instantV)
		if #iState.velBuffer>VEL_SAMPLES then table.remove(iState.velBuffer,1) end
		iState.prevMouseX    = mouseX
		iState.lastDragTime  = now
		iState.totalOffsetPx = iState.totalOffsetPx + delta

		if BackgroundFrame then
			BackgroundFrame.BackgroundTransparency = 0.6 - math.clamp(math.abs(instantV)/MAX_VELOCITY,0,1)*0.1
		end
		updateCenter(reg, iState, OPT_COUNT, updateRangeLabel)
		recycleLabels(reg, iState, OPT_COUNT)
		render(reg, iState, OPTIONS)
	end

	local function onDragEnd()
		iState.isDragging = false
		local sum = 0
		for _,v in ipairs(iState.velBuffer) do sum=sum+v end
		iState.velocity  = math.clamp((#iState.velBuffer>0) and (sum/#iState.velBuffer) or 0, -MAX_VELOCITY, MAX_VELOCITY)
		iState.velBuffer = {}

		local function onDone()
			if not iState.isActive then return end
			wheelFrame.Visible = false
			tweenCurrent(0); tweenBG(0.8); fireOnChange()
			closeClickFrame()  -- ✅ THÊM DÒNG NÀY
		end
		if math.abs(iState.velocity)<MIN_VELOCITY then startSpringSnap(0,onDone) else startPhysics(onDone) end
	end

	local function jumpToIndex(idx)
		iState.currentIndex  = wrapIdx(idx, OPT_COUNT)
		iState.totalOffsetPx = 0
		initSlotState(reg, iState, OPT_COUNT)
		updateRangeLabel()
		syncWheelFrame(iState, wheelFrame, ChonseButton)
		render(reg, iState, OPTIONS)
		if SlotNum then SlotNum.Text = tostring(iState.currentIndex) end  -- ✅ THÊM
	end

	local function applySimpleMode(enabled, instant)
		iState.simpleMode = enabled
		local tweenInfo = TweenInfo.new(
			instant and 0 or 0.2,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		)

		if SOS_BG then
			TweenService:Create(SOS_BG, tweenInfo, {
				BackgroundTransparency = enabled and 0.5 or 0.7
			}):Play()
		end

		if SOS_Slider then
			if enabled then
				SOS_Slider.AnchorPoint = Vector2.new(1, 0)
			else
				SOS_Slider.AnchorPoint = Vector2.new(0, 0)
			end
			TweenService:Create(SOS_Slider, tweenInfo, {
				Position               = enabled and UDim2.new(1, 0, 0, 0) or UDim2.new(0, 0, 0, 0),
				BackgroundTransparency = enabled and 1 or 0,
			}):Play()
		end

		if SOS_Support then
			TweenService:Create(SOS_Support, tweenInfo, {
				BackgroundTransparency = enabled and 1 or 0
			}):Play()
		end

		-- ✅ Đổi text Context + Shadow theo chế độ
		local modeText = enabled and "SIMPLE" or "SLIDER"
		if SOS_Context then
			SOS_Context.Text = modeText
		end
		if SOS_Shadow then
			SOS_Shadow.Text = modeText
		end

		-- ✅ Tắt/bật UIGradient trong Context
		if SOS_Gradient then
			SOS_Gradient.Enabled = not enabled
		end

		if enabled then
			if iState.isActive then forceStop(false) end
			closeClickFrameInstant()
		end
	end

	-- Bấm SettingOfSetting để toggle
	if SettingOfSetting then
		SettingOfSetting.MouseButton1Click:Connect(function()
			applySimpleMode(not iState.simpleMode, false)
		end)
	end

	-- Init (instant, không tween)
	applySimpleMode(config.simpleMode == true, true)

	-- Chỉ bám trục Y theo ChonseButton, X giữ nguyên theo design
	syncClickFrame = function()
		if not clickFrame or not clickFrame.Parent   then return end
		if not ChonseButton or not ChonseButton.Parent then return end
		local absPos    = ChonseButton.AbsolutePosition
		local parentPos = clickFrame.Parent.AbsolutePosition
		local curPos    = clickFrame.Position
		clickFrame.Position = UDim2.new(
			curPos.X.Scale, curPos.X.Offset,
			0, absPos.Y - parentPos.Y
		)
	end

	local function startClickTracking()
		if iState.clickTrackConn then return end
		iState.clickTrackConn = RunService.RenderStepped:Connect(function()
			if not iState.listOpen or not clickReg or clickReg.activeInst ~= inst then
				iState.clickTrackConn:Disconnect()
				iState.clickTrackConn = nil
				return
			end
			syncClickFrame()
		end)
	end

	-- Đóng từ từ (tween out) — dùng khi người dùng bấm đóng
	closeClickFrame = function()
		if not clickFrame then return end

		-- Nếu đang tween đóng rồi thì không làm lại
		if iState.clickClosing then return end

		-- Thu thập buttons hiện tại
		local buttons = {}
		for _, child in ipairs(clickFrame:GetChildren()) do
			if child ~= clickTemplate
				and not child:IsA("UIListLayout")
				and not child:IsA("UIGridLayout")
				and not child:IsA("UIPageLayout") then
				table.insert(buttons, child)
			end
		end

		table.sort(buttons, function(a, b)
			return (a.LayoutOrder or 0) < (b.LayoutOrder or 0)
		end)

		local STAGGER  = 0.03
		local DURATION = 0.14
		local total    = #buttons

		-- Reset state ngay để logic khác không bị block
		iState.listOpen     = false
		iState.clickClosing = true
		if clickReg then clickReg.activeInst = nil end

		if iState.clickTrackConn then
			iState.clickTrackConn:Disconnect()
			iState.clickTrackConn = nil
		end
		if iState.trackConn and not iState.isActive then
			iState.trackConn:Disconnect()
			iState.trackConn = nil
		end

		-- Cancel tất cả tween open đang chạy
		for _, tw in pairs(iState.clickBtnTweens) do
			if tw then tw:Cancel() end
		end
		iState.clickBtnTweens = {}

		if total == 0 then
			clickFrame.Visible  = false
			iState.clickClosing = false
			return
		end

		local function findLabel(root, name)
			return root:FindFirstChild(name) or root:FindFirstChild(name, true)
		end

		local tweenInfo = TweenInfo.new(DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

		for idx, btn in ipairs(buttons) do
			btn:SetAttribute("_closing", true)  -- ✅ tắt hover ngay lập tức
			local delay = (idx - 1) * STAGGER
			task.delay(delay, function()
				if not btn or not btn.Parent then return end

				local infoFrame = btn:FindFirstChild("InfoFrame")
				local nameLabel = findLabel(btn, "NameChonse")
				local numLabel  = findLabel(btn, "NumSlot")
				local iconLabel = findLabel(btn, "Icon")

				if infoFrame then
					local tw = TweenService:Create(infoFrame, tweenInfo, {
						Position               = UDim2.new(0.2, 0, 0.5, 0),
						BackgroundTransparency = 1,
					})
					iState.clickBtnTweens[btn] = tw
					tw:Play()
				end
				if nameLabel and nameLabel:IsA("TextLabel") then
					TweenService:Create(nameLabel, tweenInfo, { TextTransparency = 1 }):Play()
				end
				if numLabel and numLabel:IsA("TextLabel") then
					TweenService:Create(numLabel, tweenInfo, { TextTransparency = 1 }):Play()
				end
				if iconLabel and iconLabel:IsA("ImageLabel") then
					TweenService:Create(iconLabel, tweenInfo, { ImageTransparency = 1 }):Play()
				end

				if idx == total then
					task.delay(DURATION + 0.05, function()
						iState.clickClosing   = false
						iState.clickBtnTweens = {}
						clickFrame.Visible    = false
						for _, b in ipairs(buttons) do
							if b and b.Parent then b:Destroy() end
						end
					end)
				end
			end)
		end
	end

	openClickFrame = function()
		if not clickFrame  then warn("[Selected] clickFrame is nil") return end
		if not UIList      then warn("[Selected] UIList not found")  return end
		if not clickTemplate then warn("[Selected] CloneClickButton not found") return end

		registerOpen(inst)  -- ✅ tự đóng tất cả cái khác

		if clickReg and clickReg.activeInst and clickReg.activeInst ~= inst then
			clickReg.activeInst:_closeListExternal()
		end

		clearClickButtons()
		clickTemplate.Visible = false

		local function findLabel(root, name)
			return root:FindFirstChild(name) or root:FindFirstChild(name, true)
		end

		local isButton = clickTemplate:IsA("ImageButton") or clickTemplate:IsA("TextButton")
		local STAGGER  = 0.04  -- giây giữa mỗi slot
		local DURATION = 0.18

		for i = 1, OPT_COUNT do
			local btn = clickTemplate:Clone()
			btn.Name        = "ClickBtn_" .. i
			btn.LayoutOrder = i
			btn.Visible     = true
			btn.Parent      = clickFrame

			local infoFrame = btn:FindFirstChild("InfoFrame")
			local nameLabel = findLabel(btn, "NameChonse")
			local numLabel  = findLabel(btn, "NumSlot")
			local iconLabel = findLabel(btn, "Icon")

			if nameLabel then nameLabel.Text = OPTIONS[i] end
			if numLabel  then numLabel.Text  = tostring(i) end

			-- Set trạng thái ban đầu (ẩn)
			if infoFrame then
				infoFrame.Position              = UDim2.new(0.2, 0, 0.5, 0)
				infoFrame.BackgroundTransparency = 1
			end
			if nameLabel and nameLabel:IsA("TextLabel") then nameLabel.TextTransparency  = 1 end
			if numLabel  and numLabel:IsA("TextLabel")  then numLabel.TextTransparency   = 1 end
			if iconLabel and iconLabel:IsA("ImageLabel") then iconLabel.ImageTransparency = 1 end

			-- Highlight
			if i == iState.currentIndex then
				if isButton then btn.ImageTransparency = 0.5
				else             btn.BackgroundTransparency = 0.6 end
			end

			-- Tween vào với stagger
			local delay = (i - 1) * STAGGER
			local tweenInfo = TweenInfo.new(DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

			task.delay(delay, function()
				if not btn or not btn.Parent then return end

				if infoFrame then
					TweenService:Create(infoFrame, tweenInfo,
						{ Position = UDim2.new(0.5, 0, 0.5, 0), BackgroundTransparency = 0.8 }
					):Play()
				end
				if nameLabel and nameLabel:IsA("TextLabel") then
					TweenService:Create(nameLabel, tweenInfo, { TextTransparency  = 0 }):Play()
				end
				if numLabel and numLabel:IsA("TextLabel") then
					TweenService:Create(numLabel,  tweenInfo, { TextTransparency  = 0 }):Play()
				end
				if iconLabel and iconLabel:IsA("ImageLabel") then
					TweenService:Create(iconLabel, tweenInfo, { ImageTransparency = 0 }):Play()
				end
			end)

			-- Hover effect
			if infoFrame then
				btn.MouseEnter:Connect(function()
					if btn:GetAttribute("_closing") then return end
					TweenService:Create(infoFrame,
						TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ BackgroundTransparency = 0.65 }
					):Play()
				end)
				btn.MouseLeave:Connect(function()
					if btn:GetAttribute("_closing") then return end
					TweenService:Create(infoFrame,
						TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ BackgroundTransparency = 0.8 }
					):Play()
				end)
			end

			-- Click handler
			local btnConn
			if isButton then
				btnConn = btn.MouseButton1Click:Connect(function()
					btnConn:Disconnect()
					closeClickFrame()
					jumpToIndex(i)
					fireOnChange()
				end)
			else
				btnConn = btn.InputBegan:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.MouseButton1
						and input.UserInputType ~= Enum.UserInputType.Touch then return end
					btnConn:Disconnect()
					closeClickFrame()
					jumpToIndex(i)
					fireOnChange()
				end)
			end
		end

		clickReg.activeInst = inst
		iState.listOpen     = true
		syncClickFrame()
		clickFrame.Visible  = true
		startClickTracking()
	end

	-- ── Input ────────────────────────────────────────────────

	-- Bấm đơn: toggle list
	table.insert(iState.conns, ChonseButton.MouseButton1Click:Connect(function()
		if iState._justDragged then
			iState._justDragged = false
			return
		end

		-- ✅ Chế độ simple: chỉ tăng slot
		if iState.simpleMode then
			local nextIndex = wrapIdx(iState.currentIndex + 1, OPT_COUNT)
			-- Tween ChonseCurrent ẩn → đổi text → hiện lại
			tweenCurrent(1)
			task.delay(0.12, function()
				jumpToIndex(nextIndex)
				tweenCurrent(0)
				fireOnChange()
			end)
			return
		end

		-- Chế độ bình thường
		local isMyListOpen = clickFrame
			and (clickFrame.Visible or iState.clickClosing)
			and clickReg
			and (clickReg.activeInst == inst or iState.clickClosing)

		if isMyListOpen then
			if not iState.clickClosing then
				closeClickFrame()
			end
		else
			openClickFrame()
		end
	end))

	-- Giữ + kéo: mở wheel chỉ khi center thay đổi
	table.insert(iState.conns, ChonseButton.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end

		if iState.simpleMode then return end

		local startX       = input.Position.X
		local startCenter  = iState.currentIndex  -- ghi nhớ center lúc bắt đầu
		local wheelStarted = false
		local dragMoveConn, dragEndConn

		local function startWheel()
			if wheelStarted then return end
			wheelStarted = true
			iState._justDragged = true

			closeClickFrame()
			if reg.activeInst and reg.activeInst ~= inst then
				reg.activeInst:_forceStopExternal()
			end
			forceStop(iState.isActive)

			reg.activeInst   = inst
			reg.activeButton = ChonseButton
			iState.isActive  = true
			iState.isDragging   = true
			iState.prevMouseX   = startX
			iState.lastDragTime = tick()

			tweenCurrent(1); tweenBG(0.6)
			syncWheelFrame(iState, wheelFrame, ChonseButton)
			wheelFrame.Visible = true
			startTracking()        -- ✅ đổi lại thành startTracking
			render(reg, iState, OPTIONS)
		end

		dragMoveConn = UserInputService.InputChanged:Connect(function(mv)
			if mv.UserInputType ~= Enum.UserInputType.MouseMovement
				and mv.UserInputType ~= Enum.UserInputType.Touch then return end
			if not wheelStarted then
				-- Bắt đầu wheel khi di chuyển đủ để trượt 1 slot
				local delta = mv.Position.X - startX
				local sw    = getSlotWidth(reg, iState)
				if math.abs(delta) >= sw * 0.15 then
					startWheel()
				end
			end
			if wheelStarted and iState.isDragging then
				onDragMove(mv.Position.X)
			end
		end)

		dragEndConn = UserInputService.InputEnded:Connect(function(up)
			if up.UserInputType ~= Enum.UserInputType.MouseButton1
				and up.UserInputType ~= Enum.UserInputType.Touch then return end
			dragMoveConn:Disconnect()
			dragEndConn:Disconnect()
			if wheelStarted and iState.isDragging then
				onDragEnd()
			end
		end)
	end))

	table.insert(iState.conns, UserInputService.InputChanged:Connect(function(input)
		if not iState.isDragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			onDragMove(input.Position.X)
		end
	end))

	table.insert(iState.conns, UserInputService.InputEnded:Connect(function(input)
		if not iState.isDragging then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			onDragEnd()
		end
	end))

	if SlotNum then
		SlotNum.Text = tostring(iState.currentIndex)
		table.insert(iState.conns, SlotNum.FocusLost:Connect(function()
			local num = tonumber(SlotNum.Text)
			if num then
				jumpToIndex(math.clamp(math.floor(num+0.5), 1, OPT_COUNT))
				fireOnChange()
			else
				SlotNum.Text = tostring(iState.currentIndex)
			end
		end))
	end

	-- ── Init ─────────────────────────────────────────────────
	initSlotState(reg, iState, OPT_COUNT)
	updateRangeLabel()
	wheelFrame.Visible = false

	-- ── Instance ─────────────────────────────────────────────
	inst = setmetatable({
		Frame       = settingFrame,
		_title      = title,
		_tag        = config.tag,
		_options    = OPTIONS,
		_wheelFrame = wheelFrame,
	}, SliderModule)

	reg.instState[inst] = iState

	function inst:getValue()      return iState.currentIndex          end
	function inst:getValueText()  return OPTIONS[iState.currentIndex] end
	function inst:setValue(idx)   jumpToIndex(idx)                    end

	function inst:_forceStopExternal()
		forceStop(true)
	end

	function inst:_closeListExternal()
		closeClickFrameInstant()  -- ✅ đổi kênh → clear ngay
	end

	function inst:setSimpleMode(enabled)
		applySimpleMode(enabled, false)
	end

	function inst:setOnChange(fn)
		config.onChange = fn
	end

	function inst:setVisible(bool)
		settingFrame.Visible = bool
	end

	function inst:destroy()
		forceStop(false)
		closeClickFrame()
		for _,c in ipairs(iState.conns) do c:Disconnect() end
		iState.conns = {}
		reg.instState[inst] = nil
		if reg.activeInst == inst then
			reg.activeInst   = nil
			reg.activeButton = nil  -- ✅ THÊM DÒNG NÀY
		end

		local anyLeft = false
		for _,v in pairs(createdSliders) do
			if v ~= inst and v._wheelFrame == wheelFrame then anyLeft=true; break end
		end
		if not anyLeft then
			for _,slot in ipairs(reg.pool) do
				if slot.frame and slot.frame.Parent then slot.frame:Destroy() end
			end
			wheelRegistry[wheelFrame] = nil
		end

		createdSliders[settingFrame] = nil
		if settingFrame.Parent then settingFrame:Destroy() end
	end

	createdSliders[settingFrame] = inst
	return inst
end

-- ════════════════════════════════════════════════════════════
--  SliderModule.Color  |  Color picker với RGB sliders
--
--  Config:
--    template         (Frame)    : ColorTemplate
--    parent           (Frame)    : frame cha
--    title            (string)   : tên hiển thị
--    default          (Color3)   : màu mặc định (default trắng)
--    colorSettingFrame(Frame)    : frame picker ngoài (giống wheelFrame)
--    onChange         (function) : callback(color3, {r,g,b}, hex, info, tag)
--    tag              (any)      : tag gửi kèm
--
--  Cấu trúc ColorTemplate:
--    ColorTemplate (Frame)
--    ├── InfoFrame
--    │   ├── NameSetting (TextLabel)
--    │   │   └── InfoSetting (TextLabel)
--    │   ├── ColorButton (Frame)
--    │   │   └── CurrentColorFrame (Frame)
--    └── ButtonDelta
--
--  Cấu trúc ColorSettingFrame:
--    ColorSettingFrame (Frame)
--    ├── InfoFrame
--    │   ├── CurrentColor (Frame)
--    │   ├── CurrentColorText (TextLabel)
--    │   └── InfoButton (Frame)
--    └── SettingColorRBG (Frame)
--        ├── RedFrame
--        │   ├── UIGradient
--        │   └── SliderButton
--        ├── GreenFrame
--        │   ├── UIGradient
--        │   └── SliderButton
--        ├── BlueFrame
--        │   ├── UIGradient
--        │   └── SliderButton
--        ├── BlackFrame  ← HSV Value
--        │   ├── UIGradient
--        │   └── SliderButton
--        └── ColorTextFrame
--            └── ColorBox (TextBox)
-- ════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════
--  COLOR REGISTRY  —  shared state cho colorSettingFrame
-- ════════════════════════════════════════════════════════════
local colorRegistry = {}

local function getColorReg(csf)
	if not colorRegistry[csf] then
		colorRegistry[csf] = {
			activeInst     = nil,
			savedCSF_Trans = nil,
			CSF_homePos    = nil,
			trackConn      = nil,
			isOpen         = false,
			savedRGB_Trans = nil,
			savedSC3_Trans = nil,
			savedCCF_Trans = nil,
			savedSOS_Trans = nil,
			-- ✅ Nhận diện loại
			regType        = nil,   -- "Color" | "Gradient"
			-- ✅ Lưu keypoints cho Gradient
			keypoints      = {},    -- { [index] = { position=0~1, color=Color3, brightness=0~1, saturation=0~1 } }
		}
	end
	return colorRegistry[csf]
end

function SliderModule.Color(config)
	assert(config.parent,            "[SliderModule.Color] Thiếu 'parent'")
	assert(config.colorSettingFrame, "[SliderModule.Color] Thiếu 'colorSettingFrame'")

	local template = config.template or script:FindFirstChild("ColorTemplate")
	assert(template, "[SliderModule.Color] Không tìm thấy ColorTemplate")

	local title   = config.title   or "Color"
	local default = config.default or Color3.fromRGB(255, 255, 255)

	-- ── Clone template ──────────────────────────────────────
	local settingFrame   = template:Clone()
	settingFrame.Name    = "Setting_" .. title
	settingFrame.Visible = true
	settingFrame.Parent  = config.parent

	local InfoFrame         = settingFrame:FindFirstChild("InfoFrame")
	local TitleLabel        = InfoFrame and InfoFrame:FindFirstChild("NameSetting")
	local RangeLabel        = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")
	local ColorButton       = InfoFrame and InfoFrame:FindFirstChild("ColorButton")
	local CurrentColorFrame = ColorButton and ColorButton:FindFirstChild("CurrentColorFrame")

	assert(ColorButton, "[SliderModule.Color] Thiếu 'ColorButton'")
	if TitleLabel then TitleLabel.Text = title end
	setupButtonDelta(settingFrame)

	-- ── CSF refs (shared) ───────────────────────────────────
	local csf             = config.colorSettingFrame
	local reg             = getColorReg(csf)  -- ✅ shared registry
	reg.regType = "Color"

	local CSF_InfoFrame   = csf:FindFirstChild("InfoFrame")
	local CSF_CurColor    = CSF_InfoFrame and CSF_InfoFrame:FindFirstChild("CurrentColor")
	local CSF_CurText     = CSF_InfoFrame and CSF_InfoFrame:FindFirstChild("CurrentColorText")
	local CSF_InfoButton  = CSF_InfoFrame and CSF_InfoFrame:FindFirstChild("InfoButton")
	local SettingRGB      = csf:FindFirstChild("SettingColorRBG")
	local SettingColor3   = csf:FindFirstChild("SettingColor3")
	local ChonseColorFrame = csf:FindFirstChild("ChonseColorFrame")
	local SettingOfSetting = csf:FindFirstChild("SettingOfSetting")

	local GradientFrame       = csf:FindFirstChild("GradientFrame")
	local GradientUIGrad      = GradientFrame and GradientFrame:FindFirstChild("UIGradient")
	local GradientSliderFrame = GradientFrame and GradientFrame:FindFirstChild("GradientSliderFrame")
	local GradientCreateBtn   = GradientFrame and GradientFrame:FindFirstChild("CreateSliderGradientButton")
	local GradientFolderSlider = GradientSliderFrame and GradientSliderFrame:FindFirstChild("FolderSlider")

	local RedFrame    = SettingRGB and SettingRGB:FindFirstChild("RedFrame")
	local GreenFrame  = SettingRGB and SettingRGB:FindFirstChild("GreenFrame")
	local BlueFrame   = SettingRGB and SettingRGB:FindFirstChild("BlueFrame")
	local BlackFrame  = SettingRGB and SettingRGB:FindFirstChild("BlackFrame")
	local ColorTextFrame = SettingRGB and SettingRGB:FindFirstChild("ColorTextFrame")
	local ColorBox    = ColorTextFrame and ColorTextFrame:FindFirstChild("ColorBox")

	local RedSlider   = RedFrame   and RedFrame:FindFirstChild("SliderButton")
	local GreenSlider = GreenFrame and GreenFrame:FindFirstChild("SliderButton")
	local BlueSlider  = BlueFrame  and BlueFrame:FindFirstChild("SliderButton")
	local BlackSlider = BlackFrame and BlackFrame:FindFirstChild("SliderButton")
	local RedGrad     = RedFrame   and RedFrame:FindFirstChild("UIGradient")
	local GreenGrad   = GreenFrame and GreenFrame:FindFirstChild("UIGradient")
	local BlueGrad    = BlueFrame  and BlueFrame:FindFirstChild("UIGradient")
	local BlackGrad   = BlackFrame and BlackFrame:FindFirstChild("UIGradient")

	local CCF_Hue        = ChonseColorFrame and ChonseColorFrame:FindFirstChild("Hue")
	local CCF_Val        = ChonseColorFrame and ChonseColorFrame:FindFirstChild("Val")
	local CCF_Color3     = ChonseColorFrame and ChonseColorFrame:FindFirstChild("Color3")
	local CCF_ColorButton = ChonseColorFrame and ChonseColorFrame:FindFirstChild("ColorButton")
	local CCF_HueFrame   = CCF_ColorButton and CCF_ColorButton:FindFirstChild("HueFrame")
	local CCF_WhiteFrame = CCF_ColorButton and CCF_ColorButton:FindFirstChild("WhiteFrame")
	local CCF_BlackFrame = CCF_ColorButton and CCF_ColorButton:FindFirstChild("BlackFrame")
	local CCF_HueText    = CCF_Hue   and CCF_Hue:FindFirstChild("Text")
	local CCF_ValText    = CCF_Val   and CCF_Val:FindFirstChild("Text")
	local CCF_Color3Text = CCF_Color3 and CCF_Color3:FindFirstChild("Text")

	local SOS_BG      = SettingOfSetting and SettingOfSetting:FindFirstChild("BackgroundFrame")
	local SOS_Slider  = SettingOfSetting and SettingOfSetting:FindFirstChild("SliderFrame")
	local SOS_Support = SettingOfSetting and SettingOfSetting:FindFirstChild("SliderSupport")
	local SOS_Context = SettingOfSetting and SettingOfSetting:FindFirstChild("Context")
	local SOS_Shadow  = SettingOfSetting and SettingOfSetting:FindFirstChild("Shadow")
	local SOS_Gradient = SOS_Context and SOS_Context:FindFirstChild("UIGradient")

	local SC3_HueFrame  = SettingColor3 and SettingColor3:FindFirstChild("HueFrame")
	local SC3_SatFrame  = SettingColor3 and SettingColor3:FindFirstChild("SatFrame")
	local SC3_ValFrame  = SettingColor3 and SettingColor3:FindFirstChild("ValFrame")
	local SC3_HueSlider = SC3_HueFrame and SC3_HueFrame:FindFirstChild("SliderButton")
	local SC3_SatSlider = SC3_SatFrame and SC3_SatFrame:FindFirstChild("SliderButton")
	local SC3_ValSlider = SC3_ValFrame and SC3_ValFrame:FindFirstChild("SliderButton")
	local SC3_HueGrad   = SC3_HueFrame and SC3_HueFrame:FindFirstChild("UIGradient")
	local SC3_SatGrad   = SC3_SatFrame and SC3_SatFrame:FindFirstChild("UIGradient")
	local SC3_ValGrad   = SC3_ValFrame and SC3_ValFrame:FindFirstChild("UIGradient")

	-- ── Per-instance state ──────────────────────────────────
	-- ✅ Mỗi instance lưu state riêng
	local iState = {
		r      = math.floor(default.R * 255 + 0.5),
		g      = math.floor(default.G * 255 + 0.5),
		b      = math.floor(default.B * 255 + 0.5),
		hsvH   = 0,
		hsvS   = 0,
		hsvV   = 0,
		sc3Mode  = false,
		ccfOpen  = false,
		savedCCF_Trans = nil,
		CCF_homePos    = nil,
	}
	do
		local h, s, v = Color3.fromRGB(iState.r, iState.g, iState.b):ToHSV()
		iState.hsvH = h; iState.hsvS = s; iState.hsvV = v
	end

	-- shortcut locals trỏ vào iState (để code bên dưới không đổi nhiều)
	local function R() return iState.r end
	local function G() return iState.g end
	local function B() return iState.b end

	local conns = {}
	local inst

	-- ════════════════════════════════════════════════════════
	--  SHARED HELPERS (dùng chung, không đổi)
	-- ════════════════════════════════════════════════════════
	local function saveTransparencies(frame)
		local saved = {}
		if not frame then return saved end
		saved[frame] = { BackgroundTransparency = frame.BackgroundTransparency }
		for _, child in ipairs(frame:GetDescendants()) do
			-- Có T hoặc bất kỳ ancestor nào trong frame có T → bỏ qua
			local shielded = false
			local current = child
			while current and current ~= frame do
				if current:GetAttribute("T") ~= nil then
					shielded = true
					break
				end
				current = current.Parent
			end
			if shielded then continue end

			local t = {}
			if child:IsA("GuiObject") then t.BackgroundTransparency = child.BackgroundTransparency end
			if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
				t.TextTransparency = child.TextTransparency
			end
			if child:IsA("ImageLabel") or child:IsA("ImageButton") then
				t.ImageTransparency = child.ImageTransparency
			end
			if next(t) then saved[child] = t end
		end
		return saved
	end

	local function applyTransparencies(saved, tweenInfo, targetMult)
		for obj, t in pairs(saved) do
			local props = {}
			if t.BackgroundTransparency ~= nil then
				props.BackgroundTransparency = targetMult == 1 and 1 or t.BackgroundTransparency
			end
			if t.TextTransparency ~= nil then
				props.TextTransparency = targetMult == 1 and 1 or t.TextTransparency
			end
			if t.ImageTransparency ~= nil then
				props.ImageTransparency = targetMult == 1 and 1 or t.ImageTransparency
			end
			if next(props) and obj and obj.Parent then
				TweenService:Create(obj, tweenInfo, props):Play()
			end
		end
	end

	local function applyCSF_Trans(tweenInfo, targetMult)
		if not reg.savedCSF_Trans then return end
		for obj, t in pairs(reg.savedCSF_Trans) do
			if obj == SettingOfSetting then continue end
			if SettingOfSetting and obj:IsDescendantOf(SettingOfSetting) then continue end
			if SettingRGB and (obj == SettingRGB or obj:IsDescendantOf(SettingRGB)) then continue end
			if SettingColor3 and (obj == SettingColor3 or obj:IsDescendantOf(SettingColor3)) then continue end
			if ChonseColorFrame and (obj == ChonseColorFrame or obj:IsDescendantOf(ChonseColorFrame)) then continue end
			if not obj or not obj.Parent then continue end
			local props = {}
			if t.BackgroundTransparency ~= nil then
				props.BackgroundTransparency = targetMult == 1 and 1 or t.BackgroundTransparency
			end
			if t.TextTransparency ~= nil then
				props.TextTransparency = targetMult == 1 and 1 or t.TextTransparency
			end
			if t.ImageTransparency ~= nil then
				props.ImageTransparency = targetMult == 1 and 1 or t.ImageTransparency
			end
			if next(props) then TweenService:Create(obj, tweenInfo, props):Play() end
		end
	end

	local function applySOSVisual(tweenInfo)
		local enabled = iState.sc3Mode
		if SOS_BG then
			TweenService:Create(SOS_BG, tweenInfo, {
				BackgroundTransparency = enabled and 0.5 or 0.7
			}):Play()
		end
		if SOS_Slider then
			SOS_Slider.AnchorPoint = enabled and Vector2.new(1, 0) or Vector2.new(0, 0)
			TweenService:Create(SOS_Slider, tweenInfo, {
				Position               = enabled and UDim2.new(1, 0, 0, 0) or UDim2.new(0, 0, 0, 0),
				BackgroundTransparency = enabled and 1 or 0,
			}):Play()
		end
		if SOS_Support then
			TweenService:Create(SOS_Support, tweenInfo, {
				BackgroundTransparency = enabled and 1 or 0
			}):Play()
		end
		if SOS_Context then
			SOS_Context.Text = enabled and "COLOR" or "RGB"
			TweenService:Create(SOS_Context, tweenInfo, { TextTransparency = 0 }):Play()
		end
		if SOS_Shadow then
			SOS_Shadow.Text = enabled and "COLOR" or "RGB"
			TweenService:Create(SOS_Shadow, tweenInfo, { TextTransparency = 0 }):Play()
		end
		if SOS_Gradient then SOS_Gradient.Enabled = not enabled end
	end

	-- ════════════════════════════════════════════════════════
	--  INSTANCE HELPERS (dùng iState)
	-- ════════════════════════════════════════════════════════
	local function toHex(cr, cg, cb)
		return string.format("#%02X%02X%02X", cr, cg, cb)
	end

	local function blendWithDark(color)
		local dark = Color3.fromRGB(34, 34, 34)
		return Color3.new((color.R+dark.R)/2, (color.G+dark.G)/2, (color.B+dark.B)/2)
	end

	local function getCurrentColor()
		return Color3.fromRGB(iState.r, iState.g, iState.b)
	end

	local function updateSliderPos(slider, ratio)
		if not slider then return end
		local p = slider.Position
		slider.Position = UDim2.new(math.clamp(ratio,0,1), p.X.Offset, p.Y.Scale, p.Y.Offset)
	end

	local function updateSC3Gradients()
		if SC3_HueGrad then
			local kps = {}
			for i = 0, 11 do
				table.insert(kps, ColorSequenceKeypoint.new(i/11, Color3.fromHSV(i/11, 1, 1)))
			end
			SC3_HueGrad.Color = ColorSequence.new(kps)
		end
		if SC3_SatGrad then
			SC3_SatGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(1,1,1)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(iState.hsvH, 1, 1)),
			})
		end
		if SC3_ValGrad then
			SC3_ValGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(iState.hsvH, iState.hsvS, 1)),
			})
		end
	end

	local function updateSC3SliderPos()
		updateSliderPos(SC3_HueSlider, iState.hsvH)
		updateSliderPos(SC3_SatSlider, iState.hsvS)
		updateSliderPos(SC3_ValSlider, iState.hsvV)
	end

	local function updateGradients()
		local cr, cg, cb = iState.r/255, iState.g/255, iState.b/255
		if RedGrad then RedGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
			ColorSequenceKeypoint.new(1, Color3.new(1,cg,cb)),
			}) end
		if GreenGrad then GreenGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
			ColorSequenceKeypoint.new(1, Color3.new(cr,1,cb)),
			}) end
		if BlueGrad then BlueGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
			ColorSequenceKeypoint.new(1, Color3.new(cr,cg,1)),
			}) end
		if BlackGrad then
			BlackGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(iState.hsvH, iState.hsvS, 1)),
			})
		end
	end

	local function updateCCF()
		if not ChonseColorFrame then return end
		if CCF_HueFrame then
			CCF_HueFrame.BackgroundColor3 = Color3.fromHSV(iState.hsvH, 1, 1)
			local hueGrad = CCF_HueFrame:FindFirstChild("UIGradient")
			if hueGrad then
				hueGrad.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0,     Color3.fromHSV(0,     1,1)),
					ColorSequenceKeypoint.new(0.167, Color3.fromHSV(0.167, 1,1)),
					ColorSequenceKeypoint.new(0.333, Color3.fromHSV(0.333, 1,1)),
					ColorSequenceKeypoint.new(0.5,   Color3.fromHSV(0.5,   1,1)),
					ColorSequenceKeypoint.new(0.667, Color3.fromHSV(0.667, 1,1)),
					ColorSequenceKeypoint.new(0.833, Color3.fromHSV(0.833, 1,1)),
					ColorSequenceKeypoint.new(1,     Color3.fromHSV(0,     1,1)),
				})
			end
		end
		if CCF_WhiteFrame then
			local wg = CCF_WhiteFrame:FindFirstChild("UIGradient")
			if wg then
				wg.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.new(1,1,1)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(iState.hsvH, 1, 1)),
				})
				wg.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 0),
				})
			end
		end
		if CCF_BlackFrame then
			local bg = CCF_BlackFrame:FindFirstChild("UIGradient")
			if bg then
				bg.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
					ColorSequenceKeypoint.new(1, Color3.new(0,0,0)),
				})
				bg.Rotation = 90
				bg.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(1, 0),
				})
			end
		end
		if CCF_HueText   then CCF_HueText.Text   = tostring(math.floor(iState.hsvH * 360 + 0.5)) end
		if CCF_ValText   then CCF_ValText.Text   = tostring(math.floor(iState.hsvV * 100 + 0.5)) end
		if CCF_Color3Text then CCF_Color3Text.Text = toHex(iState.r, iState.g, iState.b) end
	end

	-- ✅ Load toàn bộ data của instance này lên csf (không tween)
	local function loadDataToCSF()
		local color = getCurrentColor()
		local hex   = toHex(iState.r, iState.g, iState.b)

		if CSF_CurColor then CSF_CurColor.BackgroundColor3 = color end
		if CSF_CurText  then
			CSF_CurText.Text       = hex
			CSF_CurText.TextColor3 = blendWithDark(color)
		end
		if ColorBox then ColorBox.Text = hex end

		updateSliderPos(RedSlider,   iState.r / 255)
		updateSliderPos(GreenSlider, iState.g / 255)
		updateSliderPos(BlueSlider,  iState.b / 255)
		updateSliderPos(BlackSlider, iState.hsvV)
		updateSC3SliderPos()
		updateGradients()
		updateSC3Gradients()

		local ti0 = TweenInfo.new(0)
		if iState.sc3Mode then
			if SettingRGB then
				-- ✅ Reset position về chỗ ẩn trước
				local cp = SettingRGB.Position
				SettingRGB.Position = UDim2.new(-0.5, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingRGB.Visible = false
			end
			if SettingColor3 then
				-- ✅ Reset position về chỗ hiện
				local cp = SettingColor3.Position
				SettingColor3.Position = UDim2.new(0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingColor3.Visible = true
				if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, ti0, 0) end
			end
		else
			if SettingColor3 then
				-- ✅ Reset position về chỗ ẩn trước
				local cp = SettingColor3.Position
				SettingColor3.Position = UDim2.new(1, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingColor3.Visible = false
			end
			if SettingRGB then
				-- ✅ Reset position về chỗ hiện
				local cp = SettingRGB.Position
				SettingRGB.Position = UDim2.new(0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingRGB.Visible = true
				if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, ti0, 0) end
			end
		end

		-- CCF
		if ChonseColorFrame then
			if iState.ccfOpen then
				ChonseColorFrame.Position = iState.CCF_homePos or ChonseColorFrame.Position
				ChonseColorFrame.Visible = true
				if iState.savedCCF_Trans then applyTransparencies(iState.savedCCF_Trans, ti0, 0) end
				updateCCF()
			else
				ChonseColorFrame.Visible = false
			end
		end

		-- SOS visual (instant)
		applySOSVisual(ti0)
	end
	local function updateUI(fireEvent)
		local color = getCurrentColor()
		local hex   = toHex(iState.r, iState.g, iState.b)

		if ColorButton then ColorButton.BackgroundColor3 = color end
		if TitleLabel then
			local grad = TitleLabel:FindFirstChild("UIGradient")
			if grad then
				local h, s, v = color:ToHSV()
				local softColor  = Color3.fromHSV(h, s*0.51, v)
				local startColor = Color3.new(0,0,0)
				local kp = grad.Color.Keypoints
				if kp and #kp > 0 then startColor = kp[1].Value end
				grad.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, startColor),
					ColorSequenceKeypoint.new(1, softColor),
				})
			end
		end
		if CurrentColorFrame then CurrentColorFrame.BackgroundColor3 = color end

		-- Chỉ update csf nếu đây là active inst
		if reg.activeInst == inst then
			if CSF_CurColor then CSF_CurColor.BackgroundColor3 = color end
			if CSF_CurText  then
				CSF_CurText.Text       = hex
				CSF_CurText.TextColor3 = blendWithDark(color)
			end
			if ColorBox     then ColorBox.Text = hex end
			updateSliderPos(RedSlider,   iState.r / 255)
			updateSliderPos(GreenSlider, iState.g / 255)
			updateSliderPos(BlueSlider,  iState.b / 255)
			updateSliderPos(BlackSlider, iState.hsvV)
			updateSC3SliderPos()
			updateGradients()
			updateSC3Gradients()
			if CCF_HueFrame then
				CCF_HueFrame.BackgroundColor3 = Color3.fromHSV(iState.hsvH, 1, 1)
			end
			if iState.ccfOpen then updateCCF() end

			-- Sync solid color lên GradientFrame khi color thay đổi
			if GradientUIGrad then
				GradientUIGrad.Color = ColorSequence.new(getCurrentColor())
			end
		end

		if RangeLabel then RangeLabel.Text = "CURRENT: " .. hex end

		if fireEvent and config.onChange then
			config.onChange(color, {r=iState.r, g=iState.g, b=iState.b}, hex, {
				title = title, timestamp = makeTimestamp(title),
			}, config.tag)
		end
	end

	local function lockGradientForColor()
		if not GradientFrame then return end

		if reg.activeInst and getmetatable(reg.activeInst) == SliderModule then
			-- kiểm tra inst có phải Gradient không bằng cách check _isGradient
			if reg.activeInst._isGradient then return end
		end

		-- ✅ Lấy tpl TRƯỚC khi loop
		local tpl = GradientFolderSlider and GradientFolderSlider:FindFirstChild("GradientSliderTemplate")

		if GradientFolderSlider then
			for _, child in ipairs(GradientFolderSlider:GetChildren()) do
				if child ~= tpl
					and not child:IsA("UIListLayout")
					and not child:IsA("UIGridLayout") then
					child:Destroy()
				end
			end
		end

		if GradientSliderFrame then
			local tpl2 = GradientSliderFrame:FindFirstChild("GradientSliderTemplate") or tpl
			for _, child in ipairs(GradientSliderFrame:GetChildren()) do
				if child ~= tpl2
					and child ~= GradientFolderSlider
					and not child:IsA("UIListLayout")
					and not child:IsA("UIGridLayout") then
					child:Destroy()
				end
			end
		end

		if GradientUIGrad then
			GradientUIGrad.Color = ColorSequence.new(getCurrentColor())
		end

		if GradientCreateBtn then
			GradientCreateBtn.Active = false
			GradientCreateBtn.AutoButtonColor = false
			GradientCreateBtn:SetAttribute("_colorLocked", true)
		end
	end
	-- ── Sync Y position ─────────────────────────────────────
	local function syncCSF()
		if not csf.Parent then return end
		local absPos    = ColorButton.AbsolutePosition
		local absSize   = ColorButton.AbsoluteSize
		local parentPos = csf.Parent.AbsolutePosition
		local curPos    = csf.Position
		csf.Position = UDim2.new(
			curPos.X.Scale, curPos.X.Offset,
			0, absPos.Y - parentPos.Y + absSize.Y
		)
	end

	-- ════════════════════════════════════════════════════════
	--  OPEN / CLOSE CSF
	-- ════════════════════════════════════════════════════════
	local switching = false  -- ✅ flag đánh dấu đang switch

	local function closeCSF(isSwitching)
		if reg.activeInst ~= inst then return end
		registerClose(inst)
		reg.activeInst = nil
		if reg.trackConn then reg.trackConn:Disconnect(); reg.trackConn = nil end

		-- ✅ Nếu đang switch → không tween gì hết
		if isSwitching then
			csf.Visible = true  -- giữ visible cho inst mới load vào
			return
		end

		-- ✅ Tắt thật sự → tween ẩn
		local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		applyCSF_Trans(tweenInfo, 1)
		if reg.savedSOS_Trans then applyTransparencies(reg.savedSOS_Trans, tweenInfo, 1) end
		if reg.savedRGB_Trans  then applyTransparencies(reg.savedRGB_Trans,  tweenInfo, 1) end
		if reg.savedSC3_Trans  then applyTransparencies(reg.savedSC3_Trans,  tweenInfo, 1) end
		if iState.savedCCF_Trans then applyTransparencies(iState.savedCCF_Trans, tweenInfo, 1) end

		task.delay(tweenInfo.Time, function()
			if reg.activeInst == nil then
				csf.Visible = false
				if reg.CSF_homePos then
					csf.Position = UDim2.new(
						reg.CSF_homePos.X.Scale, reg.CSF_homePos.X.Offset,
						csf.Position.Y.Scale,    csf.Position.Y.Offset
					)
				end
			end
		end)
	end

	local function openCSF()
		local prevInst    = reg.activeInst
		local isSwitching = (prevInst ~= nil and prevInst ~= inst)

		-- ✅ Lưu trans shared lần đầu
		if not reg.savedCSF_Trans then
			csf.Visible = true
			reg.savedCSF_Trans = saveTransparencies(csf)
			csf.Visible = false
		end
		if not reg.savedRGB_Trans and SettingRGB then
			reg.savedRGB_Trans = saveTransparencies(SettingRGB)
		end
		if not reg.savedSC3_Trans and SettingColor3 then
			reg.savedSC3_Trans = saveTransparencies(SettingColor3)
		end
		if not reg.savedSOS_Trans and SettingOfSetting then
			reg.savedSOS_Trans = saveTransparencies(SettingOfSetting)
		end
		if not iState.savedCCF_Trans and ChonseColorFrame then
			iState.savedCCF_Trans = saveTransparencies(ChonseColorFrame)
			iState.CCF_homePos = ChonseColorFrame.Position
		end

		-- ✅ Đóng inst cũ không tween nếu switching
		if isSwitching then
			prevInst:_closeListExternal_switch()
		end

		if GradientFrame then
			GradientFrame.Visible = false
		end

		registerOpen(inst)
		reg.activeInst = inst
		syncCSF()

		local currentPos = csf.Position
		reg.CSF_homePos = UDim2.new(
			currentPos.X.Scale, currentPos.X.Offset,
			currentPos.Y.Scale, currentPos.Y.Offset
		)

		local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local ti0       = TweenInfo.new(0)

		if isSwitching then
			-- ✅ Switch: chỉ load data, không tween
			csf.Visible = true
			loadDataToCSF()
			lockGradientForColor()
		else
			-- ✅ Mở mới: ẩn hết instant rồi tween hiện
			applyCSF_Trans(ti0, 1)
			if reg.savedSOS_Trans    then applyTransparencies(reg.savedSOS_Trans,    ti0, 1) end
			if reg.savedRGB_Trans    then applyTransparencies(reg.savedRGB_Trans,    ti0, 1) end
			if reg.savedSC3_Trans    then applyTransparencies(reg.savedSC3_Trans,    ti0, 1) end
			if iState.savedCCF_Trans then applyTransparencies(iState.savedCCF_Trans, ti0, 1) end

			csf.Visible = true

			-- ✅ Load data TRƯỚC khi tween để không flash data cũ
			loadDataToCSF()

			applyCSF_Trans(tweenInfo, 0)
			applySOSVisual(tweenInfo)

			task.delay(0.05, function()
				if reg.activeInst ~= inst then return end
				local ti = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				if not iState.sc3Mode then
					if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, ti, 0) end
					if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, ti, 1) end
				else
					if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, ti, 0) end
					if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, ti, 1) end
				end
				if iState.ccfOpen then
					if iState.savedCCF_Trans then applyTransparencies(iState.savedCCF_Trans, ti, 0) end
				end
			end)
		end

		-- Track Y
		if reg.trackConn then reg.trackConn:Disconnect() end
		reg.trackConn = RunService.RenderStepped:Connect(function()
			if reg.activeInst ~= inst then
				reg.trackConn:Disconnect(); reg.trackConn = nil
				return
			end
			syncCSF()
			local p = csf.Position
			reg.CSF_homePos = UDim2.new(
				reg.CSF_homePos.X.Scale, reg.CSF_homePos.X.Offset,
				p.Y.Scale, p.Y.Offset
			)
		end)
	end

	-- ════════════════════════════════════════════════════════
	--  applyColorSOS (per-instance, dùng iState)
	-- ════════════════════════════════════════════════════════
	local function applyColorSOS(enabled, instant)
		iState.ccfOpen  = enabled
		iState.sc3Mode  = enabled
		local tweenInfo = TweenInfo.new(
			instant and 0 or 0.2,
			Enum.EasingStyle.Quad, Enum.EasingDirection.Out
		)

		-- SOS visual
		applySOSVisual(tweenInfo)

		-- CCF
		if ChonseColorFrame then
			if not iState.CCF_homePos then
				iState.CCF_homePos = ChonseColorFrame.Position
			end
			if not iState.savedCCF_Trans then
				iState.savedCCF_Trans = saveTransparencies(ChonseColorFrame)
			end
			if instant then
				ChonseColorFrame.Visible = enabled
				if enabled then
					ChonseColorFrame.Position = iState.CCF_homePos
					applyTransparencies(iState.savedCCF_Trans, tweenInfo, 0)
				else
					ChonseColorFrame.Position = UDim2.new(1, 0, 0.27, 0)
					applyTransparencies(iState.savedCCF_Trans, tweenInfo, 1)
				end
			else
				if enabled then
					ChonseColorFrame.Position = UDim2.new(1, 0, 0.27, 0)
					ChonseColorFrame.Visible  = true
					applyTransparencies(iState.savedCCF_Trans, tweenInfo, 1)
					TweenService:Create(ChonseColorFrame, tweenInfo, {
						Position = iState.CCF_homePos
					}):Play()
					task.delay(0.05, function()
						applyTransparencies(iState.savedCCF_Trans, tweenInfo, 0)
					end)
				else
					applyTransparencies(iState.savedCCF_Trans, tweenInfo, 1)
					TweenService:Create(ChonseColorFrame, tweenInfo, {
						Position = UDim2.new(1, 0, 0.27, 0)
					}):Play()
					task.delay(tweenInfo.Time, function()
						if not iState.ccfOpen then
							ChonseColorFrame.Visible = false
						end
					end)
				end
			end
		end
		if enabled then updateCCF() end

		-- RGB ↔ SC3 (chỉ khi csf đang mở với inst này)
		if reg.activeInst ~= inst then return end
		if not reg.savedRGB_Trans and SettingRGB then
			reg.savedRGB_Trans = saveTransparencies(SettingRGB)
		end
		if not reg.savedSC3_Trans and SettingColor3 then
			reg.savedSC3_Trans = saveTransparencies(SettingColor3)
		end

		if instant then
			if SettingRGB then
				local cp = SettingRGB.Position
				SettingRGB.Position = UDim2.new(enabled and -0.5 or 0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingRGB.Visible  = not enabled
			end
			if SettingColor3 then
				local cp = SettingColor3.Position
				SettingColor3.Position = UDim2.new(enabled and 0.054 or 1, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingColor3.Visible  = enabled
			end
		else
			if enabled then
				if SettingRGB then
					local cp = SettingRGB.Position
					TweenService:Create(SettingRGB, tweenInfo, {
						Position = UDim2.new(-0.5, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
					}):Play()
					if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, tweenInfo, 1) end
				end
				if SettingColor3 then
					SettingColor3.Visible = true
					local cp = SettingColor3.Position
					SettingColor3.Position = UDim2.new(1, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
					TweenService:Create(SettingColor3, tweenInfo, {
						Position = UDim2.new(0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
					}):Play()
					if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, tweenInfo, 0) end
					updateSC3Gradients(); updateSC3SliderPos()
				end
			else
				if SettingColor3 then
					local cp = SettingColor3.Position
					TweenService:Create(SettingColor3, tweenInfo, {
						Position = UDim2.new(1, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
					}):Play()
					if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, tweenInfo, 1) end
					task.delay(0.2, function()
						if not iState.sc3Mode and SettingColor3 then
							SettingColor3.Visible = false
						end
					end)
				end
				if SettingRGB then
					SettingRGB.Visible = true
					local cp = SettingRGB.Position
					SettingRGB.Position = UDim2.new(-0.5, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
					TweenService:Create(SettingRGB, tweenInfo, {
						Position = UDim2.new(0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
					}):Play()
					if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, tweenInfo, 0) end
				end
			end
		end
	end

	-- Init SOS instant
	applyColorSOS(false, true)

	-- ════════════════════════════════════════════════════════
	--  SLIDERS SETUP
	-- ════════════════════════════════════════════════════════
	local function setupColorSlider(sliderBtn, parentFrame, onDrag)
		if not sliderBtn or not parentFrame then return end
		local dragging = false
		local function getVal(inputX)
			local absX = parentFrame.AbsolutePosition.X
			local absW = parentFrame.AbsoluteSize.X
			if absW <= 0 then return 0 end
			return math.clamp((inputX - absX) / absW, 0, 1)
		end
		table.insert(conns, parentFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true; onDrag(getVal(input.Position.X))
			end
		end))
		table.insert(conns, sliderBtn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
			end
		end))
		table.insert(conns, UserInputService.InputChanged:Connect(function(input)
			if reg.activeInst ~= inst then dragging = false; return end  -- ← thêm reset dragging
			if not dragging then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch then
				onDrag(getVal(input.Position.X))
			end
		end))
		table.insert(conns, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end))
	end

	setupColorSlider(RedSlider, RedFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		iState.r = math.floor(ratio*255+0.5)
		iState.hsvH, iState.hsvS, iState.hsvV = Color3.fromRGB(iState.r, iState.g, iState.b):ToHSV()
		updateUI(true)
	end)
	setupColorSlider(GreenSlider, GreenFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		iState.g = math.floor(ratio*255+0.5)
		iState.hsvH, iState.hsvS, iState.hsvV = Color3.fromRGB(iState.r, iState.g, iState.b):ToHSV()
		updateUI(true)
	end)
	setupColorSlider(BlueSlider, BlueFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		iState.b = math.floor(ratio*255+0.5)
		iState.hsvH, iState.hsvS, iState.hsvV = Color3.fromRGB(iState.r, iState.g, iState.b):ToHSV()
		updateUI(true)
	end)
	setupColorSlider(BlackSlider, BlackFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		iState.hsvV = ratio
		local c = Color3.fromHSV(iState.hsvH, iState.hsvS, iState.hsvV)
		iState.r = math.floor(c.R*255+0.5)
		iState.g = math.floor(c.G*255+0.5)
		iState.b = math.floor(c.B*255+0.5)
		updateUI(true)
	end)
	setupColorSlider(SC3_HueSlider, SC3_HueFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		iState.hsvH = ratio
		local c = Color3.fromHSV(iState.hsvH, iState.hsvS, iState.hsvV)
		iState.r = math.floor(c.R*255+0.5)
		iState.g = math.floor(c.G*255+0.5)
		iState.b = math.floor(c.B*255+0.5)
		updateUI(true); updateSC3Gradients()
	end)
	setupColorSlider(SC3_SatSlider, SC3_SatFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		iState.hsvS = ratio
		local c = Color3.fromHSV(iState.hsvH, iState.hsvS, iState.hsvV)
		iState.r = math.floor(c.R*255+0.5)
		iState.g = math.floor(c.G*255+0.5)
		iState.b = math.floor(c.B*255+0.5)
		updateUI(true); updateSC3Gradients()
	end)
	setupColorSlider(SC3_ValSlider, SC3_ValFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		iState.hsvV = ratio
		local c = Color3.fromHSV(iState.hsvH, iState.hsvS, iState.hsvV)
		iState.r = math.floor(c.R*255+0.5)
		iState.g = math.floor(c.G*255+0.5)
		iState.b = math.floor(c.B*255+0.5)
		updateUI(true); updateSC3Gradients()
	end)

	-- CCF picker
	if CCF_ColorButton then
		local ccfPickDrag = false
		local function applyPickerPos(inputX, inputY)
			if reg.activeInst ~= inst then return end
			local absPos  = CCF_ColorButton.AbsolutePosition
			local absSize = CCF_ColorButton.AbsoluteSize
			if absSize.X <= 0 or absSize.Y <= 0 then return end
			iState.hsvS = math.clamp((inputX - absPos.X) / absSize.X, 0, 1)
			iState.hsvV = 1 - math.clamp((inputY - absPos.Y) / absSize.Y, 0, 1)
			local c = Color3.fromHSV(iState.hsvH, iState.hsvS, iState.hsvV)
			iState.r = math.floor(c.R*255+0.5)
			iState.g = math.floor(c.G*255+0.5)
			iState.b = math.floor(c.B*255+0.5)
			updateUI(true); updateCCF()
		end
		table.insert(conns, CCF_ColorButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				ccfPickDrag = true; applyPickerPos(input.Position.X, input.Position.Y)
			end
		end))
		table.insert(conns, UserInputService.InputChanged:Connect(function(input)
			if not ccfPickDrag then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch then
				applyPickerPos(input.Position.X, input.Position.Y)
			end
		end))
		table.insert(conns, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				ccfPickDrag = false
			end
		end))
	end

	-- CCF HueFrame
	if CCF_HueFrame then
		local hueDrag = false
		local function applyHue(inputX)
			local h, s, v = CCF_HueFrame.BackgroundColor3:ToHSV()
			iState.hsvH = h
			local newColor = Color3.fromHSV(iState.hsvH, iState.hsvS, iState.hsvV)
			iState.r = math.floor(newColor.R * 255 + 0.5)
			iState.g = math.floor(newColor.G * 255 + 0.5)
			iState.b = math.floor(newColor.B * 255 + 0.5)
			updateCCF()
		end
		table.insert(conns, CCF_HueFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				hueDrag = true; applyHue(input.Position.X)
			end
		end))
		table.insert(conns, UserInputService.InputChanged:Connect(function(input)
			if not hueDrag then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch then
				applyHue(input.Position.X)
			end
		end))
		table.insert(conns, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				hueDrag = false
			end
		end))
	end

	-- Textboxes
	if CCF_HueText then
		table.insert(conns, CCF_HueText.FocusLost:Connect(function()
			if reg.activeInst ~= inst then return end
			local num = tonumber(CCF_HueText.Text)
			if num then
				iState.hsvH = math.clamp(num, 0, 360) / 360
				local c = Color3.fromHSV(iState.hsvH, iState.hsvS, iState.hsvV)
				iState.r = math.floor(c.R*255+0.5)
				iState.g = math.floor(c.G*255+0.5)
				iState.b = math.floor(c.B*255+0.5)
				updateUI(true); updateCCF()
			else CCF_HueText.Text = tostring(math.floor(iState.hsvH*360+0.5)) end
		end))
	end
	if CCF_ValText then
		table.insert(conns, CCF_ValText.FocusLost:Connect(function()
			if reg.activeInst ~= inst then return end
			local num = tonumber(CCF_ValText.Text)
			if num then
				iState.hsvV = math.clamp(num, 0, 100) / 100
				local c = Color3.fromHSV(iState.hsvH, iState.hsvS, iState.hsvV)
				iState.r = math.floor(c.R*255+0.5)
				iState.g = math.floor(c.G*255+0.5)
				iState.b = math.floor(c.B*255+0.5)
				updateUI(true); updateCCF()
			else CCF_ValText.Text = tostring(math.floor(iState.hsvV*100+0.5)) end
		end))
	end
	if CCF_Color3Text then
		table.insert(conns, CCF_Color3Text.FocusLost:Connect(function()
			if reg.activeInst ~= inst then return end
			local text = CCF_Color3Text.Text:gsub("%s","")
			local nr, ng, nb
			if text:sub(1,1) == "#" then
				local hex = text:sub(2)
				if #hex == 6 then
					nr = tonumber(hex:sub(1,2),16)
					ng = tonumber(hex:sub(3,4),16)
					nb = tonumber(hex:sub(5,6),16)
				end
			end
			if nr and ng and nb then
				iState.r = math.clamp(math.floor(nr+0.5),0,255)
				iState.g = math.clamp(math.floor(ng+0.5),0,255)
				iState.b = math.clamp(math.floor(nb+0.5),0,255)
				iState.hsvH, iState.hsvS, iState.hsvV = Color3.fromRGB(iState.r,iState.g,iState.b):ToHSV()
				updateUI(true); updateCCF()
			else CCF_Color3Text.Text = toHex(iState.r,iState.g,iState.b) end
		end))
	end
	if ColorBox then
		table.insert(conns, ColorBox.FocusLost:Connect(function()
			if reg.activeInst ~= inst then return end
			local text = ColorBox.Text:gsub("%s","")
			local nr, ng, nb
			if text:sub(1,1) == "#" then
				local hex = text:sub(2)
				if #hex == 6 then
					nr=tonumber(hex:sub(1,2),16); ng=tonumber(hex:sub(3,4),16); nb=tonumber(hex:sub(5,6),16)
				elseif #hex == 3 then
					nr=tonumber(hex:sub(1,1):rep(2),16); ng=tonumber(hex:sub(2,2):rep(2),16); nb=tonumber(hex:sub(3,3):rep(2),16)
				end
			else
				local parts = text:split(",")
				if #parts == 3 then nr=tonumber(parts[1]); ng=tonumber(parts[2]); nb=tonumber(parts[3]) end
			end
			if nr and ng and nb then
				iState.r = math.clamp(math.floor(nr+0.5),0,255)
				iState.g = math.clamp(math.floor(ng+0.5),0,255)
				iState.b = math.clamp(math.floor(nb+0.5),0,255)
				iState.hsvH, iState.hsvS, iState.hsvV = Color3.fromRGB(iState.r,iState.g,iState.b):ToHSV()
				updateUI(true)
			else ColorBox.Text = toHex(iState.r,iState.g,iState.b) end
		end))
	end

	-- InfoButton hover
	if CSF_InfoButton and CSF_InfoFrame then
		local hoverTween
		CSF_InfoButton.MouseEnter:Connect(function()
			if reg.activeInst ~= inst then return end  -- ✅ chỉ inst đang active mới hover
			if hoverTween then hoverTween:Cancel() end
			hoverTween = TweenService:Create(CSF_InfoFrame,
				TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundColor3 = getCurrentColor() }
			)
			hoverTween:Play()
		end)
		CSF_InfoButton.MouseLeave:Connect(function()
			if reg.activeInst ~= inst then return end  -- ✅
			if hoverTween then hoverTween:Cancel() end
			hoverTween = TweenService:Create(CSF_InfoFrame,
				TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundColor3 = Color3.fromRGB(0,0,0) }
			)
			hoverTween:Play()
		end)
	end

	-- ColorButton toggle
	table.insert(conns, ColorButton.MouseButton1Click:Connect(function()
		if reg.activeInst == inst then
			closeCSF()
		else
			openCSF()
		end
	end))

	-- SOS toggle
	if SettingOfSetting then
		table.insert(conns, SettingOfSetting.MouseButton1Click:Connect(function()
			if reg.activeInst ~= inst then return end
			applyColorSOS(not iState.ccfOpen, false)
		end))
	end

	-- ── Init ────────────────────────────────────────────────
	-- ✅ Chỉ update template, KHÔNG đụng csf
	do
		local color = getCurrentColor()
		local hex   = toHex(iState.r, iState.g, iState.b)

		if ColorButton       then ColorButton.BackgroundColor3       = color end
		if CurrentColorFrame then CurrentColorFrame.BackgroundColor3 = color end
		if RangeLabel        then RangeLabel.Text = "CURRENT: " .. hex end

		if TitleLabel then
			local grad = TitleLabel:FindFirstChild("UIGradient")
			if grad then
				local h, s, v   = color:ToHSV()
				local softColor  = Color3.fromHSV(h, s * 0.51, v)
				local startColor = Color3.new(0, 0, 0)
				local kp = grad.Color.Keypoints
				if kp and #kp > 0 then startColor = kp[1].Value end
				grad.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, startColor),
					ColorSequenceKeypoint.new(1, softColor),
				})
			end
		end
	end


	-- ── Instance ────────────────────────────────────────────
	inst = setmetatable({
		Frame  = settingFrame,
		_title = title,
		_tag   = config.tag,
	}, SliderModule)

	function inst:getValue()   return getCurrentColor() end
	function inst:getHex()     return toHex(iState.r, iState.g, iState.b) end
	function inst:getRGB()     return { r=iState.r, g=iState.g, b=iState.b } end

	function inst:setValue(color3)
		iState.r = math.floor(color3.R*255+0.5)
		iState.g = math.floor(color3.G*255+0.5)
		iState.b = math.floor(color3.B*255+0.5)
		iState.hsvH, iState.hsvS, iState.hsvV = Color3.fromRGB(iState.r,iState.g,iState.b):ToHSV()
		updateUI(false)
	end

	function inst:setOnChange(fn)
		config.onChange = fn
	end

	function inst:_closeListExternal()
		closeCSF(false)
	end

	function inst:_closeListExternal_switch()
		closeCSF(true)
	end

	function inst:setVisible(bool)
		settingFrame.Visible = bool
	end

	function inst:destroy()
		closeCSF(false)  -- ✅ thêm false
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		createdSliders[settingFrame] = nil
		if settingFrame.Parent then settingFrame:Destroy() end
	end

	createdSliders[settingFrame] = inst
	return inst
end

-- ════════════════════════════════════════════════════════════
--  SliderModule.Gradient  |  Gradient picker
--
--  Config:
--    template         (Frame)    : GradientTemplate
--    parent           (Frame)    : frame cha
--    title            (string)   : tên hiển thị
--    colorSettingFrame(Frame)    : dùng chung với Color
--    default          (table|ColorSequence) : keypoints mặc định
--    onChange         (function) : callback(ColorSequence, keypoints, info, tag)
--    tag              (any)
--
--  Cấu trúc GradientTemplate:
--    GradientTemplate
--    ├── InfoFrame
--    │   ├── NameSetting (TextLabel)
--    │   │   └── InfoSetting (TextLabel)
--    │   └── ColorButton (Frame)
--    │       └── CurrentColorFrame (Frame)
--    │           └── UIGradient
--    ├── LeftFrame
--    │   └── Button
--    ├── RightFrame
--    │   └── Button
--    ├── SliderFrame
--    │   └── SliderButton
--    ├── DarkFrame
--    │   └── SliderButton
--    └── ColorTextFrame
--        └── ColorBox (TextBox)
-- ════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
--  GradientStateRegistry
--  Key   = inst (object reference)
--  Value = toàn bộ state của instance đó
-- ════════════════════════════════════════════════════════════════════════════
local GradientStateRegistry = {}
local GradientKnobRegistry  = {}  -- Key = GradientSliderFrame, Value = { inst, knobList }

function SliderModule.Gradient(config)
	assert(config.parent,            "[SliderModule.Gradient] Thiếu 'parent'")
	assert(config.colorSettingFrame, "[SliderModule.Gradient] Thiếu 'colorSettingFrame'")

	local template = config.template or script:FindFirstChild("GradientTemplate")
	assert(template, "[SliderModule.Gradient] Không tìm thấy GradientTemplate")

	local title = config.title or "Gradient"

	local settingFrame   = template:Clone()
	settingFrame.Name    = "Setting_" .. title
	settingFrame.Visible = true
	settingFrame.Parent  = config.parent

	local InfoFrame         = settingFrame:FindFirstChild("InfoFrame")
	local TitleLabel        = InfoFrame and InfoFrame:FindFirstChild("NameSetting")
	local RangeLabel        = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")
	local ColorButton       = InfoFrame and InfoFrame:FindFirstChild("ColorButton")
	local CurrentColorFrame = ColorButton and ColorButton:FindFirstChild("CurrentColorFrame")
	local GradientDisplay   = CurrentColorFrame and CurrentColorFrame:FindFirstChild("UIGradient")

	local LeftFrame  = settingFrame:FindFirstChild("LeftFrame")
	local RightFrame = settingFrame:FindFirstChild("RightFrame")
	local LeftBtn    = LeftFrame  and LeftFrame:FindFirstChild("Button")
	local RightBtn   = RightFrame and RightFrame:FindFirstChild("Button")

	local SliderFrame = settingFrame:FindFirstChild("SliderFrame")
	local SliderBtn   = SliderFrame and SliderFrame:FindFirstChild("SliderButton")
	local SliderGrad  = SliderFrame and SliderFrame:FindFirstChild("UIGradient")

	local DarkFrame   = settingFrame:FindFirstChild("DarkFrame")
	local DarkBtn     = DarkFrame and DarkFrame:FindFirstChild("SliderButton")
	local DarkTextBox = DarkFrame and DarkFrame:FindFirstChild("TextBox")

	local ColorTextFrame = settingFrame:FindFirstChild("ColorTextFrame")
	local ColorBox       = ColorTextFrame and ColorTextFrame:FindFirstChild("ColorBox")

	assert(ColorButton, "[SliderModule.Gradient] Thiếu 'ColorButton'")
	setupButtonDelta(settingFrame)

	local csf = config.colorSettingFrame
	local reg = getColorReg(csf)
	reg.regType = "Gradient"

	local CSF_InfoFrame  = csf:FindFirstChild("InfoFrame")
	local CSF_CurColor   = CSF_InfoFrame and CSF_InfoFrame:FindFirstChild("CurrentColor")
	local CSF_CurText    = CSF_InfoFrame and CSF_InfoFrame:FindFirstChild("CurrentColorText")
	local CSF_InfoButton = CSF_InfoFrame and CSF_InfoFrame:FindFirstChild("InfoButton")

	local SettingRGB       = csf:FindFirstChild("SettingColorRBG")
	local SettingColor3    = csf:FindFirstChild("SettingColor3")
	local ChonseColorFrame = csf:FindFirstChild("ChonseColorFrame")
	local SettingOfSetting = csf:FindFirstChild("SettingOfSetting")

	local RedFrame   = SettingRGB and SettingRGB:FindFirstChild("RedFrame")
	local GreenFrame = SettingRGB and SettingRGB:FindFirstChild("GreenFrame")
	local BlueFrame  = SettingRGB and SettingRGB:FindFirstChild("BlueFrame")
	local BlackFrame = SettingRGB and SettingRGB:FindFirstChild("BlackFrame")

	local ColorTextFrameCSF = SettingRGB and SettingRGB:FindFirstChild("ColorTextFrame")
	local ColorBoxCSF       = ColorTextFrameCSF and ColorTextFrameCSF:FindFirstChild("ColorBox")

	local RedSlider   = RedFrame   and RedFrame:FindFirstChild("SliderButton")
	local GreenSlider = GreenFrame and GreenFrame:FindFirstChild("SliderButton")
	local BlueSlider  = BlueFrame  and BlueFrame:FindFirstChild("SliderButton")
	local BlackSlider = BlackFrame and BlackFrame:FindFirstChild("SliderButton")
	local RedGrad     = RedFrame   and RedFrame:FindFirstChild("UIGradient")
	local GreenGrad   = GreenFrame and GreenFrame:FindFirstChild("UIGradient")
	local BlueGrad    = BlueFrame  and BlueFrame:FindFirstChild("UIGradient")
	local BlackGrad   = BlackFrame and BlackFrame:FindFirstChild("UIGradient")

	local CCF_Hue         = ChonseColorFrame and ChonseColorFrame:FindFirstChild("Hue")
	local CCF_Val         = ChonseColorFrame and ChonseColorFrame:FindFirstChild("Val")
	local CCF_Color3      = ChonseColorFrame and ChonseColorFrame:FindFirstChild("Color3")
	local CCF_ColorButton = ChonseColorFrame and ChonseColorFrame:FindFirstChild("ColorButton")
	local CCF_HueFrame    = CCF_ColorButton and CCF_ColorButton:FindFirstChild("HueFrame")
	local CCF_WhiteFrame  = CCF_ColorButton and CCF_ColorButton:FindFirstChild("WhiteFrame")
	local CCF_BlackFrame  = CCF_ColorButton and CCF_ColorButton:FindFirstChild("BlackFrame")
	local CCF_HueText     = CCF_Hue   and CCF_Hue:FindFirstChild("Text")
	local CCF_ValText     = CCF_Val   and CCF_Val:FindFirstChild("Text")
	local CCF_Color3Text  = CCF_Color3 and CCF_Color3:FindFirstChild("Text")

	local SOS_BG       = SettingOfSetting and SettingOfSetting:FindFirstChild("BackgroundFrame")
	local SOS_Slider   = SettingOfSetting and SettingOfSetting:FindFirstChild("SliderFrame")
	local SOS_Support  = SettingOfSetting and SettingOfSetting:FindFirstChild("SliderSupport")
	local SOS_Context  = SettingOfSetting and SettingOfSetting:FindFirstChild("Context")
	local SOS_Shadow   = SettingOfSetting and SettingOfSetting:FindFirstChild("Shadow")
	local SOS_Gradient = SOS_Context and SOS_Context:FindFirstChild("UIGradient")

	local SC3_HueFrame  = SettingColor3 and SettingColor3:FindFirstChild("HueFrame")
	local SC3_SatFrame  = SettingColor3 and SettingColor3:FindFirstChild("SatFrame")
	local SC3_ValFrame  = SettingColor3 and SettingColor3:FindFirstChild("ValFrame")
	local SC3_HueSlider = SC3_HueFrame and SC3_HueFrame:FindFirstChild("SliderButton")
	local SC3_SatSlider = SC3_SatFrame and SC3_SatFrame:FindFirstChild("SliderButton")
	local SC3_ValSlider = SC3_ValFrame and SC3_ValFrame:FindFirstChild("SliderButton")
	local SC3_HueGrad   = SC3_HueFrame and SC3_HueFrame:FindFirstChild("UIGradient")
	local SC3_SatGrad   = SC3_SatFrame and SC3_SatFrame:FindFirstChild("UIGradient")
	local SC3_ValGrad   = SC3_ValFrame and SC3_ValFrame:FindFirstChild("UIGradient")

	local GradientFrame       = csf:FindFirstChild("GradientFrame")
	local GradientUIGrad      = GradientFrame and GradientFrame:FindFirstChild("UIGradient")
	local GradientSliderFrame = GradientFrame and GradientFrame:FindFirstChild("GradientSliderFrame")
	local FolderSlider        = GradientSliderFrame and GradientSliderFrame:FindFirstChild("FolderSlider")
	local GradientSliderTpl   = FolderSlider and FolderSlider:FindFirstChild("GradientSliderTemplate")
	local CreateBtn           = GradientFrame and GradientFrame:FindFirstChild("CreateSliderGradientButton")

	local DOUBLE_CLICK_TIME = 0.3
	local MAX_KEYPOINTS     = 20
	local MIN_POSITION_GAP  = 0.01

	local function parseDefault(def)
		if not def then
			return {
				{ position = 0, color = Color3.fromRGB(255,255,255), brightness = 1, saturation = 1, locked = true },
				{ position = 1, color = Color3.fromRGB(0,0,0),       brightness = 1, saturation = 1, locked = true },
			}
		end
		if typeof(def) == "ColorSequence" then
			local kps = {}
			for idx, kp in ipairs(def.Keypoints) do
				local h, s, v = kp.Value:ToHSV()
				table.insert(kps, {
					position   = kp.Time,
					color      = Color3.fromHSV(h, s, 1),
					brightness = v,
					saturation = s,
					locked     = (idx == 1 or idx == #def.Keypoints),
				})
			end
			return kps
		end
		local kps = {}
		for _, kp in ipairs(def) do
			table.insert(kps, {
				position   = kp.position   or 0,
				color      = kp.color      or Color3.new(1,1,1),
				brightness = kp.brightness or 1,
				saturation = kp.saturation or 1,
				locked     = kp.locked or false,
			})
		end
		table.sort(kps, function(a, b) return a.position < b.position end)
		if kps[1]    then kps[1].locked    = true end
		if kps[#kps] then kps[#kps].locked = true end
		return kps
	end

	-- ── Khởi tạo inst sớm ────────────────────────────────────────────────────
	local inst        = setmetatable({}, SliderModule)
	local conns       = {}
	local sliderDrags = {}
	local knobList    = {}

	GradientStateRegistry[inst] = {
		keypoints      = parseDefault(config.default),
		selectedIndex  = 1,
		r = 0, g = 0, b = 0,
		hsvH = 0, hsvS = 0, hsvV = 0,
		sc3Mode        = false,
		ccfOpen        = false,
		ccfPickDrag    = false,
		hueDrag        = false,
		savedCCF_Trans = nil,
		CCF_homePos    = nil,
	}

	local function S() return GradientStateRegistry[inst] end

	-- ════════════════════════════════════════════════════════════════════════════
	--  HELPERS
	-- ════════════════════════════════════════════════════════════════════════════
	local function toHex(cr, cg, cb)
		return string.format("#%02X%02X%02X", cr, cg, cb)
	end

	local function blendWithDark(color)
		local dark = Color3.fromRGB(34, 34, 34)
		return Color3.new((color.R+dark.R)/2, (color.G+dark.G)/2, (color.B+dark.B)/2)
	end

	local function getCurrentColor()
		local s = S()
		return Color3.fromRGB(s.r, s.g, s.b)
	end

	local function updateSliderPos(slider, ratio)
		if not slider then return end
		local p = slider.Position
		slider.Position = UDim2.new(math.clamp(ratio,0,1), p.X.Offset, p.Y.Scale, p.Y.Offset)
	end

	local function isOwner()
		local reg2 = GradientSliderFrame and GradientKnobRegistry[GradientSliderFrame]
		return reg2 and reg2.inst == inst
	end

	-- ── Transparency helpers ──────────────────────────────────────────────────
	local function saveTransparencies(frame)
		local saved = {}
		if not frame then return saved end
		saved[frame] = { BackgroundTransparency = frame.BackgroundTransparency }
		for _, child in ipairs(frame:GetDescendants()) do
			local shielded = false
			local current  = child
			while current and current ~= frame do
				if current:GetAttribute("T") ~= nil then shielded = true; break end
				current = current.Parent
			end
			if shielded then continue end
			local t = {}
			if child:IsA("GuiObject") then t.BackgroundTransparency = child.BackgroundTransparency end
			if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
				t.TextTransparency = child.TextTransparency
			end
			if child:IsA("ImageLabel") or child:IsA("ImageButton") then
				t.ImageTransparency = child.ImageTransparency
			end
			if next(t) then saved[child] = t end
		end
		return saved
	end

	local function applyTransparencies(saved, tweenInfo, targetMult)
		for obj, t in pairs(saved) do
			local props = {}
			if t.BackgroundTransparency ~= nil then
				props.BackgroundTransparency = targetMult == 1 and 1 or t.BackgroundTransparency
			end
			if t.TextTransparency ~= nil then
				props.TextTransparency = targetMult == 1 and 1 or t.TextTransparency
			end
			if t.ImageTransparency ~= nil then
				props.ImageTransparency = targetMult == 1 and 1 or t.ImageTransparency
			end
			if next(props) and obj and obj.Parent then
				TweenService:Create(obj, tweenInfo, props):Play()
			end
		end
	end

	local function applyCSF_Trans(tweenInfo, targetMult)
		if not reg.savedCSF_Trans then return end
		for obj, t in pairs(reg.savedCSF_Trans) do
			if obj == SettingOfSetting then continue end
			if SettingOfSetting and obj:IsDescendantOf(SettingOfSetting) then continue end
			if SettingRGB    and (obj == SettingRGB    or obj:IsDescendantOf(SettingRGB))    then continue end
			if SettingColor3 and (obj == SettingColor3 or obj:IsDescendantOf(SettingColor3)) then continue end
			if ChonseColorFrame and (obj == ChonseColorFrame or obj:IsDescendantOf(ChonseColorFrame)) then continue end
			if not obj or not obj.Parent then continue end
			local props = {}
			if t.BackgroundTransparency ~= nil then
				props.BackgroundTransparency = targetMult == 1 and 1 or t.BackgroundTransparency
			end
			if t.TextTransparency ~= nil then
				props.TextTransparency = targetMult == 1 and 1 or t.TextTransparency
			end
			if t.ImageTransparency ~= nil then
				props.ImageTransparency = targetMult == 1 and 1 or t.ImageTransparency
			end
			if next(props) then TweenService:Create(obj, tweenInfo, props):Play() end
		end
	end

	local function applySOSVisual(tweenInfo)
		local s       = S()
		local enabled = s.sc3Mode
		if SOS_BG then
			TweenService:Create(SOS_BG, tweenInfo, {
				BackgroundTransparency = enabled and 0.5 or 0.7
			}):Play()
		end
		if SOS_Slider then
			SOS_Slider.AnchorPoint = enabled and Vector2.new(1,0) or Vector2.new(0,0)
			TweenService:Create(SOS_Slider, tweenInfo, {
				Position               = enabled and UDim2.new(1,0,0,0) or UDim2.new(0,0,0,0),
				BackgroundTransparency = enabled and 1 or 0,
			}):Play()
		end
		if SOS_Support then
			TweenService:Create(SOS_Support, tweenInfo, {
				BackgroundTransparency = enabled and 1 or 0
			}):Play()
		end
		if SOS_Context then
			SOS_Context.Text = enabled and "COLOR" or "RGB"
			TweenService:Create(SOS_Context, tweenInfo, { TextTransparency = 0 }):Play()
		end
		if SOS_Shadow then
			SOS_Shadow.Text = enabled and "COLOR" or "RGB"
			TweenService:Create(SOS_Shadow, tweenInfo, { TextTransparency = 0 }):Play()
		end
		if SOS_Gradient then SOS_Gradient.Enabled = not enabled end
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  COLOR SEQUENCE BUILDERS
	-- ════════════════════════════════════════════════════════════════════════════
	local function buildColorSequence()
		local s   = S()
		local kps = s.keypoints
		if #kps < 2 then
			local c = kps[1] and Color3.fromHSV(kps[1].color:ToHSV()) or Color3.new(1,1,1)
			return ColorSequence.new(c)
		end
		local seq     = {}
		local lastPos = -1
		for _, kp in ipairs(kps) do
			local pos = math.clamp(kp.position, 0, 1)
			if pos <= lastPos then pos = lastPos + 0.0001 end
			if pos > 1 then break end
			local h = kp.color:ToHSV()
			table.insert(seq, ColorSequenceKeypoint.new(pos, Color3.fromHSV(h, kp.saturation, kp.brightness)))
			lastPos = pos
		end
		if seq[#seq].Time < 1 then
			table.insert(seq, ColorSequenceKeypoint.new(1, seq[#seq].Value))
		end
		return ColorSequence.new(seq)
	end

	local function getColorAtPosition(ratio)
		local s   = S()
		local kps = s.keypoints
		if #kps == 0 then return Color3.new(1,1,1) end
		if #kps == 1 then
			local h, sat, v = kps[1].color:ToHSV()
			return Color3.fromHSV(h, kps[1].saturation, kps[1].brightness)
		end
		local left, right
		for i = 1, #kps-1 do
			if kps[i].position <= ratio and kps[i+1].position >= ratio then
				left = kps[i]; right = kps[i+1]; break
			end
		end
		if not left then
			if ratio <= kps[1].position then
				local k = kps[1]; return Color3.fromHSV(k.color:ToHSV())
			else
				local k = kps[#kps]; local h,sat,v = k.color:ToHSV(); return Color3.fromHSV(h,sat,v)
			end
		end
		local span = right.position - left.position
		local t    = span > 0 and (ratio - left.position)/span or 0
		local lh   = left.color:ToHSV(); local rh = right.color:ToHSV()
		return Color3.fromHSV(lh, left.saturation, left.brightness)
			:Lerp(Color3.fromHSV(rh, right.saturation, right.brightness), t)
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  STATE SYNC
	-- ════════════════════════════════════════════════════════════════════════════
	local function syncFromSelected()
		local s  = S()
		local kp = s.keypoints[s.selectedIndex]
		if not kp then return end
		local h, sat, _ = kp.color:ToHSV()
		s.hsvH = h; s.hsvS = kp.saturation; s.hsvV = kp.brightness
		local c = Color3.fromHSV(h, kp.saturation, kp.brightness)
		s.r = math.floor(c.R*255+0.5)
		s.g = math.floor(c.G*255+0.5)
		s.b = math.floor(c.B*255+0.5)
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  UI UPDATE FUNCTIONS
	-- ════════════════════════════════════════════════════════════════════════════
	local function updateGradientDisplay()
		if GradientDisplay then GradientDisplay.Color = buildColorSequence() end
	end

	local function updateGradientUIGrad()
		if GradientUIGrad then GradientUIGrad.Color = buildColorSequence() end
	end

	local function updateAllGradients()
		updateGradientUIGrad()
		updateGradientDisplay()
	end

	local function updateSliderGradients()
		local s  = S()
		local kp = s.keypoints[s.selectedIndex]
		if not kp then return end
		local h = kp.color:ToHSV()
		if SliderGrad then
			SliderGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(1,1,1)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(h, 1, kp.brightness)),
			})
		end
		local darkGrad = DarkFrame and DarkFrame:FindFirstChild("UIGradient")
		if darkGrad then
			darkGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(h, kp.saturation, 1)),
			})
		end
	end

	local function updateTemplateUI()
		local s  = S()
		local kp = s.keypoints[s.selectedIndex]
		if not kp then return end
		local color = getCurrentColor()
		local hex   = toHex(s.r, s.g, s.b)
		if ColorButton then ColorButton.BackgroundColor3 = color end
		if TitleLabel then
			TitleLabel.Text = title
			local grad = TitleLabel:FindFirstChild("UIGradient")
			if grad then
				local h, sat, v  = color:ToHSV()
				local softColor  = Color3.fromHSV(h, sat*0.51, v)
				local startColor = Color3.new(0,0,0)
				local kpList     = grad.Color.Keypoints
				if kpList and #kpList > 0 then startColor = kpList[1].Value end
				grad.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, startColor),
					ColorSequenceKeypoint.new(1, softColor),
				})
			end
		end
		if RangeLabel then
			RangeLabel.Text = "CURRENT: " .. hex
				.. " || (" .. string.format("%.2f", kp.position) .. ")"
				.. " || " .. #s.keypoints .. "/" .. MAX_KEYPOINTS
		end
		if ColorBox then ColorBox.Text = hex end
		updateSliderPos(SliderBtn, s.hsvS)
		updateSliderPos(DarkBtn,   s.hsvV)
		if DarkTextBox then DarkTextBox.Text = string.format("%.2f", s.hsvV) end
		updateSliderGradients()
		updateGradientDisplay()
	end

	local function updateSC3Gradients()
		local s = S()
		if SC3_HueGrad then
			local kps = {}
			for i = 0, 11 do
				table.insert(kps, ColorSequenceKeypoint.new(i/11, Color3.fromHSV(i/11,1,1)))
			end
			SC3_HueGrad.Color = ColorSequence.new(kps)
		end
		if SC3_SatGrad then
			SC3_SatGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(1,1,1)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(s.hsvH,1,1)),
			})
		end
		if SC3_ValGrad then
			SC3_ValGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(s.hsvH,s.hsvS,1)),
			})
		end
	end

	local function updateSC3SliderPos()
		local s = S()
		updateSliderPos(SC3_HueSlider, s.hsvH)
		updateSliderPos(SC3_SatSlider, s.hsvS)
		updateSliderPos(SC3_ValSlider, s.hsvV)
	end

	local function updateRGBGradients()
		local s = S()
		local cr, cg, cb = s.r/255, s.g/255, s.b/255
		if RedGrad   then RedGrad.Color   = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0,0,0)), ColorSequenceKeypoint.new(1, Color3.new(1,cg,cb)) }) end
		if GreenGrad then GreenGrad.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0,0,0)), ColorSequenceKeypoint.new(1, Color3.new(cr,1,cb)) }) end
		if BlueGrad  then BlueGrad.Color  = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0,0,0)), ColorSequenceKeypoint.new(1, Color3.new(cr,cg,1)) }) end
		if BlackGrad then
			BlackGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(s.hsvH,s.hsvS,1)),
			})
		end
	end

	local function updateCCF()
		local s = S()
		if not ChonseColorFrame then return end
		if CCF_HueFrame then
			CCF_HueFrame.BackgroundColor3 = Color3.fromHSV(s.hsvH,1,1)
			local hueGrad = CCF_HueFrame:FindFirstChild("UIGradient")
			if hueGrad then
				hueGrad.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0,     Color3.fromHSV(0,    1,1)),
					ColorSequenceKeypoint.new(0.167, Color3.fromHSV(0.167,1,1)),
					ColorSequenceKeypoint.new(0.333, Color3.fromHSV(0.333,1,1)),
					ColorSequenceKeypoint.new(0.5,   Color3.fromHSV(0.5,  1,1)),
					ColorSequenceKeypoint.new(0.667, Color3.fromHSV(0.667,1,1)),
					ColorSequenceKeypoint.new(0.833, Color3.fromHSV(0.833,1,1)),
					ColorSequenceKeypoint.new(1,     Color3.fromHSV(0,    1,1)),
				})
			end
		end
		if CCF_WhiteFrame then
			local wg = CCF_WhiteFrame:FindFirstChild("UIGradient")
			if wg then
				wg.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.new(1,1,1)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(s.hsvH,1,1)),
				})
				wg.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0,0),
					NumberSequenceKeypoint.new(1,0),
				})
			end
		end
		if CCF_BlackFrame then
			local bg = CCF_BlackFrame:FindFirstChild("UIGradient")
			if bg then
				bg.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.new(0,0,0)),
					ColorSequenceKeypoint.new(1, Color3.new(0,0,0)),
				})
				bg.Rotation    = 90
				bg.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0,1),
					NumberSequenceKeypoint.new(1,0),
				})
			end
		end
		if CCF_HueText    then CCF_HueText.Text    = tostring(math.floor(s.hsvH*360+0.5)) end
		if CCF_ValText    then CCF_ValText.Text    = tostring(math.floor(s.hsvV*100+0.5)) end
		if CCF_Color3Text then CCF_Color3Text.Text = toHex(s.r,s.g,s.b) end
	end

	local function loadDataToCSF()
		local s     = S()
		local color = getCurrentColor()
		local hex   = toHex(s.r, s.g, s.b)
		if CSF_CurColor then CSF_CurColor.BackgroundColor3 = color end
		if CSF_CurText  then CSF_CurText.Text = hex; CSF_CurText.TextColor3 = blendWithDark(color) end
		if ColorBoxCSF  then ColorBoxCSF.Text = hex end
		updateSliderPos(RedSlider,   s.r/255)
		updateSliderPos(GreenSlider, s.g/255)
		updateSliderPos(BlueSlider,  s.b/255)
		updateSliderPos(BlackSlider, s.hsvV)
		updateSC3SliderPos()
		updateRGBGradients()
		updateSC3Gradients()

		local ti0 = TweenInfo.new(0)
		if s.sc3Mode then
			if SettingRGB then
				local cp = SettingRGB.Position
				SettingRGB.Position = UDim2.new(-0.5, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingRGB.Visible  = false
			end
			if SettingColor3 then
				local cp = SettingColor3.Position
				SettingColor3.Position = UDim2.new(0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingColor3.Visible  = true
				if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, ti0, 0) end
			end
		else
			if SettingColor3 then
				local cp = SettingColor3.Position
				SettingColor3.Position = UDim2.new(1, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingColor3.Visible  = false
			end
			if SettingRGB then
				local cp = SettingRGB.Position
				SettingRGB.Position = UDim2.new(0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingRGB.Visible  = true
				if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, ti0, 0) end
			end
		end
		if ChonseColorFrame then
			if s.ccfOpen then
				ChonseColorFrame.Position = s.CCF_homePos or ChonseColorFrame.Position
				ChonseColorFrame.Visible  = true
				if s.savedCCF_Trans then applyTransparencies(s.savedCCF_Trans, ti0, 0) end
				updateCCF()
			else
				ChonseColorFrame.Visible = false
			end
		end
		applySOSVisual(ti0)
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  KNOB SYSTEM  ✅ Toàn bộ viết lại với GradientKnobRegistry
	-- ════════════════════════════════════════════════════════════════════════════
	local function updateKnobColors()
		-- Chỉ update nếu inst này là owner
		if not isOwner() then return end
		for _, entry in ipairs(knobList) do
			if entry.clone and entry.clone.Parent then
				local kp  = entry.kpRef
				local h   = kp.color:ToHSV()
				local col = Color3.fromHSV(h, kp.saturation, kp.brightness)
				entry.clone.BackgroundColor3 = col
			end
		end
	end

	local function syncKnobPositions()
		if not GradientSliderFrame then return end
		local absW = GradientSliderFrame.AbsoluteSize.X
		if absW <= 0 then return end
		if not isOwner() then return end  -- ✅ chỉ sync nếu là owner
		for _, entry in ipairs(knobList) do
			if entry.clone and entry.clone.Parent and not entry.dragging then
				local p = entry.clone.Position
				entry.clone.Position = UDim2.new(0, entry.kpRef.position * absW, p.Y.Scale, p.Y.Offset)
			end
		end
	end

	local function destroyAllKnobs()
		-- ✅ Xóa theo registry — đảm bảo chỉ xóa knob của inst là owner
		local reg2 = GradientSliderFrame and GradientKnobRegistry[GradientSliderFrame]
		if reg2 and reg2.inst == inst then
			for _, entry in ipairs(reg2.knobList) do
				if entry.clone and entry.clone.Parent then
					entry.clone:Destroy()
				end
			end
			reg2.knobList = {}
			reg2.inst     = nil
		end
		knobList = {}
	end

	local function rebuildAllKnobs()
		destroyAllKnobs()
		if not GradientSliderTpl or not GradientSliderTpl.Parent then
			warn("[Gradient] GradientSliderTemplate bị mất"); return
		end

		-- ✅ Đăng ký inst này làm owner của GradientSliderFrame
		GradientKnobRegistry[GradientSliderFrame] = {
			inst     = inst,
			knobList = knobList,
		}

		local s = S()
		for _, kp in ipairs(s.keypoints) do
			-- ✅ Guard giữa chừng: nếu inst khác cướp ownership thì dừng
			if not isOwner() then break end

			local entry = { clone = nil, kpRef = kp, dragging = false, locked = kp.locked == true }
			local clone = GradientSliderTpl:Clone()
			clone.Visible = true

			local absW = GradientSliderFrame.AbsoluteSize.X
			local p    = GradientSliderTpl.Position
			clone.Position = UDim2.new(0, absW > 0 and kp.position * absW or 0, p.Y.Scale, p.Y.Offset)
			clone.Parent   = GradientSliderFrame

			-- Snapshot transparencies
			local savedTrans     = {}
			savedTrans[clone]    = { bg = GradientSliderTpl.BackgroundTransparency }
			local tplDesc  = GradientSliderTpl:GetDescendants()
			local cloneDesc = clone:GetDescendants()
			for i, tplChild in ipairs(tplDesc) do
				local cloneChild = cloneDesc[i]
				if not cloneChild then continue end
				local t = {}
				if tplChild:IsA("GuiObject") then t.bg = tplChild.BackgroundTransparency end
				if tplChild:IsA("TextLabel") or tplChild:IsA("TextButton") or tplChild:IsA("TextBox") then
					t.text = tplChild.TextTransparency
				end
				if tplChild:IsA("ImageLabel") or tplChild:IsA("ImageButton") then
					t.img = tplChild.ImageTransparency
				end
				if next(t) then savedTrans[cloneChild] = t end
			end

			entry.clone      = clone
			entry.savedTrans = savedTrans
			table.insert(knobList, entry)

			-- ✅ Capture tường minh — tránh closure bug trong loop
			local capturedEntry = entry
			local capturedClone = clone
			local lastClickTime = 0

			local sliderBtn = clone:FindFirstChild("SliderButton")
			if sliderBtn then
				table.insert(conns, sliderBtn.InputBegan:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.MouseButton1
						and input.UserInputType ~= Enum.UserInputType.Touch then return end

					-- ✅ Guard: chỉ owner mới xử lý
					if not isOwner() then return end
					if reg.activeInst ~= inst then return end

					local now = tick()
					local sv  = S()

					if now - lastClickTime <= DOUBLE_CLICK_TIME then
						-- Double click → xóa keypoint
						if capturedEntry.locked then return end
						if #sv.keypoints <= 2 then return end
						for i, kp2 in ipairs(sv.keypoints) do
							if kp2 == capturedEntry.kpRef then table.remove(sv.keypoints, i); break end
						end
						for i, e in ipairs(knobList) do
							if e == capturedEntry then table.remove(knobList, i); break end
						end
						capturedClone:Destroy()
						sv.selectedIndex = math.clamp(sv.selectedIndex, 1, #sv.keypoints)
						syncFromSelected()
						updateTemplateUI()
						updateAllGradients()
						updateKnobColors()
						if reg.activeInst == inst then loadDataToCSF() end
					else
						-- Single click → select
						for i, kp2 in ipairs(sv.keypoints) do
							if kp2 == capturedEntry.kpRef then sv.selectedIndex = i; break end
						end
						syncFromSelected()
						updateTemplateUI()
						updateAllGradients()
						updateKnobColors()
						if reg.activeInst == inst then loadDataToCSF() end
						if not capturedEntry.locked then capturedEntry.dragging = true end
					end
					lastClickTime = now
				end))
			end

			-- Drag move ✅ guard kép: owner + drag flag
			table.insert(conns, UserInputService.InputChanged:Connect(function(input)
				if not capturedEntry.dragging then return end
				if not isOwner() or reg.activeInst ~= inst then
					capturedEntry.dragging = false; return
				end
				if input.UserInputType ~= Enum.UserInputType.MouseMovement
					and input.UserInputType ~= Enum.UserInputType.Touch then return end
				if not capturedClone.Parent then capturedEntry.dragging = false; return end
				local absX  = GradientSliderFrame.AbsolutePosition.X
				local absW2 = GradientSliderFrame.AbsoluteSize.X
				if absW2 <= 0 then return end
				local ratio = math.clamp((input.Position.X - absX) / absW2, 0, 1)
				local sv    = S()
				capturedEntry.kpRef.position = ratio
				local cp = capturedClone.Position
				capturedClone.Position = UDim2.new(0, ratio * absW2, cp.Y.Scale, cp.Y.Offset)
				table.sort(sv.keypoints, function(a, b) return a.position < b.position end)
				for i, kp2 in ipairs(sv.keypoints) do
					if kp2 == capturedEntry.kpRef then sv.selectedIndex = i; break end
				end
				updateAllGradients()
				updateTemplateUI()
				if reg.activeInst == inst then loadDataToCSF() end
				if config.onChange then
					config.onChange(buildColorSequence(), sv.keypoints, {
						title = title, timestamp = makeTimestamp(title),
					}, config.tag)
				end
			end))

			-- Drag end
			table.insert(conns, UserInputService.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					capturedEntry.dragging = false
				end
			end))
		end

		-- ✅ Sync position sau 1 frame — đảm bảo AbsoluteSize đã ready
		local syncConn
		syncConn = RunService.RenderStepped:Connect(function()
			syncConn:Disconnect()
			if not isOwner() then return end
			syncKnobPositions()
			updateKnobColors()
		end)
	end

	local function restoreGradientFrame()
		if not GradientSliderFrame then return end

		-- ✅ Dọn sạch frame + reset registry inst cũ nếu có
		local reg2 = GradientKnobRegistry[GradientSliderFrame]
		if reg2 and reg2.inst ~= inst then
			-- Inst khác đang giữ → xóa knob của nó
			for _, entry in ipairs(reg2.knobList) do
				if entry.clone and entry.clone.Parent then entry.clone:Destroy() end
			end
			reg2.knobList = {}
			reg2.inst     = nil
		end

		-- Xóa tất cả child còn sót trong frame
		for _, child in ipairs(GradientSliderFrame:GetChildren()) do
			if child ~= GradientSliderTpl
				and child ~= FolderSlider
				and not child:IsA("UIListLayout")
				and not child:IsA("UIGridLayout") then
				child:Destroy()
			end
		end
		if FolderSlider then
			for _, child in ipairs(FolderSlider:GetChildren()) do
				if child ~= GradientSliderTpl
					and not child:IsA("UIListLayout")
					and not child:IsA("UIGridLayout") then
					child:Destroy()
				end
			end
		end

		if CreateBtn then
			CreateBtn.Active          = true
			CreateBtn.AutoButtonColor = true
			CreateBtn:SetAttribute("_colorLocked", nil)
		end
		if not GradientSliderTpl or not GradientSliderTpl.Parent then
			warn("[Gradient] GradientSliderTemplate bị mất"); return
		end

		rebuildAllKnobs()  -- ✅ tự đăng ký ownership
		updateAllGradients()
		updateKnobColors()

		-- Tween knob vào
		local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		for _, entry in ipairs(knobList) do
			if not entry.clone or not entry.clone.Parent then continue end
			local st = entry.savedTrans
			if not st then continue end
			for obj, t in pairs(st) do
				if not obj or not obj.Parent then continue end
				if t.bg   ~= nil then obj.BackgroundTransparency = 1 end
				if t.text ~= nil then obj.TextTransparency       = 1 end
				if t.img  ~= nil then obj.ImageTransparency      = 1 end
			end
			for obj, t in pairs(st) do
				if not obj or not obj.Parent then continue end
				local props = {}
				if t.bg   ~= nil then props.BackgroundTransparency = t.bg   end
				if t.text ~= nil then props.TextTransparency       = t.text end
				if t.img  ~= nil then props.ImageTransparency      = t.img  end
				if next(props) then TweenService:Create(obj, tweenInfo, props):Play() end
			end
		end
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  onKeypointChanged + selectKeypoint
	-- ════════════════════════════════════════════════════════════════════════════
	local function onKeypointChanged(fireEvent)
		local s  = S()
		local kp = s.keypoints[s.selectedIndex]
		if not kp then return end
		local h = kp.color:ToHSV()
		s.hsvH = h; s.hsvS = kp.saturation; s.hsvV = kp.brightness
		local c = Color3.fromHSV(h, kp.saturation, kp.brightness)
		s.r = math.floor(c.R*255+0.5)
		s.g = math.floor(c.G*255+0.5)
		s.b = math.floor(c.B*255+0.5)
		updateTemplateUI()
		updateAllGradients()
		updateKnobColors()
		if reg.activeInst == inst then
			local color = getCurrentColor()
			local hex   = toHex(s.r, s.g, s.b)
			if CSF_CurColor then CSF_CurColor.BackgroundColor3 = color end
			if CSF_CurText  then CSF_CurText.Text = hex; CSF_CurText.TextColor3 = blendWithDark(color) end
			if ColorBoxCSF  then ColorBoxCSF.Text = hex end
			updateSliderPos(RedSlider,   s.r/255)
			updateSliderPos(GreenSlider, s.g/255)
			updateSliderPos(BlueSlider,  s.b/255)
			updateSliderPos(BlackSlider, s.hsvV)
			updateSC3SliderPos()
			updateRGBGradients()
			updateSC3Gradients()
			if CCF_HueFrame then CCF_HueFrame.BackgroundColor3 = Color3.fromHSV(s.hsvH,1,1) end
			if s.ccfOpen then updateCCF() end
		end
		if fireEvent and config.onChange then
			config.onChange(buildColorSequence(), s.keypoints, {
				title = title, timestamp = makeTimestamp(title),
			}, config.tag)
		end
	end

	local function selectKeypoint(index)
		local s = S()
		local n = #s.keypoints
		if index < 1 then index = n end
		if index > n then index = 1 end
		s.selectedIndex = index
		syncFromSelected()
		updateTemplateUI()
		updateAllGradients()
		updateKnobColors()
		if reg.activeInst == inst then loadDataToCSF() end
	end

	local function syncCSF()
		if not csf.Parent then return end
		local absPos    = ColorButton.AbsolutePosition
		local absSize   = ColorButton.AbsoluteSize
		local parentPos = csf.Parent.AbsolutePosition
		local curPos    = csf.Position
		csf.Position = UDim2.new(
			curPos.X.Scale, curPos.X.Offset,
			0, absPos.Y - parentPos.Y + absSize.Y
		)
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  applyColorSOS
	-- ════════════════════════════════════════════════════════════════════════════
	local function applyColorSOS(enabled, instant)
		local s = S()
		s.ccfOpen = enabled; s.sc3Mode = enabled
		local tweenInfo = TweenInfo.new(instant and 0 or 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		applySOSVisual(tweenInfo)
		if ChonseColorFrame then
			if not s.CCF_homePos    then s.CCF_homePos    = ChonseColorFrame.Position end
			if not s.savedCCF_Trans then s.savedCCF_Trans = saveTransparencies(ChonseColorFrame) end
			if instant then
				ChonseColorFrame.Visible = enabled
				if enabled then
					ChonseColorFrame.Position = s.CCF_homePos
					applyTransparencies(s.savedCCF_Trans, tweenInfo, 0)
				else
					ChonseColorFrame.Position = UDim2.new(1,0,0.27,0)
					applyTransparencies(s.savedCCF_Trans, tweenInfo, 1)
				end
			else
				if enabled then
					ChonseColorFrame.Position = UDim2.new(1,0,0.27,0)
					ChonseColorFrame.Visible  = true
					applyTransparencies(s.savedCCF_Trans, tweenInfo, 1)
					TweenService:Create(ChonseColorFrame, tweenInfo, { Position = s.CCF_homePos }):Play()
					task.delay(0.05, function() applyTransparencies(s.savedCCF_Trans, tweenInfo, 0) end)
				else
					applyTransparencies(s.savedCCF_Trans, tweenInfo, 1)
					TweenService:Create(ChonseColorFrame, tweenInfo, { Position = UDim2.new(1,0,0.27,0) }):Play()
					task.delay(tweenInfo.Time, function()
						if not S().ccfOpen then ChonseColorFrame.Visible = false end
					end)
				end
			end
		end
		if enabled then updateCCF() end
		if reg.activeInst ~= inst then return end
		if not reg.savedRGB_Trans and SettingRGB    then reg.savedRGB_Trans = saveTransparencies(SettingRGB)    end
		if not reg.savedSC3_Trans and SettingColor3 then reg.savedSC3_Trans = saveTransparencies(SettingColor3) end
		if instant then
			if SettingRGB then
				local cp = SettingRGB.Position
				SettingRGB.Position = UDim2.new(enabled and -0.5 or 0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingRGB.Visible  = not enabled
			end
			if SettingColor3 then
				local cp = SettingColor3.Position
				SettingColor3.Position = UDim2.new(enabled and 0.054 or 1, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
				SettingColor3.Visible  = enabled
			end
		else
			if enabled then
				if SettingRGB then
					local cp = SettingRGB.Position
					TweenService:Create(SettingRGB, tweenInfo, { Position = UDim2.new(-0.5, cp.X.Offset, cp.Y.Scale, cp.Y.Offset) }):Play()
					if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, tweenInfo, 1) end
				end
				if SettingColor3 then
					SettingColor3.Visible = true
					local cp = SettingColor3.Position
					SettingColor3.Position = UDim2.new(1, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
					TweenService:Create(SettingColor3, tweenInfo, { Position = UDim2.new(0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset) }):Play()
					if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, tweenInfo, 0) end
					updateSC3Gradients(); updateSC3SliderPos()
				end
			else
				if SettingColor3 then
					local cp = SettingColor3.Position
					TweenService:Create(SettingColor3, tweenInfo, { Position = UDim2.new(1, cp.X.Offset, cp.Y.Scale, cp.Y.Offset) }):Play()
					if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, tweenInfo, 1) end
					task.delay(0.2, function()
						if not S().sc3Mode and SettingColor3 then SettingColor3.Visible = false end
					end)
				end
				if SettingRGB then
					SettingRGB.Visible = true
					local cp = SettingRGB.Position
					SettingRGB.Position = UDim2.new(-0.5, cp.X.Offset, cp.Y.Scale, cp.Y.Offset)
					TweenService:Create(SettingRGB, tweenInfo, { Position = UDim2.new(0.054, cp.X.Offset, cp.Y.Scale, cp.Y.Offset) }):Play()
					if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, tweenInfo, 0) end
				end
			end
		end
	end

	applyColorSOS(false, true)

	-- ════════════════════════════════════════════════════════════════════════════
	--  OPEN / CLOSE CSF
	-- ════════════════════════════════════════════════════════════════════════════
	local function closeCSF(isSwitching)
		if reg.activeInst ~= inst then return end
		registerClose(inst)
		reg.activeInst = nil
		if reg.trackConn then reg.trackConn:Disconnect(); reg.trackConn = nil end
		destroyAllKnobs()
		if isSwitching then csf.Visible = true; return end
		local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		applyCSF_Trans(tweenInfo, 1)
		if reg.savedSOS_Trans then applyTransparencies(reg.savedSOS_Trans, tweenInfo, 1) end
		if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, tweenInfo, 1) end
		if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, tweenInfo, 1) end
		local s = S()
		if s.savedCCF_Trans then applyTransparencies(s.savedCCF_Trans, tweenInfo, 1) end
		task.delay(tweenInfo.Time, function()
			if reg.activeInst == nil then
				csf.Visible = false
				if reg.CSF_homePos then
					csf.Position = UDim2.new(
						reg.CSF_homePos.X.Scale, reg.CSF_homePos.X.Offset,
						csf.Position.Y.Scale,    csf.Position.Y.Offset
					)
				end
			end
		end)
	end

	local function openCSF()
		local prevInst    = reg.activeInst
		local isSwitching = (prevInst ~= nil and prevInst ~= inst)
		local s           = S()

		csf.Visible = true
		selectKeypoint(1)

		if not reg.savedCSF_Trans then reg.savedCSF_Trans = saveTransparencies(csf) end
		if GradientFrame then GradientFrame.Visible = true end
		local cb = GradientFrame and GradientFrame:FindFirstChild("CreateSliderGradientButton")
		if cb then cb.Active = true; cb.AutoButtonColor = true; cb:SetAttribute("_colorLocked", nil) end
		if not reg.savedRGB_Trans and SettingRGB       then reg.savedRGB_Trans = saveTransparencies(SettingRGB)       end
		if not reg.savedSC3_Trans and SettingColor3    then reg.savedSC3_Trans = saveTransparencies(SettingColor3)    end
		if not reg.savedSOS_Trans and SettingOfSetting then reg.savedSOS_Trans = saveTransparencies(SettingOfSetting) end
		if not s.savedCCF_Trans and ChonseColorFrame then
			s.savedCCF_Trans = saveTransparencies(ChonseColorFrame)
			s.CCF_homePos    = ChonseColorFrame.Position
		end

		if isSwitching then prevInst:_closeListExternal_switch() end
		registerOpen(inst)
		reg.activeInst = inst
		syncCSF()
		local currentPos = csf.Position
		reg.CSF_homePos = UDim2.new(currentPos.X.Scale, currentPos.X.Offset, currentPos.Y.Scale, currentPos.Y.Offset)
		local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local ti0       = TweenInfo.new(0)

		if isSwitching then
			csf.Visible = true
			loadDataToCSF()
			if GradientUIGrad then GradientUIGrad.Color = buildColorSequence() end
			restoreGradientFrame()
		else
			applyCSF_Trans(ti0, 1)
			if reg.savedSOS_Trans then applyTransparencies(reg.savedSOS_Trans, ti0, 1) end
			if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, ti0, 1) end
			if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, ti0, 1) end
			if s.savedCCF_Trans   then applyTransparencies(s.savedCCF_Trans,   ti0, 1) end
			csf.Visible = true
			loadDataToCSF()
			if GradientUIGrad then GradientUIGrad.Color = buildColorSequence() end
			restoreGradientFrame()
			applyCSF_Trans(tweenInfo, 0)
			applySOSVisual(tweenInfo)
			task.delay(0.05, function()
				if reg.activeInst ~= inst then return end
				local sv = S()
				local ti = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				if not sv.sc3Mode then
					if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, ti, 0) end
					if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, ti, 1) end
				else
					if reg.savedSC3_Trans then applyTransparencies(reg.savedSC3_Trans, ti, 0) end
					if reg.savedRGB_Trans then applyTransparencies(reg.savedRGB_Trans, ti, 1) end
				end
				if sv.ccfOpen and sv.savedCCF_Trans then
					applyTransparencies(sv.savedCCF_Trans, ti, 0)
				end
			end)
		end

		if reg.trackConn then reg.trackConn:Disconnect() end
		reg.trackConn = RunService.RenderStepped:Connect(function()
			if reg.activeInst ~= inst then
				reg.trackConn:Disconnect(); reg.trackConn = nil; return
			end
			syncCSF()
			syncKnobPositions()
			local p = csf.Position
			reg.CSF_homePos = UDim2.new(reg.CSF_homePos.X.Scale, reg.CSF_homePos.X.Offset, p.Y.Scale, p.Y.Offset)
		end)
		updateAllGradients()
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  SLIDER SETUP HELPER
	-- ════════════════════════════════════════════════════════════════════════════
	local function setupColorSlider(sliderBtn, parentFrame, onDrag)
		if not sliderBtn or not parentFrame then return end
		local dragging = false
		table.insert(sliderDrags, function() dragging = false end)
		local function getVal(inputX)
			local absX = parentFrame.AbsolutePosition.X
			local absW = parentFrame.AbsoluteSize.X
			if absW <= 0 then return 0 end
			return math.clamp((inputX - absX) / absW, 0, 1)
		end
		table.insert(conns, parentFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true; onDrag(getVal(input.Position.X))
			end
		end))
		table.insert(conns, sliderBtn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
			end
		end))
		table.insert(conns, UserInputService.InputChanged:Connect(function(input)
			if reg.activeInst ~= inst then dragging = false; return end
			if not dragging then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch then
				onDrag(getVal(input.Position.X))
			end
		end))
		table.insert(conns, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end))
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  CREATE BUTTON  ✅ Guard: chỉ inst đang active + là owner mới tạo keypoint
	-- ════════════════════════════════════════════════════════════════════════════
	local lastCreateTime = 0
	if CreateBtn then
		table.insert(conns, CreateBtn.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then return end

			-- ✅ Chỉ inst đang active + là owner của frame mới được tạo keypoint
			if reg.activeInst ~= inst then return end
			if not isOwner() then return end

			local now = tick()
			if now - lastCreateTime <= DOUBLE_CLICK_TIME then
				local absX = CreateBtn.AbsolutePosition.X
				local absW = CreateBtn.AbsoluteSize.X
				if absW <= 0 then return end
				local ratio = math.clamp((input.Position.X - absX) / absW, 0, 1)
				local sv    = S()
				if #sv.keypoints >= MAX_KEYPOINTS then return end
				for _, kp in ipairs(sv.keypoints) do
					if math.abs(kp.position - ratio) < MIN_POSITION_GAP then return end
				end
				local sampledColor = getColorAtPosition(ratio)
				local h, sat, v   = sampledColor:ToHSV()
				local newKP = {
					position   = ratio,
					color      = Color3.fromHSV(h, 1, 1),
					brightness = v,
					saturation = sat,
					locked     = false,
				}
				table.insert(sv.keypoints, newKP)
				table.sort(sv.keypoints, function(a, b) return a.position < b.position end)
				for i, kp in ipairs(sv.keypoints) do
					if kp == newKP then sv.selectedIndex = i; break end
				end
				rebuildAllKnobs()
				syncFromSelected()
				updateTemplateUI()
				updateAllGradients()
				if reg.activeInst == inst then loadDataToCSF() end
			end
			lastCreateTime = now
		end))
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  TEMPLATE SLIDERS
	-- ════════════════════════════════════════════════════════════════════════════
	setupColorSlider(SliderBtn, SliderFrame, function(ratio)
		local sv = S(); local kp = sv.keypoints[sv.selectedIndex]
		if not kp then return end
		kp.saturation = ratio; sv.hsvS = ratio
		local c = Color3.fromHSV(sv.hsvH, ratio, sv.hsvV)
		sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
		onKeypointChanged(true)
	end)

	setupColorSlider(DarkBtn, DarkFrame, function(ratio)
		local sv = S(); local kp = sv.keypoints[sv.selectedIndex]
		if not kp then return end
		kp.brightness = ratio; sv.hsvV = ratio
		local c = Color3.fromHSV(sv.hsvH, sv.hsvS, ratio)
		sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
		onKeypointChanged(true)
	end)

	-- ════════════════════════════════════════════════════════════════════════════
	--  CSF RGB / SC3 SLIDERS
	-- ════════════════════════════════════════════════════════════════════════════
	setupColorSlider(RedSlider, RedFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		local sv = S(); sv.r = math.floor(ratio*255+0.5)
		sv.hsvH, sv.hsvS, sv.hsvV = Color3.fromRGB(sv.r,sv.g,sv.b):ToHSV()
		local kp = sv.keypoints[sv.selectedIndex]
		if kp then kp.color = Color3.fromHSV(sv.hsvH,1,1); kp.saturation = sv.hsvS; kp.brightness = sv.hsvV end
		onKeypointChanged(true)
	end)
	setupColorSlider(GreenSlider, GreenFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		local sv = S(); sv.g = math.floor(ratio*255+0.5)
		sv.hsvH, sv.hsvS, sv.hsvV = Color3.fromRGB(sv.r,sv.g,sv.b):ToHSV()
		local kp = sv.keypoints[sv.selectedIndex]
		if kp then kp.color = Color3.fromHSV(sv.hsvH,1,1); kp.saturation = sv.hsvS; kp.brightness = sv.hsvV end
		onKeypointChanged(true)
	end)
	setupColorSlider(BlueSlider, BlueFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		local sv = S(); sv.b = math.floor(ratio*255+0.5)
		sv.hsvH, sv.hsvS, sv.hsvV = Color3.fromRGB(sv.r,sv.g,sv.b):ToHSV()
		local kp = sv.keypoints[sv.selectedIndex]
		if kp then kp.color = Color3.fromHSV(sv.hsvH,1,1); kp.saturation = sv.hsvS; kp.brightness = sv.hsvV end
		onKeypointChanged(true)
	end)
	setupColorSlider(BlackSlider, BlackFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		local sv = S(); sv.hsvV = ratio
		local c = Color3.fromHSV(sv.hsvH, sv.hsvS, ratio)
		sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
		local kp = sv.keypoints[sv.selectedIndex]
		if kp then kp.brightness = ratio end
		onKeypointChanged(true)
	end)
	setupColorSlider(SC3_HueSlider, SC3_HueFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		local sv = S(); sv.hsvH = ratio
		local c = Color3.fromHSV(ratio, sv.hsvS, sv.hsvV)
		sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
		local kp = sv.keypoints[sv.selectedIndex]
		if kp then kp.color = Color3.fromHSV(ratio,1,1) end
		onKeypointChanged(true); updateSC3Gradients()
	end)
	setupColorSlider(SC3_SatSlider, SC3_SatFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		local sv = S(); sv.hsvS = ratio
		local c = Color3.fromHSV(sv.hsvH, ratio, sv.hsvV)
		sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
		local kp = sv.keypoints[sv.selectedIndex]
		if kp then kp.saturation = ratio end
		onKeypointChanged(true); updateSC3Gradients()
	end)
	setupColorSlider(SC3_ValSlider, SC3_ValFrame, function(ratio)
		if reg.activeInst ~= inst then return end
		local sv = S(); sv.hsvV = ratio
		local c = Color3.fromHSV(sv.hsvH, sv.hsvS, ratio)
		sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
		local kp = sv.keypoints[sv.selectedIndex]
		if kp then kp.brightness = ratio end
		onKeypointChanged(true); updateSC3Gradients()
	end)

	-- ════════════════════════════════════════════════════════════════════════════
	--  CCF COLOR PICKER
	-- ════════════════════════════════════════════════════════════════════════════
	if CCF_ColorButton then
		local function applyPickerPos(inputX, inputY)
			if reg.activeInst ~= inst then return end
			local absPos  = CCF_ColorButton.AbsolutePosition
			local absSize = CCF_ColorButton.AbsoluteSize
			if absSize.X <= 0 or absSize.Y <= 0 then return end
			local sv = S()
			sv.hsvS = math.clamp((inputX - absPos.X) / absSize.X, 0, 1)
			sv.hsvV = 1 - math.clamp((inputY - absPos.Y) / absSize.Y, 0, 1)
			local c = Color3.fromHSV(sv.hsvH, sv.hsvS, sv.hsvV)
			sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
			local kp = sv.keypoints[sv.selectedIndex]
			if kp then kp.saturation = sv.hsvS; kp.brightness = sv.hsvV end
			onKeypointChanged(true); updateCCF()
		end
		table.insert(conns, CCF_ColorButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				S().ccfPickDrag = true; applyPickerPos(input.Position.X, input.Position.Y)
			end
		end))
		table.insert(conns, UserInputService.InputChanged:Connect(function(input)
			local sv = S()
			if reg.activeInst ~= inst then sv.ccfPickDrag = false; return end
			if not sv.ccfPickDrag then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch then
				applyPickerPos(input.Position.X, input.Position.Y)
			end
		end))
		table.insert(conns, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				S().ccfPickDrag = false
			end
		end))
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  CCF HUE BAR
	-- ════════════════════════════════════════════════════════════════════════════
	if CCF_HueFrame then
		local function applyHue(inputX)
			if reg.activeInst ~= inst then return end
			local sv    = S()
			local h, _, _ = CCF_HueFrame.BackgroundColor3:ToHSV()
			sv.hsvH = h
			local c = Color3.fromHSV(sv.hsvH, sv.hsvS, sv.hsvV)
			sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
			local kp = sv.keypoints[sv.selectedIndex]
			if kp then kp.color = Color3.fromHSV(sv.hsvH, 1, 1) end
			onKeypointChanged(true); updateCCF()
		end
		table.insert(conns, CCF_HueFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				S().hueDrag = true; applyHue(input.Position.X)
			end
		end))
		table.insert(conns, UserInputService.InputChanged:Connect(function(input)
			local sv = S()
			if reg.activeInst ~= inst then sv.hueDrag = false; return end
			if not sv.hueDrag then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch then
				applyHue(input.Position.X)
			end
		end))
		table.insert(conns, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				S().hueDrag = false
			end
		end))
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  TEXTBOXES
	-- ════════════════════════════════════════════════════════════════════════════
	if CCF_HueText then
		table.insert(conns, CCF_HueText.FocusLost:Connect(function()
			if reg.activeInst ~= inst then return end
			local sv = S(); local num = tonumber(CCF_HueText.Text)
			if num then
				sv.hsvH = math.clamp(num,0,360)/360
				local c = Color3.fromHSV(sv.hsvH,sv.hsvS,sv.hsvV)
				sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
				local kp = sv.keypoints[sv.selectedIndex]
				if kp then kp.color = Color3.fromHSV(sv.hsvH,1,1) end
				onKeypointChanged(true); updateCCF()
			else CCF_HueText.Text = tostring(math.floor(sv.hsvH*360+0.5)) end
		end))
	end
	if CCF_ValText then
		table.insert(conns, CCF_ValText.FocusLost:Connect(function()
			if reg.activeInst ~= inst then return end
			local sv = S(); local num = tonumber(CCF_ValText.Text)
			if num then
				sv.hsvV = math.clamp(num,0,100)/100
				local c = Color3.fromHSV(sv.hsvH,sv.hsvS,sv.hsvV)
				sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
				local kp = sv.keypoints[sv.selectedIndex]
				if kp then kp.brightness = sv.hsvV end
				onKeypointChanged(true); updateCCF()
			else CCF_ValText.Text = tostring(math.floor(sv.hsvV*100+0.5)) end
		end))
	end
	if CCF_Color3Text then
		table.insert(conns, CCF_Color3Text.FocusLost:Connect(function()
			if reg.activeInst ~= inst then return end
			local sv = S(); local text = CCF_Color3Text.Text:gsub("%s","")
			local nr, ng, nb
			if text:sub(1,1) == "#" then
				local hex = text:sub(2)
				if #hex == 6 then nr=tonumber(hex:sub(1,2),16); ng=tonumber(hex:sub(3,4),16); nb=tonumber(hex:sub(5,6),16) end
			end
			if nr and ng and nb then
				sv.r = math.clamp(math.floor(nr+0.5),0,255); sv.g = math.clamp(math.floor(ng+0.5),0,255); sv.b = math.clamp(math.floor(nb+0.5),0,255)
				sv.hsvH, sv.hsvS, sv.hsvV = Color3.fromRGB(sv.r,sv.g,sv.b):ToHSV()
				local kp = sv.keypoints[sv.selectedIndex]
				if kp then kp.color = Color3.fromHSV(sv.hsvH,1,1); kp.saturation = sv.hsvS; kp.brightness = sv.hsvV end
				onKeypointChanged(true); updateCCF()
			else CCF_Color3Text.Text = toHex(sv.r,sv.g,sv.b) end
		end))
	end
	if ColorBoxCSF then
		table.insert(conns, ColorBoxCSF.FocusLost:Connect(function()
			if reg.activeInst ~= inst then return end
			local sv = S(); local text = ColorBoxCSF.Text:gsub("%s","")
			local nr, ng, nb
			if text:sub(1,1) == "#" then
				local hex = text:sub(2)
				if #hex == 6 then nr=tonumber(hex:sub(1,2),16); ng=tonumber(hex:sub(3,4),16); nb=tonumber(hex:sub(5,6),16)
				elseif #hex == 3 then nr=tonumber(hex:sub(1,1):rep(2),16); ng=tonumber(hex:sub(2,2):rep(2),16); nb=tonumber(hex:sub(3,3):rep(2),16) end
			else local parts = text:split(","); if #parts == 3 then nr=tonumber(parts[1]); ng=tonumber(parts[2]); nb=tonumber(parts[3]) end end
			if nr and ng and nb then
				sv.r = math.clamp(math.floor(nr+0.5),0,255); sv.g = math.clamp(math.floor(ng+0.5),0,255); sv.b = math.clamp(math.floor(nb+0.5),0,255)
				sv.hsvH, sv.hsvS, sv.hsvV = Color3.fromRGB(sv.r,sv.g,sv.b):ToHSV()
				local kp = sv.keypoints[sv.selectedIndex]
				if kp then kp.color = Color3.fromHSV(sv.hsvH,1,1); kp.saturation = sv.hsvS; kp.brightness = sv.hsvV end
				onKeypointChanged(true)
			else ColorBoxCSF.Text = toHex(sv.r,sv.g,sv.b) end
		end))
	end
	if ColorBox then
		table.insert(conns, ColorBox.FocusLost:Connect(function()
			local sv = S(); local text = ColorBox.Text:gsub("%s","")
			local nr, ng, nb
			if text:sub(1,1) == "#" then
				local hex = text:sub(2)
				if #hex == 6 then nr=tonumber(hex:sub(1,2),16); ng=tonumber(hex:sub(3,4),16); nb=tonumber(hex:sub(5,6),16)
				elseif #hex == 3 then nr=tonumber(hex:sub(1,1):rep(2),16); ng=tonumber(hex:sub(2,2):rep(2),16); nb=tonumber(hex:sub(3,3):rep(2),16) end
			else local parts = text:split(","); if #parts == 3 then nr=tonumber(parts[1]); ng=tonumber(parts[2]); nb=tonumber(parts[3]) end end
			if nr and ng and nb then
				sv.r = math.clamp(math.floor(nr+0.5),0,255); sv.g = math.clamp(math.floor(ng+0.5),0,255); sv.b = math.clamp(math.floor(nb+0.5),0,255)
				sv.hsvH, sv.hsvS, sv.hsvV = Color3.fromRGB(sv.r,sv.g,sv.b):ToHSV()
				local kp = sv.keypoints[sv.selectedIndex]
				if kp then kp.color = Color3.fromHSV(sv.hsvH,1,1); kp.saturation = sv.hsvS; kp.brightness = sv.hsvV end
				onKeypointChanged(true)
			else ColorBox.Text = toHex(sv.r,sv.g,sv.b) end
		end))
	end
	if DarkTextBox then
		table.insert(conns, DarkTextBox.FocusLost:Connect(function()
			local sv = S(); local num = tonumber(DarkTextBox.Text)
			if num then
				local ratio = math.clamp(num, 0, 1); sv.hsvV = ratio
				local c = Color3.fromHSV(sv.hsvH, sv.hsvS, ratio)
				sv.r = math.floor(c.R*255+0.5); sv.g = math.floor(c.G*255+0.5); sv.b = math.floor(c.B*255+0.5)
				local kp = sv.keypoints[sv.selectedIndex]
				if kp then kp.brightness = ratio end
				onKeypointChanged(true)
			else DarkTextBox.Text = string.format("%.2f", sv.hsvV) end
		end))
	end

	-- ════════════════════════════════════════════════════════════════════════════
	--  BUTTONS
	-- ════════════════════════════════════════════════════════════════════════════
	if CSF_InfoButton and CSF_InfoFrame then
		local hoverTween
		CSF_InfoButton.MouseEnter:Connect(function()
			if reg.activeInst ~= inst then return end
			if hoverTween then hoverTween:Cancel() end
			hoverTween = TweenService:Create(CSF_InfoFrame,
				TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundColor3 = getCurrentColor() }
			):Play()
		end)
		CSF_InfoButton.MouseLeave:Connect(function()
			if reg.activeInst ~= inst then return end
			if hoverTween then hoverTween:Cancel() end
			hoverTween = TweenService:Create(CSF_InfoFrame,
				TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundColor3 = Color3.fromRGB(0,0,0) }
			):Play()
		end)
	end

	if LeftBtn then
		table.insert(conns, LeftBtn.MouseButton1Click:Connect(function()
			selectKeypoint(S().selectedIndex - 1)
		end))
	end
	if RightBtn then
		table.insert(conns, RightBtn.MouseButton1Click:Connect(function()
			selectKeypoint(S().selectedIndex + 1)
		end))
	end

	table.insert(conns, ColorButton.MouseButton1Click:Connect(function()
		if reg.activeInst == inst then closeCSF(false) else openCSF() end
	end))

	if SettingOfSetting then
		table.insert(conns, SettingOfSetting.MouseButton1Click:Connect(function()
			if reg.activeInst ~= inst then return end
			applyColorSOS(not S().ccfOpen, false)
		end))
	end

	-- ── Init knobs sau 1 frame ────────────────────────────────────────────────
	if GradientSliderTpl and GradientSliderFrame then
		GradientSliderTpl.Visible = false
		local initConn
		initConn = RunService.RenderStepped:Connect(function()
			initConn:Disconnect()
			-- ✅ Không rebuild nếu frame đang có owner khác (CSF đang mở)
			if not GradientKnobRegistry[GradientSliderFrame]
				or GradientKnobRegistry[GradientSliderFrame].inst == inst then
				rebuildAllKnobs()
				syncKnobPositions()
				updateAllGradients()
				updateKnobColors()
			end
		end)
	end

	syncFromSelected()
	updateTemplateUI()

	-- ════════════════════════════════════════════════════════════════════════════
	--  PUBLIC API
	-- ════════════════════════════════════════════════════════════════════════════
	inst.Frame       = settingFrame
	inst._title      = title
	inst._tag        = config.tag
	inst._isGradient = true

	function inst:getValue()
		return buildColorSequence()
	end

	function inst:getKeypoints()
		return GradientStateRegistry[self].keypoints
	end

	function inst:getState()
		local sv  = GradientStateRegistry[self]
		local out = {}
		for k, v in pairs(sv) do out[k] = v end
		return out
	end

	function inst:setValue(def)
		local sv = GradientStateRegistry[self]
		sv.keypoints     = parseDefault(def)
		sv.selectedIndex = math.clamp(sv.selectedIndex, 1, #sv.keypoints)
		syncFromSelected()
		updateTemplateUI()
		updateAllGradients()
		if reg.activeInst == self then loadDataToCSF() end
	end

	function inst:setOnChange(fn)
		config.onChange = fn
	end

	function inst:selectKeypoint(index)
		selectKeypoint(index)
	end

	function inst:_closeListExternal()
		closeCSF(false)
	end

	function inst:_closeListExternal_switch()
		local sv = GradientStateRegistry[self]
		sv.ccfPickDrag = false
		sv.hueDrag     = false
		for _, resetFn in ipairs(sliderDrags) do resetFn() end
		closeCSF(true)
	end

	function inst:setVisible(bool)
		settingFrame.Visible = bool
	end

	function inst:destroy()
		closeCSF(false)
		-- ✅ Dọn ownership registry
		local reg2 = GradientSliderFrame and GradientKnobRegistry[GradientSliderFrame]
		if reg2 and reg2.inst == inst then
			for _, entry in ipairs(reg2.knobList) do
				if entry.clone and entry.clone.Parent then entry.clone:Destroy() end
			end
			GradientKnobRegistry[GradientSliderFrame] = nil
		end
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		GradientStateRegistry[self] = nil
		createdSliders[settingFrame] = nil
		if settingFrame.Parent then settingFrame:Destroy() end
	end

	createdSliders[settingFrame] = inst
	return inst
end

-- ════════════════════════════════════════════════════════════
--  SliderModule.Key  |  Keybind setting
--
--  Config:
--    template  (Frame)    : KeyTemplate
--    parent    (Frame)    : frame cha
--    title     (string)   : tên hiển thị
--    default   (KeyCode)  : Enum.KeyCode mặc định (default Enum.KeyCode.E)
--    onChange  (function) : callback(keyName, keyCode, info, tag)
--                             keyName  : string — tên phím, vd "E", "LeftShift"
--                             keyCode  : Enum.KeyCode — dùng trực tiếp được
--                             info     : { title, timestamp }
--                             tag      : tag gửi kèm
--    tag       (any)      : tag tùy chỉnh gửi kèm onChange
--
--  Cấu trúc KeyTemplate:
--    KeyTemplate (Frame)
--    ├── UIAspectRatioConstraint
--    ├── UICorner
--    ├── UIGradient
--    └── InfoFrame
--        ├── UICorner
--        ├── ChangeButton (Frame)    ← bấm để vào chế độ chờ phím
--        │   ├── UIAspectRatioConstraint
--        │   ├── UICorner
--        │   ├── UIGradient
--        │   ├── Decor (Frame)       ← shiny hover effect (UIGradient bên trong)
--        │   └── KeyText (TextLabel) ← hiển thị tên phím
--        ├── NameSetting (TextLabel) ← tên setting
--        │   └── InfoSetting (TextLabel) ← "KEY : E"
--        └── ButtonDelta (Frame)     ← hover effect
-- ════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════
--  SliderModule.Key  |  Keybind setting
--
--  Config:
--    template       (Frame)      : KeyTemplate
--    parent         (Frame)      : frame cha
--    title          (string)     : tên hiển thị
--    default        (KeyCode)    : Enum.KeyCode mặc định (default Enum.KeyCode.E)
--    onChange       (function)   : callback(keyName, keyCode, info, tag)
--    tag            (any)        : tag tùy chỉnh gửi kèm onChange
--    blacklist      (table)      : { Enum.KeyCode.X, ... } — phím bị cấm
--    allowDuplicate (bool)       : true = cho phép trùng phím (default false)
-- ════════════════════════════════════════════════════════════

function SliderModule.Key(config)
	assert(config.parent, "[SliderModule.Key] Thiếu 'parent'")

	local template = config.template
		or (script:FindFirstChild("KeyTemplate"))
	assert(template, "[SliderModule.Key] Không tìm thấy template — truyền vào hoặc đặt 'KeyTemplate' trong ModuleScript")

	local title          = config.title          or "Key"
	local defaultKey     = config.default        or Enum.KeyCode.E
	local allowDuplicate = config.allowDuplicate == true   -- default false
	local isAdvance      = config.isAdvance   == true
	local advanceFrame   = config.advanceFrame  -- KeyChangeFrame
	local blacklist      = {}
	if config.blacklist then
		for _, kc in ipairs(config.blacklist) do
			blacklist[kc] = true
		end
	end

	-- ── Color lists ─────────────────────────────────────────────
	-- warm    : vàng cam  (255, 200, 80)
	-- recomen : xanh lá   (100, 220, 120)
	-- redlist : đỏ        (255, 90,  90)
	local warmList    = {}
	local recomList   = {}
	local redList     = {}
	if config.warm then
		for _, kc in ipairs(config.warm) do warmList[kc] = true end
	end
	if config.recomen then
		for _, kc in ipairs(config.recomen) do recomList[kc] = true end
	end
	if config.redlist then
		for _, kc in ipairs(config.redlist) do redList[kc] = true end
	end

	local LIST_COLORS = {
		warm    = Color3.fromRGB(255, 200, 80),
		recomen = Color3.fromRGB(100, 220, 120),
		redlist = Color3.fromRGB(255, 90,  90),
		default = Color3.fromRGB(255, 255, 255),
	}

	local function getKeyColor(keyCode)
		if warmList[keyCode]  then return LIST_COLORS.warm    end
		if recomList[keyCode] then return LIST_COLORS.recomen end
		if redList[keyCode]   then return LIST_COLORS.redlist  end
		return LIST_COLORS.default
	end

	local frame = template:Clone()
	frame.Name    = "Setting_" .. title
	frame.Visible = true
	frame.Parent  = config.parent

	local InfoFrame    = frame:FindFirstChild("InfoFrame")
	local ChangeButton = InfoFrame and InfoFrame:FindFirstChild("ChangeButton")
	local KeyText      = ChangeButton and ChangeButton:FindFirstChild("KeyText")
	local Decor        = ChangeButton and ChangeButton:FindFirstChild("Decor")
	local TitleLabel   = InfoFrame and InfoFrame:FindFirstChild("NameSetting")
	local InfoSetting  = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")

	local KeyButton    = advanceFrame and advanceFrame:FindFirstChild("KeyButton")
	local CancelButton = advanceFrame and advanceFrame:FindFirstChild("CancelButton")
	local AdvKeyText   = KeyButton and KeyButton:FindFirstChild("KeyText")
	local TableButton  = advanceFrame and advanceFrame:FindFirstChild("TableButton")
	local KeyBroad     = advanceFrame and advanceFrame:FindFirstChild("KeyBroad")
	local BlackFrame   = advanceFrame and advanceFrame:FindFirstChild("BlackFrame")
	local TIPText      = advanceFrame and advanceFrame:FindFirstChild("TIPText")
	local IconFrame    = TableButton  and TableButton:FindFirstChild("IconFrame")

	-- Lưu giá trị base của các element trong advanceFrame
	local BASE = {}
	if BlackFrame then
		BASE.blackTrans = BlackFrame.BackgroundTransparency
	end
	if TIPText then
		BASE.tipPos   = TIPText.Position
		BASE.tipTrans = TIPText.TextTransparency
	end
	if KeyButton then
		BASE.keyBgTrans   = KeyButton.BackgroundTransparency
		local lbl  = KeyButton:FindFirstChildWhichIsA("TextLabel")
		local dec  = KeyButton:FindFirstChild("Decor")
		BASE.keyTextTrans  = lbl and lbl.TextTransparency or 0
		BASE.keyDecorTrans = dec and dec.BackgroundTransparency or 1
	end
	if CancelButton then
		BASE.cancelBgTrans = CancelButton.BackgroundTransparency
		local lbl  = CancelButton:FindFirstChildWhichIsA("TextLabel")
		local dec  = CancelButton:FindFirstChild("Decor")
		BASE.cancelTextTrans  = lbl and lbl.TextTransparency or 0
		BASE.cancelDecorTrans = dec and dec.BackgroundTransparency or 1
	end
	if TableButton then
		BASE.tableBgTrans = TableButton.BackgroundTransparency
		local lbl  = TableButton:FindFirstChildWhichIsA("TextLabel")
		local dec  = TableButton:FindFirstChild("Decor")
		BASE.tableTextTrans  = lbl and lbl.TextTransparency or 0
		BASE.tableDecorTrans = dec and dec.BackgroundTransparency or 1
		BASE.iconTrans = IconFrame and IconFrame.ImageTransparency or 0
	end

	if KeyBroad then
		BASE.broadPos = KeyBroad.Position
	end
	local ADV_EXP_OUT  = TweenInfo.new(0.45, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
	local ADV_EXP_IN   = TweenInfo.new(0.35, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
	local ADV_EXP_OUT2 = TweenInfo.new(0.5,  Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)

	local advTweensRef = { list = {} }  -- shared tween list, init ngay để trackTween/cancelAdvTweens luôn hoạt động

	-- Quản lý tween đang chạy (advTweensRef luôn valid từ khai báo ngoài)
	local function cancelAdvTweens()
		for _, t in ipairs(advTweensRef.list) do t:Cancel() end
		advTweensRef.list = {}
	end
	local function trackTween(t)
		table.insert(advTweensRef.list, t)
		t:Play()
	end

	-- ── KeyBroad layout mapping ──────────────────────────────
	-- Thứ tự: trái → phải, trên → dưới (theo layout bàn phím thật)
	-- { layoutOrder, tên hiển thị, Enum.KeyCode }
	local KEY_MAP = {
		-- Hàng 1: Function keys
		{  1, "ESC",      Enum.KeyCode.Escape },
		{  2, "F1",       Enum.KeyCode.F1 },
		{  3, "F2",       Enum.KeyCode.F2 },
		{  4, "F3",       Enum.KeyCode.F3 },
		{  5, "F4",       Enum.KeyCode.F4 },
		{  6, "F5",       Enum.KeyCode.F5 },
		{  7, "F6",       Enum.KeyCode.F6 },
		{  8, "F7",       Enum.KeyCode.F7 },
		{  9, "F8",       Enum.KeyCode.F8 },
		{ 10, "F9",       Enum.KeyCode.F9 },
		{ 11, "F10",      Enum.KeyCode.F10 },
		{ 12, "F11",      Enum.KeyCode.F11 },
		{ 13, "F12",      Enum.KeyCode.F12 },
		{ 14, "PRT SCR",  Enum.KeyCode.Print },
		{ 15, "DELETE",   Enum.KeyCode.Delete },
		-- Hàng 2: Numbers
		{ 16, "`",        Enum.KeyCode.Backquote },
		{ 17, "1",        Enum.KeyCode.One },
		{ 18, "2",        Enum.KeyCode.Two },
		{ 19, "3",        Enum.KeyCode.Three },
		{ 20, "4",        Enum.KeyCode.Four },
		{ 21, "5",        Enum.KeyCode.Five },
		{ 22, "6",        Enum.KeyCode.Six },
		{ 23, "7",        Enum.KeyCode.Seven },
		{ 24, "8",        Enum.KeyCode.Eight },
		{ 25, "9",        Enum.KeyCode.Nine },
		{ 26, "0",        Enum.KeyCode.Zero },
		{ 27, "-",        Enum.KeyCode.Minus },
		{ 28, "=",        Enum.KeyCode.Equals },
		{ 29, "BACKSPACE",Enum.KeyCode.Backspace },
		{ 30, "HOME",     Enum.KeyCode.Home },
		-- Hàng 3: QWERTY
		{ 31, "TAB",      Enum.KeyCode.Tab },
		{ 32, "Q",        Enum.KeyCode.Q },
		{ 33, "W",        Enum.KeyCode.W },
		{ 34, "E",        Enum.KeyCode.E },
		{ 35, "R",        Enum.KeyCode.R },
		{ 36, "T",        Enum.KeyCode.T },
		{ 37, "Y",        Enum.KeyCode.Y },
		{ 38, "U",        Enum.KeyCode.U },
		{ 39, "I",        Enum.KeyCode.I },
		{ 40, "O",        Enum.KeyCode.O },
		{ 41, "P",        Enum.KeyCode.P },
		{ 42, "[",        Enum.KeyCode.LeftBracket },
		{ 43, "]",        Enum.KeyCode.RightBracket },
		{ 44, "\\",       Enum.KeyCode.BackSlash },
		{ 45, "PGUB",     Enum.KeyCode.PageUp },
		-- Hàng 4: ASDF
		{ 46, "CAPS LOCK",Enum.KeyCode.CapsLock },
		{ 47, "A",        Enum.KeyCode.A },
		{ 48, "S",        Enum.KeyCode.S },
		{ 49, "D",        Enum.KeyCode.D },
		{ 50, "F",        Enum.KeyCode.F },
		{ 51, "G",        Enum.KeyCode.G },
		{ 52, "H",        Enum.KeyCode.H },
		{ 53, "J",        Enum.KeyCode.J },
		{ 54, "K",        Enum.KeyCode.K },
		{ 55, "L",        Enum.KeyCode.L },
		{ 56, ";",        Enum.KeyCode.Semicolon },
		{ 57, "'",        Enum.KeyCode.Quote },
		{ 58, "ENTER",    Enum.KeyCode.Return },
		{ 59, "PGDN",     Enum.KeyCode.PageDown },
		-- Hàng 5: ZXCV
		{ 60, "SHIFT",    Enum.KeyCode.LeftShift },
		{ 61, "Z",        Enum.KeyCode.Z },
		{ 62, "X",        Enum.KeyCode.X },
		{ 63, "C",        Enum.KeyCode.C },
		{ 64, "V",        Enum.KeyCode.V },
		{ 65, "B",        Enum.KeyCode.B },
		{ 66, "N",        Enum.KeyCode.N },
		{ 67, "M",        Enum.KeyCode.M },
		{ 68, ",",        Enum.KeyCode.Comma },
		{ 69, ".",        Enum.KeyCode.Period },
		{ 70, "/",        Enum.KeyCode.Slash },
		{ 71, "SHIFT",    Enum.KeyCode.RightShift },
		{ 72, "UP",       Enum.KeyCode.Up },
		{ 73, "END",      Enum.KeyCode.End },
		-- Hàng 6: Bottom row
		{ 74, "CTRL",     Enum.KeyCode.LeftControl },
		{ 75, "WD",       Enum.KeyCode.LeftSuper },
		{ 76, "ALT",      Enum.KeyCode.LeftAlt },
		{ 77, "SPACE",    Enum.KeyCode.Space },
		{ 78, "\\",       Enum.KeyCode.BackSlash },
		{ 79, "ALT GR",   Enum.KeyCode.RightAlt },
		{ 80, "FN",       Enum.KeyCode.F },
		{ 81, "CPL",      Enum.KeyCode.ScrollLock },
		{ 82, "LF",       Enum.KeyCode.Left },
		{ 83, "DW",       Enum.KeyCode.Down },
		{ 84, "RG",       Enum.KeyCode.Right },
	}

	-- ── Build lookup dictionary từ KEY_MAP ──────────────────
	-- KEY_MAP là array { order, name, keyCode }
	-- KEY_MAP_LOOKUP["ESC"] = { order=1, keyCode=Enum.KeyCode.Escape }
	-- Với key trùng tên (SHIFT, \): dùng thêm suffix "_2", "_3"...
	local KEY_MAP_LOOKUP = {}
	local KEY_MAP_ORDERED = {}   -- dùng để set LayoutOrder theo index trong list
	for _, entry in ipairs(KEY_MAP) do
		local order   = entry[1]
		local name    = entry[2]
		local keyCode = entry[3]
		local key     = name:upper():gsub("%s+", "")
		-- Nếu đã tồn tại thì thêm suffix _2, _3...
		if KEY_MAP_LOOKUP[key] then
			local i = 2
			while KEY_MAP_LOOKUP[key .. "_" .. i] do i = i + 1 end
			key = key .. "_" .. i
		end
		KEY_MAP_LOOKUP[key] = { order = order, keyCode = keyCode, displayName = name }
		table.insert(KEY_MAP_ORDERED, { key = key, order = order, keyCode = keyCode, displayName = name })
	end

	assert(InfoFrame,    "[SliderModule.Key] Thiếu 'InfoFrame'")
	assert(ChangeButton, "[SliderModule.Key] Thiếu 'ChangeButton'")
	assert(KeyText,      "[SliderModule.Key] Thiếu 'KeyText'")

	if TitleLabel then TitleLabel.Text = title end

	-- Setup ButtonDelta hover
	setupButtonDelta(frame)

	-- ── Decor shiny effect ───────────────────────────────────
	-- ── Generic: chạy Decor shine trên bất kỳ button nào có Decor/UIGradient ──
	--   ctx = { t1, t2, ct1, ct2 }  — bảng tween riêng cho mỗi button
	local function makeButtonShine(decorFrame, withFlash, ctx)
		if not decorFrame then return end
		local grad     = decorFrame:FindFirstChildWhichIsA("UIGradient")
		if not grad then return end

		local BASE_OFF  = Vector2.new(-0.3, 0)
		local BASE_BT   = decorFrame.BackgroundTransparency

		if ctx.t1 then ctx.t1:Cancel() end
		if ctx.t2 then ctx.t2:Cancel() end

		grad.Offset = BASE_OFF

		local infoDown = TweenInfo.new(0.45, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
		local infoUp   = TweenInfo.new(0.4,  Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)

		ctx.t1 = TweenService:Create(grad, infoDown, { Offset = Vector2.new(0.7, 0.7) })

		if withFlash then
			if ctx.ct2 then ctx.ct2:Cancel() end
			decorFrame.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
			decorFrame.BackgroundTransparency = 0.8
			ctx.ct1 = TweenService:Create(decorFrame, infoDown, {
				BackgroundColor3       = Color3.fromRGB(255, 255, 255),
				BackgroundTransparency = 0,
			})
			ctx.ct1:Play()
		end

		ctx.t1.Completed:Connect(function(state)
			if state ~= Enum.PlaybackState.Completed then return end
			grad.Offset = Vector2.new(-1, -1)
			if withFlash then
				if ctx.ct1 then ctx.ct1:Cancel() end
				decorFrame.BackgroundTransparency = 0.8
				ctx.ct2 = TweenService:Create(decorFrame, infoDown, {
					BackgroundColor3       = Color3.new(0, 0, 0),
					BackgroundTransparency = BASE_BT,
				})
				ctx.ct2:Play()
			end
			ctx.t2 = TweenService:Create(grad, infoUp, { Offset = BASE_OFF })
			ctx.t2:Play()
		end)

		ctx.t1:Play()
	end

	-- Tween context riêng cho ChangeButton (Decor)
	local ctxChange = {}
	local function playDecorShine(withFlash)
		makeButtonShine(Decor, withFlash, ctxChange)
	end


	-- ── Self object ──────────────────────────────────────────
	local self = setmetatable({
		Frame      = frame,
		_title     = title,
		_tag       = config.tag,
		_value     = defaultKey,
		_onChange  = config.onChange,
		_conns     = {},
		_waiting   = false,
		_preview   = nil,   -- KeyCode đang preview (chưa confirm) — chỉ dùng khi isAdvance
		_blacklist = blacklist,
		_advKeyText = AdvKeyText,
	}, SliderModule)

	local keyData                  = nil  -- shared nếu dùng chung advanceFrame
	local closeKeyBroadFn          = nil  -- set sau khi KeyBroad setup xong
	local cancelKeyTweensFn        = nil
	local resetAllKeysFn           = nil
	local openKeyBroadFn           = nil  -- shared broad functions
	local closeKeyBroadDirectFn    = nil
	local closeKeyBroadFromCenterFn= nil
	local isBroadOpenRef           = { value = false }  -- ref table để share state
	local activeInstRef            = nil  -- pointer đến instance đang active, shared
	-- advTweensRef đã khai báo phía trên (trước cancelAdvTweens/trackTween)

	-- ── Helpers ──────────────────────────────────────────────
	local function getKeyName(keyCode)
		local full = tostring(keyCode)
		return full:match("KeyCode%.(.+)$") or full
	end

	-- Gán lên self để activeInstRef.inst có thể gọi khi bấm phím trên KeyBroad
	self._getKeyName  = getKeyName
	self._getKeyColor = getKeyColor

	local function applyKey(keyCode, fireEvent)
		self._value   = keyCode
		self._waiting = false
		keyReg_exitWaiting(self)
		keyReg_set(self, keyCode)

		local name  = getKeyName(keyCode)
		local color = getKeyColor(keyCode)

		if KeyText then
			KeyText.Text      = name
			KeyText.TextColor3 = color
		end
		if AdvKeyText then
			AdvKeyText.TextColor3 = color
		end
		if InfoSetting then InfoSetting.Text = "KEY : " .. name end

		if fireEvent then
			playDecorShine(true)
		end

		if fireEvent and self._onChange then
			self._onChange(name, keyCode, {
				title     = title,
				timestamp = makeTimestamp(title),
			}, self._tag)
		end
	end

	local function closeAdvFrame(isSwitching)
		if not advanceFrame then return end
		if not advanceFrame.Visible then return end

		registerClose(self)
		self._waiting = false
		self._preview = nil
		keyReg_exitWaiting(self)

		-- Xóa pointer nếu đang trỏ về self này
		if activeInstRef and activeInstRef.inst == self then
			activeInstRef.inst = nil
		end

		cancelAdvTweens()

		-- Đóng bàn phím luôn nếu đang mở — reset ngay lập tức không chờ tween
		if closeKeyBroadFn then closeKeyBroadFn(nil, "closeAdvFrame") end
		if KeyBroad then
			if cancelKeyTweensFn then cancelKeyTweensFn() end
			KeyBroad.Visible = false
			if BASE.broadPos then
				KeyBroad.Position = UDim2.new(
					BASE.broadPos.X.Scale, BASE.broadPos.X.Offset,
					3, BASE.broadPos.Y.Offset
				)
			end
			-- Khi switch: KHÔNG reset phím — instance mới sẽ show ngay sau
			if not isSwitching and resetAllKeysFn then resetAllKeysFn() end
		end

		-- Khi switch: giữ frame visible, không tween đóng — instance mới sẽ tween mở đè lên
		if isSwitching then
			advanceFrame.Visible = true
			return
		end

		-- Fade out tất cả buttons cùng lúc
		local function fadeOutBtn(btn, icon)
			if not btn then return end
			local lbl = btn:FindFirstChildWhichIsA("TextLabel")
			local dec = btn:FindFirstChild("Decor")
			trackTween(TweenService:Create(btn, ADV_EXP_IN, { BackgroundTransparency = 1 }))
			if lbl  then trackTween(TweenService:Create(lbl,  ADV_EXP_IN, { TextTransparency       = 1 })) end
			if dec  then trackTween(TweenService:Create(dec,  ADV_EXP_IN, { BackgroundTransparency = 1 })) end
			if icon then trackTween(TweenService:Create(icon, ADV_EXP_IN, { ImageTransparency      = 1 })) end
		end
		fadeOutBtn(KeyButton)
		fadeOutBtn(CancelButton)
		fadeOutBtn(TableButton, IconFrame)

		-- TIPText bay lên + fade out
		if TIPText then
			local offPos = UDim2.new(
				BASE.tipPos.X.Scale, BASE.tipPos.X.Offset,
				3, BASE.tipPos.Y.Offset
			)
			trackTween(TweenService:Create(TIPText, ADV_EXP_IN, { Position        = offPos }))
			trackTween(TweenService:Create(TIPText, ADV_EXP_IN, { TextTransparency = 1     }))
		end

		-- BlackFrame fade out → ẩn frame sau khi xong
		if BlackFrame then
			local t = TweenService:Create(BlackFrame, ADV_EXP_IN, { BackgroundTransparency = 1 })
			t.Completed:Connect(function(state)
				if state == Enum.PlaybackState.Completed then
					advanceFrame.Visible = false
				end
			end)
			trackTween(t)
		else
			advanceFrame.Visible = false
		end
	end

	local function openAdvFrame()
		-- Detect switch: advanceFrame đang visible từ instance khác
		local isSwitching = advanceFrame and advanceFrame.Visible

		-- Đóng instance đang mở (nếu có), truyền isSwitching để giữ frame visible
		if isSwitching then
			local prevInst = nil
			for other in pairs(openRegistry) do
				if other ~= self then prevInst = other; break end
			end
			if prevInst and prevInst._closeListExternal_switch then
				prevInst:_closeListExternal_switch()
				-- Xóa khỏi openRegistry ngay lập tức để registerOpen bên dưới
				-- không tìm thấy và gọi _closeListExternal() lần 2 (gây fade out frame)
				openRegistry[prevInst] = nil
			end
		end

		registerOpen(self)
		self._waiting = true
		self._preview = self._value
		keyReg_enterWaiting(self)

		-- Cập nhật pointer → từ đây mọi click trên KeyBroad thuộc về self này
		if activeInstRef then
			activeInstRef.inst = self
		end

		if AdvKeyText then
			AdvKeyText.Text       = getKeyName(self._value)
			AdvKeyText.TextColor3 = getKeyColor(self._value)
		end

		cancelAdvTweens()

		-- Đảm bảo bàn phím ẩn sạch trước khi mở frame
		if KeyBroad then
			if cancelKeyTweensFn then cancelKeyTweensFn() end
			KeyBroad.Visible = false
			if BASE.broadPos then
				KeyBroad.Position = UDim2.new(
					BASE.broadPos.X.Scale, BASE.broadPos.X.Offset,
					3, BASE.broadPos.Y.Offset
				)
			end
			if resetAllKeysFn then resetAllKeysFn() end
		end

		-- Khi switch: frame đã visible, không reset BlackFrame về trans=1
		-- → tween đè trực tiếp từ trạng thái hiện tại
		if not isSwitching then
			-- Reset về trạng thái vô hình trước khi show
			if BlackFrame then BlackFrame.BackgroundTransparency = 1 end
			if TIPText then
				TIPText.Position         = UDim2.new(
					BASE.tipPos.X.Scale, BASE.tipPos.X.Offset,
					3, BASE.tipPos.Y.Offset
				)
				TIPText.TextTransparency = 1
			end
			local function resetBtn(btn, icon)
				if not btn then return end
				btn.BackgroundTransparency = 1
				local lbl = btn:FindFirstChildWhichIsA("TextLabel")
				local dec = btn:FindFirstChild("Decor")
				if lbl  then lbl.TextTransparency        = 1 end
				if dec  then dec.BackgroundTransparency  = 1 end
				if icon then icon.ImageTransparency      = 1 end
			end
			resetBtn(KeyButton)
			resetBtn(CancelButton)
			resetBtn(TableButton, IconFrame)
		end

		advanceFrame.Visible = true

		-- 1) BlackFrame + TIPText fade in cùng lúc
		if BlackFrame then
			trackTween(TweenService:Create(BlackFrame, ADV_EXP_OUT,
				{ BackgroundTransparency = BASE.blackTrans }
				))
		end
		if TIPText then
			trackTween(TweenService:Create(TIPText, ADV_EXP_OUT2, { Position         = BASE.tipPos   }))
			trackTween(TweenService:Create(TIPText, ADV_EXP_OUT2, { TextTransparency = BASE.tipTrans }))
		end

		-- 2) KeyButton (delay 0.05s)
		task.delay(0.05, function()
			if not advanceFrame.Visible then return end
			if KeyButton then
				local lbl = KeyButton:FindFirstChildWhichIsA("TextLabel")
				local dec = KeyButton:FindFirstChild("Decor")
				trackTween(TweenService:Create(KeyButton, ADV_EXP_OUT, { BackgroundTransparency = BASE.keyBgTrans    }))
				if lbl then trackTween(TweenService:Create(lbl, ADV_EXP_OUT, { TextTransparency       = BASE.keyTextTrans  })) end
				if dec then trackTween(TweenService:Create(dec, ADV_EXP_OUT, { BackgroundTransparency = BASE.keyDecorTrans })) end
			end

			-- 3) CancelButton (delay 0.1s sau Key)
			task.delay(0.1, function()
				if not advanceFrame.Visible then return end
				if CancelButton then
					local lbl = CancelButton:FindFirstChildWhichIsA("TextLabel")
					local dec = CancelButton:FindFirstChild("Decor")
					trackTween(TweenService:Create(CancelButton, ADV_EXP_OUT, { BackgroundTransparency = BASE.cancelBgTrans    }))
					if lbl then trackTween(TweenService:Create(lbl, ADV_EXP_OUT, { TextTransparency       = BASE.cancelTextTrans  })) end
					if dec then trackTween(TweenService:Create(dec, ADV_EXP_OUT, { BackgroundTransparency = BASE.cancelDecorTrans })) end
				end

				-- 4) TableButton + IconFrame (delay 0.1s sau Cancel)
				task.delay(0.1, function()
					if not advanceFrame.Visible then return end
					if TableButton then
						local lbl = TableButton:FindFirstChildWhichIsA("TextLabel")
						local dec = TableButton:FindFirstChild("Decor")
						trackTween(TweenService:Create(TableButton, ADV_EXP_OUT, { BackgroundTransparency = BASE.tableBgTrans    }))
						if lbl       then trackTween(TweenService:Create(lbl,       ADV_EXP_OUT, { TextTransparency       = BASE.tableTextTrans  })) end
						if dec       then trackTween(TweenService:Create(dec,       ADV_EXP_OUT, { BackgroundTransparency = BASE.tableDecorTrans })) end
						if IconFrame then trackTween(TweenService:Create(IconFrame, ADV_EXP_OUT, { ImageTransparency      = BASE.iconTrans        })) end
					end
				end)
			end)
		end)
	end

	local function enterWaiting()
		if isAdvance then
			openAdvFrame()
		else
			self._waiting = true
			keyReg_enterWaiting(self)
			if KeyText     then KeyText.Text     = "..." end
			if InfoSetting then InfoSetting.Text = "KEY : ..." end
		end
	end


	-- ── Hover → shiny (không flash) ─────────────────────────
	if Decor then
		table.insert(self._conns, ChangeButton.MouseEnter:Connect(function()
			if self._waiting then return end
			playDecorShine(false)
		end))
		table.insert(self._conns, ChangeButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				if self._waiting then return end
				playDecorShine(false)
			end
		end))
	end

	if isAdvance and advanceFrame then
		advanceFrame.Visible = false  -- ẩn ban đầu

		-- ── Setup KeyBroad: đọc text Label "Key" có sẵn → map KeyCode ──────
		if KeyBroad then
			KeyBroad.Visible = false  -- ẩn mặc định

			-- ── Nếu advanceFrame đã được init bởi instance khác → tái sử dụng keyData ──
			local _sharedBroad = KeyBroadRegistry[advanceFrame]
			if _sharedBroad then
				keyData                   = _sharedBroad.keyData                or keyData
				closeKeyBroadFn           = _sharedBroad.closeKeyBroad          or closeKeyBroadFn
				cancelKeyTweensFn         = _sharedBroad.cancelKeyTweens        or cancelKeyTweensFn
				resetAllKeysFn            = _sharedBroad.resetAllKeys           or resetAllKeysFn
				openKeyBroadFn            = _sharedBroad.openKeyBroad           or openKeyBroadFn
				closeKeyBroadDirectFn     = _sharedBroad.closeKeyBroadDirect    or closeKeyBroadDirectFn
				closeKeyBroadFromCenterFn = _sharedBroad.closeKeyBroadFromCenter or closeKeyBroadFromCenterFn
				isBroadOpenRef            = _sharedBroad.isBroadOpenRef         or isBroadOpenRef
				activeInstRef             = _sharedBroad.activeInstRef          or activeInstRef
				advTweensRef              = _sharedBroad.advTweensRef           or advTweensRef
				print("[SliderModule.Key] '" .. title .. "' tái sử dụng KeyBroad data từ advanceFrame đã có")
			else

				-- ── Build keyFrames list + metadata ─────────────────────
				local usedCount = {}
				local keyFrames = {}
				for _, child in ipairs(KeyBroad:GetChildren()) do
					if child:IsA("Frame") then
						table.insert(keyFrames, child)
					end
				end
				table.sort(keyFrames, function(a, b)
					return a.LayoutOrder < b.LayoutOrder
				end)

				-- keyData: array of { frame, keyLabel, keyCode, displayName, baseLabelPos, baseLabelTrans, baseBgTrans }
				keyData = {}

				for _, keyFrame in ipairs(keyFrames) do
					local keyLabel = keyFrame:FindFirstChild("Key")
						or keyFrame:FindFirstChildWhichIsA("TextLabel")
					if not keyLabel then continue end

					local rawText = keyLabel.Text:upper():gsub("%s+", "")
					if rawText == "" then continue end

					usedCount[rawText] = (usedCount[rawText] or 0) + 1
					local lookupKey = rawText
					if usedCount[rawText] > 1 then
						lookupKey = rawText .. "_" .. usedCount[rawText]
					end

					local entry = KEY_MAP_LOOKUP[lookupKey]
					if not entry then continue end

					local keyCode     = entry.keyCode
					local displayName = entry.displayName

					keyFrame.Name        = "Key_" .. lookupKey:lower()
					keyFrame.LayoutOrder = entry.order
					keyLabel.TextColor3  = getKeyColor(keyCode)

					table.insert(keyData, {
						frame          = keyFrame,
						keyLabel       = keyLabel,
						keyCode        = keyCode,
						displayName    = displayName,
						lookupKey      = lookupKey,
						baseLabelPos   = keyLabel.Position,
						baseLabelTrans = keyLabel.TextTransparency,
						baseBgTrans    = keyFrame.BackgroundTransparency,
						decor          = keyFrame:FindFirstChild("Decor"),
						baseDecorTrans = keyFrame:FindFirstChild("Decor") and keyFrame:FindFirstChild("Decor").BackgroundTransparency or 1,
					})
				end

				-- ── TweenInfo cho phím ───────────────────────────────────
				local KEY_IN  = TweenInfo.new(0.18, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
				local KEY_OUT = TweenInfo.new(0.14, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)

				-- Tween tracks cho phím (cancel khi cần)
				local keyTweens = {}  -- { [frame] = { t1, t2, t3 } }
				local function cancelKeyTweens()
					for _, ts in pairs(keyTweens) do
						for _, t in ipairs(ts) do t:Cancel() end
					end
					keyTweens = {}
				end

				-- ── Helper: show 1 phím ──────────────────────────────────
				local function showKey(kd)
					local f  = kd.frame
					local lb = kd.keyLabel
					local dc = kd.decor
					-- Reset trước
					f.BackgroundTransparency  = 1
					lb.TextTransparency       = 1
					if dc then dc.BackgroundTransparency = 1 end
					lb.Position = UDim2.new(
						kd.baseLabelPos.X.Scale, kd.baseLabelPos.X.Offset,
						0.65, kd.baseLabelPos.Y.Offset
					)
					-- Tween
					local t1 = TweenService:Create(f,  KEY_IN, { BackgroundTransparency = kd.baseBgTrans    })
					local t2 = TweenService:Create(lb, KEY_IN, { TextTransparency       = kd.baseLabelTrans })
					local t3 = TweenService:Create(lb, KEY_IN, { Position               = kd.baseLabelPos   })
					local t4 = dc and TweenService:Create(dc, KEY_IN, { BackgroundTransparency = kd.baseDecorTrans })
					keyTweens[f] = { t1, t2, t3, t4 }
					t1:Play() t2:Play() t3:Play()
					if t4 then t4:Play() end
				end

				-- ── Helper: hide 1 phím ──────────────────────────────────
				local function hideKey(kd, onDone)
					local f  = kd.frame
					local lb = kd.keyLabel
					local dc = kd.decor
					local offPos = UDim2.new(
						kd.baseLabelPos.X.Scale, kd.baseLabelPos.X.Offset,
						0.65, kd.baseLabelPos.Y.Offset
					)
					local t1 = TweenService:Create(f,  KEY_OUT, { BackgroundTransparency = 1 })
					local t2 = TweenService:Create(lb, KEY_OUT, { TextTransparency       = 1 })
					local t3 = TweenService:Create(lb, KEY_OUT, { Position               = offPos })
					local t4 = dc and TweenService:Create(dc, KEY_OUT, { BackgroundTransparency = 1 })
					keyTweens[f] = { t1, t2, t3, t4 }
					if onDone then
						t1.Completed:Connect(function(state)
							if state == Enum.PlaybackState.Completed then onDone() end
						end)
					end
					t1:Play() t2:Play() t3:Play()
					if t4 then t4:Play() end
				end

				-- ── Mở bàn phím: random order ───────────────────────────
				local broadTweenThreads = {}
				local function cancelBroadThreads()
					for _, thread in ipairs(broadTweenThreads) do
						task.cancel(thread)
					end
					broadTweenThreads = {}
				end

				isBroadOpenRef = { value = false }

				-- ── activeInst pointer: trỏ đến instance đang dùng advanceFrame ──
				-- Tất cả click bind đọc pointer này thay vì cứng self
				activeInstRef = { inst = nil }

				-- advTweensRef đã được init từ ngoài, dùng luôn (không tạo mới)

				-- TweenInfo riêng cho KeyBroad position
				local BROAD_OPEN  = TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)  -- mở: nhanh hơn
				local BROAD_CLOSE = TweenInfo.new(1.7, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)  -- đóng: chậm rãi rơi xuống

				local function openKeyBroad(source)
					cancelBroadThreads()
					cancelKeyTweens()
					isBroadOpenRef.value = true
					local currentTitle = activeInstRef.inst and activeInstRef.inst._title or "?"
					print("[SliderModule.Key] KeyBroad MỞ từ setting: " .. currentTitle .. " | nguồn: " .. (source or "?"))

					-- Reset KeyBroad position lên Y=3 rồi show + tween xuống base
					if BASE.broadPos then
						KeyBroad.Position = UDim2.new(
							BASE.broadPos.X.Scale, BASE.broadPos.X.Offset,
							3, BASE.broadPos.Y.Offset
						)
					end
					KeyBroad.Visible = true
					if BASE.broadPos then
						trackTween(TweenService:Create(KeyBroad, BROAD_OPEN, { Position = BASE.broadPos }))
					end

					-- Ẩn TIPText (giống closeAdv nhưng chỉ TIPText)
					if TIPText then
						local offPos = UDim2.new(
							BASE.tipPos.X.Scale, BASE.tipPos.X.Offset,
							3, BASE.tipPos.Y.Offset
						)
						trackTween(TweenService:Create(TIPText, ADV_EXP_IN, { Position         = offPos }))
						trackTween(TweenService:Create(TIPText, ADV_EXP_IN, { TextTransparency = 1      }))
					end

					-- Shuffle keyData để hiện ngẫu nhiên
					local shuffled = {}
					for i, kd in ipairs(keyData) do shuffled[i] = kd end
					for i = #shuffled, 2, -1 do
						local j = math.random(1, i)
						shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
					end

					local STEP = 0.018  -- delay giữa mỗi phím
					for i, kd in ipairs(shuffled) do
						local thread = task.delay((i - 1) * STEP, function()
							if not isBroadOpenRef.value then return end
							showKey(kd)
						end)
						table.insert(broadTweenThreads, thread)
					end
				end

				-- ── Đóng bàn phím: A→Z order ────────────────────────────
				local function closeKeyBroad(onAllDone, source)
					cancelBroadThreads()
					isBroadOpenRef.value = false
					local closedBy = activeInstRef and activeInstRef.inst and activeInstRef.inst._title or "Unknown"
					print("[SliderModule.Key] KeyBroad đóng (A→Z) bởi setting: " .. closedBy .. " | nguồn: " .. (source or "?"))

					-- Tween KeyBroad rơi xuống Y=3 chậm rãi
					if BASE.broadPos then
						local offPos = UDim2.new(
							BASE.broadPos.X.Scale, BASE.broadPos.X.Offset,
							3, BASE.broadPos.Y.Offset
						)
						trackTween(TweenService:Create(KeyBroad, BROAD_CLOSE, { Position = offPos }))
					end

					-- Sort theo displayName alphabetical
					local sorted = {}
					for i, kd in ipairs(keyData) do sorted[i] = kd end
					table.sort(sorted, function(a, b)
						return a.displayName < b.displayName
					end)

					local STEP  = 0.018
					local total = #sorted
					for i, kd in ipairs(sorted) do
						local isLast = (i == total)
						local thread = task.delay((i - 1) * STEP, function()
							hideKey(kd, isLast and function()
								KeyBroad.Visible = false
								if onAllDone then onAllDone() end
							end or nil)
						end)
						table.insert(broadTweenThreads, thread)
					end
				end
				closeKeyBroadFn       = closeKeyBroad
				openKeyBroadFn        = openKeyBroad
				closeKeyBroadDirectFn = closeKeyBroad
				cancelKeyTweensFn     = cancelKeyTweens
				resetAllKeysFn   = function()
					for _, kd in ipairs(keyData) do
						kd.frame.BackgroundTransparency = 1
						kd.keyLabel.TextTransparency    = 1
						if kd.decor then kd.decor.BackgroundTransparency = 1 end
						kd.keyLabel.Position = UDim2.new(
							kd.baseLabelPos.X.Scale, kd.baseLabelPos.X.Offset,
							0.65, kd.baseLabelPos.Y.Offset
						)
					end
				end

				-- ── Đóng bàn phím: lan từ tâm ra (khi preview đổi) ─────
				local function closeKeyBroadFromCenter(centerKeyCode, onAllDone, source)
					cancelBroadThreads()
					isBroadOpenRef.value = false
					local closedBy = activeInstRef and activeInstRef.inst and activeInstRef.inst._title or "Unknown"
					local centerName = ""
					for _, kd in ipairs(keyData) do
						if kd.keyCode == centerKeyCode then
							centerName = kd.displayName
							break
						end
					end
					print("[SliderModule.Key] KeyBroad đóng (từ tâm '" .. centerName .. "') bởi setting: " .. closedBy .. " | nguồn: " .. (source or "?"))

					-- Tween KeyBroad rơi xuống Y=3 chậm rãi
					if BASE.broadPos then
						local offPos = UDim2.new(
							BASE.broadPos.X.Scale, BASE.broadPos.X.Offset,
							3, BASE.broadPos.Y.Offset
						)
						trackTween(TweenService:Create(KeyBroad, BROAD_CLOSE, { Position = offPos }))
					end

					-- Tìm index của phím tâm trong keyData (theo LayoutOrder)
					local centerOrder = nil
					for _, kd in ipairs(keyData) do
						if kd.keyCode == centerKeyCode then
							centerOrder = kd.frame.LayoutOrder
							break
						end
					end

					-- Sort theo khoảng cách LayoutOrder từ tâm
					local sorted = {}
					for i, kd in ipairs(keyData) do sorted[i] = kd end
					if centerOrder then
						table.sort(sorted, function(a, b)
							local da = math.abs(a.frame.LayoutOrder - centerOrder)
							local db = math.abs(b.frame.LayoutOrder - centerOrder)
							return da < db
						end)
					end

					local STEP  = 0.012
					local total = #sorted
					for i, kd in ipairs(sorted) do
						local isLast = (i == total)
						local thread = task.delay((i - 1) * STEP, function()
							hideKey(kd, isLast and function()
								KeyBroad.Visible = false
								if onAllDone then onAllDone() end
							end or nil)
						end)
						table.insert(broadTweenThreads, thread)
					end
				end

				closeKeyBroadFromCenterFn = closeKeyBroadFromCenter

				-- ── Bind click vào từng phím ────────────────────────────
				for _, kd in ipairs(keyData) do
					local keyFrame   = kd.frame
					local keyCode    = kd.keyCode
					local frameDecor = keyFrame:FindFirstChild("Decor")
					local ctxFrame   = {}
					local clickKey   = keyFrame:FindFirstChild("ClickKey")
						or keyFrame:FindFirstChildWhichIsA("TextButton")

					if clickKey then
						clickKey.MouseEnter:Connect(function()
							makeButtonShine(frameDecor, false, ctxFrame)
						end)
						clickKey.InputBegan:Connect(function(input)
							if input.UserInputType == Enum.UserInputType.Touch then
								makeButtonShine(frameDecor, false, ctxFrame)
							end
						end)
						clickKey.MouseButton1Click:Connect(function()
							local active = activeInstRef.inst
							if not active then return end
							if not active._waiting then return end
							if not openRegistry[active] then return end
							if active._blacklist and active._blacklist[keyCode] then return end
							local prev = active._preview
							active._preview = keyCode
							local activeAdvKeyText = active._advKeyText
							if activeAdvKeyText then
								activeAdvKeyText.Text       = active._getKeyName(keyCode)
								activeAdvKeyText.TextColor3 = active._getKeyColor(keyCode)
							end
							local fromCenter = prev or keyCode
							closeKeyBroadFromCenterFn(fromCenter, function()
								if active._waiting then
									openKeyBroadFn("click phím trên KeyBroad")
								end
							end, "click phím KeyBroad")
						end)
					end
				end

				-- ── Init: ẩn tất cả phím khi load ──────────────────────
				for _, kd in ipairs(keyData) do
					kd.frame.BackgroundTransparency = 1
					kd.keyLabel.TextTransparency    = 1
					if kd.decor then kd.decor.BackgroundTransparency = 1 end
					kd.keyLabel.Position = UDim2.new(
						kd.baseLabelPos.X.Scale, kd.baseLabelPos.X.Offset,
						0.65, kd.baseLabelPos.Y.Offset
					)
				end

				-- ── Đăng ký vào KeyBroadRegistry ───────────────────────
				KeyBroadRegistry[advanceFrame] = {
					keyData                = keyData,
					closeKeyBroad          = closeKeyBroadFn,
					cancelKeyTweens        = cancelKeyTweensFn,
					resetAllKeys           = resetAllKeysFn,
					openKeyBroad           = openKeyBroadFn,
					closeKeyBroadDirect    = closeKeyBroadDirectFn,
					closeKeyBroadFromCenter= closeKeyBroadFromCenterFn,
					isBroadOpenRef         = isBroadOpenRef,
					activeInstRef          = activeInstRef,
					advTweensRef           = advTweensRef,
				}
				print("[SliderModule.Key] '" .. title .. "' khởi tạo KeyBroad data mới cho advanceFrame")

			end -- end else (registry check)

			-- ── TableButton / KeyButton / CancelButton: chỉ bind 1 lần cho mỗi advanceFrame ──
			if not advanceFrame:GetAttribute("KeyBroadBound") then
				advanceFrame:SetAttribute("KeyBroadBound", true)

				if TableButton then
					local TableDecor = TableButton:FindFirstChild("Decor")
					local ctxTable   = {}

					TableButton.MouseEnter:Connect(function()
						makeButtonShine(TableDecor, false, ctxTable)
					end)
					TableButton.InputBegan:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.Touch then
							makeButtonShine(TableDecor, false, ctxTable)
						end
					end)
					TableButton.MouseButton1Click:Connect(function()
						local active = activeInstRef and activeInstRef.inst or self
						if not active._waiting then return end
						if not openRegistry[active] then return end
						makeButtonShine(TableDecor, true, ctxTable)
						if isBroadOpenRef.value then
							closeKeyBroadDirectFn(function()
								if TIPText and advanceFrame.Visible then
									trackTween(TweenService:Create(TIPText, ADV_EXP_OUT2, { Position         = BASE.tipPos   }))
									trackTween(TweenService:Create(TIPText, ADV_EXP_OUT2, { TextTransparency = BASE.tipTrans }))
								end
							end, "TableButton")
						else
							openKeyBroadFn("TableButton")
						end
					end)
				end

				if KeyButton then
					local KeyDecor = KeyButton:FindFirstChild("Decor")
					local ctxKey   = {}

					KeyButton.MouseEnter:Connect(function()
						makeButtonShine(KeyDecor, false, ctxKey)
					end)
					KeyButton.InputBegan:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.Touch then
							makeButtonShine(KeyDecor, false, ctxKey)
						end
					end)
					KeyButton.MouseButton1Click:Connect(function()
						local active = activeInstRef and activeInstRef.inst or self
						if not active._waiting then return end
						if not openRegistry[active] then return end
						if not active._preview then return end
						local confirmed = active._preview
						closeAdvFrame(false)
						if not allowDuplicate and keyReg_isDuplicate(active, confirmed) then return end
						makeButtonShine(KeyDecor, true, ctxKey)
						active:_applyKeyExt(confirmed)
					end)
				end

				if CancelButton then
					local CancelDecor = CancelButton:FindFirstChild("Decor")
					local ctxCancel   = {}

					CancelButton.MouseEnter:Connect(function()
						makeButtonShine(CancelDecor, false, ctxCancel)
					end)
					CancelButton.InputBegan:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.Touch then
							makeButtonShine(CancelDecor, false, ctxCancel)
						end
					end)
					CancelButton.MouseButton1Click:Connect(function()
						local active = activeInstRef and activeInstRef.inst or self
						if not active._waiting then return end
						if not openRegistry[active] then return end
						closeAdvFrame(false)
					end)
				end

			end -- end KeyBroadBound guard
		end -- end if KeyBroad
	end -- end if isAdvance and advanceFrame

	-- ── Bấm ChangeButton → chờ phím ─────────────────────────
	table.insert(self._conns, ChangeButton.MouseButton1Click:Connect(function()
		if self._waiting then return end
		enterWaiting()
	end))

	-- ── Capture phím kế tiếp ─────────────────────────────────
	table.insert(self._conns, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not self._waiting then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

		local kc = input.KeyCode
		if kc == Enum.KeyCode.Unknown then return end

		if isAdvance then
			-- Escape = cancel
			if kc == Enum.KeyCode.Escape then
				closeAdvFrame(false)
				return
			end
			-- Enter đơn thuần → không làm gì (chỉ dùng như modifier giữ)
			if kc == Enum.KeyCode.Return then return end
			-- Blacklist check
			if blacklist[kc] then return end

			-- Giữ Enter + bấm key → confirm ngay lập tức
			if UserInputService:IsKeyDown(Enum.KeyCode.Return) then
				local confirmed = kc
				if not allowDuplicate and keyReg_isDuplicate(self, confirmed) then return end
				-- Update AdvKeyText TRƯỚC khi đóng frame
				if AdvKeyText then
					AdvKeyText.Text       = getKeyName(confirmed)
					AdvKeyText.TextColor3 = getKeyColor(confirmed)
				end
				closeAdvFrame(false)
				applyKey(confirmed, true)
				return
			end

			-- Bình thường → preview (confirm sau bằng KeyButton)
			self._preview = kc
			if AdvKeyText then
				AdvKeyText.Text       = getKeyName(kc)
				AdvKeyText.TextColor3 = getKeyColor(kc)
			end
		else
			-- Mode thường (logic cũ)
			if blacklist[kc] then return end
			if not allowDuplicate and keyReg_isDuplicate(self, kc) then
				self._waiting = false
				keyReg_exitWaiting(self)
				local oldName = getKeyName(self._value)
				if KeyText     then KeyText.Text     = oldName end
				if InfoSetting then InfoSetting.Text = "KEY : " .. oldName end
				return
			end
			applyKey(kc, true)
		end
	end))


	-- ── Public API ───────────────────────────────────────────
	function self:getValue()
		return self._value
	end

	function self:getKeyName()
		return getKeyName(self._value)
	end

	function self:setValue(keyCode)
		applyKey(keyCode, false)
	end

	-- Dùng bởi KeyButton khi confirm từ shared advanceFrame
	function self:_applyKeyExt(keyCode)
		applyKey(keyCode, true)
	end

	function self:setOnChange(fn)
		self._onChange = fn
	end

	function self:setVisible(bool)
		frame.Visible = bool
	end

	function self:_closeListExternal()
		closeAdvFrame(false)
	end

	-- Dùng khi switch: giữ advanceFrame visible để instance mới tween đè lên
	function self:_closeListExternal_switch()
		closeAdvFrame(true)
	end

	-- Dùng nội bộ bởi keyReg_enterWaiting khi 1 inst khác vào waiting
	function self:_cancelWaiting()
		if not self._waiting then return end
		self._waiting = false
		keyReg_exitWaiting(self)
		-- Restore UI về key hiện tại
		local name = getKeyName(self._value)
		if KeyText     then KeyText.Text     = name end
		if InfoSetting then InfoSetting.Text = "KEY : " .. name end
	end

	function self:destroy()
		closeAdvFrame(false)
		if ctxChange.t1  then ctxChange.t1:Cancel()  end
		if ctxChange.t2  then ctxChange.t2:Cancel()  end
		if ctxChange.ct1 then ctxChange.ct1:Cancel() end
		if ctxChange.ct2 then ctxChange.ct2:Cancel() end
		for _, conn in ipairs(self._conns) do conn:Disconnect() end
		self._conns = {}
		keyReg_remove(self)
		createdSliders[frame] = nil
		if frame.Parent then frame:Destroy() end
	end

	-- Init
	applyKey(defaultKey, false)

	-- Đăng ký vào createdSliders registry
	createdSliders[frame] = self

	return self
end

-- ============================================================
--  SliderModule.Text  |  Rich Text Editor
--
--  Config:
--    template         (Frame)    : TextTemplate
--    parent           (Frame)    : frame cha
--    title            (string)   : tên hiển thị
--    default          (table)    : { "line1", "line2", ... }
--    creator          (number)   : UserId của creator (optional)
--    co_creator       (number)   : UserId của co-creator (optional)
--    packFrame        (Frame)    : TextPackFrame (frame editor, dùng chung)
--    onChange         (function) : callback(lines, info, tag)
--    tag              (any)      : tag gửi kèm onChange
--
--  Tag system:
--    </b> Text </b>           → Bold
--    </i> Text </i>           → Italic
--    </s=24> Text </s>        → Size (number)
--    </c=#FF0000> Text </c>   → Color (hex)
--    </n1> Text </n1>         → Heading 1 (large,  bold)
--    </n2> Text </n2>         → Heading 2 (medium, bold)
--    </n3> Text </n3>         → Heading 3 (small)
--    </f=FontName> Text </f>  → Font family
--    </Delete>                → Xóa dòng này khỏi editor
--    </Xl> Text </Xl>         → TextXAlignment Left
--    </Xc> Text </Xc>         → TextXAlignment Center
--    </Xr> Text </Xr>         → TextXAlignment Right
--    </Yl> Text </Yl>         → TextYAlignment Top
--    </Yc> Text </Yc>         → TextYAlignment Center
--    </Yr> Text </Yr>         → TextYAlignment Bottom
-- ============================================================

-- ════════════════════════════════════════════════════════════
--  TEXT REGISTRY  —  shared state cho packFrame
--  (giống colorRegistry trong Color/Gradient)
--
--  textRegistry[packFrame] = {
--    activeInst : inst | nil   ← ai đang mở packFrame
--    trackConn  : conn | nil
--    toolBuilt  : bool         ← ToolFrame đã build chưa
--  }
-- ════════════════════════════════════════════════════════════
local textRegistry = {}

local function getTextReg(pf)
	if not textRegistry[pf] then
		textRegistry[pf] = {
			activeInst = nil,
			trackConn  = nil,
			toolBuilt  = false,
		}
	end
	return textRegistry[pf]
end

-- ════════════════════════════════════════════════════════════
--  TEXT STATE REGISTRY  —  per-instance state
--  (giống GradientStateRegistry trong Gradient)
--
--  TextStateRegistry[inst] = {
--    mode        : "READ" | "EDIT"
--    lines       : { "line1", ... }   ← cached raw text
--    creatorId   : number | nil
--    coCreatorId : number | nil
--    lineRowSize : UDim2
--    toolOpen    : bool
--    pageDrag    : bool
--    pagePrevY   : number
--    conns       : { conn }   ← connections của inst
--    lineConns   : { conn }   ← connections của các dòng EditText
--  }
-- ════════════════════════════════════════════════════════════
local TextStateRegistry = {}

-- ════════════════════════════════════════════════════════════
--  TOOL DEFINITIONS
--  label      : text ngắn hiển thị trên button (chỉ tag)
--  tip        : full syntax hiển thị khi hover + trong popup
--  insert     : raw text chèn vào TextBox (fallback khi không cần value)
--  valueParam : tên tham số cần nhập (nil = không cần, bỏ qua flow chọn dòng)
--  valueHint  : placeholder trong input box
-- ════════════════════════════════════════════════════════════
local TEXT_TOOLS = {
	{
		tag        = "b",
		label      = "</b>",
		tip        = '{ </b> "Text" </b> }  —  Bold text',
		insert     = "</b>  </b>",
	},
	{
		tag        = "i",
		label      = "</i>",
		tip        = '{ </i> "Text" </i> }  —  Italic text',
		insert     = "</i>  </i>",
	},
	{
		tag        = "s",
		label      = "</s>",
		tip        = '{ </s=24> "Text" </s> }  —  Change text size',
		insert     = "</s=24>  </s>",
		valueParam = "size",
		valueHint  = 'e.g.  19 , "your text here"',
	},
	{
		tag        = "c",
		label      = "</c>",
		tip        = '{ </c=#FF0000> "Text" </c> }  —  Text color (hex)',
		insert     = "</c=#FF0000>  </c>",
		valueParam = "color",
		valueHint  = 'e.g.  #FF0000 , "your text here"',
	},
	{
		tag        = "n1",
		label      = "</n1>",
		tip        = '{ </n1> "Text" </n1> }  —  Large heading (bold)',
		insert     = "</n1>  </n1>",
	},
	{
		tag        = "n2",
		label      = "</n2>",
		tip        = '{ </n2> "Text" </n2> }  —  Medium heading (bold)',
		insert     = "</n2>  </n2>",
	},
	{
		tag        = "n3",
		label      = "</n3>",
		tip        = '{ </n3> "Text" </n3> }  —  Small heading',
		insert     = "</n3>  </n3>",
	},
	{
		tag        = "f",
		label      = "</f>",
		tip        = '{ </f=FontName> "Text" </f> }  —  Font family',
		insert     = "</f=FontName>  </f>",
		valueParam = "font",
		valueHint  = 'e.g.  GothamBold , "your text here"',
	},
	-- ── Alignment X ──────────────────────────────────────────
	{
		tag    = "Xl",
		label  = "</Xl>",
		tip    = '{ </Xl> "Text" </Xl> }  —  Align text Left',
		insert = "</Xl>  </Xl>",
	},
	{
		tag    = "Xc",
		label  = "</Xc>",
		tip    = '{ </Xc> "Text" </Xc> }  —  Align text Center',
		insert = "</Xc>  </Xc>",
	},
	{
		tag    = "Xr",
		label  = "</Xr>",
		tip    = '{ </Xr> "Text" </Xr> }  —  Align text Right',
		insert = "</Xr>  </Xr>",
	},
	-- ── Alignment Y ──────────────────────────────────────────
	{
		tag    = "Yl",
		label  = "</Yl>",
		tip    = '{ </Yl> "Text" </Yl> }  —  Align text Top',
		insert = "</Yl>  </Yl>",
	},
	{
		tag    = "Yc",
		label  = "</Yc>",
		tip    = '{ </Yc> "Text" </Yc> }  —  Align text Middle (vertical)',
		insert = "</Yc>  </Yc>",
	},
	{
		tag    = "Yr",
		label  = "</Yr>",
		tip    = '{ </Yr> "Text" </Yr> }  —  Align text Bottom',
		insert = "</Yr>  </Yr>",
	},
}

-- ════════════════════════════════════════════════════════════
--  TAG → ROBLOX RICHTEXT CONVERTER
--  Chuyển custom tag sang RichText chuẩn Roblox để dùng 1 TextLabel duy nhất
-- ════════════════════════════════════════════════════════════
local DEFAULT_TEXT_SIZE = 14

local function toRichText(raw)
	if not raw or raw == "" then return "" end
	local result    = ""
	local pos       = 1
	local len       = #raw
	local closeStack = {}

	local function escapeXml(s)
		return s:gsub("&", "&amp;"):gsub('"', "&quot;")
	end

	while pos <= len do
		local tagStart, tagEnd = raw:find("</%S->", pos)
		if tagStart then
			if tagStart > pos then
				result = result .. escapeXml(raw:sub(pos, tagStart - 1))
			end
		else
			result = result .. escapeXml(raw:sub(pos))
			break
		end

		local tc = raw:sub(tagStart + 2, tagEnd - 1)

		if tc == "/b" or tc == "/i" or tc == "/s" or tc == "/c"
			or tc == "/n1" or tc == "/n2" or tc == "/n3" or tc == "/f"
			or tc == "/Xl" or tc == "/Xc" or tc == "/Xr"
			or tc == "/Yl" or tc == "/Yc" or tc == "/Yr" then
			local close = table.remove(closeStack)
			if close then result = result .. close end
		elseif tc == "b" then
			result = result .. "<b>"; table.insert(closeStack, "</b>")
		elseif tc == "i" then
			result = result .. "<i>"; table.insert(closeStack, "</i>")
		elseif tc:sub(1,2) == "s=" then
			local sz = tonumber(tc:sub(3)) or DEFAULT_TEXT_SIZE
			result = result .. '<font size="'..sz..'">'; table.insert(closeStack, "</font>")
		elseif tc:sub(1,2) == "c=" then
			local hex = tc:sub(3)
			if hex:sub(1,1) ~= "#" then hex = "#"..hex end
			result = result .. '<font color="'..hex..'">'; table.insert(closeStack, "</font>")
		elseif tc == "n1" then
			result = result .. '<font size="28"><b>'; table.insert(closeStack, "</b></font>")
		elseif tc == "n2" then
			result = result .. '<font size="22"><b>'; table.insert(closeStack, "</b></font>")
		elseif tc == "n3" then
			result = result .. '<font size="18">'; table.insert(closeStack, "</font>")
		elseif tc:sub(1,2) == "f=" then
			result = result .. '<font face="'..tc:sub(3)..'">'; table.insert(closeStack, "</font>")
			-- Alignment tags: không có RichText tương đương, bỏ qua wrapper nhưng vẫn push/pop
		elseif tc == "Xl" or tc == "Xc" or tc == "Xr"
			or tc == "Yl" or tc == "Yc" or tc == "Yr" then
			table.insert(closeStack, "")  -- pop khi gặp closing tag
		else
			result = result .. escapeXml(raw:sub(tagStart, tagEnd))
		end

		pos = tagEnd + 1
	end

	for i = #closeStack, 1, -1 do result = result .. closeStack[i] end
	return result
end

-- ════════════════════════════════════════════════════════════
--  CONTRIBUTOR HELPER
-- ════════════════════════════════════════════════════════════
local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local function loadContributorAsync(imageLabel, nameLabel, userId)
	if not userId then
		if imageLabel then imageLabel.Visible = false end
		if nameLabel  then nameLabel.Visible  = false end
		return
	end
	if imageLabel then
		imageLabel.Visible = true
		imageLabel.Image   = "https://www.roblox.com/headshot-thumbnail/image?userId="
			.. tostring(userId) .. "&width=420&height=420&format=png"
	end
	if nameLabel then
		nameLabel.Visible = true
		task.spawn(function()
			local ok, name = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if nameLabel and nameLabel.Parent then
				nameLabel.Text = ok and name or ("User#"..tostring(userId))
			end
		end)
	end
end

-- ════════════════════════════════════════════════════════════
--  SliderModule.Text
-- ════════════════════════════════════════════════════════════
function SliderModule.Text(config)
	assert(config.parent,    "[SliderModule.Text] Thiếu 'parent'")
	assert(config.packFrame, "[SliderModule.Text] Thiếu 'packFrame'")

	local template = config.template or script:FindFirstChild("TextTemplate")
	assert(template, "[SliderModule.Text] Không tìm thấy TextTemplate")

	local title          = config.title or "Text"
	local name           = config.name   -- tên hiển thị trong packFrame
	local packFrame = config.packFrame
	local reg       = getTextReg(packFrame)  -- ✅ shared registry

	-- ── Clone template ──────────────────────────────────────
	local settingFrame   = template:Clone()
	settingFrame.Name    = "Setting_" .. title
	settingFrame.Visible = true
	settingFrame.Parent  = config.parent

	-- ── Template refs ───────────────────────────────────────
	local TPL_InfoFrame   = settingFrame:FindFirstChild("InfoFrame")
	local EditTextButton  = TPL_InfoFrame and TPL_InfoFrame:FindFirstChild("EditTextButton")
	local CurrentEdit     = EditTextButton and EditTextButton:FindFirstChild("CurrentEdit")
	local SubCurrentEdit  = EditTextButton and EditTextButton:FindFirstChild("SubCurrentEdit")
	local TPL_Contributor = TPL_InfoFrame and TPL_InfoFrame:FindFirstChild("Contributor")
	local TPL_SubContrib  = TPL_Contributor and TPL_Contributor:FindFirstChild("SubContributor")
	local TitleLabel      = TPL_InfoFrame and TPL_InfoFrame:FindFirstChild("NameSetting")
	local InfoSetting     = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")

	assert(EditTextButton, "[SliderModule.Text] Thiếu 'EditTextButton'")
	if TitleLabel then TitleLabel.Text = name and (name .. "!") or title end
	if InfoSetting then InfoSetting.Text = " " .. title:upper() .. " " end
	setupButtonDelta(settingFrame)

	-- ── PackFrame refs (shared) ─────────────────────────────
	local EditScrollFrame    = packFrame:FindFirstChild("EditText")
	local PreviewScrollFrame = packFrame:FindFirstChild("PreviewText")
	local PF_InfoFrame       = packFrame:FindFirstChild("InfoFrame")
	local PF_Contributor     = PF_InfoFrame and PF_InfoFrame:FindFirstChild("Contributor")
	local PF_SubContrib      = PF_Contributor and PF_Contributor:FindFirstChild("SubContributor")
	local PF_ContribName     = PF_InfoFrame and PF_InfoFrame:FindFirstChild("ContributorName")
	local PF_NameSetting     = PF_InfoFrame and PF_InfoFrame:FindFirstChild("NameSetting")
	local PF_TitleText       = PF_InfoFrame and PF_InfoFrame:FindFirstChild("TitleText")
	local AddLineButton      = packFrame:FindFirstChild("AddLineButton")
	local ChangeModeButton   = packFrame:FindFirstChild("ChangeModeButton")
	local ToolButton         = packFrame:FindFirstChild("ToolButton")
	local PageSizeSlider     = packFrame:FindFirstChild("PageSizeSlider")
	local ToolFrame          = packFrame:FindFirstChild("ToolFrame")
	local ToolContainer      = ToolFrame and ToolFrame:FindFirstChild("Tool")
	local ToolTemplate       = ToolContainer and ToolContainer:FindFirstChild("Size")
	local TipText            = ToolFrame and ToolFrame:FindFirstChild("TipText")

	assert(EditScrollFrame,    "[SliderModule.Text] Thiếu 'EditText' ScrollingFrame")
	assert(PreviewScrollFrame, "[SliderModule.Text] Thiếu 'PreviewText' ScrollingFrame")

	-- ── inst forward declare ────────────────────────────────
	local inst

	-- ── Per-instance state ──────────────────────────────────
	-- ✅ Khởi tạo trước khi dùng S()
	local iState = {
		mode        = "READ",
		lines       = config.default or {},
		creatorId   = config.creator,
		coCreatorId   = config.co_creator,
		subCreatorId  = config.sub_contributor,
		lineRowSize = UDim2.new(1, 0, 0, 32),
		toolOpen    = false,
		pageDrag    = false,
		pagePrevY   = 0,
		conns       = {},
		lineConns   = {},
	}

	-- Shortcut truy cập state qua inst
	local function S()
		return TextStateRegistry[inst]
	end

	-- ════════════════════════════════════════════════════════
	--  CONTRIBUTOR
	-- ════════════════════════════════════════════════════════
	local function setupContributors()
		local sv          = S()
		local hasCreator  = sv.creatorId   ~= nil
		local hasCoCreate = sv.coCreatorId ~= nil

		-- Template
		if TPL_Contributor then
			TPL_Contributor.Visible = hasCreator
			if hasCreator then
				loadContributorAsync(TPL_Contributor, nil, sv.creatorId)
			end
		end
		if TPL_SubContrib then
			TPL_SubContrib.Visible = hasCoCreate
			if hasCoCreate then
				loadContributorAsync(TPL_SubContrib, nil, sv.coCreatorId)
			end
		end

		-- PackFrame (chỉ khi đang active)
		if reg.activeInst ~= inst then return end
		if PF_Contributor then
			PF_Contributor.Visible = hasCreator
			if hasCreator then
				loadContributorAsync(PF_Contributor, PF_ContribName, sv.creatorId)
			end
		end
		if PF_SubContrib then
			PF_SubContrib.Visible = sv.subCreatorId ~= nil
			if sv.subCreatorId then
				loadContributorAsync(PF_SubContrib, nil, sv.subCreatorId)
			end
		end
	end

	local function trySetCreator(userId)
		local sv = S(); if sv.creatorId then return end
		sv.creatorId = userId; setupContributors()
	end

	local function trySetCoCreator(userId)
		local sv = S(); if sv.coCreatorId then return end
		if not sv.creatorId then return end
		if sv.creatorId == userId then return end
		sv.coCreatorId = userId; setupContributors()
	end

	-- ════════════════════════════════════════════════════════
	--  PACK INFO + MODE DISPLAY
	-- ════════════════════════════════════════════════════════
	local function updatePackInfo()
		if reg.activeInst ~= inst then return end
		if PF_NameSetting then PF_NameSetting.Text = name and ("<<" .. name .. "<<") or title end
		if PF_TitleText   then PF_TitleText.Text   = " " .. title:upper() .. " " end
	end

	local function updateModeDisplay()
		local sv = S()
		if CurrentEdit    then CurrentEdit.Text    = sv.mode end
		if SubCurrentEdit then SubCurrentEdit.Text = sv.mode end
	end

	-- ════════════════════════════════════════════════════════
	--  LINE SYSTEM
	-- ════════════════════════════════════════════════════════
	local function clearLineConns()
		local sv = S()
		for _, c in ipairs(sv.lineConns) do c:Disconnect() end
		sv.lineConns = {}
	end

	-- Canvas tự động theo layout signal
	do
		local editLayout = EditScrollFrame:FindFirstChildWhichIsA("UIListLayout")
		if editLayout then
			editLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
				EditScrollFrame.CanvasSize = UDim2.new(0, 0, 0,
					editLayout.AbsoluteContentSize.Y + 8)
			end)
		end
		local previewLayout = PreviewScrollFrame:FindFirstChildWhichIsA("UIListLayout")
		if previewLayout then
			previewLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
				PreviewScrollFrame.CanvasSize = UDim2.new(0, 0, 0,
					previewLayout.AbsoluteContentSize.Y + 8)
			end)
		end
	end

	local EDIT_TEXT_SIZE = 14  -- font size mặc định khi không có tag </s=N>
	local EDIT_MIN_W     = 200 -- chiều rộng tối thiểu ban đầu

	-- ════════════════════════════════════════════════════════
	--  SEGMENT PARSER
	--  Tách raw text thành list segment, mỗi segment có:
	--    text     : string   — nội dung hiển thị
	--    size     : number   — TextSize
	--    bold     : bool
	--    italic   : bool
	--    color    : Color3 | nil
	--    richText : string   — text đã convert sang RichText (cho preview)
	-- ════════════════════════════════════════════════════════
	local function parseSegments(raw)
		-- Stack state
		local sizeStack   = { EDIT_TEXT_SIZE }
		local boldStack   = { false }
		local italicStack = { false }
		local colorStack  = { nil }
		local xAlignStack = { Enum.TextXAlignment.Left }
		local yAlignStack = { Enum.TextYAlignment.Center }

		local segments = {}
		local pos      = 1
		local len      = #raw

		local function currentSize()   return sizeStack[#sizeStack]   end
		local function currentBold()   return boldStack[#boldStack]   end
		local function currentItalic() return italicStack[#italicStack] end
		local function currentColor()  return colorStack[#colorStack]  end
		local function currentXAlign() return xAlignStack[#xAlignStack] end
		local function currentYAlign() return yAlignStack[#yAlignStack] end

		local function pushText(t)
			if t == "" then return end
			local seg = {
				text   = t,
				size   = currentSize(),
				bold   = currentBold(),
				italic = currentItalic(),
				color  = currentColor(),
				xAlign = currentXAlign(),
				yAlign = currentYAlign(),
			}
			-- Build richText cho preview
			local rt = t:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
			if seg.bold   then rt = "<b>" .. rt .. "</b>" end
			if seg.italic then rt = "<i>" .. rt .. "</i>" end
			if seg.size ~= EDIT_TEXT_SIZE then
				rt = '<font size="'..seg.size..'">'..rt.."</font>"
			end
			if seg.color then
				local hex = string.format("#%02X%02X%02X",
					math.floor(seg.color.R*255),
					math.floor(seg.color.G*255),
					math.floor(seg.color.B*255))
				rt = '<font color="'..hex..'">'..rt.."</font>"
			end
			seg.richText = rt
			table.insert(segments, seg)
		end

		while pos <= len do
			local ts, te = raw:find("</%S->", pos)
			if not ts then
				pushText(raw:sub(pos))
				break
			end
			if ts > pos then pushText(raw:sub(pos, ts - 1)) end

			local tc = raw:sub(ts + 2, te - 1)

			if tc == "b" then
				table.insert(boldStack, true)
			elseif tc == "/b" then
				if #boldStack > 1 then table.remove(boldStack) end
			elseif tc == "i" then
				table.insert(italicStack, true)
			elseif tc == "/i" then
				if #italicStack > 1 then table.remove(italicStack) end
			elseif tc:sub(1,2) == "s=" then
				local sz = tonumber(tc:sub(3)) or EDIT_TEXT_SIZE
				table.insert(sizeStack, sz)
			elseif tc == "/s" then
				if #sizeStack > 1 then table.remove(sizeStack) end
			elseif tc:sub(1,2) == "c=" then
				local hex = tc:sub(3)
				if hex:sub(1,1) ~= "#" then hex = "#"..hex end
				local r = tonumber(hex:sub(2,3),16) or 255
				local g = tonumber(hex:sub(4,5),16) or 255
				local b = tonumber(hex:sub(6,7),16) or 255
				table.insert(colorStack, Color3.fromRGB(r,g,b))
			elseif tc == "/c" then
				if #colorStack > 1 then table.remove(colorStack) end
			elseif tc == "n1" then
				table.insert(sizeStack, 28); table.insert(boldStack, true)
			elseif tc == "/n1" then
				if #sizeStack > 1 then table.remove(sizeStack) end
				if #boldStack > 1 then table.remove(boldStack) end
			elseif tc == "n2" then
				table.insert(sizeStack, 22); table.insert(boldStack, true)
			elseif tc == "/n2" then
				if #sizeStack > 1 then table.remove(sizeStack) end
				if #boldStack > 1 then table.remove(boldStack) end
			elseif tc == "n3" then
				table.insert(sizeStack, 18)
			elseif tc == "/n3" then
				if #sizeStack > 1 then table.remove(sizeStack) end
			elseif tc:sub(1,2) == "f=" then
				-- font family — bỏ qua trong segment (chỉ affect preview)
			elseif tc == "/f" then
				-- bỏ qua
				-- ── Alignment X ──────────────────────────────────
			elseif tc == "Xl" then
				table.insert(xAlignStack, Enum.TextXAlignment.Left)
			elseif tc == "Xc" then
				table.insert(xAlignStack, Enum.TextXAlignment.Center)
			elseif tc == "Xr" then
				table.insert(xAlignStack, Enum.TextXAlignment.Right)
			elseif tc == "/Xl" or tc == "/Xc" or tc == "/Xr" then
				if #xAlignStack > 1 then table.remove(xAlignStack) end
				-- ── Alignment Y ──────────────────────────────────
			elseif tc == "Yl" then
				table.insert(yAlignStack, Enum.TextYAlignment.Top)
			elseif tc == "Yc" then
				table.insert(yAlignStack, Enum.TextYAlignment.Center)
			elseif tc == "Yr" then
				table.insert(yAlignStack, Enum.TextYAlignment.Bottom)
			elseif tc == "/Yl" or tc == "/Yc" or tc == "/Yr" then
				if #yAlignStack > 1 then table.remove(yAlignStack) end
			end

			pos = te + 1
		end

		return segments
	end

	-- ════════════════════════════════════════════════════════
	--  MEASURE SEGMENT
	--  Tạo 1 TextLabel ẩn để đo TextBounds của segment
	-- ════════════════════════════════════════════════════════
	local _measureLabel = nil
	local function measureSegment(seg)
		if not _measureLabel then
			_measureLabel = Instance.new("TextLabel")
			_measureLabel.BackgroundTransparency = 1
			_measureLabel.TextWrapped            = false
			_measureLabel.TextScaled             = false
			_measureLabel.Visible                = false
			_measureLabel.Size                   = UDim2.new(0, 9999, 0, 9999)
			_measureLabel.Parent                 = EditScrollFrame.Parent or EditScrollFrame
		end
		_measureLabel.Text      = seg.text
		_measureLabel.TextSize  = seg.size
		_measureLabel.Font      = seg.bold and Enum.Font.GothamBold or Enum.Font.Gotham
		local bounds = _measureLabel.TextBounds
		return bounds.X, bounds.Y
	end

	-- ════════════════════════════════════════════════════════
	--  REFRESH CANVAS X
	-- ════════════════════════════════════════════════════════
	local function refreshEditCanvasX()
		if not EditScrollFrame.Parent then return end
		local maxX = EditScrollFrame.AbsoluteSize.X
		for _, child in ipairs(EditScrollFrame:GetChildren()) do
			if child:IsA("ImageButton") and child.Name == "Line" then
				local w = child.AbsoluteSize.X
				if w > maxX then maxX = w end
			end
		end
		EditScrollFrame.CanvasSize = UDim2.new(
			0, maxX + 20,
			0, EditScrollFrame.CanvasSize.Y.Offset)
	end

	-- ════════════════════════════════════════════════════════
	--  BUILD SEGMENT CHILDREN (dùng chung edit + preview)
	--  Tạo UIListLayout nằm ngang + 1 Label/TextBox mỗi segment
	--  isEdit = true  → TextBox (có thể gõ)
	--  isEdit = false → TextLabel (preview RichText)
	-- ════════════════════════════════════════════════════════
	local function buildSegmentChildren(lineFrame, segments, isEdit, sv2)
		-- UIListLayout nằm ngang
		local layout = Instance.new("UIListLayout")
		layout.FillDirection     = Enum.FillDirection.Horizontal
		layout.SortOrder         = Enum.SortOrder.LayoutOrder
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding           = UDim.new(0, 0)
		layout.Parent            = lineFrame

		local maxH = 0  -- chiều cao lớn nhất trong dòng

		for idx, seg in ipairs(segments) do
			local isLast      = (idx == #segments)
			local bx, by      = measureSegment(seg)
			local displayName = "Text_" .. (seg.text ~= "" and seg.text:sub(1, 20) or "(empty)")
			if by > 0 and by < 10000 then
				if by > maxH then maxH = by end
			end

			if isEdit then
				-- TextBox cho từng segment
				local tb = Instance.new("TextBox")
				tb.Name                   = displayName
				tb.LayoutOrder            = idx
				tb.BackgroundTransparency = 1
				tb.TextColor3             = seg.color or Color3.new(1,1,1)
				tb.TextScaled             = false
				tb.TextSize               = seg.size
				tb.Font                   = seg.bold and Enum.Font.GothamBold or Enum.Font.Gotham
				tb.TextXAlignment         = seg.xAlign or Enum.TextXAlignment.Left
				tb.TextYAlignment         = Enum.TextYAlignment.Center
				tb.TextWrapped            = false
				tb.ClearTextOnFocus       = false
				tb.MultiLine              = false
				tb.Text                   = seg.text
				tb.PlaceholderText        = ""
				tb.PlaceholderColor3      = Color3.fromRGB(120,120,120)

				if isLast then
					-- Segment cuối: fill phần còn lại theo scale
					tb.AutomaticSize = Enum.AutomaticSize.None
					tb.Size          = UDim2.new(1, 0, 1, 0)
				else
					-- Segment giữa: size theo TextBounds.X
					tb.AutomaticSize = Enum.AutomaticSize.X
					tb.Size          = UDim2.new(0, math.max(bx, 1), 1, 0)
				end
				tb.Parent = lineFrame

				-- Track TextBounds thay đổi → update segment width
				if not isLast and sv2 then
					local c = tb:GetPropertyChangedSignal("TextBounds"):Connect(function()
						local nx = tb.TextBounds.X
						if nx > 0 and nx < 100000 then
							tb.Size = UDim2.new(0, nx, 1, 0)
						end
						-- Cập nhật chiều cao dòng nếu Y lớn hơn
						local ny = tb.TextBounds.Y
						if ny > 0 and ny < 10000 and ny > lineFrame.Size.Y.Offset then
							lineFrame.Size = UDim2.new(
								lineFrame.Size.X.Scale, lineFrame.Size.X.Offset,
								0, ny)
						end
					end)
					table.insert(sv2.lineConns, c)
				end
			else
				-- TextLabel cho preview: Scale Y = 1, căn dưới
				local lbl = Instance.new("TextLabel")
				lbl.Name                   = displayName
				lbl.LayoutOrder            = idx
				lbl.BackgroundTransparency = 1
				lbl.TextColor3             = Color3.new(1,1,1)
				lbl.TextScaled             = false
				lbl.TextSize               = seg.size
				lbl.Font                   = seg.bold and Enum.Font.GothamBold or Enum.Font.Gotham
				lbl.TextXAlignment         = seg.xAlign or Enum.TextXAlignment.Left
				lbl.TextYAlignment         = seg.yAlign or Enum.TextYAlignment.Bottom  -- ✅ căn dưới
				lbl.TextWrapped            = false
				lbl.RichText               = true
				lbl.Text                   = seg.richText

				if isLast then
					lbl.AutomaticSize = Enum.AutomaticSize.None
					lbl.Size          = UDim2.new(1, 0, 1, 0)   -- ✅ scale Y = 1
				else
					lbl.AutomaticSize = Enum.AutomaticSize.X
					lbl.Size          = UDim2.new(0, math.max(bx, 1), 1, 0)  -- ✅ scale Y = 1
				end
				lbl.Parent = lineFrame
			end
		end

		-- Set chiều cao lineFrame = segment cao nhất
		if maxH > 0 then
			lineFrame.Size = UDim2.new(
				lineFrame.Size.X.Scale, lineFrame.Size.X.Offset,
				0, maxH)
		end
	end

	-- ════════════════════════════════════════════════════════
	--  HELPER: tính LayoutOrder tiếp theo cho EditScrollFrame
	-- ════════════════════════════════════════════════════════
	local function nextEditOrder()
		local maxOrder = 0
		for _, child in ipairs(EditScrollFrame:GetChildren()) do
			if child:IsA("ImageButton") and child.LayoutOrder > maxOrder then
				maxOrder = child.LayoutOrder
			end
		end
		return maxOrder + 1
	end

	local function nextPreviewOrder()
		local maxOrder = 0
		for _, child in ipairs(PreviewScrollFrame:GetChildren()) do
			if child:IsA("ImageButton") and child.LayoutOrder > maxOrder then
				maxOrder = child.LayoutOrder
			end
		end
		return maxOrder + 1
	end

	-- ════════════════════════════════════════════════════════
	--  CREATE PREVIEW LINE
	-- ════════════════════════════════════════════════════════
	local function createPreviewLine(rawText)
		-- Container: ImageButton để có hover
		local lineFrame = Instance.new("ImageButton")
		lineFrame.Name                   = "Line"
		lineFrame.LayoutOrder            = nextPreviewOrder()
		lineFrame.BackgroundColor3       = Color3.new(0, 0, 0)
		lineFrame.BackgroundTransparency = 1
		lineFrame.AutoButtonColor        = false
		lineFrame.Image                  = ""
		lineFrame.AutomaticSize          = Enum.AutomaticSize.X
		lineFrame.Size                   = UDim2.new(0, EDIT_MIN_W, 0, EDIT_TEXT_SIZE)

		-- Hover effect
		lineFrame.MouseEnter:Connect(function()
			TweenService:Create(lineFrame,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 0.8 }
			):Play()
		end)
		lineFrame.MouseLeave:Connect(function()
			TweenService:Create(lineFrame,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 1 }
			):Play()
		end)

		local raw      = rawText or ""
		local segments = parseSegments(raw)

		if #segments == 0 then
			segments = {{ text="", size=EDIT_TEXT_SIZE, bold=false,
				italic=false, color=nil, richText="" }}
		end

		buildSegmentChildren(lineFrame, segments, false, nil)
		lineFrame.Parent = PreviewScrollFrame

		return lineFrame
	end

	local function getAllEditLines()
		local editLines = {}
		for _, child in ipairs(EditScrollFrame:GetChildren()) do
			if child:IsA("ImageButton") and child.Name == "Line" then
				table.insert(editLines, child)
			end
		end
		table.sort(editLines, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		local lines = {}
		for _, lineFrame in ipairs(editLines) do
			-- TextBox con có tên bắt đầu bằng "Text_"
			local tb = nil
			for _, child in ipairs(lineFrame:GetChildren()) do
				if child:IsA("TextBox") then tb = child; break end
			end
			table.insert(lines, tb and tb.Text or "")
		end
		return lines
	end
	local function clearEditLines()
		clearLineConns()  -- ✅ disconnect trước khi destroy
		for _, child in ipairs(EditScrollFrame:GetChildren()) do
			if child:IsA("ImageButton") then child:Destroy() end
		end
	end

	local function clearPreviewLines()
		for _, child in ipairs(PreviewScrollFrame:GetChildren()) do
			if child:IsA("ImageButton") then child:Destroy() end
		end
	end

	local function syncPreview()
		clearPreviewLines()
		for _, line in ipairs(getAllEditLines()) do
			createPreviewLine(line)
		end
	end



	-- ════════════════════════════════════════════════════════
	--  FUZZY MATCH HELPERS
	-- ════════════════════════════════════════════════════════

	-- Chuẩn hoá: lowercase, collapse spaces
	local function normalizeStr(s)
		return s:lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
	end

	-- Tính số ký tự chung theo thứ tự (LCS length đơn giản)
	local function lcsLength(a, b)
		local na, nb = #a, #b
		if na == 0 or nb == 0 then return 0 end
		local prev = {}
		for j = 0, nb do prev[j] = 0 end
		for i = 1, na do
			local curr = {[0]=0}
			for j = 1, nb do
				if a:sub(i,i) == b:sub(j,j) then
					curr[j] = prev[j-1] + 1
				else
					curr[j] = math.max(prev[j], curr[j-1])
				end
			end
			prev = curr
		end
		return prev[nb]
	end

	-- Score: tỉ lệ LCS / max(len) — 0..1
	local function fuzzyScore(query, target)
		local q = normalizeStr(query)
		local t = normalizeStr(target)
		if q == "" then return 0 end
		if t:find(q, 1, true) then return 1 end  -- exact substring → perfect
		local lcs = lcsLength(q, t)
		return lcs / math.max(#q, #t)
	end

	-- Parse input người dùng: "value , text" hoặc chỉ "text"
	-- Trả về: paramValue (string|nil), searchText (string)
	local function parseValueInput(raw, hasParam)
		if not hasParam then
			return nil, raw:match("^%s*(.-)%s*$")
		end
		-- Tìm dấu phẩy đầu tiên
		local commaPos = raw:find(",")
		if commaPos then
			local paramPart  = raw:sub(1, commaPos-1):match("^%s*(.-)%s*$")
			local searchPart = raw:sub(commaPos+1):match("^%s*(.-)%s*$")
			-- Loại bỏ dấu ngoặc kép nếu có
			searchPart = searchPart:match('^"(.-)"$') or searchPart
			return paramPart, searchPart
		else
			-- Không có dấu phẩy → toàn bộ là search text, không có param
			return nil, raw:match("^%s*(.-)%s*$")
		end
	end

	-- ════════════════════════════════════════════════════════
	--  APPLY TAG TO LINE RAW TEXT
	--  Tìm đoạn text khớp nhất trong rawLine, wrap bằng tag mới.
	--  Xử lý split segment khi cần.
	-- ════════════════════════════════════════════════════════
	local function applyTagToLine(rawLine, tool, paramValue, searchText)
		-- Parse segments của dòng này
		local segs = parseSegments(rawLine)
		if #segs == 0 then return rawLine end

		-- Score từng segment
		local bestScore = 0
		local bestIdx   = nil
		for i, seg in ipairs(segs) do
			local sc = fuzzyScore(searchText, seg.text)
			if sc > bestScore then
				bestScore = sc
				bestIdx   = i
			end
		end

		-- Không tìm thấy gì đủ gần (threshold 0.2)
		if not bestIdx or bestScore < 0.2 then return rawLine end

		local targetSeg = segs[bestIdx]

		-- Tìm vị trí sub-string trong segment text (normalized)
		local normQuery  = normalizeStr(searchText)
		local normTarget = normalizeStr(targetSeg.text)

		-- Tìm start/end trong targetSeg.text của phần match
		local matchStart, matchEnd = nil, nil

		-- Thử exact substring (case-insensitive) trước
		local lo = normTarget:find(normQuery, 1, true)
		if lo then
			-- map back từ normalized → original (approximate, dùng char count)
			matchStart = lo
			matchEnd   = lo + #normQuery - 1
		else
			-- Không có exact → wrap toàn bộ segment
			matchStart = 1
			matchEnd   = #targetSeg.text
		end

		-- Build tag wrapper
		local function makeOpenTag()
			if tool.tag == "s" and paramValue then
				return "</s=" .. paramValue .. ">"
			elseif tool.tag == "c" and paramValue then
				local hex = paramValue
				if hex:sub(1,1) ~= "#" then hex = "#"..hex end
				return "</c=" .. hex .. ">"
			elseif tool.tag == "f" and paramValue then
				return "</f=" .. paramValue .. ">"
			else
				return "</" .. tool.tag .. ">"
			end
		end
		local function makeCloseTag()
			return "</" .. "/" .. tool.tag:gsub("=.+","") .. ">"
		end

		-- Rebuild raw line từ segments, wrapping phần match
		-- Strategy: tái tạo raw text của từng segment dựa trên segs
		-- (Chúng ta không lưu raw per-segment nên phải rebuild từ text + style)

		local function segToRaw(seg, innerText)
			local t = innerText or seg.text
			-- Alignment
			local xTag = nil
			if seg.xAlign == Enum.TextXAlignment.Center then xTag = "Xc"
			elseif seg.xAlign == Enum.TextXAlignment.Right then xTag = "Xr"
			end
			local yTag = nil
			if seg.yAlign == Enum.TextYAlignment.Top then yTag = "Yl"
			elseif seg.yAlign == Enum.TextYAlignment.Bottom then yTag = "Yr"
			end
			if seg.bold then t = "</" .. "b>" .. t .. "</" .. "/b>" end
			if seg.italic then t = "</" .. "i>" .. t .. "</" .. "/i>" end
			if seg.size ~= EDIT_TEXT_SIZE then
				t = "</" .. "s=" .. seg.size .. ">" .. t .. "</" .. "/s>"
			end
			if seg.color then
				local hex = string.format("#%02X%02X%02X",
					math.floor(seg.color.R*255),
					math.floor(seg.color.G*255),
					math.floor(seg.color.B*255))
				t = "</" .. "c=" .. hex .. ">" .. t .. "</" .. "/c>"
			end
			if xTag then t = "</" .. xTag .. ">" .. t .. "</" .. "/" .. xTag .. ">" end
			if yTag then t = "</" .. yTag .. ">" .. t .. "</" .. "/" .. yTag .. ">" end
			return t
		end

		local open  = makeOpenTag()
		local close = "</" .. "/" .. tool.tag:gsub("=.+","") .. ">"

		local result = ""
		for i, seg in ipairs(segs) do
			if i ~= bestIdx then
				result = result .. segToRaw(seg)
			else
				local st = seg.text
				local before = st:sub(1, matchStart - 1)
				local middle = st:sub(matchStart, matchEnd)
				local after  = st:sub(matchEnd + 1)

				local wrappedMiddle = open .. middle .. close

				-- Rebuild segment với trước, giữa-wrap, sau
				if before ~= "" then
					result = result .. segToRaw(seg, before)
				end
				-- Middle: merge style của seg + new tag
				-- Nếu middle thừa kế style của seg, wrap thêm tag mới
				local midRaw = segToRaw(seg, middle)
				-- Bỏ lớp ngoài rồi bọc lại với tag mới bên trong
				result = result .. segToRaw(seg, open .. middle .. close)
				if after ~= "" then
					result = result .. segToRaw(seg, after)
				end
			end
		end

		return result
	end

	-- ════════════════════════════════════════════════════════
	--  LINE SELECT MODE STATE (shared per packFrame)
	-- ════════════════════════════════════════════════════════
	local lineSelectMode = {
		active    = false,
		tool      = nil,   -- tool đang chờ chọn dòng
		inputBox  = nil,   -- TextBox nhập value (tạo động)
		inputConn = nil,   -- connection confirm
	}

	local function exitLineSelectMode()
		lineSelectMode.active = false
		lineSelectMode.tool   = nil
		if lineSelectMode.inputBox and lineSelectMode.inputBox.Parent then
			lineSelectMode.inputBox:Destroy()
		end
		lineSelectMode.inputBox = nil
		if lineSelectMode.inputConn then
			lineSelectMode.inputConn:Disconnect()
			lineSelectMode.inputConn = nil
		end
		-- Restore hover color trên tất cả lines về bình thường
		if EditScrollFrame then
			for _, child in ipairs(EditScrollFrame:GetChildren()) do
				if child:IsA("ImageButton") and child.Name == "Line" then
					child.BackgroundColor3 = Color3.new(0,0,0)
				end
			end
		end
		if TipText then TipText.Text = "" end
	end

	-- Tạo input box nổi lên trên packFrame để nhập value + searchText
	local function createValueInputBox(tool, onConfirm)
		-- Xóa cái cũ nếu có
		if lineSelectMode.inputBox and lineSelectMode.inputBox.Parent then
			lineSelectMode.inputBox:Destroy()
		end

		local inputFrame = Instance.new("Frame")
		inputFrame.Name                   = "ValueInputPopup"
		inputFrame.Size                   = UDim2.new(0, 280, 0, 60)
		inputFrame.AnchorPoint            = Vector2.new(0.5, 0)
		inputFrame.Position               = UDim2.new(0.5, 0, 0, 4)
		inputFrame.BackgroundColor3       = Color3.fromRGB(30, 30, 40)
		inputFrame.BackgroundTransparency = 0.1
		inputFrame.BorderSizePixel        = 0
		inputFrame.ZIndex                 = 20
		inputFrame.Parent                 = packFrame

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = inputFrame

		local hintLabel = Instance.new("TextLabel")
		hintLabel.Size                   = UDim2.new(1, -8, 0, 18)
		hintLabel.Position               = UDim2.new(0, 4, 0, 2)
		hintLabel.BackgroundTransparency = 1
		hintLabel.TextColor3             = Color3.fromRGB(150, 200, 255)
		hintLabel.TextSize               = 11
		hintLabel.Font                   = Enum.Font.Gotham
		hintLabel.TextXAlignment         = Enum.TextXAlignment.Left
		hintLabel.Text                   = tool.valueHint or '"text to find"'
		hintLabel.ZIndex                 = 21
		hintLabel.Parent                 = inputFrame

		local tb = Instance.new("TextBox")
		tb.Name                   = "ValueInput"
		tb.Size                   = UDim2.new(1, -8, 0, 28)
		tb.Position               = UDim2.new(0, 4, 0, 20)
		tb.BackgroundColor3       = Color3.fromRGB(50, 50, 65)
		tb.BackgroundTransparency = 0
		tb.BorderSizePixel        = 0
		tb.TextColor3             = Color3.new(1,1,1)
		tb.TextSize               = 13
		tb.Font                   = Enum.Font.Gotham
		tb.TextXAlignment         = Enum.TextXAlignment.Left
		tb.PlaceholderText        = tool.valueHint or ""
		tb.PlaceholderColor3      = Color3.fromRGB(100,100,120)
		tb.ClearTextOnFocus       = false
		tb.Text                   = ""
		tb.ZIndex                 = 21
		tb.Parent                 = inputFrame

		local tbCorner = Instance.new("UICorner")
		tbCorner.CornerRadius = UDim.new(0, 4)
		tbCorner.Parent = tb

		lineSelectMode.inputBox = inputFrame

		-- Enter → confirm
		lineSelectMode.inputConn = tb.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				onConfirm(tb.Text)
			end
		end)

		task.defer(function() tb:CaptureFocus() end)
		return tb
	end

	-- ════════════════════════════════════════════════════════
	--  TOOL FRAME
	--  ✅ Build 1 lần cho packFrame, dùng chung giữa các inst
	-- ════════════════════════════════════════════════════════
	local function buildToolFrame()
		if reg.toolBuilt then return end
		reg.toolBuilt = true
		if not ToolTemplate or not ToolContainer then return end
		ToolTemplate.Visible = false

		for _, child in ipairs(ToolContainer:GetChildren()) do
			if child ~= ToolTemplate
				and not child:IsA("UIListLayout")
				and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end

		for idx, tool in ipairs(TEXT_TOOLS) do
			local btn = ToolTemplate:Clone()
			btn.Name        = "Tool_" .. tool.tag
			btn.LayoutOrder = idx
			btn.Visible     = true

			-- ── Hiển thị chỉ tag ngắn ──────────────────────
			local CodeText = btn:FindFirstChild("CodeText")
			if CodeText then
				CodeText.RichText = true
				-- Chỉ hiện label ngắn với màu vàng
				local escaped = tool.label
					:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
				CodeText.Text = '<font color="#FFC850">' .. escaped .. "</font>"
			end

			local Decor = btn:FindFirstChild("Decor")
			btn.MouseEnter:Connect(function()
				-- Tip = full syntax
				if TipText then TipText.Text = tool.tip end
				if Decor then
					TweenService:Create(Decor,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ BackgroundTransparency = 0.7 }
					):Play()
				end
			end)
			btn.MouseLeave:Connect(function()
				if TipText and not lineSelectMode.active then
					TipText.Text = ""
				end
				if Decor then
					TweenService:Create(Decor,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ BackgroundTransparency = 1 }
					):Play()
				end
			end)

			-- ── Click: nếu cần valueParam → vào line-select mode ──
			btn.MouseButton1Click:Connect(function()
				if not reg.activeInst then return end
				local sv = TextStateRegistry[reg.activeInst]
				if not sv or sv.mode ~= "EDIT" then return end

				if tool.valueParam then
					-- Bật line-select mode
					if lineSelectMode.active and lineSelectMode.tool == tool then
						-- Click lần 2 cùng tool → thoát
						exitLineSelectMode()
						return
					end
					exitLineSelectMode()
					lineSelectMode.active = true
					lineSelectMode.tool   = tool

					if TipText then
						TipText.Text = "▶ Click một dòng để áp dụng  [" .. tool.label .. "]"
					end

					-- Highlight tất cả Line buttons màu xanh nhạt
					for _, child in ipairs(EditScrollFrame:GetChildren()) do
						if child:IsA("ImageButton") and child.Name == "Line" then
							child.BackgroundColor3 = Color3.fromRGB(30, 80, 180)
						end
					end

					-- Tạo popup nhập value + searchText
					createValueInputBox(tool, function(inputText)
						-- Người dùng đã nhấn Enter → lưu lại inputText
						-- Chờ người dùng click dòng
						lineSelectMode.pendingInput = inputText
						if TipText then
							TipText.Text = "▶ Đã nhập: [" .. inputText .. "] — Click dòng để apply"
						end
					end)

				else
					-- Không cần valueParam → chèn tag ngay vào TextBox đang focus
					exitLineSelectMode()
					for _, child in ipairs(EditScrollFrame:GetChildren()) do
						if child:IsA("ImageButton") and child.Name == "Line" then
							for _, tbChild in ipairs(child:GetChildren()) do
								if tbChild:IsA("TextBox") and tbChild:IsFocused() then
									tbChild.Text = tbChild.Text .. tool.insert
									break
								end
							end
						end
					end
				end
			end)

			btn.Parent = ToolContainer
		end
	end

	local function toggleToolFrame()
		local sv    = S()
		sv.toolOpen = not sv.toolOpen
		if not ToolFrame then return end
		ToolFrame.Visible = sv.toolOpen
		TweenService:Create(ToolFrame,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = sv.toolOpen and 0 or 1 }
		):Play()
	end

	-- ════════════════════════════════════════════════════════
	--  PAGE SIZE SLIDER
	-- ════════════════════════════════════════════════════════
	local MIN_ROW_Y = 24
	local MAX_ROW_Y = 80

	local function applyRowSize(newY)
		local sv = S()
		newY = math.clamp(newY, MIN_ROW_Y, MAX_ROW_Y)
		sv.lineRowSize = UDim2.new(1, 0, 0, newY)

		-- Edit: chỉ thay chiều cao, giữ chiều rộng tự giãn
		for _, child in ipairs(EditScrollFrame:GetChildren()) do
			if child:IsA("Frame") and child.Name == "EditLine" then
				child.Size = UDim2.new(
					child.Size.X.Scale, child.Size.X.Offset,
					0, newY)
			end
		end

		-- Preview: resize chiều cao dựa trên segment labels thực tế
		for _, child in ipairs(PreviewScrollFrame:GetChildren()) do
			if child:IsA("ImageButton") and child.Name:sub(1,4) == "Line" then
				local maxSegH = 0
				for _, seg in ipairs(child:GetChildren()) do
					if seg:IsA("TextLabel") then
						local by = seg.TextBounds.Y
						if by > 0 and by < 10000 and by > maxSegH then
							maxSegH = by
						end
					end
				end
				local finalH = math.max(maxSegH, newY)
				child.Size = UDim2.new(1, 0, 0, finalH)
			end
		end

		refreshEditCanvasX()
	end

	-- ════════════════════════════════════════════════════════
	--  OPEN / CLOSE PACKFRAME
	-- ════════════════════════════════════════════════════════
	local function closePackFrame(isSwitching)
		if reg.activeInst ~= inst then return end
		-- ✅ Lưu lines trước khi đóng
		local sv = S()
		sv.lines = getAllEditLines()

		registerClose(inst)
		reg.activeInst = nil

		if reg.trackConn then
			reg.trackConn:Disconnect()
			reg.trackConn = nil
		end

		if isSwitching then
			packFrame.Visible = true  -- giữ visible để inst mới load đè lên
			return
		end

		TweenService:Create(packFrame,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		):Play()
		task.delay(0.2, function()
			if reg.activeInst == nil then
				packFrame.Visible = false
			end
		end)
	end

	
	-- ════════════════════════════════════════════════════════
	--  CREATE EDIT LINE
	-- ════════════════════════════════════════════════════════
	local function createEditLine(text)
		local sv        = S()
		local rawText   = text or ""

		-- Kiểm tra </Delete> → xóa dòng này (dùng khi load lại)
		-- (check khi gõ, xem bên dưới)

		-- Container: ImageButton để có hover
		local lineFrame = Instance.new("ImageButton")
		lineFrame.Name                   = "Line"
		lineFrame.LayoutOrder            = nextEditOrder()
		lineFrame.BackgroundColor3       = Color3.new(0, 0, 0)
		lineFrame.BackgroundTransparency = 1      -- mặc định trong suốt
		lineFrame.AutoButtonColor        = false
		lineFrame.Image                  = ""
		lineFrame.AutomaticSize          = Enum.AutomaticSize.X
		lineFrame.Size                   = UDim2.new(0, EDIT_MIN_W, 0, EDIT_TEXT_SIZE)

		-- Hover effect (line-select mode aware)
		lineFrame.MouseEnter:Connect(function()
			local hoverColor = lineSelectMode.active
				and Color3.fromRGB(50, 120, 255)
				or Color3.new(0,0,0)
			lineFrame.BackgroundColor3 = hoverColor
			TweenService:Create(lineFrame,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 0.8 }
			):Play()
		end)
		lineFrame.MouseLeave:Connect(function()
			if lineSelectMode.active then
				lineFrame.BackgroundColor3 = Color3.fromRGB(30, 80, 180)
				TweenService:Create(lineFrame,
					TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ BackgroundTransparency = 0.6 }
				):Play()
			else
				lineFrame.BackgroundColor3 = Color3.new(0,0,0)
				TweenService:Create(lineFrame,
					TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ BackgroundTransparency = 1 }
				):Play()
			end
		end)

		-- ── Line-Select Mode: click dòng để apply tag ───────
		lineFrame.MouseButton1Click:Connect(function()
			if not lineSelectMode.active then return end
			local tool      = lineSelectMode.tool
			local inputText = lineSelectMode.pendingInput or ""
			if inputText == "" then
				if TipText then TipText.Text = "⚠ Nhập value trước rồi nhấn Enter!" end
				return
			end

			local tb2 = nil
			for _, ch in ipairs(lineFrame:GetChildren()) do
				if ch:IsA("TextBox") then tb2 = ch; break end
			end
			if not tb2 then return end

			local paramValue, searchText = parseValueInput(inputText, tool.valueParam ~= nil)
			if not searchText or searchText == "" then
				exitLineSelectMode(); return
			end

			local newRaw = applyTagToLine(tb2.Text, tool, paramValue, searchText)
			if newRaw ~= tb2.Text then
				tb2.Text = newRaw
			end

			exitLineSelectMode()
		end)

		local tbDisplayName = "Text_" .. (rawText ~= "" and rawText:sub(1,20) or "(empty)")
		local tb = Instance.new("TextBox")
		tb.Name                   = tbDisplayName
		tb.BackgroundTransparency = 1
		tb.TextColor3             = Color3.new(1, 1, 1)
		tb.TextScaled             = false
		tb.TextSize               = EDIT_TEXT_SIZE
		tb.Font                   = Enum.Font.Gotham
		tb.TextXAlignment         = Enum.TextXAlignment.Left
		tb.TextYAlignment         = Enum.TextYAlignment.Center
		tb.TextWrapped            = false
		tb.ClearTextOnFocus       = false
		tb.MultiLine              = false
		tb.AutomaticSize          = Enum.AutomaticSize.X
		tb.Size                   = UDim2.new(0, EDIT_MIN_W, 1, 0)
		tb.Text                   = rawText
		tb.PlaceholderText        = "Type here..."
		tb.PlaceholderColor3      = Color3.fromRGB(120, 120, 120)
		tb.Parent                 = lineFrame

		lineFrame.Parent = EditScrollFrame

		local sv2 = S()

		-- Tên TextBox cập nhật theo nội dung
		local cName = tb:GetPropertyChangedSignal("Text"):Connect(function()
			tb.Name = "Text_" .. (tb.Text ~= "" and tb.Text:sub(1,20) or "(empty)")

			-- </Delete> → xóa dòng này
			if tb.Text:find("</Delete>") then
				lineFrame:Destroy()
				refreshEditCanvasX()
			end
		end)
		table.insert(sv2.lineConns, cName)

		-- Theo dõi TextBounds.Y → chiều cao lineFrame
		local c1 = tb:GetPropertyChangedSignal("TextBounds"):Connect(function()
			local by = tb.TextBounds.Y
			if by > 0 and by < 10000 then
				lineFrame.Size = UDim2.new(
					lineFrame.Size.X.Scale, lineFrame.Size.X.Offset,
					0, by)
			end
		end)
		table.insert(sv2.lineConns, c1)

		-- Khi lineFrame giãn ngang → cập nhật CanvasSize.X
		local c2 = lineFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			refreshEditCanvasX()
		end)
		table.insert(sv2.lineConns, c2)

		-- Set chiều cao sau 1 frame
		task.defer(function()
			if not tb.Parent then return end
			local by = tb.TextBounds.Y
			if by > 0 and by < 10000 then
				lineFrame.Size = UDim2.new(
					lineFrame.Size.X.Scale, lineFrame.Size.X.Offset,
					0, by)
			end
		end)

		return lineFrame, tb
	end
	
	-- ════════════════════════════════════════════════════════
	--  MODE SWITCH
	-- ════════════════════════════════════════════════════════
	local function applyMode(mode)
		local sv = S()
		sv.mode  = mode
		updateModeDisplay()

		if mode == "EDIT" then
			EditScrollFrame.Visible    = true
			PreviewScrollFrame.Visible = false
			local hasLines = false
			for _, c in ipairs(EditScrollFrame:GetChildren()) do
				if c:IsA("ImageButton") then hasLines=true; break end
			end
			if not hasLines then createEditLine("") end
		else
			sv.lines = getAllEditLines()  -- ✅ lưu trước khi sang READ
			syncPreview()
			EditScrollFrame.Visible    = false
			PreviewScrollFrame.Visible = true
		end
	end
	
	local function loadLinesToEdit(lines)
		clearEditLines()
		if not lines or #lines == 0 then
			createEditLine("")
		else
			for _, line in ipairs(lines) do
				createEditLine(line)
			end
		end
	end
	
	-- Load toàn bộ data của inst lên packFrame
	local function loadDataToPackFrame()
		local sv = S()
		updatePackInfo()
		setupContributors()
		loadLinesToEdit(sv.lines)
		if sv.mode == "EDIT" then
			EditScrollFrame.Visible    = true
			PreviewScrollFrame.Visible = false
		else
			syncPreview()
			EditScrollFrame.Visible    = false
			PreviewScrollFrame.Visible = true
		end
	end
	
	local function openPackFrame()
		local prevInst    = reg.activeInst
		local isSwitching = prevInst ~= nil and prevInst ~= inst

		if isSwitching then
			prevInst:_closeListExternal_switch()
		end

		registerOpen(inst)
		reg.activeInst = inst
		buildToolFrame()

		if not isSwitching then
			packFrame.BackgroundTransparency = 1
		end
		packFrame.Visible = true
		TweenService:Create(packFrame,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0.9 }
		):Play()

		loadDataToPackFrame()
	end


	-- ════════════════════════════════════════════════════════
	--  SHARED BUTTON BINDS  (1 lần cho packFrame)
	-- ════════════════════════════════════════════════════════
	if not packFrame:GetAttribute("TextBound") then
		packFrame:SetAttribute("TextBound", true)

		if AddLineButton then
			AddLineButton.MouseButton1Click:Connect(function()
				local active = reg.activeInst; if not active then return end
				local sv     = TextStateRegistry[active]
				if sv and sv.mode == "EDIT" then
					-- ✅ Gọi createEditLine trên context của active inst
					active:_addLine("")
				end
			end)
		end

		if ChangeModeButton then
			ChangeModeButton.MouseButton1Click:Connect(function()
				local active = reg.activeInst; if not active then return end
				local sv     = TextStateRegistry[active]
				if not sv then return end

				local newMode = sv.mode == "READ" and "EDIT" or "READ"

				if newMode == "EDIT" then
					local player = Players.LocalPlayer
					if player then
						if not sv.creatorId then
							active:setCreator(player.UserId)
						elseif sv.creatorId ~= player.UserId then
							active:setCoCreator(player.UserId)
						end
					end
				end

				-- ✅ Fire onChange khi rời EDIT → READ
				if sv.mode == "EDIT" and newMode == "READ" then
					sv.lines = getAllEditLines()
					if config.onChange then
						config.onChange(sv.lines, {
							title     = active._title,
							timestamp = makeTimestamp(active._title),
						}, active._tag)
					end
				end

				active:setMode(newMode)
			end)
		end

		if ToolButton then
			ToolButton.MouseButton1Click:Connect(function()
				local active = reg.activeInst; if not active then return end
				active:_toggleTool()
			end)
		end

		if PageSizeSlider then
			PageSizeSlider.InputBegan:Connect(function(input)
				local active = reg.activeInst; if not active then return end
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					local sv = TextStateRegistry[active]
					if sv then sv.pageDrag=true; sv.pagePrevY=input.Position.Y end
				end
			end)
			UserInputService.InputChanged:Connect(function(input)
				local active = reg.activeInst; if not active then return end
				local sv     = TextStateRegistry[active]
				if not sv or not sv.pageDrag then return end
				if input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch then
					local delta  = sv.pagePrevY - input.Position.Y
					sv.pagePrevY = input.Position.Y
					active:_applyRowSize(sv.lineRowSize.Y.Offset + delta * 0.5)
				end
			end)
			UserInputService.InputEnded:Connect(function(input)
				local active = reg.activeInst; if not active then return end
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					local sv = TextStateRegistry[active]
					if sv then sv.pageDrag = false end
				end
			end)
		end
	end

	-- EditTextButton → toggle packFrame
	table.insert(iState.conns, EditTextButton.MouseButton1Click:Connect(function()
		if reg.activeInst == inst then
			closePackFrame(false)
		else
			openPackFrame()
		end
	end))

	-- ════════════════════════════════════════════════════════
	--  BUILD INST  (✅ trước khi đăng ký TextStateRegistry)
	-- ════════════════════════════════════════════════════════
	inst = setmetatable({
		Frame  = settingFrame,
		_title = title,
		_tag   = config.tag,
	}, SliderModule)

	-- ✅ Đăng ký state ngay sau khi tạo inst
	TextStateRegistry[inst] = iState

	-- ── Init ────────────────────────────────────────────────
	updateModeDisplay()
	setupContributors()
	if ToolFrame then ToolFrame.Visible = false end
	packFrame.Visible = false

	-- ════════════════════════════════════════════════════════
	--  PUBLIC API
	-- ════════════════════════════════════════════════════════
	function inst:getValue()
		-- ✅ Realtime nếu đang active, cached nếu không
		if reg.activeInst == self then
			return getAllEditLines()
		end
		return S().lines
	end

	function inst:setValue(lines)
		local sv = S()
		sv.lines = lines or {}
		if reg.activeInst == self then
			loadLinesToEdit(sv.lines)
			if sv.mode == "READ" then syncPreview() end
		end
	end

	function inst:setMode(mode)
		applyMode(mode)
	end

	function inst:setCreator(userId)
		trySetCreator(userId)
	end

	function inst:setCoCreator(userId)
		trySetCoCreator(userId)
	end

	function inst:setOnChange(fn)
		config.onChange = fn
	end

	function inst:setVisible(bool)
		settingFrame.Visible = bool
	end

	-- Internal: thêm dòng mới (gọi từ shared AddLineButton)
	function inst:_addLine(text)
		createEditLine(text)
	end

	-- Internal: toggle ToolFrame
	function inst:_toggleTool()
		toggleToolFrame()
	end

	-- Internal: apply row size
	function inst:_applyRowSize(newY)
		applyRowSize(newY)
	end

	-- Internal: đóng từ external (không switch)
	function inst:_closeListExternal()
		closePackFrame(false)
	end

	-- Internal: đóng khi switch inst (giữ packFrame visible)
	function inst:_closeListExternal_switch()
		local sv = S()
		sv.lines = getAllEditLines()  -- ✅ lưu trước khi switch
		closePackFrame(true)
	end

	function inst:destroy()
		closePackFrame(false)
		local sv = S()
		-- ✅ Disconnect tất cả connections
		for _, c in ipairs(sv.conns)    do c:Disconnect() end
		for _, c in ipairs(sv.lineConns) do c:Disconnect() end
		sv.conns     = {}
		sv.lineConns = {}
		-- ✅ Xóa khỏi TextStateRegistry
		TextStateRegistry[self] = nil
		-- ✅ Xóa textRegistry nếu không còn inst nào dùng packFrame
		local anyLeft = false
		for _, v in pairs(createdSliders) do
			if v ~= self and TextStateRegistry[v] ~= nil then
				anyLeft = true; break
			end
		end
		if not anyLeft then
			textRegistry[packFrame] = nil
		end
		createdSliders[settingFrame] = nil
		if settingFrame.Parent then settingFrame:Destroy() end
	end

	createdSliders[settingFrame] = inst
	return inst
end

-- ============================================================
--  SliderModule.Code  |  Reward Code Redeem Component  v2
--
--  Dán đoạn này vào Setting13.lua, TRƯỚC dòng "return SliderModule"
--  Sau đó thêm "or t == "Code"" vào assert trong SliderModule.New
--
-- ════════════════════════════════════════════════════════════
--  CHẾ ĐỘ HOẠT ĐỘNG
-- ════════════════════════════════════════════════════════════
--
--  ┌─────────────────────────────────────────────────────────┐
--  │  Không có codes, không có module  →  TEST MODE          │
--  │  Chỉ có codes (không có module)   →  TEST MODE          │
--  │  Có module (dù có codes hay không) →  REAL MODE         │
--  └─────────────────────────────────────────────────────────┘
--
--  TEST MODE:
--    - Nhận code bất kỳ → "✓ TEST: <code>"
--    - Không cấp phần thưởng thật
--    - Nếu có codes → kiểm tra đúng/sai như bình thường
--    - Không cần config "TEST" — tự động
--
--  REAL MODE:
--    - Module tự xử lý reward (DataStore, RemoteEvent...)
--    - onRedeem vẫn được gọi sau khi module xử lý
--    - codes trong config bị bỏ qua hoàn toàn
--
-- ════════════════════════════════════════════════════════════
--  CẤU TRÚC MODULE THẬT
-- ════════════════════════════════════════════════════════════
--
--  Module cần export một table với các function sau:
--
--    local CodeModule = {}
--
--    -- [Bắt buộc] Kiểm tra + lấy data của code
--    -- Trả về: { valid, reward, uses, maxUses, reason } hoặc nil nếu không tìm thấy
--    function CodeModule.getCode(code)
--        -- code đã được normalize (trim + uppercase nếu caseSensitive=false)
--        return { valid=true, reward="100 Coins", uses=1, maxUses=50 }
--        -- hoặc return nil  ← module không biết code này
--    end
--
--    -- [Tùy chọn] Xử lý reward sau khi xác nhận hợp lệ
--    -- Gọi sau khi getCode trả về valid=true
--    function CodeModule.onCodeRedeemed(code, reward, info)
--        -- info = { title, timestamp, uses, maxUses, userId }
--        -- Nơi để fire RemoteEvent, lưu DataStore...
--    end
--
--    -- [Tùy chọn] Nhận lịch sử mỗi khi có redeem thành công
--    function CodeModule.onHistory(entry)
--        -- entry = { code, reward, timestamp, userId }
--    end
--
--    -- [Tùy chọn] Nhận userId để xác định người dùng
--    -- Nếu không có, SliderModule tự lấy Players.LocalPlayer.UserId
--    function CodeModule.getUserId()
--        return game:GetService("Players").LocalPlayer.UserId
--    end
--
--    return CodeModule
--
-- ════════════════════════════════════════════════════════════
--  CẤU TRÚC TEMPLATE (CodeTemplate)
-- ════════════════════════════════════════════════════════════
--
--  CodeTemplate (Frame)
--  ├── UIAspectRatioConstraint
--  ├── UICorner / UIGradient
--  ├── BoxFrame (Frame)
--  │   ├── UICorner
--  │   ├── CodeEnter          ← TextBox nhập code  [BẮT BUỘC]
--  │   └── Decor              ← nút submit (ImageButton/TextButton/Frame+Button)
--  ├── InfoFrame (Frame)
--  │   ├── NameSetting        ← TextLabel title
--  │   │   └── InfoSetting    ← TextLabel trạng thái / lịch sử
--  └── ButtonDelta            ← hover effect tự động
--
-- ════════════════════════════════════════════════════════════
--  CONFIG
-- ════════════════════════════════════════════════════════════
--
--  Bắt buộc:
--    template      (Frame)     : CodeTemplate
--    parent        (Frame)     : frame cha
--
--  Chung:
--    title         (string)    : tên hiển thị — default "Reward Code"
--    tag           (any)       : gửi kèm mọi callback
--    placeholder   (string)    : placeholder TextBox — default "ENTER CODE..."
--    caseSensitive (bool)      : phân biệt hoa/thường — default false
--    cooldown      (number)    : giây chờ giữa 2 lần attempt — default 5
--    maxHistory    (number)    : số entry lịch sử lưu — default 20
--
--  Nguồn code (TEST only — bị bỏ qua khi có module):
--    codes         (table)     : { ["CODE"] = { reward, maxUses, onRedeem } }
--
--  Module thật (kích hoạt REAL MODE):
--    module        (table)     : 1 module duy nhất
--    multiModule   (table)     : { m1, m2, m3, ... } — tìm theo thứ tự
--                                Nếu truyền cả module lẫn multiModule,
--                                module được thêm vào đầu danh sách
--
-- ════════════════════════════════════════════════════════════
--  CALLBACKS
-- ════════════════════════════════════════════════════════════
--
--    onRedeem  (function) : onRedeem(code, reward, info, tag)
--                             Gọi sau khi module xử lý xong (REAL)
--                             hoặc sau khi xác nhận TEST thành công
--                             info = { title, timestamp, uses, maxUses,
--                                      userId, mode="REAL"|"TEST" }
--
--    onInvalid (function) : onInvalid(code, reason, info, tag)
--                             reason = "NOT_FOUND" | "ALREADY_USED"
--                                    | "MAX_USES"  | "COOLDOWN"
--                             info   = { title, timestamp, uses, maxUses,
--                                        remaining (chỉ khi COOLDOWN) }
--
--    onCheck   (function) : onCheck(code, result, info, tag)
--                             result = { valid, reward, uses, maxUses,
--                                        reason, mode }
--                             Gọi mọi lần attempt (kể cả COOLDOWN)
--
-- ════════════════════════════════════════════════════════════
--  PUBLIC API
-- ════════════════════════════════════════════════════════════
--
--    inst:redeem(code)             -- redeem thủ công
--    inst:check(code)              -- kiểm tra không tốn lượt/cooldown
--    inst:getMode()                -- "REAL" | "TEST"
--    inst:getModuleCount()         -- số module đang dùng
--
--    -- Chỉ có tác dụng ở TEST MODE:
--    inst:addCode(key, data)
--    inst:removeCode(key)
--    inst:resetUses(key)
--    inst:resetAllUses()
--
--    -- Runtime module management:
--    inst:addModule(mod)           -- thêm module vào cuối danh sách
--    inst:removeModule(mod)        -- xóa module khỏi danh sách
--    inst:setModules(list)         -- thay toàn bộ danh sách module
--
--    -- Lịch sử:
--    inst:getHistory()             -- { {code, reward, timestamp, userId, mode} }
--    inst:clearHistory()
--    inst:getUsedCodes()           -- set code đã dùng session này
--
--    inst:getValue()               -- code cuối redeem thành công
--    inst:setOnChange(fn)          -- alias cho onRedeem
--    inst:setVisible(bool)
--    inst:destroy()
-- ============================================================

-- ════════════════════════════════════════════════════════════
--  CODE USAGE REGISTRY  —  shared giữa mọi instance
--  Dùng trong TEST MODE để theo dõi số lần dùng
-- ════════════════════════════════════════════════════════════
local codeUsageRegistry = {}

function SliderModule.Code(config)
	assert(config.parent,   "[SliderModule.Code] Thiếu 'parent'")

	local template = config.template
		or script:FindFirstChild("CodeTemplate")
	assert(template, "[SliderModule.Code] Không tìm thấy template — truyền vào hoặc đặt 'CodeTemplate' trong ModuleScript")

	-- ════════════════════════════════════════════════════════
	--  CONFIG
	-- ════════════════════════════════════════════════════════
	local title         = config.title        or "Reward Code"
	local placeholder   = config.placeholder  or "ENTER CODE..."
	local caseSensitive = config.caseSensitive or false
	local cooldownTime  = config.cooldown      or 5
	local maxHistory    = config.maxHistory    or 20

	-- ── Xây danh sách module ─────────────────────────────────
	-- Ưu tiên: config.module → đầu danh sách
	-- Tiếp theo: config.multiModule (array)
	local moduleList = {}
	if config.module then
		table.insert(moduleList, config.module)
	end
	if config.multiModule and type(config.multiModule) == "table" then
		for _, m in ipairs(config.multiModule) do
			-- Tránh duplicate nếu cùng module được truyền cả 2 chỗ
			local exists = false
			for _, existing in ipairs(moduleList) do
				if existing == m then exists = true; break end
			end
			if not exists then
				table.insert(moduleList, m)
			end
		end
	end

	-- ── Xác định chế độ ─────────────────────────────────────
	-- REAL = có ít nhất 1 module
	-- TEST = không có module nào
	local function isRealMode()
		return #moduleList > 0
	end

	-- ── TEST MODE: bảng code nội bộ ─────────────────────────
	local testCodes = {}
	if config.codes and type(config.codes) == "table" then
		for k, v in pairs(config.codes) do
			testCodes[k] = v
		end
	end

	-- ════════════════════════════════════════════════════════
	--  CLONE TEMPLATE
	-- ════════════════════════════════════════════════════════
	local frame = template:Clone()
	frame.Name    = "Setting_" .. title
	frame.Visible = true
	frame.Parent  = config.parent

	local BoxFrame   = frame:FindFirstChild("BoxFrame")
	local InfoFrame  = frame:FindFirstChild("InfoFrame")
	local TitleLabel = InfoFrame  and InfoFrame:FindFirstChild("NameSetting")
	local RangeLabel = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")
	local CodeEnter  = BoxFrame   and BoxFrame:FindFirstChild("CodeEnter")
	local Decor      = BoxFrame   and BoxFrame:FindFirstChild("Decor")

	assert(BoxFrame,  "[SliderModule.Code] Thiếu 'BoxFrame'")
	assert(CodeEnter, "[SliderModule.Code] Thiếu 'CodeEnter' (TextBox) trong BoxFrame")

	-- Init UI
	if TitleLabel then TitleLabel.Text = title end
	if RangeLabel then RangeLabel.Text = isRealMode() and "READY" or "READY [TEST]" end
	CodeEnter.PlaceholderText = placeholder
	CodeEnter.Text            = ""

	setupButtonDelta(frame)

	-- ════════════════════════════════════════════════════════
	--  STATE
	-- ════════════════════════════════════════════════════════
	local history        = {}           -- { code, reward, timestamp, userId, mode }
	local usedByPlayer   = {}           -- set normalizedCode đã dùng session này
	local lastRedeemTime = -math.huge
	local statusTween    = nil

	-- ════════════════════════════════════════════════════════
	--  HELPERS
	-- ════════════════════════════════════════════════════════
	local function normalizeCode(raw)
		local trimmed = tostring(raw):match("^%s*(.-)%s*$")
		return caseSensitive and trimmed or trimmed:upper()
	end

	local function getUserId()
		-- Ưu tiên hỏi module đầu tiên có getUserId
		for _, m in ipairs(moduleList) do
			if type(m.getUserId) == "function" then
				local ok, id = pcall(m.getUserId)
				if ok and id then return id end
			end
		end
		-- Fallback: LocalPlayer
		local Players = game:GetService("Players")
		local lp = Players.LocalPlayer
		return lp and lp.UserId or 0
	end

	-- Màu status
	local COLOR_OK      = Color3.fromRGB(100, 220, 100)
	local COLOR_FAIL    = Color3.fromRGB(220, 80,  80 )
	local COLOR_WARN    = Color3.fromRGB(220, 180, 60 )
	local COLOR_TEST    = Color3.fromRGB(100, 180, 255)
	local COLOR_DEFAULT = RangeLabel and RangeLabel.TextColor3 or Color3.fromRGB(180, 180, 180)

	local function flashStatus(text, color, duration)
		if not RangeLabel then return end
		if statusTween then statusTween:Cancel() end
		RangeLabel.Text       = text
		RangeLabel.TextColor3 = color
		statusTween = TweenService:Create(RangeLabel,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out,
				0, false, duration or 2.5),
			{ TextColor3 = COLOR_DEFAULT }
		)
		statusTween:Play()
		statusTween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and RangeLabel then
				RangeLabel.TextColor3 = COLOR_DEFAULT
			end
		end)
	end

	local function addToHistory(entry)
		table.insert(history, 1, entry)
		if #history > maxHistory then
			table.remove(history, #history)
		end
		-- Thông báo tất cả module
		for _, m in ipairs(moduleList) do
			if type(m.onHistory) == "function" then
				pcall(m.onHistory, entry)
			end
		end
	end

	local function getUsageEntry(key)
		if not codeUsageRegistry[key] then
			codeUsageRegistry[key] = { uses = 0 }
		end
		return codeUsageRegistry[key]
	end

	-- ════════════════════════════════════════════════════════
	--  REAL MODE: Tìm code trong module list
	--  Trả về: { moduleRef, result } hoặc nil
	--    result = { valid, reward, uses, maxUses, reason }
	-- ════════════════════════════════════════════════════════
	local function queryModules(normalizedKey)
		for _, m in ipairs(moduleList) do
			if type(m.getCode) == "function" then
				local ok, result = pcall(m.getCode, normalizedKey)
				if ok and result ~= nil then
					-- Module này biết code → dùng module này
					return m, result
				end
			end
		end
		return nil, { valid=false, reason="NOT_FOUND", uses=0, maxUses=nil, reward=nil }
	end

	-- ════════════════════════════════════════════════════════
	--  TEST MODE: kiểm tra trong testCodes
	-- ════════════════════════════════════════════════════════
	local function checkTestCode(key)
		local data = testCodes[key]
		if not data then
			-- Không có bảng codes → nhận mọi code (pure test)
			if not next(testCodes) then
				return { valid=true, reward="[TEST]", uses=0, maxUses=nil }
			end
			return { valid=false, reason="NOT_FOUND", uses=0, maxUses=nil }
		end

		local entry   = getUsageEntry(key)
		local maxUses = data.maxUses

		if usedByPlayer[key] then
			return { valid=false, reason="ALREADY_USED", uses=entry.uses, maxUses=maxUses, reward=data.reward }
		end
		if maxUses and entry.uses >= maxUses then
			return { valid=false, reason="MAX_USES", uses=entry.uses, maxUses=maxUses, reward=data.reward }
		end
		return { valid=true, reward=data.reward, uses=entry.uses, maxUses=maxUses }
	end

	-- ════════════════════════════════════════════════════════
	--  CORE: check(code)  —  không tốn lượt, không cooldown
	-- ════════════════════════════════════════════════════════
	local function checkCode(raw)
		local key = normalizeCode(raw)
		local result

		if isRealMode() then
			local _, res = queryModules(key)
			result = res
			result.mode = "REAL"
		else
			result = checkTestCode(key)
			result.mode = "TEST"
		end

		return result
	end

	-- ════════════════════════════════════════════════════════
	--  CORE: redeem(code)  —  thực thi đổi thưởng
	-- ════════════════════════════════════════════════════════
	local function redeemCode(raw)
		local key = normalizeCode(raw)
		local now = tick()

		-- ── Cooldown ─────────────────────────────────────────
		if (now - lastRedeemTime) < cooldownTime then
			local remaining = math.ceil(cooldownTime - (now - lastRedeemTime))
			flashStatus("COOLDOWN: Wait " .. remaining .. "s", COLOR_WARN)
			local info = {
				title     = title,
				timestamp = makeTimestamp(title),
				remaining = remaining,
				mode      = isRealMode() and "REAL" or "TEST",
			}
			if config.onInvalid then config.onInvalid(key, "COOLDOWN", info, config.tag) end
			if config.onCheck   then
				config.onCheck(key, { valid=false, reason="COOLDOWN",
					remaining=remaining, mode=info.mode }, info, config.tag)
			end
			return false
		end

		-- ════════════════════════════════════════════════════
		--  REAL MODE
		-- ════════════════════════════════════════════════════
		if isRealMode() then
			local foundModule, result = queryModules(key)
			result.mode = "REAL"

			-- onCheck
			if config.onCheck then
				config.onCheck(key, result, {
					title=title, timestamp=makeTimestamp(title)
				}, config.tag)
			end

			if not result.valid then
				local messages = {
					NOT_FOUND    = "INVALID: Code not found",
					ALREADY_USED = "ALREADY REDEEMED",
					MAX_USES     = "CODE EXPIRED",
				}
				flashStatus(messages[result.reason] or "INVALID CODE", COLOR_FAIL)
				lastRedeemTime = now

				if config.onInvalid then
					config.onInvalid(key, result.reason, {
						title     = title,
						timestamp = makeTimestamp(title),
						uses      = result.uses,
						maxUses   = result.maxUses,
						mode      = "REAL",
					}, config.tag)
				end
				return false
			end

			-- ✅ REAL: hợp lệ — gọi module xử lý reward
			local userId = getUserId()
			local info = {
				title     = title,
				timestamp = makeTimestamp(title),
				uses      = result.uses,
				maxUses   = result.maxUses,
				userId    = userId,
				mode      = "REAL",
			}

			-- Gọi onCodeRedeemed của module tìm thấy code (nếu có)
			if foundModule and type(foundModule.onCodeRedeemed) == "function" then
				local ok, err = pcall(foundModule.onCodeRedeemed, key, result.reward, info)
				if not ok then
					warn("[SliderModule.Code] module.onCodeRedeemed error: " .. tostring(err))
				end
			end

			lastRedeemTime = now
			usedByPlayer[key] = true

			-- Lưu lịch sử
			local entry = {
				code      = key,
				reward    = result.reward,
				timestamp = makeTimestamp(title),
				userId    = userId,
				mode      = "REAL",
			}
			addToHistory(entry)

			-- Hiển thị UI
			local rewardStr = tostring(result.reward or "Reward")
			local usesStr   = result.maxUses
				and (" [" .. (result.uses) .. "/" .. result.maxUses .. "]")
				or  (" [" .. (result.uses) .. " uses]")
			flashStatus("✓ REDEEMED: " .. rewardStr .. usesStr, COLOR_OK, 4)

			-- Gọi onRedeem global
			if config.onRedeem then
				config.onRedeem(key, result.reward, info, config.tag)
			end

			return true

			-- ════════════════════════════════════════════════════
			--  TEST MODE
			-- ════════════════════════════════════════════════════
		else
			local result = checkTestCode(key)
			result.mode = "TEST"

			if config.onCheck then
				config.onCheck(key, result, {
					title=title, timestamp=makeTimestamp(title)
				}, config.tag)
			end

			if not result.valid then
				local messages = {
					NOT_FOUND    = "INVALID: Code not found",
					ALREADY_USED = "ALREADY REDEEMED",
					MAX_USES     = "CODE EXPIRED",
				}
				flashStatus(messages[result.reason] or "INVALID CODE", COLOR_FAIL)
				lastRedeemTime = now

				if config.onInvalid then
					config.onInvalid(key, result.reason, {
						title     = title,
						timestamp = makeTimestamp(title),
						uses      = result.uses,
						maxUses   = result.maxUses,
						mode      = "TEST",
					}, config.tag)
				end
				return false
			end

			-- ✅ TEST: thành công — cập nhật usage nếu có codes
			if next(testCodes) and testCodes[key] then
				local entry = getUsageEntry(key)
				entry.uses        = entry.uses + 1
				usedByPlayer[key] = true

				local data = testCodes[key]
				-- Gọi onRedeem riêng của code nếu có (test only)
				if data.onRedeem then
					pcall(data.onRedeem, key, data.reward)
				end
			end

			lastRedeemTime = now

			local rewardStr = tostring(result.reward or "[TEST]")
			flashStatus("✓ TEST: " .. key .. " → " .. rewardStr, COLOR_TEST, 3)

			-- Lưu lịch sử
			local histEntry = {
				code      = key,
				reward    = result.reward,
				timestamp = makeTimestamp(title),
				userId    = getUserId(),
				mode      = "TEST",
			}
			addToHistory(histEntry)

			if config.onRedeem then
				config.onRedeem(key, result.reward, {
					title     = title,
					timestamp = makeTimestamp(title),
					uses      = result.uses,
					maxUses   = result.maxUses,
					userId    = getUserId(),
					mode      = "TEST",
				}, config.tag)
			end

			return true
		end
	end

	-- ════════════════════════════════════════════════════════
	--  INSTANCE
	-- ════════════════════════════════════════════════════════
	local self = setmetatable({
		Frame  = frame,
		_title = title,
		_tag   = config.tag,
		_conns = {},
	}, SliderModule)

	-- ── Input: Enter key ─────────────────────────────────────
	table.insert(self._conns, CodeEnter.FocusLost:Connect(function(enterPressed)
		if not enterPressed then return end
		local raw = CodeEnter.Text
		if raw == "" or raw == placeholder then return end
		redeemCode(raw)
		CodeEnter.Text = ""
	end))

	-- ── Input: Decor là Button trực tiếp ─────────────────────
	if Decor and (Decor:IsA("TextButton") or Decor:IsA("ImageButton")) then
		table.insert(self._conns, Decor.MouseButton1Click:Connect(function()
			local raw = CodeEnter.Text
			if raw == "" or raw == placeholder then return end
			redeemCode(raw)
			CodeEnter.Text = ""
		end))
	end

	-- ── Input: Decor là Frame chứa Button bên trong ──────────
	if Decor and Decor:IsA("Frame") then
		local innerBtn = Decor:FindFirstChildWhichIsA("TextButton")
			or Decor:FindFirstChildWhichIsA("ImageButton")
		if innerBtn then
			table.insert(self._conns, innerBtn.MouseButton1Click:Connect(function()
				local raw = CodeEnter.Text
				if raw == "" or raw == placeholder then return end
				redeemCode(raw)
				CodeEnter.Text = ""
			end))
		end
	end

	-- ════════════════════════════════════════════════════════
	--  PUBLIC API
	-- ════════════════════════════════════════════════════════

	--- Redeem thủ công (không qua UI)
	function self:redeem(code)
		return redeemCode(tostring(code))
	end

	--- Kiểm tra không tốn lượt / cooldown
	function self:check(code)
		local key    = normalizeCode(tostring(code))
		local result = checkCode(key)
		if config.onCheck then
			config.onCheck(key, result, {
				title=title, timestamp=makeTimestamp(title)
			}, config.tag)
		end
		return result
	end

	--- Trả về chế độ hiện tại
	function self:getMode()
		return isRealMode() and "REAL" or "TEST"
	end

	--- Số module đang dùng
	function self:getModuleCount()
		return #moduleList
	end

	-- ── Module management (runtime) ──────────────────────────

	--- Thêm module vào cuối danh sách
	function self:addModule(mod)
		assert(type(mod) == "table", "[SliderModule.Code:addModule] mod phải là table")
		table.insert(moduleList, mod)
		-- Cập nhật label nếu lần đầu chuyển sang REAL
		if RangeLabel and #moduleList == 1 then
			RangeLabel.Text = "READY"
		end
	end

	--- Xóa module khỏi danh sách
	function self:removeModule(mod)
		for i, m in ipairs(moduleList) do
			if m == mod then
				table.remove(moduleList, i)
				break
			end
		end
		if RangeLabel and #moduleList == 0 then
			RangeLabel.Text = "READY [TEST]"
		end
	end

	--- Thay toàn bộ danh sách module
	function self:setModules(list)
		moduleList = list or {}
		if RangeLabel then
			RangeLabel.Text = isRealMode() and "READY" or "READY [TEST]"
		end
	end

	-- ── TEST MODE: quản lý codes ─────────────────────────────

	--- Thêm code (TEST only)
	function self:addCode(key, data)
		if isRealMode() then
			warn("[SliderModule.Code:addCode] Bị bỏ qua — đang ở REAL MODE")
			return
		end
		local normalized = caseSensitive and key or key:upper()
		testCodes[normalized] = data
	end

	--- Xóa code (TEST only)
	function self:removeCode(key)
		if isRealMode() then
			warn("[SliderModule.Code:removeCode] Bị bỏ qua — đang ở REAL MODE")
			return
		end
		local normalized = caseSensitive and key or key:upper()
		testCodes[normalized] = nil
	end

	--- Reset usage của 1 code (TEST only)
	function self:resetUses(key)
		local normalized = caseSensitive and key or key:upper()
		if codeUsageRegistry[normalized] then
			codeUsageRegistry[normalized].uses = 0
		end
		usedByPlayer[normalized] = nil
		if RangeLabel then RangeLabel.Text = "RESET: " .. normalized end
	end

	--- Reset tất cả usage (TEST only)
	function self:resetAllUses()
		for k in pairs(testCodes) do
			local normalized = caseSensitive and k or k:upper()
			if codeUsageRegistry[normalized] then
				codeUsageRegistry[normalized].uses = 0
			end
		end
		usedByPlayer = {}
		if RangeLabel then RangeLabel.Text = "ALL CODES RESET" end
	end

	-- ── Lịch sử ──────────────────────────────────────────────

	--- Lấy lịch sử (mới nhất trước)
	--- Mỗi entry: { code, reward, timestamp, userId, mode }
	function self:getHistory()
		local copy = {}
		for i, v in ipairs(history) do copy[i] = v end
		return copy
	end

	--- Xóa lịch sử
	function self:clearHistory()
		history = {}
		if RangeLabel then RangeLabel.Text = "HISTORY CLEARED" end
	end

	--- Set code đã dùng trong session
	function self:getUsedCodes()
		local copy = {}
		for k, v in pairs(usedByPlayer) do copy[k] = v end
		return copy
	end

	-- ── Misc ─────────────────────────────────────────────────

	--- Code cuối được redeem thành công
	function self:getValue()
		return history[1] and history[1].code or nil
	end

	--- Thay toàn bộ testCodes runtime
	function self:setCodes(newCodes)
		testCodes = newCodes or {}
	end

	--- Alias onChange → onRedeem
	function self:setOnChange(fn)
		config.onRedeem = fn
	end

	function self:setVisible(bool)
		frame.Visible = bool
	end

	function self:destroy()
		for _, conn in ipairs(self._conns) do conn:Disconnect() end
		self._conns = {}
		if statusTween then statusTween:Cancel() end
		createdSliders[frame] = nil
		if frame.Parent then frame:Destroy() end
	end

	createdSliders[frame] = self
	return self
end

-- ════════════════════════════════════════════════════════════
--  Cập nhật SliderModule.New — thêm "Code" vào assert:
--
--  assert(t == "Slider" or t == "SliderButton" or t == "Enabled"
--      or t == "Selected" or t == "Color" or t == "Gradient"
--      or t == "Key" or t == "Code",
--      '[SliderModule.New] ...')
-- ════════════════════════════════════════════════════════════




-- ════════════════════════════════════════════════════════════
--  Cập nhật SliderModule.New — thêm "Key" vào assert:
--
--  assert(t == "Slider" or t == "SliderButton" or t == "Enabled"
--      or t == "Selected" or t == "Color" or t == "Gradient" or t == "Key",
--      '[SliderModule.New] type phải là "Slider", "SliderButton", "Enabled", "Selected", "Color", "Gradient", hoặc "Key", nhận: ' .. tostring(t))
-- ════════════════════════════════════════════════════════════

--  3) SliderModule.New  |  Gọi theo type

-- ════════════════════════════════════════════════════════════
function SliderModule.New(config)
	local t = config.type or "Slider"
	assert(t == "Slider" or t == "SliderButton" or t == "Enabled"
		or t == "Selected" or t == "Color" or t == "Gradient"
		or t == "Key" or t == "Code",
		'[SliderModule.New] type phải là "Slider", "SliderButton", "Enabled", "Selected", "Color", "Gradient", "Key", " hoặc "Code", nhận: ' .. tostring(t))
	return SliderModule[t](config)
end

-- ════════════════════════════════════════════════════════════
--  PUBLIC METHODS
-- ════════════════════════════════════════════════════════════

function SliderModule:setValue(value)
	local snapped = snap(value, self._min, self._max, self._step)
	local ratio   = toRatio(snapped, self._min, self._max)
	self._value   = snapped

	local tp = self.Thumb.Position
	self.Thumb.Position = UDim2.new(ratio, tp.X.Offset, tp.Y.Scale, tp.Y.Offset)

	if self._fill then
		self._fill.BackgroundTransparency = 1 - ratio
	end
	if self._fillBar then
		if self._fillTween then self._fillTween:Cancel() end
		self._fillTween = TweenService:Create(
			self._fillBar,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.new(ratio, 0, self._fillBar.Size.Y.Scale, self._fillBar.Size.Y.Offset) }
		)
		self._fillTween:Play()
	end
	if self._buttons then
		for i, btn in ipairs(self._buttons) do
			local threshold = self._min + (i / self._parts) * (self._max - self._min)
			btn.BackgroundTransparency = (snapped >= threshold - 1e-9) and 0.5 or 1
		end
	end
	if self.ValueBox then
		self.ValueBox.Text = fmt(snapped, self._step)
	end
end

function SliderModule:getValue()
	return self._value
end

function SliderModule:setOnChange(fn)
	self._onChange = fn
end

function SliderModule:setVisible(bool)
	self.Frame.Visible = bool
end

function SliderModule:destroy()
	for _, conn in ipairs(self._conns) do conn:Disconnect() end
	self._conns = {}
	if self._fillTween then self._fillTween:Cancel() end
	-- Xóa khỏi registry
	if self.Frame then
		createdSliders[self.Frame] = nil
		if self.Frame.Parent then self.Frame:Destroy() end
	end
end

return SliderModule

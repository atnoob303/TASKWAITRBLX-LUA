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
-- ════════════════════════════════════════════════════════════
local TEXT_TOOLS = {
	{
		tag    = "b",
		parts  = {
			{ text = "</b>",           color = Color3.fromRGB(255, 200, 80)  },
			{ text = ' "Text"',        color = Color3.fromRGB(255, 255, 255) },
			{ text = " </b>",          color = Color3.fromRGB(255, 200, 80)  },
			{ text = "  —  Bold text", color = Color3.fromRGB(150, 200, 255) },
		},
		tip    = "Wrap text to make it bold",
		insert = "</b>  </b>",
	},
	{
		tag    = "i",
		parts  = {
			{ text = "</i>",             color = Color3.fromRGB(255, 200, 80)  },
			{ text = ' "Text"',          color = Color3.fromRGB(255, 255, 255) },
			{ text = " </i>",            color = Color3.fromRGB(255, 200, 80)  },
			{ text = "  —  Italic text", color = Color3.fromRGB(150, 200, 255) },
		},
		tip    = "Wrap text to make it italic",
		insert = "</i>  </i>",
	},
	{
		tag    = "s",
		parts  = {
			{ text = "</s=",                  color = Color3.fromRGB(255, 200, 80)  },
			{ text = "24",                    color = Color3.fromRGB(100, 220, 120) },
			{ text = ">",                     color = Color3.fromRGB(255, 200, 80)  },
			{ text = ' "Text"',               color = Color3.fromRGB(255, 255, 255) },
			{ text = " </s>",                 color = Color3.fromRGB(255, 200, 80)  },
			{ text = "  —  Change text size", color = Color3.fromRGB(150, 200, 255) },
		},
		tip    = "Set custom size for text (replace 24 with your number)",
		insert = "</s=24>  </s>",
	},
	{
		tag    = "c",
		parts  = {
			{ text = "</c=",                  color = Color3.fromRGB(255, 200, 80)  },
			{ text = "#FF0000",               color = Color3.fromRGB(100, 220, 120) },
			{ text = ">",                     color = Color3.fromRGB(255, 200, 80)  },
			{ text = ' "Text"',               color = Color3.fromRGB(255, 255, 255) },
			{ text = " </c>",                 color = Color3.fromRGB(255, 200, 80)  },
			{ text = "  —  Text color (hex)", color = Color3.fromRGB(150, 200, 255) },
		},
		tip    = "Set text color using hex code (e.g. #FF0000 for red)",
		insert = "</c=#FF0000>  </c>",
	},
	{
		tag    = "n1",
		parts  = {
			{ text = "</n1>",              color = Color3.fromRGB(255, 200, 80)  },
			{ text = ' "Text"',            color = Color3.fromRGB(255, 255, 255) },
			{ text = " </n1>",             color = Color3.fromRGB(255, 200, 80)  },
			{ text = "  —  Large heading", color = Color3.fromRGB(150, 200, 255) },
		},
		tip    = "Large heading — biggest title style (bold)",
		insert = "</n1>  </n1>",
	},
	{
		tag    = "n2",
		parts  = {
			{ text = "</n2>",               color = Color3.fromRGB(255, 200, 80)  },
			{ text = ' "Text"',             color = Color3.fromRGB(255, 255, 255) },
			{ text = " </n2>",              color = Color3.fromRGB(255, 200, 80)  },
			{ text = "  —  Medium heading", color = Color3.fromRGB(150, 200, 255) },
		},
		tip    = "Medium heading — section title style (bold)",
		insert = "</n2>  </n2>",
	},
	{
		tag    = "n3",
		parts  = {
			{ text = "</n3>",              color = Color3.fromRGB(255, 200, 80)  },
			{ text = ' "Text"',            color = Color3.fromRGB(255, 255, 255) },
			{ text = " </n3>",             color = Color3.fromRGB(255, 200, 80)  },
			{ text = "  —  Small heading", color = Color3.fromRGB(150, 200, 255) },
		},
		tip    = "Small heading — sub-section title style",
		insert = "</n3>  </n3>",
	},
	{
		tag    = "f",
		parts  = {
			{ text = "</f=",             color = Color3.fromRGB(255, 200, 80)  },
			{ text = "FontName",         color = Color3.fromRGB(100, 220, 120) },
			{ text = ">",                color = Color3.fromRGB(255, 200, 80)  },
			{ text = ' "Text"',          color = Color3.fromRGB(255, 255, 255) },
			{ text = " </f>",            color = Color3.fromRGB(255, 200, 80)  },
			{ text = "  —  Font family", color = Color3.fromRGB(150, 200, 255) },
		},
		tip    = "Apply a font family to text (replace FontName with font name)",
		insert = "</f=FontName>  </f>",
	},
}

-- ════════════════════════════════════════════════════════════
--  TAG PARSER
-- ════════════════════════════════════════════════════════════
local DEFAULT_TEXT_SIZE  = 14
local HEADING_TEXT_SIZES = { [1] = 28, [2] = 22, [3] = 18 }

local function parseTextLine(raw)
	local chunks = {}
	local pos    = 1
	local len    = #raw
	local state  = { bold=false, italic=false, size=nil, color=nil, font=nil, heading=nil }
	local stack  = {}

	local function pushState()
		table.insert(stack, {
			bold=state.bold, italic=state.italic, size=state.size,
			color=state.color, font=state.font, heading=state.heading,
		})
	end
	local function popState()
		if #stack > 0 then
			local s = table.remove(stack)
			state.bold=s.bold; state.italic=s.italic; state.size=s.size
			state.color=s.color; state.font=s.font; state.heading=s.heading
		end
	end
	local function addChunk(text)
		if text == "" then return end
		table.insert(chunks, {
			text=text, bold=state.bold, italic=state.italic,
			size=state.size, color=state.color, font=state.font, heading=state.heading,
		})
	end
	local function hexToColor3(hex)
		hex = hex:gsub("#","")
		if #hex ~= 6 then return nil end
		local r=tonumber(hex:sub(1,2),16)
		local g=tonumber(hex:sub(3,4),16)
		local b=tonumber(hex:sub(5,6),16)
		if not (r and g and b) then return nil end
		return Color3.fromRGB(r,g,b)
	end

	while pos <= len do
		local tagStart, tagEnd = raw:find("</%S->", pos)
		if not tagStart then addChunk(raw:sub(pos)); break end
		if tagStart > pos then addChunk(raw:sub(pos, tagStart-1)) end

		local tc = raw:sub(tagStart+2, tagEnd-1)

		if     tc=="b"            then pushState(); state.bold=true
		elseif tc=="/b"           then popState()
		elseif tc=="i"            then pushState(); state.italic=true
		elseif tc=="/i"           then popState()
		elseif tc:sub(1,2)=="s=" then pushState(); state.size=tonumber(tc:sub(3))
		elseif tc=="/s"           then popState()
		elseif tc:sub(1,2)=="c=" then pushState(); state.color=hexToColor3(tc:sub(3))
		elseif tc=="/c"           then popState()
		elseif tc=="n1"           then pushState(); state.heading=1; state.bold=true
		elseif tc=="/n1"          then popState()
		elseif tc=="n2"           then pushState(); state.heading=2; state.bold=true
		elseif tc=="/n2"          then popState()
		elseif tc=="n3"           then pushState(); state.heading=3
		elseif tc=="/n3"          then popState()
		elseif tc:sub(1,2)=="f=" then pushState(); state.font=tc:sub(3)
		elseif tc=="/f"           then popState()
		end

		pos = tagEnd + 1
	end
	return chunks
end

-- ════════════════════════════════════════════════════════════
--  APPLY FORMAT TO LABEL
-- ════════════════════════════════════════════════════════════
local function applyChunkToLabel(label, chunk)
	label.Text       = chunk.text
	label.TextColor3 = chunk.color or Color3.new(1,1,1)

	local size = DEFAULT_TEXT_SIZE
	if chunk.heading then
		size = HEADING_TEXT_SIZES[chunk.heading] or DEFAULT_TEXT_SIZE
	elseif chunk.size then
		size = chunk.size
	end
	label.TextSize = size

	local weight = chunk.bold   and Enum.FontWeight.Bold   or Enum.FontWeight.Regular
	local style  = chunk.italic and Enum.FontStyle.Italic  or Enum.FontStyle.Normal
	local family = label.FontFace.Family
	label.FontFace           = Font.new(family, weight, style)
	label.AutomaticSize      = Enum.AutomaticSize.X
	label.Size               = UDim2.new(0, 0, 1, 0)
	label.TextXAlignment     = Enum.TextXAlignment.Left
	label.TextYAlignment     = Enum.TextYAlignment.Center
	label.BackgroundTransparency = 1
end

-- ════════════════════════════════════════════════════════════
--  CONTRIBUTOR HELPER
-- ════════════════════════════════════════════════════════════
local Players = game:GetService("Players")

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

	local title     = config.title or "Text"
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
	if TitleLabel then TitleLabel.Text = title end
	if InfoSetting then InfoSetting.Text = " " .. title:upper() .. " " end
	setupButtonDelta(settingFrame)

	-- ── PackFrame refs (shared) ─────────────────────────────
	local EditScrollFrame    = packFrame:FindFirstChild("EditText")
	local PreviewScrollFrame = packFrame:FindFirstChild("PreviewText")
	local PF_InfoFrame       = packFrame:FindFirstChild("InfoFrame")
	local PF_Contributor     = PF_InfoFrame and PF_InfoFrame:FindFirstChild("Contributor")
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
		coCreatorId = config.co_creator,
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
		if PF_NameSetting then PF_NameSetting.Text = title end
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

	local function updateEditCanvas()
		task.defer(function()
			if not EditScrollFrame or not EditScrollFrame.Parent then return end
			local layout = EditScrollFrame:FindFirstChildWhichIsA("UIListLayout")
			if layout then
				EditScrollFrame.CanvasSize = UDim2.new(0, 0, 0,
					layout.AbsoluteContentSize.Y + 8)
			end
		end)
	end

	local function updatePreviewCanvas()
		task.defer(function()
			if not PreviewScrollFrame or not PreviewScrollFrame.Parent then return end
			local layout = PreviewScrollFrame:FindFirstChildWhichIsA("UIListLayout")
			if layout then
				PreviewScrollFrame.CanvasSize = UDim2.new(0, 0, 0,
					layout.AbsoluteContentSize.Y + 8)
			end
		end)
	end

	local function createEditLine(text)
		local sv = S()
		local lineFrame = Instance.new("Frame")
		lineFrame.Name               = "EditLine"
		lineFrame.Size               = sv.lineRowSize
		lineFrame.BackgroundTransparency = 1
		lineFrame.AutomaticSize      = Enum.AutomaticSize.None

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.SortOrder     = Enum.SortOrder.LayoutOrder
		layout.Padding       = UDim.new(0, 0)
		layout.Parent        = lineFrame

		local tb = Instance.new("TextBox")
		tb.Name                  = "TextInput"
		tb.Size                  = UDim2.new(1, 0, 1, 0)
		tb.BackgroundTransparency = 1
		tb.TextColor3            = Color3.new(1, 1, 1)
		tb.TextSize              = DEFAULT_TEXT_SIZE
		tb.Font                  = Enum.Font.Gotham
		tb.TextXAlignment        = Enum.TextXAlignment.Left
		tb.TextYAlignment        = Enum.TextYAlignment.Center
		tb.ClearTextOnFocus      = false
		tb.MultiLine             = false
		tb.Text                  = text or ""
		tb.PlaceholderText       = "Type here..."
		tb.PlaceholderColor3     = Color3.fromRGB(120, 120, 120)
		tb.Parent                = lineFrame

		lineFrame.Parent = EditScrollFrame

		-- ✅ Track text changes → update canvas, lưu vào lineConns
		local c = tb:GetPropertyChangedSignal("Text"):Connect(updateEditCanvas)
		table.insert(sv.lineConns, c)

		updateEditCanvas()
		return lineFrame, tb
	end

	local function createPreviewLine(rawText)
		local sv = S()
		local lineFrame = Instance.new("Frame")
		lineFrame.Name               = "PreviewLine"
		lineFrame.Size               = sv.lineRowSize
		lineFrame.BackgroundTransparency = 1
		lineFrame.AutomaticSize      = Enum.AutomaticSize.Y

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.SortOrder     = Enum.SortOrder.LayoutOrder
		layout.Padding       = UDim.new(0, 2)
		layout.Parent        = lineFrame

		local chunks = parseTextLine(rawText or "")
		if #chunks == 0 then
			chunks = {{ text=rawText or "", bold=false, italic=false,
				size=nil, color=nil, font=nil, heading=nil }}
		end

		for idx, chunk in ipairs(chunks) do
			local lbl = Instance.new("TextLabel")
			lbl.Name        = "Chunk_" .. idx
			lbl.LayoutOrder = idx
			applyChunkToLabel(lbl, chunk)
			lbl.Parent = lineFrame
		end

		lineFrame.Parent = PreviewScrollFrame
		updatePreviewCanvas()
		return lineFrame
	end

	local function getAllEditLines()
		local lines = {}
		for _, child in ipairs(EditScrollFrame:GetChildren()) do
			if child:IsA("Frame") and child.Name == "EditLine" then
				local tb = child:FindFirstChild("TextInput")
				table.insert(lines, tb and tb.Text or "")
			end
		end
		return lines
	end

	local function clearEditLines()
		clearLineConns()  -- ✅ disconnect trước khi destroy
		for _, child in ipairs(EditScrollFrame:GetChildren()) do
			if child:IsA("Frame") then child:Destroy() end
		end
	end

	local function clearPreviewLines()
		for _, child in ipairs(PreviewScrollFrame:GetChildren()) do
			if child:IsA("Frame") then child:Destroy() end
		end
	end

	local function syncPreview()
		clearPreviewLines()
		for _, line in ipairs(getAllEditLines()) do
			createPreviewLine(line)
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
				if c:IsA("Frame") then hasLines=true; break end
			end
			if not hasLines then createEditLine("") end
		else
			sv.lines = getAllEditLines()  -- ✅ lưu trước khi sang READ
			syncPreview()
			EditScrollFrame.Visible    = false
			PreviewScrollFrame.Visible = true
		end
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

			local CodeText = btn:FindFirstChild("CodeText")
			if CodeText then
				CodeText.RichText = true
				local richStr = ""
				for _, part in ipairs(tool.parts) do
					local hex = string.format("%02X%02X%02X",
						math.floor(part.color.R*255),
						math.floor(part.color.G*255),
						math.floor(part.color.B*255)
					)
					richStr = richStr
						.. '<font color="#'..hex..'">'
						.. part.text:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
						.. "</font>"
				end
				CodeText.Text = richStr
			end

			local Decor = btn:FindFirstChild("Decor")
			btn.MouseEnter:Connect(function()
				if TipText then TipText.Text = tool.tip end
				if Decor then
					TweenService:Create(Decor,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ BackgroundTransparency = 0.7 }
					):Play()
				end
			end)
			btn.MouseLeave:Connect(function()
				if TipText then TipText.Text = "" end
				if Decor then
					TweenService:Create(Decor,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ BackgroundTransparency = 1 }
					):Play()
				end
			end)

			-- Click → chèn tag vào TextBox đang focus của active inst
			btn.MouseButton1Click:Connect(function()
				if not reg.activeInst then return end
				for _, child in ipairs(EditScrollFrame:GetChildren()) do
					if child:IsA("Frame") and child.Name == "EditLine" then
						local tb = child:FindFirstChild("TextInput")
						if tb and tb:IsFocused() then
							tb.Text = tb.Text .. tool.insert
							break
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
		for _, child in ipairs(EditScrollFrame:GetChildren()) do
			if child:IsA("Frame") then child.Size = sv.lineRowSize end
		end
		for _, child in ipairs(PreviewScrollFrame:GetChildren()) do
			if child:IsA("Frame") then child.Size = sv.lineRowSize end
		end
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
			{ BackgroundTransparency = 0 }
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

-- ============================================================
--  UIChat Script  |  Full features + Settings System
--  Organized by: References → Settings → State → Functions → Events
-- ============================================================


-- ============================================================
--  [1] SERVICES
-- ============================================================
local Players           = game:GetService("Players")
local TextChatService   = game:GetService("TextChatService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")


-- ============================================================
--  [2] REFERENCES
-- ============================================================
local localPlayer            = Players.LocalPlayer
local ChatChannelFrame       = script.Parent.ChatChannelFrame
local ScrollingFrame         = ChatChannelFrame.ChannelChat
local Template               = script.MessageTemplate
local Chatbox                = ChatChannelFrame.ChatBox
local SendButton             = Chatbox.SendMessenger
local ChatMessenger          = Chatbox.ChatMessenger
local MobileSupportChatFrame = ChatChannelFrame:FindFirstChild("MobileSupportChatFrame")
local Preview                = ChatChannelFrame.MessengerMore
local HistoryChat            = ChatChannelFrame:FindFirstChild("HistoryChat")

local ChatboxFrame    = Chatbox
local ChatboxBG       = ChatboxFrame:FindFirstChild("BackgroundFrame")
local ChatboxAvatar   = ChatboxFrame:FindFirstChild("Avatar")
local BaseChatboxBGCorner = ChatboxBG and ChatboxBG:FindFirstChildOfClass("UICorner")
local BaseChatSize        = ChatMessenger.Size
local BaseChatboxBGSize   = ChatboxBG.Size
local BaseNameSize        = Template.NamePl.Size
local BaseBGSize          = Template.BackgroundFrame.Size

local avatarBG           = Preview.BackgroundFrame:FindFirstChild("Avatar")
local avatarBGBaseTrans  = avatarBG and avatarBG.BackgroundTransparency or 1

-- Khởi tạo ban đầu
Preview.Visible  = false
Chatbox.Visible  = true


-- ============================================================
--  [3] REMOTE SETUP
--  Tất cả remote nằm trong ReplicatedStorage/Remotes
--  Load:  ChatSettingsRemote:InvokeServer("LOAD")         → nhận table settings
--  Save:  ChatSettingsRemote:InvokeServer("SAVE", SETTINGS) → lưu DataStore
--  Reset: ChatSettingsRemote:InvokeServer("RESET")        → về default + nhận lại table
-- ============================================================
local GameSettingUp      = ReplicatedStorage:WaitForChild("GameSettingUp")
local DataPlayer         = GameSettingUp:WaitForChild("DataPlayer")
local ChatSettingsRemote = DataPlayer:WaitForChild("ChatSettingsRemote")

-- ── Chat System Remotes ──────────────────────────────────────
local ChattedEvent   = ReplicatedStorage:FindFirstChild("GameSettingUp").ChatEvent:WaitForChild("ChattedEvent")
local ChatRemotes    = ReplicatedStorage:FindFirstChild("GameSettingUp"):FindFirstChild("ChatEvent"):WaitForChild("ChatRemotes")
local RF_GetChannels = ChatRemotes:WaitForChild("GetChannels")

-- ActiveChannelId: đồng bộ với ChatClient nếu có, mặc định "Global"
local ActiveChannelId = "Global"
local function getActiveChannelId()
	local ok, ChatClient = pcall(require, game.StarterPlayer.StarterPlayerScripts:FindFirstChild("ChatClient"))
	if ok and ChatClient and ChatClient.GetActiveChannel then
		return ChatClient:GetActiveChannel()
	end
	return ActiveChannelId
end


-- ============================================================
--  [4] DEFAULT SETTINGS  |  Giá trị gốc, không bao giờ thay đổi
-- ============================================================
local DEFAULT_SETTINGS = {

	-- ── 🎨 Visual: Transparency ──────────────────────────────
	TRANS_NEW               = 0.75,   -- BG tin nhắn mới nhất
	TRANS_OLD               = 0.90,   -- BG tin nhắn cũ
	TRANS_HOVER_FOCUS       = 0.80,   -- BG khi hover
	TRANS_FADE_MAX          = 1,      -- Mờ tối đa (positional fade)
	CHATBOX_BG_TRANS        = 0.75,   -- BG chatbox bình thường
	PREVIEW_TRANS_SHOW_MAIN = 0.8,    -- Preview frame chính
	PREVIEW_TRANS_SHOW      = 0.7,    -- Preview background

	-- ── ⏱️ Timing: Chatbox ───────────────────────────────────
	IDLE_DELAY              = 3,      -- Giây chờ trước khi fade chatbox
	FADE_DURATION           = 5,      -- Giây để fade chatbox hoàn toàn

	-- ── ⏱️ Timing: Tin nhắn ──────────────────────────────────
	APPEAR_SCALE_TIME       = 1.5,    -- Thời gian scale xuất hiện
	APPEAR_AVATAR_TIME      = 5,      -- Thời gian avatar fade in
	APPEAR_NAME_DELAY       = 0.5,    -- Delay trước khi tên hiện
	APPEAR_TIME_DELAY       = 0.25,   -- Delay trước khi thời gian hiện
	APPEAR_TYPE_DELAY       = 0.4,    -- Delay trước khi typewriter bắt đầu
	APPEAR_TYPE_SPEED       = 0.03,   -- Tốc độ typewriter (giây/ký tự)
	APPEAR_SCALE_START      = 1,      -- AspectRatio ban đầu khi xuất hiện

	-- ── ⏱️ Timing: Tween ─────────────────────────────────────
	TWEEN_SCROLL_TIME       = 0.35,
	TWEEN_HOVER_TIME        = 0.18,
	TWEEN_STATE_TIME        = 0.25,
	PREVIEW_TWEEN_IN        = 0.15,
	PREVIEW_TWEEN_OUT       = 0.25,

	-- ── 📐 Scale / Layout ────────────────────────────────────
	MAX_SCALE               = 2,      -- Scale X tối đa của BackgroundFrame tin nhắn
	SCALE_BONUS             = 0.15,   -- Bonus thêm vào finalScale
	CONTENT_OFFSET_X        = 0.372,  -- Vị trí X bắt đầu của ContentBR
	RATIO_NEW               = 3,      -- AspectRatio tin mới
	RATIO_OLD               = 3.2,    -- AspectRatio tin cũ
	WRAPBONUS               = 0.3,    -- Bonus Y khi chatbox multiline
	BASE_BG_SCALE_Y         = 1,      -- Scale Y cơ bản chatbox (1 dòng)

	-- ── 📐 Scale: Tên + Nội dung ─────────────────────────────
	BASE_NAME_CAPACITY      = 5,      -- Số ký tự tên "miễn phí"
	BASE_CONTENT_CAPACITY   = 9,      -- Số ký tự nội dung "miễn phí"
	NAME_SCALE_PER_CHAR     = 0.043,  -- Scale thêm mỗi ký tự tên
	MAX_CONTENT_LENGTH      = 20,     -- Ký tự tối đa hiện trong ContentChat (typewriter)
	TRUNCATE_TARGET_SCALE   = 1.85,   -- Scale mục tiêu khi truncate ContentBR

	-- ── 📐 Scale: Chat Channel Frame ─────────────────────────
	CHAT_SCALE              = 1,      -- Scale tổng thể ChatChannelFrame (1 = mặc định)

	-- ── 🌫️ Positional Fade ───────────────────────────────────
	FADE_Y_FULL             = 290,    -- Y: hiện 100%
	FADE_Y_START            = 240,    -- Y: bắt đầu mờ (lên trên)
	FADE_Y_END              = 100,    -- Y: mờ hoàn toàn
	FADE_Y_BOTTOM_START     = 300,    -- Y: bắt đầu mờ phía dưới
	FADE_Y_BOTTOM_END       = 320,    -- Y: mờ hoàn toàn phía dưới

	-- ── 📝 Text / Wrap ───────────────────────────────────────
	AUTO_WRAP_LENGTH        = 20,     -- Ký tự mỗi dòng trước khi wrap
	WRAP_COOLDOWN           = 0.1,    -- Giây cooldown giữa mỗi lần wrap
	MAX_LINES               = 5,      -- Số dòng tối đa chatbox
	MAX_INPUT_LENGTH        = 100,    -- Ký tự tối đa input

	-- ── 🔧 Feature Flags ─────────────────────────────────────
	ENABLE_TYPEWRITER       = true,   -- Hiệu ứng typewriter tin nhắn
	ENABLE_APPEAR_ANIM      = true,   -- Animation xuất hiện tin nhắn
	ENABLE_PREVIEW          = true,   -- Hover preview khi text dài
	ENABLE_POSITIONAL_FADE  = true,   -- Fade tin nhắn theo vị trí Y
	ENABLE_IDLE_FADE        = true,   -- Chatbox tự ẩn khi idle
	ENABLE_AUTO_WRAP        = true,   -- Tự wrap text dài
	ENABLE_TAG              = true,   -- Hiển thị tag kênh (#Friend, #Global, v.v.)

	-- ── 💬 Chat Mode ─────────────────────────────────────────
	-- 1 = Roblox Default UI, 2 = Custom Frame (mặc định), 3 = Bubble Mode
	CHAT_MODE               = 2,
	BUBBLE_MAX_PLAYERS      = 3,      -- Số người tối đa có bubble cùng lúc

	-- ── 🗑️ Cleanup ───────────────────────────────────────────
	MAX_MESSAGES            = 50,
	MESSAGE_LIFETIME        = 15 * 60,

	-- ── 🔢 Misc ──────────────────────────────────────────────
	TEXT_ALPHA_VISIBLE      = 1,
	TEXT_ALPHA_FADED        = 0,
	FADE_TRIGGER            = 0.3,
	FADE_TRIGGER_NEW        = 0.1,
}


-- ============================================================
--  [5] RUNTIME SETTINGS
--  Merge từ DEFAULT_SETTINGS, sau đó override bằng
--  giá trị từ ChatSettingsConfig (ModuleScript) để đồng bộ
--  với DataStore và UI. DataStore load sẽ override tiếp.
-- ============================================================
local ChatSettingsConfig = DataPlayer:WaitForChild("ChatSettingsConfig")

local SETTINGS = {}

-- Bước 1: copy toàn bộ hardcode defaults
for k, v in pairs(DEFAULT_SETTINGS) do
	SETTINGS[k] = v
end

-- Bước 2: override bằng default từ ModuleScript (source of truth cho UI setting)
local configList = require(ChatSettingsConfig)
for _, entry in ipairs(configList) do
	if SETTINGS[entry.key] ~= nil then
		SETTINGS[entry.key] = entry.default
	end
end


-- ============================================================
--  [6] DATASTORE  |  Load/Save qua Server (DataStore chỉ chạy ở server)
-- ============================================================

-- Áp CHAT_SCALE lên ChatChannelFrame
local function applyChatScale()
	local uiScale = ChatChannelFrame:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = ChatChannelFrame
	end
	TweenService:Create(uiScale,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = SETTINGS.CHAT_SCALE }
	):Play()
end

local function saveSettings()
	task.spawn(function()
		local success, err = pcall(function()
			ChatSettingsRemote:InvokeServer("SAVE", SETTINGS)
		end)
		if not success then
			warn("[ChatSettings] Không thể lưu:", err)
		end
	end)
end

local function loadSettings()
	task.spawn(function()
		local success, data = pcall(function()
			return ChatSettingsRemote:InvokeServer("LOAD")
		end)
		if success and data then
			for k, v in pairs(data) do
				if DEFAULT_SETTINGS[k] ~= nil then
					SETTINGS[k] = v
				end
			end
			applyChatScale()
		end
	end)
end

-- Load setting khi khởi động
task.spawn(loadSettings)


-- ============================================================
--  [7] SETTING API  |  Hàm public để update setting
-- ============================================================

-- Cập nhật một hoặc nhiều setting
local function applySettings(newValues)
	for k, v in pairs(newValues) do
		if DEFAULT_SETTINGS[k] ~= nil then
			SETTINGS[k] = v
		else
			warn("[ChatSettings] Key không hợp lệ:", k)
		end
	end
	-- Áp ngay các setting có side effect
	if newValues.CHAT_SCALE then applyChatScale() end
end

-- Reset về default + sync lại từ server
local function resetSettings()
	task.spawn(function()
		local success, data = pcall(function()
			return ChatSettingsRemote:InvokeServer("RESET")
		end)
		if success and data then
			for k, v in pairs(DEFAULT_SETTINGS) do SETTINGS[k] = v end
			for k, v in pairs(data) do
				if DEFAULT_SETTINGS[k] ~= nil then SETTINGS[k] = v end
			end
		else
			for k, v in pairs(DEFAULT_SETTINGS) do SETTINGS[k] = v end
		end
		applyChatScale()
	end)
end

-- Áp CHAT_SCALE khi load
task.spawn(applyChatScale)


-- ============================================================
--  [8] STATE
-- ============================================================
local LastMessageId      = nil
local messageList        = {}
local newestFrame        = nil
local hoveredFrame       = nil
local lastWrapTime       = 0
local scrollFrameVisible = false

-- Lịch sử chat theo từng kênh (dùng cho HistoryChat panel)
-- globalChatLog[channelId] = { entry, ... }  — tối đa HISTORY_MAX tin/kênh
-- entry: { userId, displayName, text, channelId, time }
local globalChatLog   = {}
local HISTORY_MAX     = 75

-- Bubble mode state
-- bubbleMap[userId] = { frame, channelId }  — 1 bubble/người
-- bubbleOrder = { userId, ... }             — thứ tự FIFO để đẩy người cũ ra
local bubbleMap   = {}
local bubbleOrder = {}

-- Bubble layout/fade state
-- bubbleNewest   = userId | nil   — người nhắn mới nhất
-- bubbleDimTimer[userId] = number — tick() khi nhận tin mới (để tính 5 giây)
local bubbleNewest   = nil
local bubbleDimTimer = {}

-- MessengerTime state (mode 3)
-- unreadCount[userId] = number  — số tin chưa đọc của từng player
-- historyOpen = userId | nil    — player đang mở HistoryChat
local unreadCount  = {}
local historyOpen  = nil
local historyOpenChannel = nil  -- kênh đang mở trong HistoryChat

-- Forward declarations
local appendChatLog

-- Chatbox state
local chatboxAlpha    = 1
local isFocused       = false
local isHovered       = false
local idleTime        = 0
local isFading        = false
local isSending       = false
local isAutoWrapping  = false
local isRestoringText = false
local savedDraftText  = ""
local lastLineCount   = 1
local extraLines      = 0
local isShiftHeld     = false
local isMobile        = UserInputService.TouchEnabled

-- Chatbox size constants
local SIZE_DEFAULT = UDim2.new(0.863, 0, 0.102, 0)
local SIZE_FOCUSED = UDim2.new(0.962, 0, 0.083, 0)

local CORNER_BY_LINE = {
	[1] = UDim.new(1,     0),
	[2] = UDim.new(0.1,   0),
	[3] = UDim.new(0.05,  0),
	[4] = UDim.new(0.025, 0),
	[5] = UDim.new(0.012, 0),
}


-- ============================================================
--  [9] HELPERS
-- ============================================================

local function getTime()
	local hour   = tonumber(os.date("%I"))
	local minute = tonumber(os.date("%M"))
	local period = os.date("%p")
	return string.format("%02d:%02d%s", hour, minute, period)
end

local function getActualLineCount()
	local count = 1
	for _ in ChatMessenger.Text:gmatch("\n") do count = count + 1 end
	return count
end

local function cleanEmptyLines(text)
	local cleaned = {}
	for line in text:gmatch("([^\n]*)\n?") do
		if line:match("%S") then table.insert(cleaned, line) end
	end
	return table.concat(cleaned, "\n")
end

local function applyAutoWrap(text)
	local wrapped = {}
	for line in text:gmatch("([^\n]*)\n?") do
		if #line > SETTINGS.AUTO_WRAP_LENGTH then
			local cutAt = SETTINGS.AUTO_WRAP_LENGTH
			for i = SETTINGS.AUTO_WRAP_LENGTH, 1, -1 do
				if line:sub(i, i) == " " then cutAt = i - 1; break end
			end
			table.insert(wrapped, line:sub(1, cutAt))
			table.insert(wrapped, line:sub(cutAt + 1):match("^%s*(.-)$") or "")
		else
			table.insert(wrapped, line)
		end
	end
	return table.concat(wrapped, "\n")
end


-- ============================================================
--  [10] CHATBOX: Background + Transparency
-- ============================================================

local function tweenCornerRadius(targetRadius)
	if not BaseChatboxBGCorner then return end
	TweenService:Create(BaseChatboxBGCorner,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CornerRadius = targetRadius }
	):Play()
end

local function setAvatarColor(focused)
	if not ChatboxAvatar then return end
	local color = focused and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(150, 150, 150)
	TweenService:Create(ChatboxAvatar,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ ImageColor3 = color }
	):Play()
end

local function setScrollFrameX(targetScale, duration, easingStyle, easingDirection)
	easingStyle      = easingStyle      or Enum.EasingStyle.Quad
	easingDirection  = easingDirection  or Enum.EasingDirection.Out
	TweenService:Create(ScrollingFrame,
		TweenInfo.new(duration, easingStyle, easingDirection),
		{ Position = UDim2.new(
			targetScale, ScrollingFrame.Position.X.Offset,
			ScrollingFrame.Position.Y.Scale, ScrollingFrame.Position.Y.Offset
			)}
	):Play()
end

local function applyChatboxAlpha(alpha)
	chatboxAlpha = alpha
	if ChatboxBG then
		ChatboxBG.BackgroundTransparency = SETTINGS.CHATBOX_BG_TRANS + (1 - SETTINGS.CHATBOX_BG_TRANS) * (1 - alpha)
	end
	if ChatboxAvatar then
		ChatboxAvatar.ImageTransparency      = 1 - alpha
		ChatboxAvatar.BackgroundTransparency = 1 - (1 - 0.6) * alpha
	end
	ChatMessenger.TextTransparency  = 1 - alpha
	ChatMessenger.PlaceholderColor3 = Color3.fromRGB(180, 180, 180)
	if alpha < 0.05 then SendButton.Visible = false end
	if alpha < 1 and scrollFrameVisible then
		scrollFrameVisible = false
		setScrollFrameX(0, 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end
end

local function showChatbox()
	isFading = false
	idleTime = 0
	applyChatboxAlpha(1)
	local ti = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if ChatboxBG    then TweenService:Create(ChatboxBG,    ti, { BackgroundTransparency = SETTINGS.CHATBOX_BG_TRANS }):Play() end
	if ChatboxAvatar then TweenService:Create(ChatboxAvatar, ti, { ImageTransparency = 0, BackgroundTransparency = 0.6 }):Play() end
	TweenService:Create(ChatMessenger, ti, { TextTransparency = 0 }):Play()
	TweenService:Create(ChatboxFrame,
		TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = isFocused and SIZE_FOCUSED or SIZE_DEFAULT }
	):Play()
	if not scrollFrameVisible then
		scrollFrameVisible = true
		setScrollFrameX(0.04, 0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end
end


-- ============================================================
--  [11] CHATBOX: Multiline / Sync BG
-- ============================================================

local function syncBGToTextBounds(lineCount, isNewLine)
	lineCount = math.clamp(lineCount or getActualLineCount(), 1, SETTINGS.MAX_LINES)

	ChatMessenger.TextXAlignment = Enum.TextXAlignment.Left
	ChatMessenger.TextYAlignment = lineCount == 1
		and Enum.TextYAlignment.Center
		or  Enum.TextYAlignment.Top

	local ti = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	if isNewLine then
		local actualLines     = math.max(getActualLineCount(), 1)
		local singleLineH     = ChatMessenger.TextBounds.Y / actualLines
		local scaleY          = singleLineH / ChatboxFrame.AbsoluteSize.Y
		TweenService:Create(ChatboxBG, ti, { Size = UDim2.new(
			BaseChatboxBGSize.X.Scale, BaseChatboxBGSize.X.Offset,
			math.max(SETTINGS.BASE_BG_SCALE_Y, SETTINGS.BASE_BG_SCALE_Y + (scaleY * actualLines) + SETTINGS.WRAPBONUS),
			BaseChatboxBGSize.Y.Offset
			)}):Play()

	elseif isFocused then
		local trimmed    = ChatMessenger.Text:match("^%s*(.-)%s*$") or ""
		local actualLines = getActualLineCount()
		if #trimmed == 0 or actualLines < 2 then
			TweenService:Create(ChatboxBG, ti, { Size = UDim2.new(
				BaseChatboxBGSize.X.Scale, BaseChatboxBGSize.X.Offset,
				SETTINGS.BASE_BG_SCALE_Y, BaseChatboxBGSize.Y.Offset
				)}):Play()
		else
			local scaleY = ChatMessenger.TextBounds.Y / ChatboxFrame.AbsoluteSize.Y
			TweenService:Create(ChatboxBG, ti, { Size = UDim2.new(
				BaseChatboxBGSize.X.Scale, BaseChatboxBGSize.X.Offset,
				math.max(SETTINGS.BASE_BG_SCALE_Y, scaleY + SETTINGS.WRAPBONUS),
				BaseChatboxBGSize.Y.Offset
				)}):Play()
		end
	else
		TweenService:Create(ChatboxBG, ti, { Size = UDim2.new(
			BaseChatboxBGSize.X.Scale, BaseChatboxBGSize.X.Offset,
			BaseChatboxBGSize.Y.Scale + (lineCount - 1),
			BaseChatboxBGSize.Y.Offset
			)}):Play()
	end

	TweenService:Create(ChatMessenger, ti, { Size = UDim2.new(
		BaseChatSize.X.Scale, BaseChatSize.X.Offset,
		BaseChatSize.Y.Scale + (lineCount - 1),
		BaseChatSize.Y.Offset
		)}):Play()

	tweenCornerRadius(CORNER_BY_LINE[lineCount] or CORNER_BY_LINE[SETTINGS.MAX_LINES])
end


-- ============================================================
--  [12] MESSAGE: Transparency + State helpers
-- ============================================================

local function setBGTransparency(frame, value)
	local bg = frame:FindFirstChild("BackgroundFrame")
	if bg then bg.BackgroundTransparency = value end
end

local function setChildrenAlpha(frame, alpha, avatarBaseTrans)
	local namePl  = frame:FindFirstChild("NamePl")
	local content = frame:FindFirstChild("ContentChat")
	local avatar  = frame:FindFirstChild("Avatar")
	if namePl then
		namePl.TextTransparency = 1 - alpha
		local t = namePl:FindFirstChild("Time")
		if t then t.TextTransparency = 1 - alpha end
	end
	if content then content.TextTransparency = 1 - alpha end
	if avatar  then
		avatar.ImageTransparency      = 1 - alpha
		local base = avatarBaseTrans or 0.6
		avatar.BackgroundTransparency = 1 - (1 - base) * alpha
	end
end

local function tweenBGTransparency(frame, targetTrans, duration)
	local bg = frame:FindFirstChild("BackgroundFrame")
	if not bg then return end
	TweenService:Create(bg,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = targetTrans }
	):Play()
end

local function tweenAspectRatio(frame, targetRatio, duration)
	local uiarc = frame:FindFirstChildOfClass("UIAspectRatioConstraint")
	if not uiarc then return end
	TweenService:Create(uiarc,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ AspectRatio = targetRatio }
	):Play()
end

local function applyOldState(frame, animated)
	local t = animated and SETTINGS.TWEEN_STATE_TIME or 0
	tweenBGTransparency(frame, SETTINGS.TRANS_OLD, t)
	tweenAspectRatio(frame, SETTINGS.RATIO_OLD, t)
end

local function applyNewState(frame, animated)
	local t = animated and SETTINGS.TWEEN_STATE_TIME or 0
	tweenBGTransparency(frame, SETTINGS.TRANS_NEW, t)
	tweenAspectRatio(frame, SETTINGS.RATIO_NEW, t)
end

local function getBaseTransparency(entry)
	return entry.isNewest and SETTINGS.TRANS_NEW or SETTINGS.TRANS_OLD
end


-- ============================================================
--  [13] MESSAGE: Hover
-- ============================================================

local function applyHoverFocus(frame)
	tweenBGTransparency(frame, SETTINGS.TRANS_HOVER_FOCUS, SETTINGS.TWEEN_HOVER_TIME)
	tweenAspectRatio(frame, SETTINGS.RATIO_NEW, SETTINGS.TWEEN_HOVER_TIME)
	setChildrenAlpha(frame, SETTINGS.TEXT_ALPHA_VISIBLE)
end

local function onHoverEnter(focusFrame)
	hoveredFrame = focusFrame
	for _, entry in ipairs(messageList) do
		if not (entry.frame and entry.frame.Parent) then continue end
		if entry.frame == focusFrame then
			applyHoverFocus(entry.frame)
		elseif entry.isNewest then
			applyOldState(entry.frame, true)
		end
	end
end

local function onHoverLeave(leavingFrame)
	if hoveredFrame ~= leavingFrame then return end
	hoveredFrame = nil
	for _, entry in ipairs(messageList) do
		if not (entry.frame and entry.frame.Parent) then continue end
		if entry.isNewest then applyNewState(entry.frame, true)
		else applyOldState(entry.frame, true) end
	end
end


-- ============================================================
--  [14] MESSAGE: Cleanup + Demote
-- ============================================================

local function demotePreviousNewest()
	if not newestFrame then return end
	for _, entry in ipairs(messageList) do
		if entry.frame == newestFrame then
			entry.isNewest = false; break
		end
	end
	applyOldState(newestFrame, true)
	newestFrame = nil
end

local function cleanupMessages()
	local now = os.time()
	if #messageList > SETTINGS.MAX_MESSAGES then
		local excess = #messageList - SETTINGS.MAX_MESSAGES
		for i = 1, excess do
			local entry = messageList[i]
			if entry and (now - entry.timestamp) >= SETTINGS.MESSAGE_LIFETIME then
				if entry.frame and entry.frame.Parent then entry.frame:Destroy() end
				entry.frame = nil
			end
		end
	end
	local cleaned = {}
	for _, entry in ipairs(messageList) do
		if entry.frame and entry.frame.Parent then table.insert(cleaned, entry) end
	end
	messageList = cleaned
end

-- Ẩn tất cả tin cũ, chỉ hiện tin đúng kênh đang chọn
local function filterByChannel(channelId)
	for _, entry in ipairs(messageList) do
		if entry.frame and entry.frame.Parent then
			entry.frame.Visible = (entry.channelId == channelId)
		end
	end
end


-- ============================================================
--  [15] MESSAGE: Scroll
-- ============================================================

local function smoothScrollToBottom()
	task.wait(0.05)
	local targetY = math.max(0, ScrollingFrame.AbsoluteCanvasSize.Y - ScrollingFrame.AbsoluteSize.Y)
	TweenService:Create(ScrollingFrame,
		TweenInfo.new(SETTINGS.TWEEN_SCROLL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CanvasPosition = Vector2.new(0, targetY) }
	):Play()
end


-- ============================================================
--  [16] MESSAGE: Appear Animation
-- ============================================================

local function playAppearAnimation(frame, displayText, avatarBaseTrans)
	if not SETTINGS.ENABLE_APPEAR_ANIM then
		-- Không có animation: hiện thẳng luôn
		local content = frame:FindFirstChild("ContentChat")
		if content then
			if SETTINGS.ENABLE_TYPEWRITER then
				content.Text = ""
				task.delay(SETTINGS.APPEAR_TYPE_DELAY, function()
					task.spawn(function()
						for i = 1, #displayText do
							if not (frame and frame.Parent) then break end
							content.Text = displayText:sub(1, i)
							task.wait(SETTINGS.APPEAR_TYPE_SPEED)
						end
					end)
				end)
			else
				content.Text = displayText
			end
		end
		return
	end

	local uiarc     = frame:FindFirstChildOfClass("UIAspectRatioConstraint")
	local avatar    = frame:FindFirstChild("Avatar")
	local namePl    = frame:FindFirstChild("NamePl")
	local timeLabel = namePl and namePl:FindFirstChild("Time")
	local content   = frame:FindFirstChild("ContentChat")

	frame.Size = UDim2.new(0, 0, 0, 0)
	if namePl    then namePl.TextTransparency    = 1 end
	if timeLabel then timeLabel.TextTransparency = 1 end
	if content   then content.Text = ""; content.TextTransparency = 0 end
	if avatar    then avatar.ImageTransparency = 1; avatar.BackgroundTransparency = 1 end

	TweenService:Create(frame,
		TweenInfo.new(SETTINGS.APPEAR_SCALE_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = UDim2.new(0.5, 0, 0.1, 65) }
	):Play()

	if uiarc then
		uiarc.AspectRatio = SETTINGS.APPEAR_SCALE_START
		TweenService:Create(uiarc,
			TweenInfo.new(SETTINGS.APPEAR_SCALE_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
			{ AspectRatio = SETTINGS.RATIO_NEW }
		):Play()
	end
	if avatar then
		TweenService:Create(avatar,
			TweenInfo.new(SETTINGS.APPEAR_AVATAR_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ ImageTransparency = 0, BackgroundTransparency = avatarBaseTrans }
		):Play()
	end
	task.delay(SETTINGS.APPEAR_NAME_DELAY, function()
		if not (frame and frame.Parent) then return end
		if namePl then TweenService:Create(namePl, TweenInfo.new(0.15), { TextTransparency = 0 }):Play() end
	end)
	task.delay(SETTINGS.APPEAR_TIME_DELAY, function()
		if not (frame and frame.Parent) then return end
		if timeLabel then TweenService:Create(timeLabel, TweenInfo.new(0.15), { TextTransparency = 0 }):Play() end
	end)
	task.delay(SETTINGS.APPEAR_TYPE_DELAY, function()
		if not (frame and frame.Parent) or not content then return end
		if SETTINGS.ENABLE_TYPEWRITER then
			task.spawn(function()
				for i = 1, #displayText do
					if not (frame and frame.Parent) then break end
					content.Text = displayText:sub(1, i)
					task.wait(SETTINGS.APPEAR_TYPE_SPEED)
				end
			end)
		else
			content.Text = displayText
		end
	end)
end


-- ============================================================
--  [17] MESSAGE: Hover Preview Button
-- ============================================================

local function setupHoverButton(frame, fullText, displayName, timeText, userId)
	if not SETTINGS.ENABLE_PREVIEW then return end
	local bg = frame:FindFirstChild("BackgroundFrame")
	if not bg then return end

	local btn    = Instance.new("TextButton")
	btn.Name     = "HoverButton"
	btn.Size     = UDim2.new(1, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.Text     = ""
	btn.ZIndex   = 10
	btn.Parent   = bg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = btn

	local mouseTracker = nil

	local function setPreviewAlpha(alpha)
		local ti     = TweenInfo.new(
			alpha > 0 and SETTINGS.PREVIEW_TWEEN_IN or SETTINGS.PREVIEW_TWEEN_OUT,
			Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local bg2    = Preview:FindFirstChild("BackgroundFrame")
		local namePl = Preview.BackgroundFrame:FindFirstChild("NamePl")
		local cont   = Preview:FindFirstChild("ContentChat")
		local ava    = Preview.BackgroundFrame:FindFirstChild("Avatar")
		if bg2   then TweenService:Create(bg2,    ti, { BackgroundTransparency = alpha > 0 and SETTINGS.PREVIEW_TRANS_SHOW or 1 }):Play() end
		TweenService:Create(Preview, ti, { BackgroundTransparency = alpha > 0 and SETTINGS.PREVIEW_TRANS_SHOW_MAIN or 1 }):Play()
		if cont  then TweenService:Create(cont,   ti, { TextTransparency = 1 - alpha }):Play() end
		if ava   then
			TweenService:Create(ava, ti, { ImageTransparency = 1 - alpha }):Play()
			TweenService:Create(ava, ti, { BackgroundTransparency = alpha > 0 and avatarBGBaseTrans or 1 }):Play()
		end
		if namePl then
			TweenService:Create(namePl, ti, { TextTransparency = 1 - alpha }):Play()
			local t = Preview.BackgroundFrame:FindFirstChild("Time")
			if t then TweenService:Create(t, ti, { TextTransparency = 1 - alpha }):Play() end
		end
	end

	local function showPreview()
		if #fullText <= SETTINGS.MAX_CONTENT_LENGTH then return end
		local namePl = Preview.BackgroundFrame:FindFirstChild("NamePl")
		local cont   = Preview:FindFirstChild("ContentChat")
		local ava    = Preview.BackgroundFrame:FindFirstChild("Avatar")
		if namePl then namePl.Text = displayName end
		if cont   then cont.Text   = fullText end
		if namePl then
			local t = Preview.BackgroundFrame:FindFirstChild("Time")
			if t then t.Text = timeText end
		end
		if ava then
			ava.Image = ""
			task.spawn(function()
				local img = Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size420x420)
				ava.Image = img
			end)
		end
		Preview.Visible = true
		setPreviewAlpha(1)
	end

	local function hidePreview()
		setPreviewAlpha(0)
		task.delay(SETTINGS.PREVIEW_TWEEN_OUT + 0.05, function()
			if not hoveredFrame then Preview.Visible = false end
		end)
	end

	btn.MouseEnter:Connect(function()
		onHoverEnter(frame); showPreview()
		if mouseTracker then mouseTracker:Disconnect() end
		mouseTracker = UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				Preview.Position = UDim2.new(
					Preview.Position.X.Scale, Preview.Position.X.Offset,
					0, input.Position.Y - Preview.AbsoluteSize.Y / -5
				)
			end
		end)
	end)

	btn.MouseLeave:Connect(function()
		onHoverLeave(frame); hidePreview()
		if mouseTracker then mouseTracker:Disconnect(); mouseTracker = nil end
	end)
end


-- ============================================================
--  [18] MESSAGE: Receive + Build
-- ============================================================

-- ============================================================
--  [18] MESSAGE: Render  (dùng chung cho MessageReceived + ChattedEvent)
--  params:
--    userId      : number   — để load avatar
--    displayName : string   — tên hiển thị trên bubble
--    fullText    : string   — nội dung gốc (plain text, dùng cho preview/typewriter)
--    frameName   : string   — tên frame (unique)
-- ============================================================

-- ============================================================
--  [17B] TAG: Xác định và hiển thị tag kênh trên tin nhắn
--  - Bản thân người chơi    → không hiện tag
--  - Friend (bất kỳ kênh)   → #Friend (ưu tiên cao nhất)
--  - Kênh Friend            → #Friend
--  - Kênh DEFAULT/Global    → không hiện tag
--  - Kênh Server/Team/Staff → #Server / #Team / #Staff
--  - Kênh Private/*         → #Private
--  - Kênh Group/*           → #Group
--  - Kênh khác              → #<tên kênh>
-- ============================================================

-- Cache friend list để không gọi lại liên tục
local friendCache     = {}  -- [userId] = true/false
local friendCacheTime = {}  -- [userId] = os.time()
local FRIEND_CACHE_TTL = 60 -- giây

local function checkIsFriend(userId)
	if userId == localPlayer.UserId then return false end
	local now = os.time()
	if friendCache[userId] ~= nil and (now - (friendCacheTime[userId] or 0)) < FRIEND_CACHE_TTL then
		return friendCache[userId]
	end
	local ok, result = pcall(function()
		return Players:GetFriendship(localPlayer.UserId, userId)
	end)
	-- GetFriendship không tồn tại trực tiếp trên client → dùng LocalPlayer:IsFriendsWith
	if not ok then
		ok, result = pcall(function()
			return localPlayer:IsFriendsWith(userId)
		end)
	end
	local isFriend = ok and result == true
	friendCache[userId]     = isFriend
	friendCacheTime[userId] = now
	return isFriend
end

-- TAG_COLOR: màu chữ cho từng loại tag
local TAG_COLOR = {
	Friend  = Color3.fromRGB(100, 210, 255),  -- xanh nhạt
	Global  = Color3.fromRGB(180, 180, 180),  -- xám
	Server  = Color3.fromRGB(255, 200, 80),   -- vàng
	Team    = Color3.fromRGB(100, 220, 120),  -- xanh lá
	Staff   = Color3.fromRGB(255, 100, 100),  -- đỏ
	Private = Color3.fromRGB(220, 140, 255),  -- tím
	Group   = Color3.fromRGB(255, 170, 100),  -- cam
}
local TAG_COLOR_DEFAULT = Color3.fromRGB(200, 200, 200)

local function applyTagGradient(tagFrame, color)
	local gradient = tagFrame:FindFirstChildOfClass("UIGradient")
	if not gradient then return end
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, color),
		ColorSequenceKeypoint.new(1, Color3.new(
			math.clamp(color.R * 0.5, 0, 1),
			math.clamp(color.G * 0.5, 0, 1),
			math.clamp(color.B * 0.5, 0, 1)
			)),
	})
end

local function applyTag(frame, userId, channelId)
	local tagFrame = frame:FindFirstChild("TagFrame")
	if not tagFrame then return end

	if not SETTINGS.ENABLE_TAG then
		tagFrame.Visible = false
		return
	end

	-- ── Bước 1 (sync): các tag không cần check friend ──
	-- Bản thân → không tag
	if userId == localPlayer.UserId then
		tagFrame.Visible = false
		return
	end

	-- Kênh Friend → tag Friend ngay, không cần check
	if channelId and channelId:lower():find("friend") then
		local tagText = tagFrame:FindFirstChild("TagText")
		if tagText then
			tagText.Text       = "#Friend"
			tagText.TextColor3 = TAG_COLOR["Friend"]
		end
		applyTagGradient(tagFrame, TAG_COLOR["Friend"])
		tagFrame.Visible = true
		return
	end

	-- Kênh DEFAULT/Global → không tag
	if not channelId or channelId == "DEFAULT" or channelId == "Global" then
		tagFrame.Visible = false
		return
	end

	-- Xác định label từ tên kênh (không cần network)
	local lower = channelId:lower()
	local syncLabel
	if lower:find("private") then syncLabel = "Private"
	elseif lower:find("group") then syncLabel = "Group"
	elseif lower == "server"  then syncLabel = "Server"
	elseif lower == "team"    then syncLabel = "Team"
	elseif lower == "staff"   then syncLabel = "Staff"
	else   syncLabel = channelId:sub(1, 10):upper()
	end

	-- Hiện tag kênh ngay (sync)
	local tagText = tagFrame:FindFirstChild("TagText")
	if tagText then
		tagText.Text       = "#" .. syncLabel
		tagText.TextColor3 = TAG_COLOR[syncLabel] or TAG_COLOR_DEFAULT
	end
	applyTagGradient(tagFrame, TAG_COLOR[syncLabel] or TAG_COLOR_DEFAULT)
	tagFrame.Visible = true

	-- ── Bước 2 (async): nếu là friend thì override thành #Friend ──
	task.spawn(function()
		if checkIsFriend(userId) then
			if not (frame and frame.Parent) then return end
			local tf = frame:FindFirstChild("TagFrame")
			if not tf then return end
			local tt = tf:FindFirstChild("TagText")
			if tt then
				tt.Text       = "#Friend"
				tt.TextColor3 = TAG_COLOR["Friend"]
			end
			applyTagGradient(tf, TAG_COLOR["Friend"])
			tf.Visible = true
		end
	end)
end


-- ============================================================
--  [18] MESSAGE: Receive + Build
-- ============================================================
-- Forward declaration cho bubble mode (định nghĩa đầy đủ ở [25])
local renderBubble

local function renderMessage(userId, displayName, fullText, frameName, channelId)
	cleanupMessages()
	demotePreviousNewest()

	-- Clone template
	local newMessage = Template:Clone()
	newMessage.Name    = frameName or (tostring(userId) .. "_" .. tostring(os.clock()))
	newMessage.Visible = true
	newMessage.Parent  = ScrollingFrame
	newMessage.NamePl.Size          = BaseNameSize
	newMessage.BackgroundFrame.Size = BaseBGSize

	-- Ẩn TagFrame ngay, applyTag sẽ quyết định có hiện không
	local tagFrameInit = newMessage:FindFirstChild("TagFrame")
	if tagFrameInit then tagFrameInit.Visible = false end

	-- Ẩn MessengerTime ngay (chỉ dùng ở mode 3)
	local mtInit = newMessage:FindFirstChild("MessengerTime")
	if mtInit then mtInit.Visible = false end

	local ContentBR = newMessage:FindFirstChild("ContentBR")

	-- ── Tên hiển thị ──
	local nameExtraChars = math.max(0, #displayName - SETTINGS.BASE_NAME_CAPACITY)
	local nameExtraScale = nameExtraChars * SETTINGS.NAME_SCALE_PER_CHAR
	newMessage.NamePl.Text = displayName
	if nameExtraChars > 0 then
		newMessage.NamePl.Size = UDim2.new(
			BaseNameSize.X.Scale,
			BaseNameSize.X.Offset + nameExtraChars * 6,
			BaseNameSize.Y.Scale,
			BaseNameSize.Y.Offset
		)
	end

	-- ── Nội dung ──
	local displayText = fullText
	if #fullText > SETTINGS.MAX_CONTENT_LENGTH then
		displayText = fullText:sub(1, SETTINGS.MAX_CONTENT_LENGTH) .. "..."
	end
	newMessage.ContentChat.Text = displayText

	-- ── Scale BackgroundFrame bằng ContentBR.TextBounds ──
	local finalContentScale = 0
	if ContentBR then
		ContentBR.Text = fullText
		local contentScale = (ContentBR.TextBounds.X / newMessage.BackgroundFrame.AbsoluteSize.X) + SETTINGS.CONTENT_OFFSET_X
		finalContentScale  = contentScale

		if contentScale > SETTINGS.MAX_SCALE then
			local text = fullText
			while contentScale > SETTINGS.TRUNCATE_TARGET_SCALE and #text > 0 do
				text = text:sub(1, #text - 1)
				ContentBR.Text = text .. "..."
				contentScale = (ContentBR.TextBounds.X / newMessage.BackgroundFrame.AbsoluteSize.X) + SETTINGS.CONTENT_OFFSET_X
			end
			newMessage.ContentChat.Text = ContentBR.Text
			finalContentScale = SETTINGS.MAX_SCALE
		end
	end

	local finalScale = math.clamp(
		math.max(nameExtraScale + BaseBGSize.X.Scale, finalContentScale) + SETTINGS.SCALE_BONUS,
		0, SETTINGS.MAX_SCALE
	)
	newMessage.BackgroundFrame.Size = UDim2.new(finalScale, BaseBGSize.X.Offset, BaseBGSize.Y.Scale, BaseBGSize.Y.Offset)

	-- ── Avatar + Thời gian ──
	newMessage.NamePl.Time.Text = getTime()
	task.spawn(function()
		local img = Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size420x420)
		newMessage.Avatar.Image = img
	end)

	-- ── Tag kênh ──
	applyTag(newMessage, userId, channelId)

	-- ── State + Animation ──
	applyNewState(newMessage, false)
	newestFrame = newMessage

	local avatarEl        = newMessage:FindFirstChild("Avatar")
	local avatarBaseTrans = avatarEl and avatarEl.BackgroundTransparency or 1

	playAppearAnimation(newMessage, displayText, avatarBaseTrans)

	-- Lưu vào globalChatLog để mode 3 có thể rebuild bubble từ lịch sử
	appendChatLog(userId, displayName, fullText, channelId)

	table.insert(messageList, {
		frame           = newMessage,
		timestamp       = os.time(),
		isNewest        = true,
		avatarBaseTrans = avatarBaseTrans,
		channelId       = channelId or "DEFAULT",
		userId          = userId,
	})

	-- Ẩn ngay nếu không đúng kênh đang chọn
	if channelId ~= ActiveChannelId then
		newMessage.Visible = false
	end

	setupHoverButton(newMessage, fullText, displayName, newMessage.NamePl.Time.Text, userId)
	smoothScrollToBottom()
end


-- ============================================================
--  [18A] EVENT: Nhận tin từ Chat System (ChattedEvent)
--  Tham số: channelId, formattedText, channelType, preview
--  Friend:  channelId, formattedText, senderId, channelType, preview
-- ============================================================

-- Cache dedup: tránh render lại tin optimistic khi server gửi về
-- key = userId .. "_" .. text, value = true
local pendingOptimistic = {}

ChattedEvent.OnClientEvent:Connect(function(channelId, formattedText, arg3, arg4, arg5)
	local preview
	if type(arg3) == "number" then
		preview = arg5
	else
		preview = arg4
	end

	if not preview or not preview.PlayerId or not preview.PlayerName then return end

	-- Nếu là tin của chính mình đã render optimistic → bỏ qua
	local dedupKey = tostring(preview.PlayerId) .. "_" .. (preview.Text or "")
	if preview.PlayerId == localPlayer.UserId and pendingOptimistic[dedupKey] then
		pendingOptimistic[dedupKey] = nil
		return
	end

	-- Route theo chat mode (chatModeRouter defined in [25], use SETTINGS check inline)
	if SETTINGS.CHAT_MODE == 1 then return end
	if SETTINGS.CHAT_MODE == 3 then
		renderBubble(preview.PlayerId, preview.PlayerName, preview.Text or "", channelId)
	else
		renderMessage(
			preview.PlayerId,
			preview.PlayerName,
			preview.Text or "",
			tostring(preview.PlayerId) .. "_" .. tostring(os.clock()),
			channelId
		)
	end
end)


-- ============================================================
--  [18B] EVENT: MessageReceived — kênh DEFAULT (RBXGeneral)
--  Bypass Chat System hoàn toàn, render trực tiếp
-- ============================================================

TextChatService.MessageReceived:Connect(function(message)
	if message.Status ~= Enum.TextChatMessageStatus.Success then return end
	if not message.TextSource then return end

	-- Chỉ nhận từ RBXGeneral
	if not message.TextChannel then return end
	if message.TextChannel.Name ~= "RBXGeneral" then return end

	local player = Players:GetPlayerByUserId(message.TextSource.UserId)
	if not player then return end

	-- Dedup: bỏ qua tin optimistic của chính mình
	local dedupKey = tostring(player.UserId) .. "_" .. message.Text
	if player.UserId == localPlayer.UserId and pendingOptimistic[dedupKey] then
		pendingOptimistic[dedupKey] = nil
		return
	end

	if SETTINGS.CHAT_MODE == 1 then return end
	if SETTINGS.CHAT_MODE == 3 then
		renderBubble(player.UserId, player.DisplayName, message.Text, "DEFAULT")
	else
		renderMessage(
			player.UserId,
			player.DisplayName,
			message.Text,
			tostring(player.UserId) .. "_" .. tostring(message.MessageId),
			"DEFAULT"
		)
	end
end)


-- ============================================================
--  [19] SEND MESSAGE
-- ============================================================

local function sendMessage()
	local cleaned = cleanEmptyLines(ChatMessenger.Text)
	local text    = cleaned:match("^%s*(.-)%s*$")
	if not text or #text == 0 or not text:match("%S") then return end
	if #text > SETTINGS.MAX_INPUT_LENGTH then text = text:sub(1, SETTINGS.MAX_INPUT_LENGTH) end

	isSending = true
	ChatMessenger.MultiLine = false
	extraLines  = 0
	lastLineCount = 1
	syncBGToTextBounds(1)

	-- Send animation
	local stretchSize = UDim2.new(SIZE_FOCUSED.X.Scale + 0.5, SIZE_FOCUSED.X.Offset, SIZE_FOCUSED.Y.Scale, SIZE_FOCUSED.Y.Offset)
	TweenService:Create(ChatboxFrame,
		TweenInfo.new(0.15, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = stretchSize }
	):Play()
	task.delay(0.15, function()
		TweenService:Create(ChatboxFrame,
			TweenInfo.new(1, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = SIZE_FOCUSED }
		):Play()
	end)

	setScrollFrameX(0, 0.12, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
	task.delay(0.15, function()
		setScrollFrameX(0.04, 0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end)

	local channelId = getActiveChannelId()

	-- ── Optimistic render ngay lập tức ──────────────────────
	local dedupKey = tostring(localPlayer.UserId) .. "_" .. text
	pendingOptimistic[dedupKey] = true
	if SETTINGS.CHAT_MODE == 3 then
		renderBubble(localPlayer.UserId, localPlayer.DisplayName, text, channelId)
	elseif SETTINGS.CHAT_MODE == 2 then
		renderMessage(
			localPlayer.UserId,
			localPlayer.DisplayName,
			text,
			tostring(localPlayer.UserId) .. "_optimistic_" .. tostring(os.clock()),
			channelId
		)
	end
	-- Mode 1: Roblox default chat tự render, không cần làm gì
	-- Tự xóa dedup sau 5 giây phòng server không reply
	task.delay(5, function()
		pendingOptimistic[dedupKey] = nil
	end)

	-- ── Gửi lên server ──────────────────────────────────────
	if channelId == "DEFAULT" then
		-- Kênh mặc định Roblox: gửi thẳng qua RBXGeneral
		task.spawn(function()
			local textChannels = TextChatService:FindFirstChild("TextChannels")
			if textChannels then
				local general = textChannels:FindFirstChild("RBXGeneral")
				if general then general:SendAsync(text) end
			end
		end)
	else
		-- Chat System
		ChattedEvent:FireServer("Chatted", channelId, text)
	end

	ChatMessenger.Text = ""
	savedDraftText     = ""
	task.wait()
	ChatMessenger.Text = ""
	SendButton.Visible = false
	isSending          = false
	ChatMessenger:CaptureFocus()
end

SendButton.Visible = false
SendButton.MouseButton1Click:Connect(function()
	sendMessage()
	ChatMessenger:CaptureFocus()
end)


-- ============================================================
--  [20] EVENTS: Chatbox Focus / Input
-- ============================================================

ChatMessenger.Focused:Connect(function()
	isFocused = true
	idleTime  = 0
	isFading  = false
	setAvatarColor(true)
	applyChatboxAlpha(1)
	task.spawn(function()
		isRestoringText = true
		ChatMessenger.Text = savedDraftText
		ChatMessenger.CursorPosition = #savedDraftText + 1
		isRestoringText = false
		task.wait(0.1)
		lastLineCount = getActualLineCount()
		syncBGToTextBounds()
	end)
	TweenService:Create(ChatboxFrame,
		TweenInfo.new(0.35, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = SIZE_FOCUSED }
	):Play()
	if ChatboxBG then ChatboxBG.BackgroundTransparency = SETTINGS.CHATBOX_BG_TRANS end
end)

ChatMessenger.FocusLost:Connect(function(enterPressed)
	isFocused = false
	setAvatarColor(false)
	local cleaned  = cleanEmptyLines(ChatMessenger.Text)
	ChatMessenger.Text = cleaned
	savedDraftText     = cleaned
	local actualLines  = getActualLineCount()
	lastLineCount  = actualLines
	extraLines     = actualLines - 1
	syncBGToTextBounds(actualLines)
	if not isSending then
		TweenService:Create(ChatboxFrame,
			TweenInfo.new(0.3, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
			{ Size = SIZE_DEFAULT }
		):Play()
	end
	if enterPressed then task.defer(function() sendMessage() end) end
end)

UserInputService.InputBegan:Connect(function(input, _)
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		isShiftHeld = true
		if isFocused then ChatMessenger.MultiLine = true end
	end
	if input.KeyCode == Enum.KeyCode.Return and isShiftHeld and isFocused then
		local actualLines = getActualLineCount()
		if actualLines >= SETTINGS.MAX_LINES then ChatMessenger.MultiLine = false; return end
		extraLines = actualLines
		if actualLines + 1 >= SETTINGS.MAX_LINES then
			task.defer(function() ChatMessenger.MultiLine = false end)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		isShiftHeld = false
		ChatMessenger.MultiLine = false
	end
end)

ChatMessenger:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	local newLines = getActualLineCount()
	lastLineCount  = newLines
	extraLines     = newLines - 1
	syncBGToTextBounds(newLines)
end)

ChatMessenger:GetPropertyChangedSignal("Text"):Connect(function()
	if isAutoWrapping or isRestoringText then return end
	if #ChatMessenger.Text > SETTINGS.MAX_INPUT_LENGTH then
		ChatMessenger.Text = ChatMessenger.Text:sub(1, SETTINGS.MAX_INPUT_LENGTH); return
	end

	-- Auto wrap
	if SETTINGS.ENABLE_AUTO_WRAP then
		local needsWrap = false
		for line in ChatMessenger.Text:gmatch("([^\n]*)") do
			if #line > SETTINGS.AUTO_WRAP_LENGTH then needsWrap = true; break end
		end
		if needsWrap then
			local now = tick()
			if (now - lastWrapTime) >= SETTINGS.WRAP_COOLDOWN then
				local wrapped = applyAutoWrap(ChatMessenger.Text)
				if wrapped ~= ChatMessenger.Text then
					local lineCount = getActualLineCount()
					if lineCount < SETTINGS.MAX_LINES then
						lastWrapTime    = now
						isAutoWrapping  = true
						ChatMessenger.MultiLine = true
						local newText   = cleanEmptyLines(applyAutoWrap(ChatMessenger.Text))
						ChatMessenger.Text    = newText
						savedDraftText        = newText
						ChatMessenger.CursorPosition = #newText + 1
						if not isShiftHeld then ChatMessenger.MultiLine = false end
						isAutoWrapping = false
					end
				end
			end
		end
	end

	local actualLines = getActualLineCount()
	lastLineCount = actualLines
	extraLines    = actualLines - 1
	syncBGToTextBounds(actualLines)

	if isShiftHeld and isFocused and actualLines < SETTINGS.MAX_LINES then
		ChatMessenger.MultiLine = true
	elseif actualLines >= SETTINGS.MAX_LINES then
		ChatMessenger.MultiLine = false
	end

	local trimmed = ChatMessenger.Text:match("^%s*(.-)%s*$")
	SendButton.Visible = trimmed:match("%S") ~= nil
end)


-- ============================================================
--  [21] EVENTS: Hover Chatbox
-- ============================================================

local HoverDetector = Instance.new("TextButton")
HoverDetector.Name                   = "HoverDetector"
HoverDetector.Size                   = UDim2.new(1, 0, 1, 0)
HoverDetector.BackgroundTransparency = 1
HoverDetector.Text                   = ""
HoverDetector.ZIndex                 = 20
HoverDetector.Parent                 = ChatboxBG or ChatboxFrame

HoverDetector.MouseEnter:Connect(function()
	isHovered = true
	if chatboxAlpha < 1 then showChatbox() end
end)
HoverDetector.MouseLeave:Connect(function()
	isHovered = false
end)


-- ============================================================
--  [22] RUNSERVICE: Idle Fade + Positional Fade
-- ============================================================

RunService.Heartbeat:Connect(function(dt)
	if not SETTINGS.ENABLE_IDLE_FADE then return end
	if isFocused or isHovered then
		idleTime = 0; isFading = false
		if chatboxAlpha < 1 then showChatbox() end
		return
	end
	local trimmed = ChatMessenger.Text:match("^%s*(.-)%s*$") or ""
	if #trimmed > 0 then
		idleTime = 0; isFading = false
		if chatboxAlpha < 1 then showChatbox() end
		return
	end
	idleTime = idleTime + dt
	if idleTime >= SETTINGS.IDLE_DELAY then
		isFading = true
		local fadeProgress = math.clamp((idleTime - SETTINGS.IDLE_DELAY) / SETTINGS.FADE_DURATION, 0, 1)
		applyChatboxAlpha(1 - fadeProgress)
		if fadeProgress > 0 and fadeProgress < 0.02 then
			scrollFrameVisible = false
			setScrollFrameX(0, 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(ChatboxFrame,
				TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = SIZE_DEFAULT }
			):Play()
		end
	end
end)

RunService.RenderStepped:Connect(function()
	local FADE_Y_FULL, FADE_Y_START, FADE_Y_END, FADE_Y_BOTTOM_START, FADE_Y_BOTTOM_END

	if isMobile and MobileSupportChatFrame then
		local frameTop    = MobileSupportChatFrame.AbsolutePosition.Y
		local frameBottom = frameTop + MobileSupportChatFrame.AbsoluteSize.Y
		local MARGIN      = 30
		FADE_Y_FULL         = frameTop
		FADE_Y_START        = frameTop
		FADE_Y_END          = frameTop    - MARGIN
		FADE_Y_BOTTOM_START = frameBottom
		FADE_Y_BOTTOM_END   = frameBottom + MARGIN
	else
		FADE_Y_FULL         = SETTINGS.FADE_Y_FULL
		FADE_Y_START        = SETTINGS.FADE_Y_START
		FADE_Y_END          = SETTINGS.FADE_Y_END
		FADE_Y_BOTTOM_START = SETTINGS.FADE_Y_BOTTOM_START
		FADE_Y_BOTTOM_END   = SETTINGS.FADE_Y_BOTTOM_END
	end

	for _, entry in ipairs(messageList) do
		local frame = entry.frame
		if not (frame and frame.Parent) then continue end

		-- Hover: không áp positional fade
		if frame == hoveredFrame then
			setBGTransparency(frame, SETTINGS.TRANS_HOVER_FOCUS)
			setChildrenAlpha(frame, SETTINGS.TEXT_ALPHA_VISIBLE)
			local uiScale = frame:FindFirstChildOfClass("UIScale")
			if uiScale then
				TweenService:Create(uiScale,
					TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Scale = 1 }
				):Play()
			end
			continue
		end

		-- UIScale
		local uiScale = frame:FindFirstChildOfClass("UIScale")
		if not uiScale then uiScale = Instance.new("UIScale"); uiScale.Parent = frame end
		uiScale.Scale = entry.isNewest and 1 or 0.95

		if not SETTINGS.ENABLE_POSITIONAL_FADE then
			-- Không fade: hiện 100%
			setBGTransparency(frame, getBaseTransparency(entry))
			setChildrenAlpha(frame, 1)
			continue
		end

		local frameAbsY    = frame.AbsolutePosition.Y + frame.AbsoluteSize.Y
		local frameAbsYTop = frame.AbsolutePosition.Y

		-- Fade phía trên
		local topFade
		if    frameAbsY >= FADE_Y_FULL then topFade = 0
		elseif frameAbsY <= FADE_Y_END  then topFade = 1
		else   topFade = math.clamp((FADE_Y_START - frameAbsY) / (FADE_Y_START - FADE_Y_END), 0, 1)
		end

		-- Fade phía dưới
		local bottomFade = math.clamp(
			(frameAbsYTop - FADE_Y_BOTTOM_START) / (FADE_Y_BOTTOM_END - FADE_Y_BOTTOM_START),
			0, 1
		)

		local fadeRatio = math.max(topFade, bottomFade)
		local baseTrans = getBaseTransparency(entry)
		setBGTransparency(frame, baseTrans + (SETTINGS.TRANS_FADE_MAX - baseTrans) * fadeRatio)
		setChildrenAlpha(frame, 1 - fadeRatio)
	end
end)


-- ============================================================
--  [23] INIT
-- ============================================================

-- Avatar chatbox local player
task.spawn(function()
	if ChatboxAvatar and localPlayer then
		local img = Players:GetUserThumbnailAsync(
			localPlayer.UserId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size420x420
		)
		ChatboxAvatar.Image = img
	end
end)

-- Cleanup định kỳ
task.spawn(function()
	while true do task.wait(60); cleanupMessages() end
end)

-- Trạng thái ban đầu
setAvatarColor(false)
ChatboxFrame.Size = SIZE_DEFAULT

-- ── Lắng nghe ChatSettingsChanged từ UI Settings Panel ──────
local ChatSettingsChanged = DataPlayer:WaitForChild("ChatSettingsChanged")
ChatSettingsChanged.Event:Connect(function(key, value)
	if DEFAULT_SETTINGS[key] ~= nil then
		SETTINGS[key] = value
		if key == "CHAT_SCALE" then applyChatScale() end
	end
end)


-- ============================================================
--  [24] CHANNEL SELECTOR
--  Setting dropdown chọn channel — tích hợp với SliderModule
--  Tự rebuild khi có channel mới (Private/Group động)
-- ============================================================

-- ── Paths ────────────────────────────────────────────────────
local SliderModule     = require(script.SettingFrame)
local TemplateC        = script.SettingGUISetup.ChonseTemplate
local TemplateE        = script.SettingGUISetup.EnabledTemplate
local SettingFrameMenu = script.Parent.SettingFrame.SettingFrameMenu
local WheelFrame       = script.Parent.SettingFrame.ChonseFrameSlider
local ClickFrame       = script.Parent.SettingFrame.ChonseFrameClick
local ChatChannelEvent = ReplicatedStorage:FindFirstChild("GameSettingUp"):FindFirstChild("ChatEvent"):WaitForChild("ChatChannelEvent")

-- ── State ────────────────────────────────────────────────────
local CHANNEL_SELECTOR  = nil
local currentChannelIds = {}

-- ── Xóa icon emoji ở đầu chuỗi + in hoa ─────────────────────
local function cleanLabel(str)
	-- Xóa emoji/icon unicode ở đầu (ký tự không phải ASCII + khoảng trắng)
	local cleaned = str:gsub("^[%z\1-\127\194-\244][\128-\191]*%s*", function(c)
		if c:match("^[%a%d%p%s]") then return c end  -- giữ lại ký tự ASCII bình thường
		return ""
	end)
	-- Fallback nếu xóa hết → dùng nguyên gốc
	if cleaned == "" then cleaned = str end
	return cleaned:upper()
end

-- ── Lấy danh sách channel từ server ─────────────────────────
local function fetchChannelOptions()
	local ok, channels = pcall(function()
		return RF_GetChannels:InvokeServer()
	end)
	if not ok or type(channels) ~= "table" then
		return { "GLOBAL", "—" }, { "Global", "Global" }
	end

	local options, ids = {}, {}
	local added = {}

	-- Luôn thêm kênh DEFAULT (RBXGeneral) vào đầu danh sách
	table.insert(options, "DEFAULT")
	table.insert(ids, "DEFAULT")
	added["DEFAULT"] = true

	-- Default channels theo thứ tự cố định
	local defaultOrder = { "Global", "Server", "Team", "Staff", "Friend" }
	for _, name in ipairs(defaultOrder) do
		for _, ch in ipairs(channels) do
			if ch.Id == name and not added[ch.Id] then
				table.insert(options, cleanLabel(ch.DisplayName or ch.Id))
				table.insert(ids, ch.Id)
				added[ch.Id] = true
			end
		end
	end

	-- Private/Group động — thêm sau
	for _, ch in ipairs(channels) do
		if not added[ch.Id] then
			table.insert(options, cleanLabel(ch.DisplayName or ch.Id))
			table.insert(ids, ch.Id)
			added[ch.Id] = true
		end
	end

	-- Selected cần ít nhất 2 option
	if #options < 2 then
		table.insert(options, "—")
		table.insert(ids, ids[1] or "Global")
	end

	return options, ids
end

-- ── Tìm index của channel đang active ───────────────────────
local function findActiveIndex(ids)
	for i, id in ipairs(ids) do
		if id == ActiveChannelId then return i end
	end
	return 1
end

-- ── Tạo/rebuild CHANNEL_SELECTOR ────────────────────────────
local function buildChannelSelector(options, ids)
	if CHANNEL_SELECTOR then
		CHANNEL_SELECTOR:destroy()
		CHANNEL_SELECTOR = nil
	end

	CHANNEL_SELECTOR = SliderModule.Selected({
		wheelFrame = WheelFrame,
		clickFrame = ClickFrame,
		template   = TemplateC,
		parent     = SettingFrameMenu,
		title      = "CHANNEL",
		options    = options,
		default    = findActiveIndex(ids),
		onChange   = function(idx, info)
			local selectedId = ids[idx]
			if not selectedId or selectedId == "—" then return end
			-- Cập nhật ActiveChannelId trong ChatFrame
			ActiveChannelId = selectedId
			-- Ẩn tin cũ, chỉ hiện tin đúng kênh mới
			filterByChannel(selectedId)
			smoothScrollToBottom()
		end,
	})

	currentChannelIds = ids
end

-- ── Khởi tạo lần đầu ────────────────────────────────────────
task.spawn(function()
	task.wait(2)  -- đợi server tạo xong channels
	local options, ids = fetchChannelOptions()
	buildChannelSelector(options, ids)
end)

-- ── Toggle: Hiển thị tag kênh (#Friend, #Global, ...) ───────
SliderModule.Enabled({
	template  = TemplateE,
	parent    = SettingFrameMenu,
	title     = "CHANNEL TAG",
	default   = SETTINGS.ENABLE_TAG,
	truefalse = {"ON", "OFF"},
	tag       = "ENABLE_TAG",
	onChange  = function(value)
		SETTINGS.ENABLE_TAG = value
		-- Refresh tag toàn bộ tin đang hiển thị
		task.spawn(function()
			for _, entry in ipairs(messageList) do
				if entry.frame and entry.frame.Parent then
					applyTag(entry.frame, entry.userId, entry.channelId)
				end
			end
		end)
	end,
})

-- ── Realtime: rebuild khi có channel mới/đổi tên ────────────
ChatChannelEvent.OnClientEvent:Connect(function(action, channelId, displayName)
	task.spawn(function()
		task.wait(0.3)
		local options, ids = fetchChannelOptions()

		-- Chỉ rebuild nếu danh sách thực sự thay đổi
		local changed = (#ids ~= #currentChannelIds)
		if not changed then
			for i, id in ipairs(ids) do
				if currentChannelIds[i] ~= id then changed = true; break end
			end
		end

		if changed then
			buildChannelSelector(options, ids)
		end
	end)
end)


-- ============================================================
--  [25] CHAT MODE SYSTEM
--  Mode 1: Roblox Default UI  — ẩn custom frame, bật Roblox chat
--  Mode 2: Custom Frame       — frame hiện tại (mặc định)
--  Mode 3: Bubble Mode        — 1 bubble/người, cập nhật thay vì clone mới
-- ============================================================

local TemplateS = script.SettingGUISetup.SliderTemplate

-- ============================================================
--  [26] HISTORY CHAT + MESSENGER TIME
--  - MessengerTime: chỉ hiện ở mode 3, hiển thị số tin chưa đọc
--  - HistoryChat: panel lịch sử, mở khi click vào bubble
--  - globalChatLog: lưu tối đa 75 tin gần nhất mọi kênh
-- ============================================================

-- ── Thêm tin vào globalChatLog (per-channel) ────────────────
local refreshHistoryChat  -- forward declaration

appendChatLog = function(userId, displayName, text, channelId)
	local key = channelId or "DEFAULT"
	if not globalChatLog[key] then globalChatLog[key] = {} end
	table.insert(globalChatLog[key], {
		userId      = userId,
		displayName = displayName,
		text        = text,
		channelId   = key,
		time        = getTime(),
	})
	-- Giữ tối đa HISTORY_MAX tin mỗi kênh
	while #globalChatLog[key] > HISTORY_MAX do
		table.remove(globalChatLog[key], 1)
	end
	-- Tự cập nhật HistoryChat nếu đang mở đúng kênh này
	if historyOpen ~= nil and historyOpenChannel == key and refreshHistoryChat then
		refreshHistoryChat()
	end
end

-- ── MessengerTime: cập nhật badge số tin chưa đọc ───────────
local function updateMessengerTime(frame, userId)
	if SETTINGS.CHAT_MODE ~= 3 then return end
	local mt = frame and frame:FindFirstChild("MessengerTime")
	if not mt then return end

	local count = unreadCount[userId] or 0
	if count <= 0 then
		mt.Visible = false
		return
	end

	local timeLabel = mt:FindFirstChild("Time")
	if timeLabel then
		timeLabel.Text = count > 9 and "9+" or tostring(count)
	end
	mt.Visible = true
end

-- ── Ẩn MessengerTime của TẤT CẢ player khác (khi local gõ) ──
local function hideAllMessengerTime()
	for uid, entry in pairs(bubbleMap) do
		if uid ~= localPlayer.UserId then
			unreadCount[uid] = 0
			local mt = entry.frame and entry.frame:FindFirstChild("MessengerTime")
			if mt then mt.Visible = false end
		end
	end
end

-- ── Đóng HistoryChat panel ───────────────────────────────────
local function closeHistoryChat()
	if not HistoryChat then return end
	historyOpen        = nil
	historyOpenChannel = nil
	TweenService:Create(HistoryChat,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	):Play()
	task.delay(0.22, function()
		HistoryChat.Visible = false
		-- Xóa các TextLabel đã tạo
		for _, child in ipairs(HistoryChat:GetChildren()) do
			if child:IsA("TextLabel") or child.Name == "HistoryEntry" then
				child:Destroy()
			end
		end
	end)
end

-- ── Build nội dung HistoryChat (dùng chung cho open + refresh) ──
local function buildHistoryContent(userId, channelId)
	if not HistoryChat then return end

	local key      = channelId or "DEFAULT"
	local filtered = globalChatLog[key] or {}

	-- Xóa nội dung cũ
	for _, child in ipairs(HistoryChat:GetChildren()) do
		if child.Name == "HistoryEntry" or child:IsA("UIListLayout") or child:IsA("UIPadding") then
			child:Destroy()
		end
	end

	-- Layout
	local layout = Instance.new("UIListLayout")
	layout.Name                = "UIListLayout"
	layout.SortOrder           = Enum.SortOrder.LayoutOrder
	layout.Padding             = UDim.new(0, 6)
	layout.FillDirection       = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.Parent              = HistoryChat

	local padding = Instance.new("UIPadding")
	padding.Name         = "UIPadding"
	padding.PaddingTop   = UDim.new(0, 8)
	padding.PaddingBottom= UDim.new(0, 8)
	padding.PaddingLeft  = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent       = HistoryChat

	-- ── Helper: seed màu từ tên ──────────────────────────────
	local function nameToColor(name)
		local hash = 0
		for i = 1, #name do
			hash = (hash * 31 + string.byte(name, i)) % 16777216
		end
		return Color3.fromRGB(
			120 + hash % 136,
			120 + (hash // 256) % 136,
			120 + (hash // 65536) % 136
		)
	end

	-- ── Helper: Color3 → hex string ──────────────────────────
	local function toHex(color)
		return string.format("%02X%02X%02X",
			math.floor(color.R * 255),
			math.floor(color.G * 255),
			math.floor(color.B * 255)
		)
	end

	-- TAG_COLOR_HEX: lấy từ TAG_COLOR đã có sẵn
	local function getTagHex(channelKey)
		local lower = (channelKey or ""):lower()
		local label
		if     lower:find("friend")  then label = "Friend"
		elseif lower:find("private") then label = "Private"
		elseif lower:find("group")   then label = "Group"
		elseif lower == "server"     then label = "Server"
		elseif lower == "team"       then label = "Team"
		elseif lower == "staff"      then label = "Staff"
		else   label = nil
		end
		local color = label and TAG_COLOR[label] or TAG_COLOR_DEFAULT
		return toHex(color), label and ("#" .. label:upper()) or ("#" .. channelKey:sub(1,8):upper())
	end

	-- Tạo từ cũ nhất → mới nhất
	local totalHeight = 16
	local TEXT_SIZE   = 13
	local PANEL_WIDTH = HistoryChat.AbsoluteSize.X > 0 and HistoryChat.AbsoluteSize.X - 20 or 260

	for i, entry in ipairs(filtered) do
		local isSelf    = (entry.userId == localPlayer.UserId)
		local isViewed  = (entry.userId == userId)

		-- ── Màu tên ──────────────────────────────────────────
		local nameColor
		if isSelf then
			nameColor = nameToColor(entry.displayName)
		else
			nameColor = nameToColor(entry.displayName)
		end
		local nameHex = toHex(nameColor)

		-- ── Tag ──────────────────────────────────────────────
		local hasTag = entry.channelId
			and entry.channelId ~= "DEFAULT"
			and entry.channelId ~= "Global"
			and not isSelf

		local tagPart = ""
		if hasTag then
			local tagHex, tagLabel = getTagHex(entry.channelId)
			tagPart = string.format('<i><font color="#%s">[%s]</font></i>  ', tagHex, tagLabel)
		end

		-- ── Format RichText ──────────────────────────────────
		local line = string.format(
			'%s<b><font color="#%s">[%s]</font></b> : <font color="#FFFFFF">%s</font>',
			tagPart, nameHex, entry.displayName, entry.text
		)

		-- Tính chiều cao (dùng plain text để đo, tránh lỗi RichText)
		local plainLine = (hasTag and "[TAG] " or "") .. "[" .. entry.displayName .. "] : " .. entry.text
		local ok, bounds = pcall(function()
			return game:GetService("TextService"):GetTextSize(
				plainLine, TEXT_SIZE, Enum.Font.Montserrat, Vector2.new(PANEL_WIDTH, 9999)
			)
		end)
		local lineH = (ok and bounds.Y or TEXT_SIZE) + 8

		local label = Instance.new("TextLabel")
		label.Name                 = "HistoryEntry"
		label.LayoutOrder          = i
		label.Size                 = UDim2.new(1, 0, 0, lineH)
		label.BackgroundTransparency = 1
		label.Font                 = Enum.Font.Montserrat
		label.TextSize             = TEXT_SIZE
		label.TextColor3           = Color3.fromRGB(255, 255, 255)
		label.Text                 = line
		label.TextWrapped          = true
		label.TextXAlignment       = Enum.TextXAlignment.Left
		label.TextYAlignment       = Enum.TextYAlignment.Top
		label.RichText             = true
		label.Parent               = HistoryChat

		totalHeight = totalHeight + lineH + 6
	end

	-- Canvas tự mở rộng theo Y
	HistoryChat.CanvasSize = UDim2.new(0, 0, 0, totalHeight)

	-- Scroll xuống cuối (tin mới nhất)
	task.defer(function()
		local maxY = math.max(0, HistoryChat.AbsoluteCanvasSize.Y - HistoryChat.AbsoluteSize.Y)
		HistoryChat.CanvasPosition = Vector2.new(0, maxY)
	end)
end

-- ── Refresh HistoryChat khi có tin mới (không fade lại) ─────
refreshHistoryChat = function()
	if not historyOpen or not historyOpenChannel then return end
	buildHistoryContent(historyOpen, historyOpenChannel)
end

-- ── Mở HistoryChat panel cho 1 player ───────────────────────
local function openHistoryChat(userId, channelId)
	if not HistoryChat then return end

	-- Toggle: bấm lại thì đóng
	if historyOpen == userId then
		closeHistoryChat()
		return
	end

	historyOpen        = userId
	historyOpenChannel = channelId or "DEFAULT"

	buildHistoryContent(userId, channelId)

	-- Hiện panel với fade in
	HistoryChat.Visible = true
	HistoryChat.BackgroundTransparency = 1
	TweenService:Create(HistoryChat,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 0.15 }
	):Play()
end

-- ── Setup click handler cho bubble (mode 3) ──────────────────
local function setupBubbleClick(frame, userId, channelId)
	local bg = frame:FindFirstChild("BackgroundFrame")
	if not bg then return end

	-- Tái dùng HoverButton nếu có, hoặc tạo mới (mode 3 không dùng preview)
	local btn = bg:FindFirstChild("HoverButton")
	if not btn then
		btn = Instance.new("TextButton")
		btn.Name = "HoverButton"
		btn.Size = UDim2.new(1, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.ZIndex = 10
		btn.Parent = bg
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = btn
	end

	-- Hover → ẩn MessengerTime
	btn.MouseEnter:Connect(function()
		onHoverEnter(frame)
		unreadCount[userId] = 0
		local mt = frame:FindFirstChild("MessengerTime")
		if mt then mt.Visible = false end
	end)
	btn.MouseLeave:Connect(function()
		onHoverLeave(frame)
	end)

	-- Click → mở/đóng HistoryChat
	btn.MouseButton1Click:Connect(function()
		-- Reset unread khi click
		unreadCount[userId] = 0
		local mt = frame:FindFirstChild("MessengerTime")
		if mt then mt.Visible = false end
		openHistoryChat(userId, channelId)
	end)
end

-- ── Áp mode lên UI ──────────────────────────────────────────
local function applyChatMode(mode)
	-- Ẩn Roblox default chat UI ở mode 2 và 3
	local cfg = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	local inputCfg = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
	if mode == 1 then
		if cfg      then cfg.Enabled      = true end
		if inputCfg then inputCfg.Enabled = true end
		ChatChannelFrame.Visible = false
		if HistoryChat then HistoryChat.Visible = false end
	else
		if cfg      then cfg.Enabled      = false end
		if inputCfg then inputCfg.Enabled = false end
		ChatChannelFrame.Visible = true
	end

	if mode == 2 then
		-- Xóa toàn bộ bubble nếu đang có
		for _, entry in pairs(bubbleMap) do
			if entry.frame and entry.frame.Parent then entry.frame:Destroy() end
		end
		bubbleMap     = {}
		bubbleOrder   = {}
		unreadCount   = {}
		bubbleNewest  = nil
		bubbleDimTimer = {}
		-- Ẩn MessengerTime trên tất cả tin nhắn cũ
		for _, entry in ipairs(messageList) do
			if entry.frame and entry.frame.Parent then
				local mt = entry.frame:FindFirstChild("MessengerTime")
				if mt then mt.Visible = false end
			end
		end
		if HistoryChat then closeHistoryChat() end

	elseif mode == 3 then
		-- Xóa hết tin nhắn thường, reset sang bubble
		for _, entry in ipairs(messageList) do
			if entry.frame and entry.frame.Parent then entry.frame:Destroy() end
		end
		messageList = {}
		newestFrame = nil
		-- Rebuild bubble từ globalChatLog (lấy tin mới nhất của mỗi player)
		task.spawn(function()
			task.wait(0.1)
			-- Duyệt từ mới → cũ, lấy tin đầu tiên gặp của mỗi userId
			local seen = {}
			local toRender = {}
			local channelLog = globalChatLog[ActiveChannelId] or {}
			for i = #channelLog, 1, -1 do
				local entry = channelLog[i]
				if not seen[entry.userId] then
					seen[entry.userId] = true
					table.insert(toRender, 1, entry)  -- giữ thứ tự cũ→mới
				end
			end
			for _, entry in ipairs(toRender) do
				renderBubble(entry.userId, entry.displayName, entry.text, entry.channelId)
			end
		end)
	end
end

-- ── Bubble Layout/Fade Helpers ──────────────────────────────

-- Tính opacity chuẩn theo slot cho từng bubble
-- slot 0 = mới nhất, 1 = bản thân (hoặc thứ 2), 2+ = còn lại
local function getBubbleBaseOpacity(slotUserId)
	local isSelf    = (slotUserId == localPlayer.UserId)
	local isNewest  = (slotUserId == bubbleNewest)
	local total     = #bubbleOrder

	-- Chỉ 1 người → 100%
	if total <= 1 then return 1 end

	if isNewest then
		return 1  -- người mới nhất luôn 100%
	elseif isSelf then
		-- Bản thân: 100% nếu mình là newest, 90% nếu người khác newest
		if bubbleNewest ~= localPlayer.UserId then
			return 0.9
		else
			return 1
		end
	else
		-- Người khác không phải newest: 70%
		return 0.7
	end
end

-- Tính layout order cho từng userId
local function getBubbleLayoutOrder(uid)
	if uid == bubbleNewest then
		return 0
	elseif uid == localPlayer.UserId then
		return 1
	else
		-- Tìm vị trí trong bubbleOrder (bỏ qua slot 0 và 1)
		local idx = 2
		for _, oid in ipairs(bubbleOrder) do
			if oid ~= bubbleNewest and oid ~= localPlayer.UserId then
				if oid == uid then return idx end
				idx = idx + 1
			end
		end
		return idx
	end
end

-- Áp layout order + opacity lên tất cả bubble hiện tại
local function refreshBubbleLayout(senderUserId)
	local now = tick()

	-- Ghi timer dim cho tất cả người KHÁC với sender
	if senderUserId then
		for _, uid in ipairs(bubbleOrder) do
			if uid ~= senderUserId then
				-- Chỉ set timer nếu chưa có hoặc đã hết
				local existing = bubbleDimTimer[uid]
				if not existing or (now - existing) >= 5 then
					bubbleDimTimer[uid] = now
				end
			end
		end
	end

	for _, uid in ipairs(bubbleOrder) do
		local entry = bubbleMap[uid]
		if not (entry and entry.frame and entry.frame.Parent) then continue end
		local frame = entry.frame

		-- Layout order
		frame.LayoutOrder = getBubbleLayoutOrder(uid)

		-- Base opacity theo slot
		local baseOpacity = getBubbleBaseOpacity(uid)

		-- Dim 0.9x nếu trong vòng 5 giây kể từ tin mới (không áp cho sender và bản thân newest)
		local dimTimer = bubbleDimTimer[uid]
		local isDimmed = dimTimer and (now - dimTimer) < 5
		if isDimmed and uid ~= senderUserId then
			baseOpacity = baseOpacity * 0.9
		end

		local targetTrans = 1 - baseOpacity
		local bg = frame:FindFirstChild("BackgroundFrame")
		if bg then
			TweenService:Create(bg,
				TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = targetTrans }
			):Play()
		end
		setChildrenAlpha(frame, baseOpacity)
	end

	-- Recover: sau 5 giây reset dim và refresh lại
	if senderUserId then
		task.delay(5, function()
			if SETTINGS.CHAT_MODE ~= 3 then return end
			local nowCheck = tick()
			for _, uid in ipairs(bubbleOrder) do
				local t = bubbleDimTimer[uid]
				if t and (nowCheck - t) >= 5 then
					bubbleDimTimer[uid] = nil
				end
			end
			refreshBubbleLayout(nil)
		end)
	end
end

-- ── Bubble Engine ────────────────────────────────────────────
--  Gọi thay cho renderMessage khi CHAT_MODE == 3
renderBubble = function(userId, displayName, fullText, channelId)
	-- Chỉ hiện đúng kênh đang chọn
	if channelId ~= ActiveChannelId then
		appendChatLog(userId, displayName, fullText, channelId)
		return
	end

	-- Log vào history
	appendChatLog(userId, displayName, fullText, channelId)

	-- Cập nhật người nhắn mới nhất
	bubbleNewest = userId

	local existing = bubbleMap[userId]

	if existing and existing.frame and existing.frame.Parent then
		-- ── Người đã có bubble → update text + time + unread ──
		local frame     = existing.frame
		local content   = frame:FindFirstChild("ContentChat")
		local namePl    = frame:FindFirstChild("NamePl")
		local timeLabel = namePl and namePl:FindFirstChild("Time")

		local displayText = fullText
		if #fullText > SETTINGS.MAX_CONTENT_LENGTH then
			displayText = fullText:sub(1, SETTINGS.MAX_CONTENT_LENGTH) .. "..."
		end
		if content then
			if SETTINGS.ENABLE_TYPEWRITER then
				content.Text = ""
				task.spawn(function()
					for i = 1, #displayText do
						if not (frame and frame.Parent) then break end
						content.Text = displayText:sub(1, i)
						task.wait(SETTINGS.APPEAR_TYPE_SPEED)
					end
				end)
			else
				content.Text = displayText
			end
		end
		if timeLabel then timeLabel.Text = getTime() end

		if userId ~= localPlayer.UserId and historyOpen ~= userId then
			unreadCount[userId] = (unreadCount[userId] or 0) + 1
		end
		updateMessengerTime(frame, userId)
		applyTag(frame, userId, channelId)

	else
		-- ── Người mới → tạo bubble mới ──
		while #bubbleOrder >= SETTINGS.BUBBLE_MAX_PLAYERS do
			local oldUserId = table.remove(bubbleOrder, 1)
			local oldEntry  = bubbleMap[oldUserId]
			if oldEntry and oldEntry.frame and oldEntry.frame.Parent then
				local f = oldEntry.frame
				TweenService:Create(f,
					TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ BackgroundTransparency = 1 }
				):Play()
				task.delay(0.35, function()
					if f and f.Parent then f:Destroy() end
				end)
			end
			bubbleMap[oldUserId] = nil
			bubbleDimTimer[oldUserId] = nil
		end

		local frameName = tostring(userId) .. "_bubble"
		renderMessage(userId, displayName, fullText, frameName, channelId)

		local newEntry = messageList[#messageList]
		if newEntry then
			bubbleMap[userId] = { frame = newEntry.frame, channelId = channelId }
			table.insert(bubbleOrder, userId)

			if userId ~= localPlayer.UserId then
				unreadCount[userId] = (unreadCount[userId] or 0) + 1
			else
				unreadCount[userId] = 0
			end

			local mt = newEntry.frame:FindFirstChild("MessengerTime")
			if mt then mt.Visible = false end
			updateMessengerTime(newEntry.frame, userId)
			setupBubbleClick(newEntry.frame, userId, channelId)
		end
	end

	-- Refresh layout order + fade cho tất cả bubble
	refreshBubbleLayout(userId)
end

-- ── Settings UI ──────────────────────────────────────────────

-- Select chọn mode (Default UI / Custom Frame / Bubble Mode)
SliderModule.Selected({
	wheelFrame = WheelFrame,
	clickFrame = ClickFrame,
	template   = TemplateC,
	parent     = SettingFrameMenu,
	title      = "CHAT MODE",
	options    = { "DEFAULT UI", "COUSER MODE", "BUBBLE MODE" },
	default    = SETTINGS.CHAT_MODE,
	onChange   = function(idx, info)
		SETTINGS.CHAT_MODE = idx
		applyChatMode(idx)
	end,
})

-- Slider số người tối đa trong bubble mode
SliderModule.Slider({
	template = TemplateS,
	parent   = SettingFrameMenu,
	title    = "BUBBLE PLAYERS",
	min      = 1,
	max      = 10,
	step     = 1,
	default  = SETTINGS.BUBBLE_MAX_PLAYERS,
	tag      = "BUBBLE_MAX_PLAYERS",
	onChange = function(value)
		SETTINGS.BUBBLE_MAX_PLAYERS = math.floor(value)
	end,
})

-- Áp mode ngay khi load
task.spawn(function()
	task.wait(0.5)
	applyChatMode(SETTINGS.CHAT_MODE)
end)

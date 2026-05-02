--[[
    ChatClient.lua  (LocalScript)
    ═══════════════════════════════════════════════════════════════════
    Đặt trong StarterPlayerScripts

    Cách dùng từ LocalScript khác:
        local ChatClient = require(game.StarterPlayerScripts.ChatClient)

        ChatClient:CreateFriendChat()
        ChatClient:DM(123456789)
        ChatClient:CreateChannel({ Type = "player", Name = "Squad", Members = { 111, 222 } })
        ChatClient:SetActiveChannel("pchat_abc12345")
]]

local Players          = game:GetService("Players")
local TextChatService  = game:GetService("TextChatService")
local ReplicatedStorage= game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- ════════════════════════════════════════════════════════════════════
--  WAIT FOR REMOTES
-- ════════════════════════════════════════════════════════════════════
local ChattedEvent     = ReplicatedStorage:WaitForChild("ChattedEvent")
local ChatChannelEvent = ReplicatedStorage:WaitForChild("ChatChannelEvent")
local ChatRemotes      = ReplicatedStorage:WaitForChild("ChatRemotes")

local RF_CreateChannel = ChatRemotes:WaitForChild("CreateChannel")
local RF_DeleteChannel = ChatRemotes:WaitForChild("DeleteChannel")
local RF_AddMember     = ChatRemotes:WaitForChild("AddMember")
local RF_RemoveMember  = ChatRemotes:WaitForChild("RemoveMember")
local RF_GetChannels   = ChatRemotes:WaitForChild("GetChannels")
local RF_ToggleFriend  = ChatRemotes:WaitForChild("ToggleFriend")



local FriendCache = {}  -- [userId] = true nếu là bạn bè
local PreviousMsg = {}

-- ════════════════════════════════════════════════════════════════════
--  WAIT FOR DEFAULT TEXT CHANNELS
--  TextChannel được tạo ở server cần thời gian replicate sang client
--  Phải WaitForChild trước khi dùng
-- ════════════════════════════════════════════════════════════════════
local TextChannels = TextChatService:WaitForChild("TextChannels")

-- Danh sách channel mặc định cần chờ
local DEFAULT_CHANNEL_NAMES = { "Global", "Server", "Team", "Staff", "Friend" }

-- Chờ tất cả default channels replicate xong
local DefaultTextChannels = {}
for _, name in ipairs(DEFAULT_CHANNEL_NAMES) do
	task.spawn(function()
		local ch = TextChannels:WaitForChild(name, 10)
		if ch then
			DefaultTextChannels[name] = ch
			print("[ChatClient] ✅ Channel ready:", name)
		else
			warn("[ChatClient] ❌ Channel not found:", name)
		end
	end)
end

-- Thay thế đoạn load FriendCache hiện tại:
task.spawn(function()
	local ok, pages = pcall(Players.GetFriendsAsync, Players, LocalPlayer.UserId)
	if not ok then
		warn("[ChatClient] ❌ GetFriendsAsync failed!")
		return
	end
	while true do
		for _, info in ipairs(pages:GetCurrentPage()) do
			FriendCache[info.Id] = true
			warn("[ChatClient] 👥 Friend cached:", info.Username, "| Id:", info.Id)
		end
		if pages.IsFinished then break end
		pcall(function() pages:AdvanceToNextPageAsync() end)
	end
	local count = 0
	for _ in pairs(FriendCache) do count += 1 end
	warn("[ChatClient] ✅ FriendCache xong —", count, "bạn bè")
end)

-- Thêm vào sau phần DefaultTextChannels load xong
task.spawn(function()
	task.wait(3)  -- đợi channel replicate
	local friendCh = TextChannels:WaitForChild("Friend", 10)
	if friendCh then
		warn("[ChatClient] Friend channel exists:", friendCh.Name)
		-- Kiểm tra player có trong channel không
		local textSource = friendCh:FindFirstChild(tostring(LocalPlayer.UserId))
			or friendCh:FindFirstChild(LocalPlayer.Name)
		warn("[ChatClient] Player in Friend channel:", textSource and "YES" or "NO")
	else
		warn("[ChatClient] ❌ Friend channel NOT found!")
	end
end)

-- ════════════════════════════════════════════════════════════════════
--  STATE
-- ════════════════════════════════════════════════════════════════════
local ActiveChannelId = "Global"
local KnownChannels   = {}

-- ════════════════════════════════════════════════════════════════════
--  HELPERS
-- ════════════════════════════════════════════════════════════════════

local function IsKnownChannel(channelName)
	if table.find(DEFAULT_CHANNEL_NAMES, channelName) then 
		warn("[Chat] isKnown: default →", channelName)
		return true 
	end
	if KnownChannels[channelName] then 
		warn("[Chat] isKnown: KnownChannels →", channelName)
		return true 
	end
	local ch = TextChannels:FindFirstChild(channelName)
	if ch and ch:FindFirstChild("ChatData") then 
		warn("[Chat] isKnown: ChatData →", channelName)
		return true 
	end
	warn("[Chat] ❌ NOT known:", channelName)
	return false
end

local function UpdateChannelDataFolder()
	local dataFolder = LocalPlayer:FindFirstChild("ChatChannels")
	if not dataFolder then
		dataFolder = Instance.new("Folder")
		dataFolder.Name = "ChatChannels"
		dataFolder.Parent = LocalPlayer
	end

	for _, child in pairs(dataFolder:GetChildren()) do
		if not KnownChannels[child.Name] then
			child:Destroy()
		end
	end

	for id, ch in pairs(KnownChannels) do
		local chFolder = dataFolder:FindFirstChild(id)
		if not chFolder then
			chFolder = Instance.new("Folder")
			chFolder.Name = id
			chFolder.Parent = dataFolder
		end

		local idVal = chFolder:FindFirstChild("Id") or Instance.new("StringValue", chFolder)
		idVal.Name  = "Id"
		idVal.Value = id

		local nameVal = chFolder:FindFirstChild("DisplayName") or Instance.new("StringValue", chFolder)
		nameVal.Name  = "DisplayName"
		nameVal.Value = ch.DisplayName or id  -- ✅ tên đã đúng từ server

		local typeVal = chFolder:FindFirstChild("Type") or Instance.new("StringValue", chFolder)
		typeVal.Name  = "Type"
		typeVal.Value = ch.Type or "unknown"

		local isDefaultVal = chFolder:FindFirstChild("IsDefault") or Instance.new("BoolValue", chFolder)
		isDefaultVal.Name  = "IsDefault"
		isDefaultVal.Value = ch.IsDefault or false

		local ownerVal = chFolder:FindFirstChild("OwnerId") or Instance.new("NumberValue", chFolder)
		ownerVal.Name  = "OwnerId"
		ownerVal.Value = ch.OwnerId or 0
	end
end

local function FindChannelById(channelId)

	print("🔎 [FindChannelById] Tìm:", channelId)

	for _, ch in pairs(TextChannels:GetChildren()) do
		if ch:IsA("TextChannel") then

			print("   ↳ Checking channel:", ch.Name)

			-- Check Attribute
			local attrId = ch:GetAttribute("ChannelId")
			if attrId then
				print("      Attribute ChannelId =", attrId)
				if attrId == channelId then
					print("      ✅ MATCH via Attribute")
					return ch
				end
			end

			-- Check ChatData
			local chatData = ch:FindFirstChild("ChatData")
			if chatData then
				local idVal = chatData:FindFirstChild("Id")
				if idVal then
					print("      ChatData.Id =", idVal.Value)
					if idVal.Value == channelId then
						print("      ✅ MATCH via ChatData")
						return ch
					end
				end
			end
		end
	end

	print("❌ [FindChannelById] Không tìm thấy:", channelId)
	return nil
end

local function GetDisplayChannel(channelId, channelType)
	local ch

	if channelType == "private" or channelType == "group" then
		-- Tìm qua ChatData
		ch = FindChannelById(channelId)
	else
		-- Default channels → tìm thẳng tên
		ch = TextChannels:FindFirstChild(channelId)
	end

	-- Fallback
	return ch
		or TextChannels:FindFirstChild("Global")
		or TextChannels:FindFirstChildWhichIsA("TextChannel")
end

local function DisplayMessage(channelId, text, channelType)
	local channel = GetDisplayChannel(channelId, channelType)
	if channel then
		local ok, err = pcall(function()
			channel:DisplaySystemMessage(text)
		end)
		if not ok then
			warn("[ChatClient] ❌ DisplaySystemMessage failed:", err)
		end
	else
		warn("[ChatClient] ❌ Không tìm thấy channel:", channelId)
	end
end

-- Load danh sách channel từ server
local function RefreshChannels()
	local ok, channels = pcall(function()
		return RF_GetChannels:InvokeServer()
	end)
	if not ok or type(channels) ~= "table" then return end

	KnownChannels = {}
	for _, ch in ipairs(channels) do
		KnownChannels[ch.Id] = ch
	end

	UpdateChannelDataFolder()  -- ✅ thêm dòng này

	print("[ChatClient] Channels loaded:", #channels)
end

-- ════════════════════════════════════════════════════════════════════
--  LOAD CHANNELS KHI VÀO GAME
-- ════════════════════════════════════════════════════════════════════
task.spawn(RefreshChannels)

-- ════════════════════════════════════════════════════════════════════
--  NHẬN TIN TỪ SERVER
-- ════════════════════════════════════════════════════════════════════

ChatChannelEvent.OnClientEvent:Connect(function(action, channelId, displayName)
	if action == "rename" then
		warn("[ChatClient] Rename →", channelId, "=", displayName)

		-- ✅ Cập nhật KnownChannels
		if KnownChannels[channelId] then
			KnownChannels[channelId].DisplayName = displayName
		else
			-- Channel mới chưa có trong KnownChannels → thêm vào
			KnownChannels[channelId] = { Id = channelId, DisplayName = displayName }
		end

		-- ✅ Cập nhật folder data
		local dataFolder = LocalPlayer:FindFirstChild("ChatChannels")
		if not dataFolder then
			dataFolder = Instance.new("Folder")
			dataFolder.Name = "ChatChannels"
			dataFolder.Parent = LocalPlayer
		end

		local chFolder = dataFolder:FindFirstChild(channelId)
		if not chFolder then
			chFolder = Instance.new("Folder")
			chFolder.Name = channelId
			chFolder.Parent = dataFolder

			local idVal = Instance.new("StringValue", chFolder)
			idVal.Name  = "Id"
			idVal.Value = channelId
		end

		local nameVal = chFolder:FindFirstChild("DisplayName") or Instance.new("StringValue", chFolder)
		nameVal.Name  = "DisplayName"
		nameVal.Value = displayName
	end
end)

ChattedEvent.OnClientEvent:Connect(function(channelId, text, senderIdOrType, channelType)

	-- Chuẩn hóa tham số
	local realType = channelType or senderIdOrType
	local senderId = nil
	if realType == "friend" then
		senderId = senderIdOrType
	end

	-- Lọc Friend channel
	if realType == "friend" and senderId then
		if senderId ~= LocalPlayer.UserId then
			if not FriendCache[senderId] then return end
		end
	end

	if type(channelId) ~= "string" then
		channelId = ActiveChannelId
	end

	-- Nếu private/group chưa có TextChannel → refresh rồi hiện vào Global tạm
	if (realType == "private" or realType == "group") and not FindChannelById(channelId) then
		task.spawn(RefreshChannels)
		DisplayMessage("Global", text, "global")
		return
	end

	DisplayMessage(channelId, text, realType)
end)

-- ════════════════════════════════════════════════════════════════════
--  INTERCEPT TIN NHẮN PLAYER GÕ
--  Suppress hiển thị mặc định của Roblox → gửi lên server → server
--  format lại → FireClient xuống → DisplayMessage
-- ════════════════════════════════════════════════════════════════════
TextChatService.OnIncomingMessage = function(message)
	local props = Instance.new("TextChatMessageProperties")
	if not message.TextSource then return props end

	local senderId = message.TextSource.UserId
	local textChannel = message.TextChannel
	if not textChannel then return props end

	-- 🔎 Lấy ChannelId thật
	local channelId = textChannel:GetAttribute("ChannelId")

	if not channelId then
		local chatData = textChannel:FindFirstChild("ChatData")
		if chatData then
			local idVal = chatData:FindFirstChild("Id")
			if idVal then
				channelId = idVal.Value
			end
		end
	end

	-- Fallback cho default channels
	channelId = channelId or textChannel.Name

	if not IsKnownChannel(textChannel.Name) then return props end

	props.Text = " "

	if senderId ~= LocalPlayer.UserId then return props end
	if PreviousMsg[senderId] == message.Text then return props end
	PreviousMsg[senderId] = message.Text

	task.spawn(function()
		print("📤 Gửi lên server bằng ID:", channelId)
		ChattedEvent:FireServer("Chatted", channelId, message.Text)
	end)

	task.delay(1, function()
		if PreviousMsg[senderId] == message.Text then
			PreviousMsg[senderId] = nil
		end
	end)

	return props
end

-- ════════════════════════════════════════════════════════════════════
--  PUBLIC API
-- ════════════════════════════════════════════════════════════════════
local ChatClient = {}

-- Đổi channel đang active (tin nhắn sẽ hiện vào đây)
function ChatClient:SetActiveChannel(channelId)
	if KnownChannels[channelId]
		or table.find(DEFAULT_CHANNEL_NAMES, channelId) then
		ActiveChannelId = channelId
		print("[ChatClient] Active channel →", channelId)
		return true
	end
	warn("[ChatClient] SetActiveChannel: channel không tồn tại:", channelId)
	return false
end


function ChatClient:GetActiveChannel()
	return ActiveChannelId
end

function ChatClient:GetChannels()
	return KnownChannels
end

function ChatClient:Refresh()
	RefreshChannels()
end

-- Tạo channel mới
-- params: { Type, Name?, Members?, TargetUserId? }
function ChatClient:CreateChannel(params)
	local ok, success, channelId = pcall(RF_CreateChannel.InvokeServer, RF_CreateChannel, params)
	if not ok then
		warn("[ChatClient] CreateChannel error:", success)
		return false, success
	end

	if success then
		RefreshChannels()
		if type(channelId) == "string" then
			task.wait(0.5)
			ActiveChannelId = channelId
		end
		return true, channelId
	else
		warn("[ChatClient] CreateChannel failed:", channelId)
		return false, channelId
	end
end

function ChatClient:DeleteChannel(channelId)
	local ok, reason = RF_DeleteChannel:InvokeServer(channelId)
	if ok then RefreshChannels() end
	return ok, reason
end

function ChatClient:AddMember(channelId, targetUserId)
	return RF_AddMember:InvokeServer(channelId, targetUserId)
end

function ChatClient:RemoveMember(channelId, targetUserId)
	return RF_RemoveMember:InvokeServer(channelId, targetUserId)
end

-- Tạo Friend Channel nhanh
function ChatClient:CreateFriendChat()
	return self:CreateChannel({ Type = "friend" })
end

-- DM 1-1 nhanh
function ChatClient:DM(targetUserId)
	return self:CreateChannel({ Type = "private", TargetUserId = targetUserId })
end

-- Switch về Global
function ChatClient:SwitchToGlobal()
	ActiveChannelId = "Global"
end

-- Bật/tắt Friend Chat
function ChatClient:SetFriendEnabled(enabled)
	local ok, result = pcall(RF_ToggleFriend.InvokeServer, RF_ToggleFriend, enabled)
	return ok and result
end

-- Tạo Group Chat
function ChatClient:CreateGroup(name, memberUserIds)
	return self:CreateChannel({ Type = "group", Name = name, Members = memberUserIds })
end

-- DM 1-1
function ChatClient:CreatePrivate(targetUserId)
	return self:CreateChannel({ Type = "private", TargetUserId = targetUserId })
end

return ChatClient

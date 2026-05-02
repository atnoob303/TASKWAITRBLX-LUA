--[[
    ChatServer.lua  (Script)
    ═══════════════════════════════════════════════════════════════════
    Đặt trong ServerScriptService

    Structure:
    ServerScriptService
    └── ChatServer
        ├── ChatConfig      ← ModuleScript
        ├── ChannelManager  ← ModuleScript
        ├── Filter          ← ModuleScript
        └── Commands        ← ModuleScript

    ReplicatedStorage (tự tạo)
    ├── ChattedEvent        ← RemoteEvent
    ├── ChatChannelEvent    ← RemoteEvent
    └── ChatRemotes         ← Folder
        ├── CreateChannel   ← RemoteFunction
        ├── DeleteChannel   ← RemoteFunction
        ├── AddMember       ← RemoteFunction
        ├── RemoveMember    ← RemoteFunction
        ├── GetChannels     ← RemoteFunction
        └── ToggleFriend    ← RemoteFunction
]]

-- ── Services ─────────────────────────────────────────────────────
local Players             = game:GetService("Players")
local HttpService         = game:GetService("HttpService")
local TextService         = game:GetService("TextService")
local DataStoreService    = game:GetService("DataStoreService")
local TextChatService     = game:GetService("TextChatService")
local MessagingService    = game:GetService("MessagingService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local LocalizationService = game:GetService("LocalizationService")

-- ════════════════════════════════════════════════════════════════════
--  REMOTES
-- ════════════════════════════════════════════════════════════════════

local ChattedEvent = Instance.new("RemoteEvent")
ChattedEvent.Name  = "ChattedEvent"
ChattedEvent.Parent= ReplicatedStorage

local ChatChannelEvent = Instance.new("RemoteEvent")
ChatChannelEvent.Name  = "ChatChannelEvent"
ChatChannelEvent.Parent= ReplicatedStorage

local ChatRemotes = Instance.new("Folder")
ChatRemotes.Name  = "ChatRemotes"
ChatRemotes.Parent= ReplicatedStorage

local function MakeRF(name)
	local rf = Instance.new("RemoteFunction")
	rf.Name  = name
	rf.Parent= ChatRemotes
	return rf
end

local RF_CreateChannel = MakeRF("CreateChannel")
local RF_DeleteChannel = MakeRF("DeleteChannel")
local RF_AddMember     = MakeRF("AddMember")
local RF_RemoveMember  = MakeRF("RemoveMember")
local RF_GetChannels   = MakeRF("GetChannels")
local RF_ToggleFriend  = MakeRF("ToggleFriend")  -- bật/tắt friend chat

-- ── Modules ──────────────────────────────────────────────────────
local Config         = require(script.ChatConfig)
local ChannelManager = require(script.ChannelManager)
local Filter         = require(script.Filter)
local Commands       = require(script.Commands)

-- ── DataStores ───────────────────────────────────────────────────
local BanDataStore = DataStoreService:GetDataStore(Config.DataStores.Ban)
local MuteStore    = DataStoreService:GetDataStore(Config.DataStores.Mute)

-- ── Cooldown & Dedup ─────────────────────────────────────────────
local PlayerCooldown = {}
local RecentMessages = {}

-- ── Setup TextChatService ────────────────────────────────────────
TextChatService.ChannelTabsConfiguration.Enabled = true

-- ════════════════════════════════════════════════════════════════════
--  PLAYER ADDED  (đặt trước các tạo Remote để chạy ngay)
-- ════════════════════════════════════════════════════════════════════

local function IsModOrOwner(player)
	local rank = player:GetRankInGroup(Config.GroupId)
	return rank >= Config.Ranks.Moderator.Rank
		or table.find(Config.Ranks.Moderator.Players, player.UserId) ~= nil
		or rank >= Config.Ranks.Owner.Rank
		or table.find(Config.Ranks.Owner.Players, player.UserId) ~= nil
end

-- Backup: kiểm tra lại sau 3 giây, ném thẳng vào nếu chưa vào được
local function EnsureInDefaultChannels(player)
	if not player or not player.Parent then return end
	local textChannels = TextChatService:FindFirstChild("TextChannels")
	if not textChannels then return end

	local rank    = player:GetRankInGroup(Config.GroupId)
	local isMod   = IsModOrOwner(player)
	local isOwner = rank >= Config.Ranks.Owner.Rank
		or table.find(Config.Ranks.Owner.Players, player.UserId) ~= nil

	for _, cfg in ipairs(Config.DefaultChannels) do
		if not cfg.Enabled then continue end
		local vis    = cfg.Visible
		local canSee = (vis == "all") or (vis == "mod" and isMod) or (vis == "owner" and isOwner)
		if not canSee then continue end

		local ch = textChannels:FindFirstChild(cfg.Name)
		if ch and not ch:FindFirstChild(player.Name) then
			warn("[ChatServer] ⚠ Force-add", player.Name, "→", cfg.Name)
			pcall(function() ch:AddUserAsync(player.UserId) end)
		end
	end
end

local function NotifyFriendsOnline(player)
	-- Lấy tên place hiện tại
	local placeName = game.Name or "Unknown"
	local placeId   = game.PlaceId

	local notifyMsg = string.format(
		'<font color="rgb(100,255,180)">👥 %s đã online • %s</font>',
		"@" .. player.Name,
		placeName
	)

	-- Gửi cho bạn bè đang online CÙNG SERVER này
	for _, p in pairs(Players:GetPlayers()) do
		if p ~= player
			and ChannelManager:GetFriendEnabled(p.UserId)
			and ChannelManager:IsFriend(p.UserId, player.UserId) then
			ChattedEvent:FireClient(p, "Friend", notifyMsg)
		end
	end

	-- Gửi cross-server cho bạn bè ở server khác
	local friendList = ChannelManager:GetFriendList(player.UserId)
	for friendId, _ in pairs(friendList) do
		local friendTopic = Config.Topics.Friend .. friendId
		pcall(MessagingService.PublishAsync, MessagingService, friendTopic,
			HttpService:JSONEncode({
				__type           = "friend_online",  -- phân biệt với tin nhắn thường
				FormattedMessage = notifyMsg,
				Sender           = player.Name,
				SenderId         = player.UserId,
				PlaceName        = placeName,
				PlaceId          = placeId,
				__serverId       = game.JobId,
			})
		)
	end
end

Players.PlayerAdded:Connect(function(player)
	local okBan, banData = pcall(BanDataStore.GetAsync, BanDataStore, tostring(player.UserId))
	if okBan and banData and banData.Banned then
		player:Kick("🚫 Banned: " .. (banData.Reason or "Vi phạm quy tắc"))
		return
	end

	task.spawn(function()
		ChannelManager:OnPlayerAdded(player)
		task.wait(3)
		EnsureInDefaultChannels(player)
	end)

	task.spawn(function()
		-- Đợi cache xong
		local waited = 0
		while not ChannelManager:IsCacheReady(player.UserId) and waited < 10 do
			task.wait(0.5)
			waited += 0.5
		end
		if not player or not player.Parent then return end

		-- Subscribe friend topic
		local myTopic = Config.Topics.Friend .. player.UserId
		pcall(function()
			MessagingService:SubscribeAsync(myTopic, function(message)
				local ok, data = pcall(HttpService.JSONDecode, HttpService, message.Data)
				if not ok then return end
				if data.__serverId == game.JobId then return end
				if not ChannelManager:GetFriendEnabled(player.UserId) then return end
				if not ChannelManager:IsFriend(player.UserId, data.SenderId) then return end
				ChattedEvent:FireClient(player, "Friend", data.FormattedMessage)
			end)
		end)

		-- ✅ Thông báo cho bạn bè biết mình vào server
		NotifyFriendsOnline(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	-- OnPlayerRemoving tự gọi OnOwnerLeft → xóa channel + notify members
	ChannelManager:OnPlayerRemoving(player)
	PlayerCooldown[player.UserId] = nil
	RecentMessages[player.UserId] = nil
end)

-- ── Initialize ───────────────────────────────────────────────────
ChannelManager:InitDefaultChannels()
ChannelManager:InitNotifySubscriber()

-- ════════════════════════════════════════════════════════════════════
--  HELPER: Format
-- ════════════════════════════════════════════════════════════════════

local function GetPlayerNameColor(player)
	local seed = tonumber(string.sub(tostring(player.UserId), -4)) or 1234
	local r = (seed * 2531011  + 214013)   % 206 + 50
	local g = (seed * 6364136  + 1442695)  % 206 + 50
	local b = (seed * 1103515245 + 12345)  % 206 + 50
	return string.format("rgb(%d,%d,%d)", r, g, b)
end



local function GetFlag(player)
	local ok, code = pcall(LocalizationService.GetCountryRegionForPlayerAsync, LocalizationService, player)
	if not ok or not code or #code < 2 then return "🌐" end
	local f = string.byte(string.upper(string.sub(code,1,1))) - 0x41 + 0x1F1E6
	local s = string.byte(string.upper(string.sub(code,2,2))) - 0x41 + 0x1F1E6
	return utf8.char(f) .. utf8.char(s)
end

local function GetRankTags(player, rank)
	local tags = ""
	if rank >= Config.Ranks.Owner.Rank or table.find(Config.Ranks.Owner.Players, player.UserId) then
		tags = "🔨 "
	elseif rank >= Config.Ranks.Moderator.Rank or table.find(Config.Ranks.Moderator.Players, player.UserId) then
		tags = "🛡 "
	elseif rank >= Config.Ranks.Tester.Rank or table.find(Config.Ranks.Tester.Players, player.UserId) then
		tags = "🧪 "
	end
	return tags
end

local function BuildFormattedMessage(player, text, meta, isSelf)
	local nameColor = GetPlayerNameColor(player)
	local rank      = player:GetRankInGroup(Config.GroupId)
	local prefix    = ""

	if meta.ShowFlag  then prefix = GetFlag(player) .. " " end
	if meta.ShowRankTag then prefix = prefix .. GetRankTags(player, rank) end

	local displayName = prefix .. "@" .. player.Name
	if isSelf then
		displayName = '<font color="rgb(255,255,255)">[You]</font> ' .. displayName
	end

	return string.format(
		'<font color="%s">%s:</font> <font color="rgb(255,255,255)">%s</font>',
		nameColor, displayName, text
	)
end

-- ════════════════════════════════════════════════════════════════════
--  CORE: Xử lý tin nhắn
-- ════════════════════════════════════════════════════════════════════

local function HandleSendMessage(player, channelId, rawText)
	local uid = player.UserId

	-- Dedup
	if RecentMessages[uid] == rawText then return end
	RecentMessages[uid] = rawText

	-- Cooldown
	if PlayerCooldown[uid] then return end
	PlayerCooldown[uid] = true
	task.delay(Config.MessageCooldown, function()
		PlayerCooldown[uid] = false
		RecentMessages[uid] = nil
	end)

	-- Lấy channel
	local ch = ChannelManager:GetChannel(channelId)
	if not ch then return end
	local meta = ch.Meta

	-- Kiểm tra quyền chat
	local canChat = meta.CanChat
	if canChat ~= "all" then
		local rank  = player:GetRankInGroup(Config.GroupId)
		local isMod = IsModOrOwner(player)
		if canChat == "mod" and not isMod then return end
		if type(canChat) == "table" and not table.find(canChat, uid) then return end
	end

	local rank = player:GetRankInGroup(Config.GroupId)

	-- Check command
	local Filtered = false
	if IsModOrOwner(player) then
		if Commands:CheckCommand(player, rawText, Config) then
			Filtered = true
		end
	end

	-- Kiểm tra mute
	if not Filtered then
		local ok, muteRecord = pcall(MuteStore.GetAsync, MuteStore, tostring(uid))
		if ok and muteRecord and muteRecord.Muted then
			ChattedEvent:FireClient(player, "Global",
				string.format('<font color="rgb(250,100,100)">🔇 Muted: %s</font>', muteRecord.Reason)
			)
			Filtered = true
		end
	end

	-- Roblox text filter
	local filteredText = rawText
	if not Filtered then
		local ok1, filterObj = pcall(TextService.FilterStringAsync, TextService, rawText, uid, Enum.TextFilterContext.PublicChat)
		if not ok1 then warn("[ChatSystem] FilterStringAsync failed:", player.Name) return end
		local ok2, result = pcall(filterObj.GetNonChatStringForBroadcastAsync, filterObj)
		if not ok2 then warn("[ChatSystem] GetNonChatString failed") return end
		filteredText = result
	end

	-- Custom filters
	if not Filtered then
		if Filter:CountEmojis(filteredText) then
			ChattedEvent:FireClient(player, channelId, '<font color="rgb(250,100,100)">' .. Filter.Responses.EmojiCap .. '</font>')
			Filtered = true
		elseif Filter:CheckSameCharacterLimit(filteredText) then
			ChattedEvent:FireClient(player, channelId, '<font color="rgb(250,100,100)">' .. Filter.Responses.SameChracter .. '</font>')
			Filtered = true
		elseif Filter:IsFiltered(filteredText) then
			ChattedEvent:FireClient(player, channelId, '<font color="rgb(250,100,100)">' .. Filter.Responses.Filtered .. '</font>')
			Filtered = true
		end
	end

	if Filtered then return end

	-- Giới hạn độ dài
	if #filteredText > Config.MaxMessageLength then
		filteredText = string.sub(filteredText, 1, Config.MaxMessageLength) .. "..."
	end

	-- ════════════════════════════════════════════════════════════════
	--  DISPATCH
	-- ════════════════════════════════════════════════════════════════
	local channelType = meta.Type
	local formatted   = BuildFormattedMessage(player, filteredText, meta, false)

	-- ── GLOBAL ───────────────────────────────────────────────────
	if channelType == "global" then
		local tag = '<font color="rgb(100,200,255)">[Global]</font> '
		ChattedEvent:FireClient(player, channelId, tag .. BuildFormattedMessage(player, filteredText, meta, true), "global")
		pcall(MessagingService.PublishAsync, MessagingService, Config.Topics.Global,
			HttpService:JSONEncode({
				ChannelId        = channelId,
				ChannelType      = "global",
				FormattedMessage = tag .. formatted,
				Sender           = player.Name,
				__serverId       = game.JobId,
			})
		)

		-- ── STAFF ────────────────────────────────────────────────────
	elseif channelType == "staff" then
		local tag = '<font color="rgb(255,120,120)">[Staff]</font> '
		for _, p in pairs(Players:GetPlayers()) do
			if IsModOrOwner(p) then
				ChattedEvent:FireClient(p, channelId, tag .. BuildFormattedMessage(player, filteredText, meta, p == player), "staff")
			end
		end
		pcall(MessagingService.PublishAsync, MessagingService, Config.Topics.Staff,
			HttpService:JSONEncode({
				ChannelId        = channelId,
				ChannelType      = "staff",
				FormattedMessage = tag .. formatted,
				Sender           = player.Name,
				__serverId       = game.JobId,
			})
		)

		-- ── SERVER ───────────────────────────────────────────────────
	elseif channelType == "server" then
		local tag = string.format('<font color="%s">[%s]</font> ', meta.Color, meta.DisplayName or "Server")
		for _, p in pairs(Players:GetPlayers()) do
			local vis = meta.Visible
			local canSee = (vis == "all") or (vis == "mod" and IsModOrOwner(p))
			if canSee then
				ChattedEvent:FireClient(p, channelId, tag .. BuildFormattedMessage(player, filteredText, meta, p == player), "server")
			end
		end

		-- ── TEAM ─────────────────────────────────────────────────────
	elseif channelType == "team" then
		local tag = '<font color="rgb(255,220,100)">[Team]</font> '
		local myTeam = player.Team
		for _, p in pairs(Players:GetPlayers()) do
			if p.Team == myTeam then
				ChattedEvent:FireClient(p, channelId, tag .. BuildFormattedMessage(player, filteredText, meta, p == player), "team")
			end
		end

		-- ── FRIEND ───────────────────────────────────────────────────
	elseif channelType == "friend" then
		local tag = '<font color="rgb(255,180,255)">[Friends]</font> '
		local senderId = player.UserId
		ChattedEvent:FireClient(player, channelId, tag .. BuildFormattedMessage(player, filteredText, meta, true), senderId, "friend")
		for _, p in pairs(Players:GetPlayers()) do
			if p ~= player then
				ChattedEvent:FireClient(p, channelId, tag .. formatted, senderId, "friend")
			end
		end
		pcall(MessagingService.PublishAsync, MessagingService, Config.Topics.Friend,
			HttpService:JSONEncode({
				ChannelId        = channelId,
				ChannelType      = "friend",
				FormattedMessage = tag .. formatted,
				Sender           = player.Name,
				SenderId         = senderId,
				__serverId       = game.JobId,
			})
		)

		-- ── PRIVATE & GROUP ──────────────────────────────────────────
	elseif channelType == "private" or channelType == "group" then
		local tag = string.format('<font color="%s">[%s]</font> ',
			meta.Color or "rgb(200,200,255)", meta.DisplayName or channelId)
		for _, p in pairs(Players:GetPlayers()) do
			if table.find(meta.Members or {}, p.UserId) then
				ChattedEvent:FireClient(p, channelId, tag .. BuildFormattedMessage(player, filteredText, meta, p == player), channelType)
			end
		end
		if meta.Topic then
			pcall(MessagingService.PublishAsync, MessagingService, meta.Topic,
				HttpService:JSONEncode({
					ChannelId        = channelId,
					ChannelType      = channelType,
					FormattedMessage = tag .. formatted,
					Sender           = player.Name,
					__serverId       = game.JobId,
				})
			)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════
--  MESSAGING SERVICE SUBSCRIBERS
-- ════════════════════════════════════════════════════════════════════

-- Global cross-server
pcall(function()
	MessagingService:SubscribeAsync(Config.Topics.Global, function(message)
		local ok, data = pcall(HttpService.JSONDecode, HttpService, message.Data)
		if not ok then return end
		--if data.__serverId == game.JobId then return end 
		for _, player in pairs(Players:GetPlayers()) do
			if player.Name ~= data.Sender then
				ChattedEvent:FireClient(player, data.ChannelId or "Global", data.FormattedMessage, data.ChannelType or "global")
			end
		end
	end)
end)

-- Staff cross-server
pcall(function()
	MessagingService:SubscribeAsync(Config.Topics.Staff, function(message)
		local ok, data = pcall(HttpService.JSONDecode, HttpService, message.Data)
		if not ok then return end
		if data.__serverId == game.JobId then return end
		for _, player in pairs(Players:GetPlayers()) do
			if player.Name ~= data.Sender and IsModOrOwner(player) then
				ChattedEvent:FireClient(player, data.ChannelId or "Staff", data.FormattedMessage, data.ChannelType or "staff")
			end
		end
	end)
end)

-- Friend cross-server: mỗi player subscribe topic của bạn bè khi join
-- (Được handle trong OnPlayerAdded bên dưới)
-- Friend cross-server subscriber
pcall(function()
	MessagingService:SubscribeAsync(Config.Topics.Friend, function(message)
		local ok, data = pcall(HttpService.JSONDecode, HttpService, message.Data)
		if not ok then return end
		if data.__serverId == game.JobId then return end
		for _, player in pairs(Players:GetPlayers()) do
			if player.Name ~= data.Sender then
				ChattedEvent:FireClient(player, data.ChannelId or "Friend", data.FormattedMessage, data.SenderId, data.ChannelType or "friend")
			end
		end
	end)
end)

-- Ban cross-server
pcall(function()
	MessagingService:SubscribeAsync(Config.Topics.Ban, function(message)
		local ok, data = pcall(HttpService.JSONDecode, HttpService, message.Data)
		if not ok then return end
		for _, player in pairs(Players:GetPlayers()) do
			if player.Name == data.Target then
				player:Kick("🚫 Bị ban: " .. (data.Reason or "Vi phạm quy tắc"))
			elseif player.Name ~= data.Sender then
				if data.Announcement and #data.Announcement > 0 then
					ChattedEvent:FireClient(player, "Global", data.Announcement)
				end
			end
		end
	end)
end)

-- ════════════════════════════════════════════════════════════════════
--  SUBSCRIBE FRIEND TOPICS KHI PLAYER JOIN
--  Mỗi player cần subscribe topic bạn bè của mình để nhận tin
-- ════════════════════════════════════════════════════════════════════

-- RIP

-- ════════════════════════════════════════════════════════════════════
--  REMOTE EVENT: Nhận tin từ client
-- ════════════════════════════════════════════════════════════════════

ChattedEvent.OnServerEvent:Connect(function(player, event, channelId, text)
	if event == "Chatted" then
		if type(channelId) ~= "string" or type(text) ~= "string" then return end
		if #text == 0 or #text > 2000 then return end
		HandleSendMessage(player, channelId, text)
	end
end)

-- ════════════════════════════════════════════════════════════════════
--  REMOTE FUNCTIONS
-- ════════════════════════════════════════════════════════════════════

RF_GetChannels.OnServerInvoke = function(player)
	return ChannelManager:GetVisibleChannels(player)
end

RF_ToggleFriend.OnServerInvoke = function(player, enabled)
	ChannelManager:SetFriendEnabled(player, enabled == true)
	return true, enabled
end

RF_CreateChannel.OnServerInvoke = function(player, params)
	if type(params) ~= "table" then return false, "Tham số không hợp lệ" end
	local t = params.Type

	if t == "private" then
		if type(params.TargetUserId) ~= "number" then return false, "TargetUserId không hợp lệ" end
		return ChannelManager:CreatePrivateChannel(player, params.TargetUserId)

	elseif t == "group" then
		local members = params.Members or {}
		if type(members) ~= "table" then return false, "Members không hợp lệ" end
		for _, v in ipairs(members) do
			if type(v) ~= "number" then return false, "UserId phải là số" end
		end
		return ChannelManager:CreateGroupChannel(player, params.Name, members)

	else
		return false, "Loại channel không hợp lệ: " .. tostring(t)
	end
end

RF_DeleteChannel.OnServerInvoke = function(player, channelId)
	if type(channelId) ~= "string" then return false, "ChannelId không hợp lệ" end
	return ChannelManager:DeleteChannel(player, channelId)
end

RF_AddMember.OnServerInvoke = function(player, channelId, targetUserId)
	if type(channelId) ~= "string" then return false, "ChannelId không hợp lệ" end
	if type(targetUserId) ~= "number" then return false, "UserId không hợp lệ" end
	return ChannelManager:AddMember(player, channelId, targetUserId)
end

RF_RemoveMember.OnServerInvoke = function(player, channelId, targetUserId)
	if type(channelId) ~= "string" then return false, "ChannelId không hợp lệ" end
	if type(targetUserId) ~= "number" then return false, "UserId không hợp lệ" end
	return ChannelManager:RemoveMember(player, channelId, targetUserId)
end

-- ════════════════════════════════════════════════════════════════════
--  PLAYER ADDED EXTENSION: Subscribe friend topics
-- ════════════════════════════════════════════════════════════════════

-- RIP 2

print("[ChatSystem] ✅ Chat system loaded!")
print("[ChatSystem] Default channels:", #Config.DefaultChannels)
print("[ChatSystem] Channel types: Global, Staff(cross), Server, Team, Friend(toggle), Private(1-1), Group")

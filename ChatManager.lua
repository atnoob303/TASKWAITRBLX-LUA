--[[
    ChannelManager.lua  (ModuleScript)
]]

local Players          = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService      = game:GetService("HttpService")
local TextChatService  = game:GetService("TextChatService")
local MessagingService = game:GetService("MessagingService")

local Config = require(script.Parent.ChatConfig)

local ChannelManager   = {}
ChannelManager.__index = ChannelManager

local PlayerChannelStore = DataStoreService:GetDataStore(Config.DataStores.PlayerChannels)
local FriendEnabledStore = DataStoreService:GetDataStore(Config.DataStores.FriendEnabled)

-- Runtime
local Channels      = {}  -- [channelId] = { Meta, TextChannel }
local FriendEnabled = {}  -- [userId] = bool
local SubscribedTopics = {}  -- thêm ở đầu file, sau "local FriendEnabled = {}"
local FriendCacheReady = {}  -- thêm ở đầu file cùng chỗ với FriendCache
local FriendCache = {}  -- [userId] = { [friendId] = true }

-- ════════════════════════════════════════════════════════════════════
--  INTERNAL HELPERS
-- ════════════════════════════════════════════════════════════════════

local function CreateChannelDataFolder(channelId, meta)
	local folder = Instance.new("Folder")
	folder.Name = "ChatData"

	local function addStr(name, val)
		local v = Instance.new("StringValue")
		v.Name = name
		v.Value = tostring(val or "")
		v.Parent = folder
	end

	local function addNum(name, val)
		local v = Instance.new("NumberValue")
		v.Name = name
		v.Value = tonumber(val) or 0
		v.Parent = folder
	end

	local function addBool(name, val)
		local v = Instance.new("BoolValue")
		v.Name = name
		v.Value = val == true
		v.Parent = folder
	end

	-- ✅ Bắt buộc
	addStr("Id",          channelId)
	addStr("DisplayName", meta.DisplayName)
	addStr("Type",        meta.Type)
	addStr("Color",       meta.Color)
	addStr("Topic",       meta.Topic)
	addStr("Members",     HttpService:JSONEncode(meta.Members or {}))
	addNum("OwnerId",     meta.OwnerId)
	addStr("Name",        meta.DisplayName or channelId)
	addNum("CreatedAt",   meta.CreatedAt)  -- ✅ thời gian tạo
	addBool("IsDefault",  meta.IsDefault)

	-- ✅ Chỉ có ở private
	if meta.DisplayNameForTarget then
		addStr("NameForTarget",        meta.DisplayNameForTarget)  -- ✅ tên target thấy
		addStr("DisplayNameForTarget", meta.DisplayNameForTarget)
	end

	return folder
end

local function CacheFriends(player)
	local uid = player.UserId
	FriendCache[uid] = {}
	FriendCacheReady[uid] = false  -- bắt đầu

	local ok, pages = pcall(Players.GetFriendsAsync, Players, uid)
	if not ok then
		warn("[Chat] ❌ GetFriendsAsync failed for", player.Name)
		FriendCacheReady[uid] = true  -- ✅ vẫn phải set true để không bị kẹt
		return
	end

	while true do
		local currentPage = pages:GetCurrentPage()
		for _, info in ipairs(currentPage) do
			FriendCache[uid][info.Id] = true
		end
		if pages.IsFinished then break end
		local okNext, err = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not okNext then
			warn("[Chat] ❌ AdvanceToNextPage failed:", err)
			break
		end
	end

	FriendCacheReady[uid] = true  -- ✅ THÊM DÒNG NÀY
	warn("[Chat] ✅ Cache ready:", player.Name)
	
	--[[       MỞ KHI MUỐN XEM DANH SÁCH BẠN BÈ
	✅ In danh sách bạn bè ra Output
	local friendNames = {}
	for friendId, _ in pairs(FriendCache[uid]) do
		local okName, name = pcall(Players.GetNameFromUserIdAsync, Players, friendId)
		if okName and name then
			table.insert(friendNames, name .. " (" .. friendId .. ")")
		else
			table.insert(friendNames, "Unknown (" .. friendId .. ")")
		end
	end

	if #friendNames == 0 then
		warn("[Chat] 👥 " .. player.Name .. " không có bạn bè nào")
	else
		warn("[Chat] 👥 Danh sách bạn bè của " .. player.Name .. " (" .. #friendNames .. " người):")
		for i, name in ipairs(friendNames) do
			warn("[Chat]   " .. i .. ". " .. name)
		end
	end ]]
	
end

local function IsFriend(userId, targetId)
	local cache = FriendCache[userId]
	if not cache then return false end
	return cache[targetId] == true
end

local function GetTextChannels()
	return TextChatService:WaitForChild("TextChannels")
end

local function CreateTextChannel(name, displayName, channelId)
	local existing = GetTextChannels():FindFirstChild(name)
	if existing then
		if displayName then
			existing:SetAttribute("DisplayName", displayName)
		end
		return existing
	end
	local ch = Instance.new("TextChannel")
	ch.Name  = name
	
	if displayName then
		ch:SetAttribute("DisplayName", displayName)
	end
	ch:SetAttribute("Id",channelId)
	ch.Parent = GetTextChannels()
	return ch
end

local function RemoveTextChannel(name)
	local ch = GetTextChannels():FindFirstChild(name)
	if ch then ch:Destroy() end
end

local function GenerateId()
	return HttpService:GenerateGUID(false):sub(1, 8):lower()
end

local function IsModOrOwner(player)
	local rank = player:GetRankInGroup(Config.GroupId)
	return rank >= Config.Ranks.Moderator.Rank
		or table.find(Config.Ranks.Moderator.Players, player.UserId) ~= nil
		or rank >= Config.Ranks.Owner.Rank
		or table.find(Config.Ranks.Owner.Players, player.UserId) ~= nil
end

local function AddUserSafe(textChannel, player)
	task.spawn(function()
		for attempt = 1, 5 do
			if not player or not player.Parent then return end
			local ok, err = pcall(function()
				textChannel:AddUserAsync(player.UserId)
			end)
			if ok then
				print(string.format("[Chat] ✅ %s → [%s]", player.Name, textChannel.Name))
				return
			end
			task.wait(0.5 * attempt)
		end
		warn(string.format("[Chat] ❌ Cannot add %s to %s", player.Name, textChannel.Name))
	end)
end

local function NotifyChannelName(player, channelId, displayName)
	local event = game.ReplicatedStorage:FindFirstChild("ChatChannelEvent")
	if event then
		event:FireClient(player, "rename", channelId, displayName)
	end
end

-- ════════════════════════════════════════════════════════════════════
--  CROSS-SERVER: Subscribe topic của group/private
--  Nhận tin → forward đến members online ở server này
-- ════════════════════════════════════════════════════════════════════

local function SubscribeGroupTopic(channelId, topic, members)
	-- ✅ Tránh subscribe cùng topic nhiều lần
	if SubscribedTopics[topic] then return end
	SubscribedTopics[topic] = true

	pcall(function()
		MessagingService:SubscribeAsync(topic, function(msg)
			local ok, data = pcall(HttpService.JSONDecode, HttpService, msg.Data)
			if not ok then return end

			-- Lệnh xóa channel
			if data.__action == "delete" then
				local ch = Channels[data.ChannelId]
				if ch then
					RemoveTextChannel(data.ChannelId)
					Channels[data.ChannelId] = nil
				end
				local event = game.ReplicatedStorage:FindFirstChild("ChattedEvent")
				if event then
					for _, p in pairs(Players:GetPlayers()) do
						if table.find(members, p.UserId) then
							event:FireClient(p, data.ChannelId, data.Message or "")
						end
					end
				end
				return
			end

			-- ✅ Skip nếu tin đến từ chính server này (tránh duplicate)
			if data.__serverId == game.JobId then return end

			-- Forward cho tất cả members online (không filter sender nữa)
			local event = game.ReplicatedStorage:FindFirstChild("ChattedEvent")
			if not event then return end
			for _, p in pairs(Players:GetPlayers()) do
				if table.find(members, p.UserId) then
					event:FireClient(p, channelId, data.FormattedMessage)
				end
			end
		end)
	end)
end

-- Notify server khác tạo channel cho member
local function NotifyMemberCrossServer(channelId, topic, targetUserId, meta)
	pcall(MessagingService.PublishAsync, MessagingService,
		Config.Topics.Notify,
		HttpService:JSONEncode({
			Action       = "add",
			ChannelId    = channelId,
			Topic        = topic,
			TargetUserId = targetUserId,
			Meta = {
				DisplayName = meta.DisplayName,
				DisplayNameForTarget = meta.DisplayNameForTarget,
				Type        = meta.Type,
				Color       = meta.Color,
				Members     = meta.Members,
				OwnerId     = meta.OwnerId,
			},
		})
	)
end

-- ════════════════════════════════════════════════════════════════════
--  DATASTORE: Lưu/load channels của player
-- ════════════════════════════════════════════════════════════════════

local function SavePlayerChannels(userId)
	local data = {}
	for id, ch in pairs(Channels) do
		if not ch.Meta.IsDefault then
			local isOwner  = ch.Meta.OwnerId == userId
			local isMember = table.find(ch.Meta.Members or {}, userId) ~= nil
			if isOwner or isMember then
				table.insert(data, {
					Id                   = id,
					Name                 = ch.Meta.Name,
					DisplayName          = ch.Meta.DisplayName,
					DisplayNameForTarget = ch.Meta.DisplayNameForTarget,
					Type                 = ch.Meta.Type,
					Color                = ch.Meta.Color,
					Members              = ch.Meta.Members,
					OwnerId              = ch.Meta.OwnerId,
					Topic                = ch.Meta.Topic,
					CreatedAt            = ch.Meta.CreatedAt,
				})
			end
		end
	end
	pcall(PlayerChannelStore.SetAsync, PlayerChannelStore, tostring(userId), data)
end

local function LoadAndRestoreChannels(player)
	local ok, data = pcall(PlayerChannelStore.GetAsync, PlayerChannelStore, tostring(player.UserId))
	if not ok or not data then return end

	for _, saved in ipairs(data) do
		local channelId = saved.Id
		local topic     = saved.Topic
		local members   = saved.Members or {}

		if not Channels[channelId] then
			local ch = CreateTextChannel(saved.Name, saved.DisplayName, channelId)  -- ✅ truyền displayName
			Channels[channelId] = {
				Meta = {
					Id                   = channelId,
					Name                 = saved.Name,
					DisplayName          = saved.DisplayName or "Chat",
					DisplayNameForTarget = saved.DisplayNameForTarget,
					Type                 = saved.Type or "group",
					Color                = saved.Color or "rgb(200,200,255)",
					Visible              = members,
					CanChat              = members,
					IsDefault            = false,
					OwnerId              = saved.OwnerId or player.UserId,
					Members              = members,
					Topic                = topic,
					ShowFlag             = false,
					ShowRankTag          = false,
					CreatedAt            = saved.CreatedAt or os.time(),
				},
				TextChannel = ch,
			}

			local dataFolder = CreateChannelDataFolder(channelId, Channels[channelId].Meta)
			dataFolder.Parent = ch

			if topic then
				SubscribeGroupTopic(channelId, topic, members)
			end
			print(string.format("[Chat] Restored channel %s for %s", channelId, player.Name))
		end

		local ch = Channels[channelId]
		if ch then
			AddUserSafe(ch.TextChannel, player)
			if ch.Meta.Type == "private" then
				if ch.Meta.OwnerId == player.UserId then
					NotifyChannelName(player, channelId, ch.Meta.DisplayName)
				else
					NotifyChannelName(player, channelId, ch.Meta.DisplayNameForTarget or ch.Meta.DisplayName)
				end
			elseif ch.Meta.Type == "group" then
				NotifyChannelName(player, channelId, ch.Meta.DisplayName)
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════
--  DEFAULT CHANNELS
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:InitDefaultChannels()
	for _, cfg in ipairs(Config.DefaultChannels) do
		if cfg.Enabled then
			local ch = CreateTextChannel(cfg.Name,cfg.DisplayName,cfg.Id)
			Channels[cfg.Name] = {
				Meta = {
					Id          = cfg.Id,
					Name        = cfg.Name,
					DisplayName = cfg.DisplayName,
					Type        = cfg.Type,
					Color       = cfg.Color,
					ShowFlag    = cfg.ShowFlag,
					ShowRankTag = cfg.ShowRankTag,
					Visible     = cfg.Visible,
					CanChat     = cfg.CanChat,
					IsDefault   = true,
					OwnerId     = nil,
					Members     = {},
					Topic       = nil,
				},
				TextChannel = ch,
			}
			print("[Chat] Default channel:", cfg.Name)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════
--  PRIVATE CHAT (1-1, cross-server, hoạt động như Global)
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:CreatePrivateChannel(player, targetUserId)
	local ids = { player.UserId, targetUserId }
	table.sort(ids)
	local topic = Config.Topics.Private .. ids[1] .. "_" .. ids[2]

	-- ✅ Lấy tên target trước
	local targetName = "[Unknown]"
	local okName, name = pcall(Players.GetNameFromUserIdAsync, Players, targetUserId)
	if okName and name then targetName = name end

	-- ✅ ID mới: PlayerA_PlayerB_a3f9
	local suffix = GenerateId()
	local channelId = player.Name .. "_" .. targetName .. "_" .. suffix

	if Channels[channelId] then
		return true, channelId
	end

	local members = { player.UserId, targetUserId }
	local createdAt = os.time()  -- ✅ thời gian tạo

	local ch = CreateTextChannel(channelId,"🔒 " .. targetName,channelId)

	Channels[channelId] = {
		Meta = {
			Id                   = channelId,
			Name                 = channelId,
			DisplayName          = "🔒 " .. targetName,
			DisplayNameForTarget = "🔒 " .. player.Name,
			Type                 = "private",
			Color                = "rgb(255,255,180)",
			Visible              = members,
			CanChat              = members,
			IsDefault            = false,
			OwnerId              = player.UserId,
			Members              = members,
			Topic                = topic,
			ShowFlag             = false,
			ShowRankTag          = false,
			CreatedAt            = createdAt,  -- ✅ lưu trong Meta
		},
		TextChannel = ch,
	}

	-- ✅ Tạo folder data trong TextChannel
	local dataFolder = CreateChannelDataFolder(channelId, Channels[channelId].Meta)
	dataFolder.Parent = ch

	for _, p in pairs(Players:GetPlayers()) do
		if table.find(members, p.UserId) then
			AddUserSafe(ch, p)
			if p.UserId == player.UserId then
				NotifyChannelName(p, channelId, "🔒 " .. targetName)
			else
				NotifyChannelName(p, channelId, "🔒 " .. player.Name)
			end
		end
	end

	SubscribeGroupTopic(channelId, topic, members)

	if not Players:GetPlayerByUserId(targetUserId) then
		NotifyMemberCrossServer(channelId, topic, targetUserId, Channels[channelId].Meta)
	end

	SavePlayerChannels(player.UserId)
	SavePlayerChannels(targetUserId)

	print("[Chat] Private channel created:", channelId)
	return true, channelId
end
-- ════════════════════════════════════════════════════════════════════
--  GROUP CHAT (cross-server, hoạt động như Global)
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:CreateGroupChannel(player, channelName, memberUserIds)
	local count = 0
	for _, ch in pairs(Channels) do
		if ch.Meta.OwnerId == player.UserId then count += 1 end
	end
	if count >= Config.MaxChannelsPerPlayer then
		return false, "Đã đạt giới hạn " .. Config.MaxChannelsPerPlayer .. " channel"
	end

	if not table.find(memberUserIds, player.UserId) then
		table.insert(memberUserIds, player.UserId)
	end

	-- ✅ ID mới: Squad_170312_a3f9
	local name      = channelName or "Group"
	local timeStr = tostring(os.time()):sub(-6)  -- 6 số cuối timestamp
	local suffix  = GenerateId()
	local channelId = (channelName or "Group") .. "_" .. timeStr .. "_" .. suffix
	local topic     = Config.Topics.Group .. channelId
	local createdAt = os.time()  -- ✅ thời gian tạo

	local ch = CreateTextChannel(name,"💬 " .. (channelName or "Group"),channelId)

	Channels[channelId] = {
		Meta = {
			Id          = channelId,
			Name        = name,
			DisplayName = "💬 " .. (channelName or "Group"),
			Type        = "group",
			Color       = "rgb(200,200,255)",
			Visible     = memberUserIds,
			CanChat     = memberUserIds,
			IsDefault   = false,
			OwnerId     = player.UserId,
			Members     = memberUserIds,
			Topic       = topic,
			ShowFlag    = false,
			ShowRankTag = false,
			CreatedAt   = createdAt,  -- ✅ lưu trong Meta
		},
		TextChannel = ch,
	}

	-- ✅ Tạo folder data trong TextChannel
	local dataFolder = CreateChannelDataFolder(channelId, Channels[channelId].Meta)
	dataFolder.Parent = ch

	for _, p in pairs(Players:GetPlayers()) do
		if table.find(memberUserIds, p.UserId) then
			AddUserSafe(ch, p)
		end
	end

	SubscribeGroupTopic(channelId, topic, memberUserIds)

	for _, uid in ipairs(memberUserIds) do
		if uid ~= player.UserId and not Players:GetPlayerByUserId(uid) then
			NotifyMemberCrossServer(channelId, topic, uid, Channels[channelId].Meta)
		end
	end

	SavePlayerChannels(player.UserId)
	for _, uid in ipairs(memberUserIds) do
		if uid ~= player.UserId then
			task.spawn(function()  -- ✅ không blocking
				SavePlayerChannels(uid)
			end)
		end
	end

	print("[Chat] Group channel created:", channelId)
	return true, channelId
end

-- ════════════════════════════════════════════════════════════════════
--  DELETE CHANNEL
--  Gửi signal thẳng đến tất cả members qua topic → xóa ngay lập tức
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:DeleteChannel(player, channelId)
	local ch = Channels[channelId]
	if not ch then return false, "Channel không tồn tại" end
	if ch.Meta.IsDefault then return false, "Không thể xóa channel mặc định" end
	if ch.Meta.OwnerId ~= player.UserId and not IsModOrOwner(player) then
		return false, "Không có quyền xóa"
	end

	local members = ch.Meta.Members or {}
	local topic   = ch.Meta.Topic
	local displayName = ch.Meta.DisplayName

	-- Xóa local
	RemoveTextChannel(channelId)
	Channels[channelId] = nil

	-- Gửi signal xóa cross-server đến tất cả members
	if topic then
		local deleteMsg = string.format(
			'<font color="rgb(255,100,100)">🗑 %s đã bị xóa.</font>',
			displayName
		)
		pcall(MessagingService.PublishAsync, MessagingService, topic,
			HttpService:JSONEncode({
				__action  = "delete",
				ChannelId = channelId,
				Message   = deleteMsg,
			})
		)
	end

	-- Thông báo cho members đang online ở server này
	local event = game.ReplicatedStorage:FindFirstChild("ChattedEvent")
	if event then
		local deleteMsg = string.format(
			'<font color="rgb(255,100,100)">🗑 %s đã bị xóa.</font>',
			displayName
		)
		for _, p in pairs(Players:GetPlayers()) do
			if table.find(members, p.UserId) then
				event:FireClient(p, channelId, deleteMsg)
			end
		end
	end

	-- ✅ FIX: Save DataStore cho tất cả members (không chỉ owner)
	for _, uid in ipairs(members) do
		SavePlayerChannels(uid)
	end

	print("[Chat] Channel deleted:", channelId)
	return true
end

-- ════════════════════════════════════════════════════════════════════
--  OWNER THOÁT → TỰ XÓA CHANNEL
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:OnOwnerLeft(player)
	local toDelete = {}
	for channelId, ch in pairs(Channels) do
		if ch.Meta.OwnerId == player.UserId and not ch.Meta.IsDefault then
			table.insert(toDelete, channelId)
		end
	end
	for _, channelId in ipairs(toDelete) do
		self:DeleteChannel(player, channelId)
	end
end

-- ════════════════════════════════════════════════════════════════════
--  ADD / REMOVE MEMBER
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:AddMember(requesterPlayer, channelId, targetUserId)
	local ch = Channels[channelId]
	if not ch then return false, "Channel không tồn tại" end
	if ch.Meta.IsDefault then return false, "Không thể thêm vào channel mặc định" end
	if ch.Meta.OwnerId ~= requesterPlayer.UserId and not IsModOrOwner(requesterPlayer) then
		return false, "Không có quyền thêm thành viên"
	end
	if table.find(ch.Meta.Members, targetUserId) then
		return false, "Người này đã trong channel"
	end

	table.insert(ch.Meta.Members, targetUserId)
	if type(ch.Meta.Visible) == "table" then table.insert(ch.Meta.Visible, targetUserId) end
	if type(ch.Meta.CanChat) == "table" then table.insert(ch.Meta.CanChat, targetUserId) end

	local target = Players:GetPlayerByUserId(targetUserId)
	if target then
		AddUserSafe(ch.TextChannel, target)
	else
		NotifyMemberCrossServer(channelId, ch.Meta.Topic, targetUserId, ch.Meta)
	end

	SavePlayerChannels(requesterPlayer.UserId)
	SavePlayerChannels(targetUserId)

	return true
end

function ChannelManager:RemoveMember(requesterPlayer, channelId, targetUserId)
	local ch = Channels[channelId]
	if not ch then return false, "Channel không tồn tại" end
	if ch.Meta.OwnerId ~= requesterPlayer.UserId and not IsModOrOwner(requesterPlayer) then
		return false, "Không có quyền kick"
	end

	local idx = table.find(ch.Meta.Members, targetUserId)
	if not idx then return false, "Người này không trong channel" end
	table.remove(ch.Meta.Members, idx)

	if type(ch.Meta.Visible) == "table" then
		local i = table.find(ch.Meta.Visible, targetUserId)
		if i then table.remove(ch.Meta.Visible, i) end
	end
	if type(ch.Meta.CanChat) == "table" then
		local i = table.find(ch.Meta.CanChat, targetUserId)
		if i then table.remove(ch.Meta.CanChat, i) end
	end

	return true
end

-- ════════════════════════════════════════════════════════════════════
--  FRIEND TOGGLE
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:GetFriendEnabled(userId)
	if FriendEnabled[userId] ~= nil then return FriendEnabled[userId] end
	local ok, val = pcall(FriendEnabledStore.GetAsync, FriendEnabledStore, tostring(userId))
	FriendEnabled[userId] = (ok and val == true)
	return FriendEnabled[userId]
end

function ChannelManager:SetFriendEnabled(player, enabled)
	FriendEnabled[player.UserId] = enabled
	pcall(FriendEnabledStore.SetAsync, FriendEnabledStore, tostring(player.UserId), enabled)
	return true
end

-- ════════════════════════════════════════════════════════════════════
--  PLAYER ADDED / REMOVING
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:OnPlayerAdded(player)
	local isMod   = IsModOrOwner(player)
	local rank    = player:GetRankInGroup(Config.GroupId)
	local isOwner = rank >= Config.Ranks.Owner.Rank
		or table.find(Config.Ranks.Owner.Players, player.UserId) ~= nil

	-- Add vào default channels
	for id, ch in pairs(Channels) do
		if ch.Meta.IsDefault then
			local vis    = ch.Meta.Visible
			local canSee = (vis == "all")
				or (vis == "mod"   and (isMod or isOwner))
				or (vis == "owner" and isOwner)
			if canSee then AddUserSafe(ch.TextChannel, player) end
		else
			if ch.Meta.Members and table.find(ch.Meta.Members, player.UserId) then
				AddUserSafe(ch.TextChannel, player)
			end
		end
	end

	task.spawn(function()
		FriendEnabled[player.UserId] = self:GetFriendEnabled(player.UserId)

		-- ✅ Cache friends TRƯỚC, đợi xong mới load channels
		CacheFriends(player)
		warn("[Chat] Friend cache ready for", player.Name, 
			"— total:", (function()
				local c = 0
				for _ in pairs(FriendCache[player.UserId] or {}) do c += 1 end
				return c
			end)()
		)

		LoadAndRestoreChannels(player)
	end)
end

function ChannelManager:OnPlayerRemoving(player)
	FriendEnabled[player.UserId] = nil
	FriendCache[player.UserId] = nil
	FriendCacheReady[player.UserId] = nil  -- ✅ thêm dòng này
end

-- ════════════════════════════════════════════════════════════════════
--  NOTIFY SUBSCRIBER (cross-server add member)
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:InitNotifySubscriber()
	pcall(function()
		MessagingService:SubscribeAsync(Config.Topics.Notify, function(msg)
			local ok, data = pcall(HttpService.JSONDecode, HttpService, msg.Data)
			if not ok or data.Action ~= "add" then return end

			local target = Players:GetPlayerByUserId(data.TargetUserId)
			if not target then return end

			local channelId = data.ChannelId
			local topic     = data.Topic
			local meta      = data.Meta or {}
			local members   = meta.Members or {}

			-- Tạo channel trên server này nếu chưa có
			if not Channels[channelId] then
				local ch = CreateTextChannel(channelId)
				Channels[channelId] = {
					Meta = {
						Id          = channelId,
						Name        = channelId,
						DisplayName = meta.DisplayName or "Chat",
						DisplayNameForTarget = meta.DisplayNameForTarget,
						Type        = meta.Type or "group",
						Color       = meta.Color or "rgb(200,200,255)",
						Visible     = members,
						CanChat     = members,
						IsDefault   = false,
						OwnerId     = meta.OwnerId,
						Members     = members,
						Topic       = topic,
						ShowFlag    = false,
						ShowRankTag = false,
					},
					TextChannel = ch,
				}
				-- Subscribe topic để nhận tin
				SubscribeGroupTopic(channelId, topic, members)
			end

			local ch = Channels[channelId]
			if ch then
				AddUserSafe(ch.TextChannel, target)

				-- ✅ Gửi tên đúng cho target
				if ch.Meta.Type == "private" then
					NotifyChannelName(target, channelId, ch.Meta.DisplayNameForTarget or ch.Meta.DisplayName)
				else
					NotifyChannelName(target, channelId, ch.Meta.DisplayName)
				end

				-- Thông báo cho target
				local event = game.ReplicatedStorage:FindFirstChild("ChattedEvent")
				if event then
					local notifyMsg = string.format(
						'<font color="%s">📩 Bạn đã được thêm vào %s</font>',
						meta.Color or "rgb(200,200,255)",
						meta.DisplayName or "một đoạn chat"
					)
					event:FireClient(target, channelId, notifyMsg)
				end
			end
		end)
	end)
end

-- ════════════════════════════════════════════════════════════════════
--  GET CHANNEL / GET VISIBLE
-- ════════════════════════════════════════════════════════════════════

function ChannelManager:GetChannel(channelId)
	return Channels[channelId]
end

function ChannelManager:GetVisibleChannels(player)
	local isMod   = IsModOrOwner(player)
	local rank    = player:GetRankInGroup(Config.GroupId)
	local isOwner = rank >= Config.Ranks.Owner.Rank
		or table.find(Config.Ranks.Owner.Players, player.UserId) ~= nil

	local result = {}
	for id, ch in pairs(Channels) do
		local vis    = ch.Meta.Visible
		local canSee = (vis == "all")
			or (vis == "mod"   and (isMod or isOwner))
			or (vis == "owner" and isOwner)
			or (type(vis) == "table" and table.find(vis, player.UserId) ~= nil)
		if canSee then
			-- ✅ Tên hiển thị đúng theo từng người
			local displayName = ch.Meta.DisplayName
			if ch.Meta.Type == "private" and ch.Meta.OwnerId ~= player.UserId then
				displayName = ch.Meta.DisplayNameForTarget or ch.Meta.DisplayName
			end

			table.insert(result, {
				Id          = id,
				Name        = ch.Meta.Name,
				DisplayName = displayName,  -- ✅ tên đúng
				Type        = ch.Meta.Type,
				Color       = ch.Meta.Color,
				IsDefault   = ch.Meta.IsDefault,
				OwnerId     = ch.Meta.OwnerId,
				Members     = ch.Meta.Members,
			})
		end
	end
	return result
end

function ChannelManager:IsFriend(userId, targetId)
	return IsFriend(userId, targetId)
end
function ChannelManager:IsCacheReady(userId)
	return FriendCacheReady[userId] == true
end

function ChannelManager:GetFriendList(userId)
	return FriendCache[userId] or {}
end

return ChannelManager

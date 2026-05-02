--[[
    ╔══════════════════════════════════════════════════════════════════╗
    ║                    CHAT SYSTEM CONFIGURATION                     ║
    ╚══════════════════════════════════════════════════════════════════╝

    CHANNEL TYPES:
    ─────────────────────────────────────────────────────────────────
    "global"  → Cross-server, tất cả mọi người
    "staff"   → Cross-server, chỉ mod/owner
    "server"  → Local, chỉ trong server hiện tại
    "team"    → Local, cùng Roblox Team
    "friend"  → Cross-server toggle bật/tắt, nhận tin từ bạn bè
    "private" → Cross-server 1-1 giữa 2 người cố định
    "group"   → Cross-server cho nhóm người cụ thể
]]

local ChatConfig = {}

-- ════════════════════════════════════════════════════════════════════
--  GLOBAL SETTINGS
-- ════════════════════════════════════════════════════════════════════
ChatConfig.GroupId = 35962039

ChatConfig.Ranks = {
	Tester    = { Rank = 2,   Players = {} },
	Moderator = { Rank = 3,   Players = {} },
	Owner     = { Rank = 255, Players = {} },
}

ChatConfig.MaxChannelsPerPlayer = 5
ChatConfig.MessageCooldown      = 1
ChatConfig.MaxMessageLength     = 200

-- ════════════════════════════════════════════════════════════════════
--  DEFAULT CHANNELS
-- ════════════════════════════════════════════════════════════════════
ChatConfig.DefaultChannels = {

	{
		Name        = "Global",
		DisplayName = "🌐 Global",
		Type        = "global",
		Enabled     = true,
		Visible     = "all",
		CanChat     = "all",
		Color       = "rgb(100,200,255)",
		ShowFlag    = true,
		ShowRankTag = true,
	},
	{
		Name        = "Server",
		DisplayName = "🖥 Server",
		Type        = "server",
		Enabled     = true,
		Visible     = "all",
		CanChat     = "all",
		Color       = "rgb(180,255,180)",
		ShowFlag    = false,
		ShowRankTag = true,
	},
	{
		Name        = "Team",
		DisplayName = "👥 Team",
		Type        = "team",
		Enabled     = true,
		Visible     = "all",
		CanChat     = "all",
		Color       = "rgb(255,220,100)",
		ShowFlag    = false,
		ShowRankTag = false,
	},
	-- Staff giờ là cross-server (type = "staff")
	{
		Name        = "Staff",
		DisplayName = "🛡 Staff",
		Type        = "staff",
		Enabled     = true,
		Visible     = "mod",
		CanChat     = "mod",
		Color       = "rgb(255,120,120)",
		ShowFlag    = false,
		ShowRankTag = true,
	},
	-- Friend: tab riêng, player toggle bật/tắt
	{
		Name        = "Friend",
		DisplayName = "👫 Friends",
		Type        = "friend",
		Enabled     = true,
		Visible     = "all",
		CanChat     = "all",
		Color       = "rgb(255,180,255)",
		ShowFlag    = false,
		ShowRankTag = false,
	},
}

-- ════════════════════════════════════════════════════════════════════
--  MESSAGING SERVICE TOPICS
-- ════════════════════════════════════════════════════════════════════
ChatConfig.Topics = {
	Global  = "Chat_Global",
	Staff   = "Chat_Staff",
	Friend  = "Chat_Friend_",   -- + senderId
	Private = "Chat_Priv_",     -- + sorted(id1,id2)
	Group   = "Chat_Group_",    -- + channelId
	Notify  = "Chat_Notify",    -- add thành viên cross-server
	Ban     = "Chat_Ban",
}

-- ════════════════════════════════════════════════════════════════════
--  DATASTORE NAMES
-- ════════════════════════════════════════════════════════════════════
ChatConfig.DataStores = {
	Ban           = "GlobalChatBan",
	Mute          = "GlobalChatMute",
	PlayerChannels= "PlayerChatChannels_v2",
	FriendEnabled = "ChatFriendEnabled_v1",
}

return ChatConfig

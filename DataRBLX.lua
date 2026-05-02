-- ServerDataManager (Script trong ServerScriptService)
-- Quản lý: cross-server data, global data, server session, conflict resolution
-- Yêu cầu: DataManager đã chạy trước

local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService   = game:GetService("MessagingService")
local DataStoreService   = game:GetService("DataStoreService")
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

-- ════════════════════════════════════════════
--              SERVICES & STORES
-- ════════════════════════════════════════════

-- MemoryStore (cross-server, tự xóa theo TTL)
local MemoryLive     = MemoryStoreService:GetSortedMap("LiveData")
local MemoryGlobal   = MemoryStoreService:GetSortedMap("GlobalData")
local MemorySession  = MemoryStoreService:GetSortedMap("SessionRegistry")

-- DataStore (lưu vĩnh viễn)
local EventLogStore  = DataStoreService:GetDataStore("ServerEventLog_v1")
local GlobalStore    = DataStoreService:GetDataStore("GlobalPersist_v1")

-- Server identity
local SERVER_ID      = game.JobId ~= "" and game.JobId or "STUDIO_" .. tostring(math.random(10000))
local SERVER_START   = os.time()
local SERVER_PLACE   = tostring(game.PlaceId)

-- Remotes
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	or Instance.new("Folder", ReplicatedStorage)
Remotes.Name = "Remotes"

local function makeRemote(name, isFunc)
	local r = Remotes:FindFirstChild(name)
	if r then return r end
	r = Instance.new(isFunc and "RemoteFunction" or "RemoteEvent")
	r.Name = name
	r.Parent = Remotes
	return r
end

local RF_GetGlobal      = makeRemote("GetGlobal", true)
local RF_GetLive        = makeRemote("GetLive", true)
local RF_GetServerInfo  = makeRemote("GetServerInfo", true)
local RE_AdminMessage   = makeRemote("AdminMessage", false)

-- ════════════════════════════════════════════
--           SESSION DATA (trong phiên)
-- ════════════════════════════════════════════
-- Data tồn tại trong phiên server — xóa khi server đóng
-- Event log — ghi lại sự việc, lưu khi server đóng

local SessionData = {}
SessionData._data   = {}   -- data chia sẻ trong server này
SessionData._events = {}   -- event log của server này
SessionData._playerList = {} -- danh sách player đã vào server này

-- Set/Get session data (không lưu ra ngoài)
function SessionData:Set(key, value)
	self._data[key] = {
		value   = value,
		updated = os.time(),
	}
end

function SessionData:Get(key)
	local entry = self._data[key]
	return entry and entry.value or nil
end

function SessionData:GetAll()
	return self._data
end

-- Ghi sự việc vào event log
function SessionData:Log(eventType, data)
	table.insert(self._events, {
		type      = eventType,
		data      = data,
		time      = os.time(),
		serverId  = SERVER_ID,
	})
end

-- Ghi nhận player vào/ra
function SessionData:RegisterPlayer(player, isJoining)
	local uid = tostring(player.UserId)
	if isJoining then
		self._playerList[uid] = {
			name    = player.Name,
			userId  = player.UserId,
			joined  = os.time(),
		}
		self:Log("PLAYER_JOIN", { name = player.Name, userId = player.UserId })
	else
		if self._playerList[uid] then
			self._playerList[uid].left = os.time()
		end
		self:Log("PLAYER_LEAVE", { name = player.Name, userId = player.UserId })
	end
end

-- Lưu event log khi server đóng
function SessionData:SaveEventLog()
	if #self._events == 0 then return end
	local key = "EventLog_" .. SERVER_ID .. "_" .. tostring(SERVER_START)
	local ok, err = pcall(function()
		EventLogStore:SetAsync(key, {
			serverId    = SERVER_ID,
			placeId     = SERVER_PLACE,
			startTime   = SERVER_START,
			endTime     = os.time(),
			playerList  = self._playerList,
			events      = self._events,
		})
	end)
	if ok then
		print("ServerDataManager: Event log saved — " .. #self._events .. " events")
	else
		warn("ServerDataManager: Event log save failed — " .. tostring(err))
	end
end

-- ════════════════════════════════════════════
--           LIVE DATA (cross-server, TTL)
-- ════════════════════════════════════════════
-- Data tồn tại ngắn hạn — tự xóa sau TTL giây
-- Dùng cho: boss HP, event đang diễn ra, countdown

local LiveData = {}

function LiveData:Set(key, value, ttl)
	ttl = ttl or 300 -- mặc định 5 phút
	local ok, err = pcall(function()
		MemoryLive:SetAsync(key, {
			value     = value,
			setBy     = SERVER_ID,
			setAt     = os.time(),
		}, ttl)
	end)
	if not ok then
		warn("LiveData:Set failed — " .. tostring(err))
	end
end

function LiveData:Get(key)
	local ok, result = pcall(function()
		return MemoryLive:GetAsync(key)
	end)
	if ok and result then
		return result.value, result.setAt
	end
	return nil, nil
end

function LiveData:Delete(key)
	pcall(function()
		MemoryLive:RemoveAsync(key)
	end)
end

-- Update an toàn (tránh race condition)
function LiveData:Update(key, updateFn, ttl)
	ttl = ttl or 300
	pcall(function()
		MemoryLive:UpdateAsync(key, function(old)
			local current = old and old.value or nil
			local newVal = updateFn(current)
			if newVal == nil then return nil end
			return {
				value = newVal,
				setBy = SERVER_ID,
				setAt = os.time(),
			}
		end, ttl)
	end)
end

-- ════════════════════════════════════════════
--         GLOBAL DATA (toàn bộ server)
-- ════════════════════════════════════════════
-- Data chia sẻ và đồng bộ qua tất cả server
-- Các loại: number, value, adminMessage, shopPrice, eventState

local GlobalData = {}
GlobalData._cache = {} -- Cache local để giảm request

-- Các loại global data được phép
local GLOBAL_TYPES = {
	number       = true,
	value        = true,
	adminMessage = true,
	shopPrice    = true,
	eventState   = true,
}

function GlobalData:Set(dataType, key, value)
	if not GLOBAL_TYPES[dataType] then
		warn("GlobalData: Type không hợp lệ — " .. tostring(dataType))
		return false
	end

	local fullKey = dataType .. "_" .. key

	-- Lưu vào MemoryStore (realtime)
	local ok = pcall(function()
		MemoryGlobal:SetAsync(fullKey, {
			value    = value,
			type     = dataType,
			setBy    = SERVER_ID,
			setAt    = os.time(),
		}, 86400) -- TTL 24h
	end)

	-- Lưu vào DataStore (vĩnh viễn) cho một số loại
	if dataType == "shopPrice" or dataType == "eventState" then
		pcall(function()
			GlobalStore:SetAsync(fullKey, {
				value = value,
				setAt = os.time(),
			})
		end)
	end

	-- Cache local
	self._cache[fullKey] = { value = value, time = os.time() }

	-- Broadcast qua MessagingService
	pcall(function()
		MessagingService:PublishAsync("GlobalUpdate", {
			type    = dataType,
			key     = key,
			value   = value,
			setBy   = SERVER_ID,
		})
	end)

	return ok
end

function GlobalData:Get(dataType, key)
	local fullKey = dataType .. "_" .. key

	-- Dùng cache nếu còn mới (dưới 5 giây)
	local cached = self._cache[fullKey]
	if cached and (os.time() - cached.time) < 5 then
		return cached.value
	end

	-- Lấy từ MemoryStore
	local ok, result = pcall(function()
		return MemoryGlobal:GetAsync(fullKey)
	end)

	if ok and result then
		self._cache[fullKey] = { value = result.value, time = os.time() }
		return result.value
	end

	-- Fallback về DataStore
	local ok2, stored = pcall(function()
		return GlobalStore:GetAsync(fullKey)
	end)
	if ok2 and stored then
		return stored.value
	end

	return nil
end

-- Increment global number an toàn
function GlobalData:Increment(key, amount)
	local fullKey = "number_" .. key
	pcall(function()
		MemoryGlobal:UpdateAsync(fullKey, function(old)
			local current = old and old.value or 0
			return {
				value = current + amount,
				type  = "number",
				setBy = SERVER_ID,
				setAt = os.time(),
			}
		end, 86400)
	end)
	-- Broadcast
	pcall(function()
		MessagingService:PublishAsync("GlobalUpdate", {
			type   = "number",
			key    = key,
			amount = amount,
			op     = "increment",
			setBy  = SERVER_ID,
		})
	end)
end

-- Admin gửi thông báo toàn server
function GlobalData:AdminBroadcast(message, duration)
	duration = duration or 60
	self:Set("adminMessage", "current", {
		message  = message,
		duration = duration,
		sentAt   = os.time(),
	})
	-- Gửi thẳng qua MessagingService để realtime hơn
	pcall(function()
		MessagingService:PublishAsync("AdminBroadcast", {
			message  = message,
			duration = duration,
			sentAt   = os.time(),
		})
	end)
	print("ServerDataManager: Admin broadcast — " .. message)
end

-- ════════════════════════════════════════════
--        CONFLICT RESOLUTION
-- ════════════════════════════════════════════
-- Xử lý khi player thoát rồi vào server khác
-- So sánh timestamp để quyết định merge hay overwrite

local ConflictResolver = {}

-- Lưu timestamp khi player thoát
function ConflictResolver:SaveExitStamp(player)
	local key = "Exit_" .. tostring(player.UserId)
	pcall(function()
		MemorySession:SetAsync(key, {
			userId    = player.UserId,
			exitTime  = os.time(),
			serverId  = SERVER_ID,
			placeId   = SERVER_PLACE,
		}, 300) -- TTL 5 phút — đủ để server khác check
	end)
end

-- Khi player vào — check xem họ vừa từ server khác sang không
function ConflictResolver:CheckOnJoin(player)
	local key = "Exit_" .. tostring(player.UserId)
	local ok, exitInfo = pcall(function()
		return MemorySession:GetAsync(key)
	end)

	if not ok or not exitInfo then
		return { conflict = false, reason = "no_exit_stamp" }
	end

	-- Họ vừa thoát từ server khác (không phải thoát hẳn)
	if exitInfo.serverId ~= SERVER_ID then
		local timeDiff = os.time() - exitInfo.exitTime
		if timeDiff < 30 then
			-- Vừa thoát trong 30 giây — có thể đang chuyển server
			return {
				conflict  = true,
				reason    = "recent_server_switch",
				exitTime  = exitInfo.exitTime,
				fromServer = exitInfo.serverId,
				timeDiff  = timeDiff,
			}
		end
	end

	return { conflict = false, reason = "safe" }
end

-- Merge data thay vì overwrite khi có conflict
function ConflictResolver:MergeData(localData, remoteData)
	if not remoteData then return localData end
	if not localData then return remoteData end

	local merged = {}

	-- Với mỗi section
	for section, fields in pairs(localData) do
		merged[section] = {}
		for key, localVal in pairs(fields) do
			local remoteVal = remoteData[section] and remoteData[section][key]
			if remoteVal == nil then
				-- Remote không có → giữ local
				merged[section][key] = localVal
			elseif type(localVal) == "number" and type(remoteVal) == "number" then
				-- Số → lấy giá trị lớn hơn (tránh mất progress)
				merged[section][key] = math.max(localVal, remoteVal)
			else
				-- Còn lại → ưu tiên remote (mới hơn)
				merged[section][key] = remoteVal
			end
		end
	end

	return merged
end

-- ════════════════════════════════════════════
--         MESSAGING SUBSCRIPTIONS
-- ════════════════════════════════════════════

-- Nhận update global từ server khác
pcall(function()
	MessagingService:SubscribeAsync("GlobalUpdate", function(msg)
		local data = msg.Data
		if data.setBy == SERVER_ID then return end -- Bỏ qua nếu chính mình gửi

		-- Cập nhật cache local
		local fullKey = data.type .. "_" .. data.key
		if data.op == "increment" then
			local cached = GlobalData._cache[fullKey]
			local current = cached and cached.value or 0
			GlobalData._cache[fullKey] = {
				value = current + (data.amount or 0),
				time  = os.time(),
			}
		else
			GlobalData._cache[fullKey] = {
				value = data.value,
				time  = os.time(),
			}
		end
	end)
end)

-- Nhận admin broadcast
pcall(function()
	MessagingService:SubscribeAsync("AdminBroadcast", function(msg)
		local data = msg.Data
		-- Gửi đến tất cả player trong server này
		for _, player in Players:GetPlayers() do
			RE_AdminMessage:FireClient(player, {
				message  = data.message,
				duration = data.duration,
				sentAt   = data.sentAt,
			})
		end
		print("ServerDataManager: Received admin broadcast — " .. data.message)
	end)
end)

-- ════════════════════════════════════════════
--         PLAYER LIFECYCLE HOOKS
-- ════════════════════════════════════════════

local function onPlayerAdded(player)
	SessionData:RegisterPlayer(player, true)

	-- Check conflict
	local result = ConflictResolver:CheckOnJoin(player)
	if result.conflict then
		warn("ServerDataManager: Conflict detected for "
			.. player.Name .. " — " .. result.reason)
		SessionData:Log("CONFLICT_DETECTED", {
			player   = player.Name,
			userId   = player.UserId,
			reason   = result.reason,
			timeDiff = result.timeDiff,
		})
		-- DataManager sẽ handle merge — thông báo qua session flag
		SessionData:Set("conflict_" .. tostring(player.UserId), result)
	end
end

local function onPlayerRemoving(player)
	SessionData:RegisterPlayer(player, false)
	ConflictResolver:SaveExitStamp(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, p in Players:GetPlayers() do
	task.spawn(onPlayerAdded, p)
end

-- ════════════════════════════════════════════
--         SERVER CLOSE HANDLER
-- ════════════════════════════════════════════

game:BindToClose(function()
	print("ServerDataManager: Server đóng — saving event log...")

	-- Xóa session khỏi registry
	pcall(function()
		MemorySession:RemoveAsync("Server_" .. SERVER_ID)
	end)

	-- Lưu event log vĩnh viễn
	SessionData:SaveEventLog()

	print("ServerDataManager: Done")
end)

-- Đăng ký server vào registry (để các server khác biết server này tồn tại)
pcall(function()
	MemorySession:SetAsync("Server_" .. SERVER_ID, {
		serverId  = SERVER_ID,
		placeId   = SERVER_PLACE,
		startTime = SERVER_START,
		playerCount = 0,
	}, 86400)
end)

-- Cập nhật playerCount mỗi 30 giây
task.spawn(function()
	while true do
		task.wait(30)
		pcall(function()
			MemorySession:UpdateAsync("Server_" .. SERVER_ID, function(old)
				if not old then return nil end
				old.playerCount = #Players:GetPlayers()
				old.lastPing    = os.time()
				return old
			end, 86400)
		end)
	end
end)

-- ════════════════════════════════════════════
--         REMOTE HANDLERS
-- ════════════════════════════════════════════

-- Client lấy global data (không nhạy cảm)
RF_GetGlobal.OnServerInvoke = function(player, dataType, key)
	if dataType == "adminMessage" or dataType == "shopPrice"
		or dataType == "eventState" or dataType == "number" then
		return GlobalData:Get(dataType, key)
	end
	return nil
end

-- Client lấy live data
RF_GetLive.OnServerInvoke = function(player, key)
	local value, setAt = LiveData:Get(key)
	return value, setAt
end

-- Client xem thông tin server hiện tại
RF_GetServerInfo.OnServerInvoke = function(player)
	return {
		serverId    = SERVER_ID,
		placeId     = SERVER_PLACE,
		startTime   = SERVER_START,
		playerCount = #Players:GetPlayers(),
		uptime      = os.time() - SERVER_START,
	}
end

-- ════════════════════════════════════════════
--         PUBLIC API
-- ════════════════════════════════════════════

local API = {}

-- Session data
function API.Session(key, value)
	if value ~= nil then
		SessionData:Set(key, value)
	else
		return SessionData:Get(key)
	end
end

function API.Log(eventType, data)
	SessionData:Log(eventType, data)
end

function API.GetEventLog()
	return SessionData._events
end

-- Live data (cross-server, TTL)
function API.SetLive(key, value, ttl)
	LiveData:Set(key, value, ttl)
end

function API.GetLive(key)
	return LiveData:Get(key)
end

function API.UpdateLive(key, fn, ttl)
	LiveData:Update(key, fn, ttl)
end

function API.DeleteLive(key)
	LiveData:Delete(key)
end

-- Global data (tất cả server)
function API.SetGlobal(dataType, key, value)
	return GlobalData:Set(dataType, key, value)
end

function API.GetGlobal(dataType, key)
	return GlobalData:Get(dataType, key)
end

function API.IncrementGlobal(key, amount)
	GlobalData:Increment(key, amount)
end

function API.AdminBroadcast(message, duration)
	GlobalData:AdminBroadcast(message, duration)
end

-- Conflict info cho player
function API.GetConflict(player)
	return SessionData:Get("conflict_" .. tostring(player.UserId))
end

-- Server info
function API.GetServerInfo()
	return {
		serverId    = SERVER_ID,
		placeId     = SERVER_PLACE,
		startTime   = SERVER_START,
		uptime      = os.time() - SERVER_START,
		playerCount = #Players:GetPlayers(),
	}
end

-- Lấy danh sách server đang chạy
function API.GetActiveServers()
	local servers = {}
	local ok, pages = pcall(function()
		return MemorySession:GetRangeAsync(Enum.SortDirection.Ascending, 20)
	end)
	if ok and pages then
		for _, entry in ipairs(pages) do
			if entry.key:sub(1, 7) == "Server_" then
				table.insert(servers, entry.value)
			end
		end
	end
	return servers
end

return API

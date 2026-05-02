-- ServerDataManager (Script trong ServerScriptService)
-- Quản lý: cross-server data, global data, server session, conflict resolution, scheduled data
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

local MemoryLive      = MemoryStoreService:GetSortedMap("LiveData")
local MemoryGlobal    = MemoryStoreService:GetSortedMap("GlobalData")
local MemorySession   = MemoryStoreService:GetSortedMap("SessionRegistry")
local MemoryScheduled = MemoryStoreService:GetSortedMap("ScheduledData") -- [NEW]

local EventLogStore   = DataStoreService:GetDataStore("ServerEventLog_v1")
local GlobalStore     = DataStoreService:GetDataStore("GlobalPersist_v1")
local ScheduledStore  = DataStoreService:GetDataStore("ScheduledData_v1")  -- [NEW]

local SERVER_ID    = game.JobId ~= "" and game.JobId or "STUDIO_" .. tostring(math.random(10000))
local SERVER_START = os.time()
local SERVER_PLACE = tostring(game.PlaceId)

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
local RF_GetScheduled   = makeRemote("GetScheduled", true)   -- [NEW]
local RE_AdminMessage   = makeRemote("AdminMessage", false)
local RE_ScheduledFired = makeRemote("ScheduledFired", false) -- [NEW]

-- ════════════════════════════════════════════
--           RATE LIMIT PROTECTION [FIX]
-- ════════════════════════════════════════════
-- Chống client spam invoke RF_GetGlobal / RF_GetLive

local RemoteCallTracker = {}
local RATE_LIMIT_MAX    = 10   -- tối đa 10 call
local RATE_LIMIT_WINDOW = 5    -- trong 5 giây

local function checkRateLimit(player, remoteName)
	local uid = tostring(player.UserId) .. "_" .. remoteName
	local now = os.time()
	if not RemoteCallTracker[uid] then
		RemoteCallTracker[uid] = { count = 0, windowStart = now }
	end
	local tracker = RemoteCallTracker[uid]
	if now - tracker.windowStart >= RATE_LIMIT_WINDOW then
		tracker.count = 0
		tracker.windowStart = now
	end
	tracker.count += 1
	if tracker.count > RATE_LIMIT_MAX then
		warn("ServerDataManager: Rate limit hit — " .. player.Name .. " / " .. remoteName)
		return false
	end
	return true
end

-- Dọn tracker khi player rời (tránh memory leak)
local function cleanRateTracker(player)
	local uid = tostring(player.UserId)
	for key in pairs(RemoteCallTracker) do
		if key:sub(1, #uid) == uid then
			RemoteCallTracker[key] = nil
		end
	end
end

-- ════════════════════════════════════════════
--           SESSION DATA (trong phiên)
-- ════════════════════════════════════════════

local SessionData = {}
SessionData._data       = {}
SessionData._events     = {}
SessionData._playerList = {}

function SessionData:Set(key, value)
	self._data[key] = { value = value, updated = os.time() }
end

function SessionData:Get(key)
	local entry = self._data[key]
	return entry and entry.value or nil
end

function SessionData:GetAll()
	return self._data
end

function SessionData:Log(eventType, data)
	table.insert(self._events, {
		type     = eventType,
		data     = data,
		time     = os.time(),
		serverId = SERVER_ID,
	})
end

function SessionData:RegisterPlayer(player, isJoining)
	local uid = tostring(player.UserId)
	if isJoining then
		self._playerList[uid] = {
			name   = player.Name,
			userId = player.UserId,
			joined = os.time(),
		}
		self:Log("PLAYER_JOIN", { name = player.Name, userId = player.UserId })
	else
		if self._playerList[uid] then
			self._playerList[uid].left = os.time()
		end
		self:Log("PLAYER_LEAVE", { name = player.Name, userId = player.UserId })
	end
end

function SessionData:SaveEventLog()
	if #self._events == 0 then return end
	local key = "EventLog_" .. SERVER_ID .. "_" .. tostring(SERVER_START)
	local ok, err = pcall(function()
		EventLogStore:SetAsync(key, {
			serverId   = SERVER_ID,
			placeId    = SERVER_PLACE,
			startTime  = SERVER_START,
			endTime    = os.time(),
			playerList = self._playerList,
			events     = self._events,
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

local LiveData = {}

function LiveData:Set(key, value, ttl)
	ttl = ttl or 300
	local ok, err = pcall(function()
		MemoryLive:SetAsync(key, {
			value = value,
			setBy = SERVER_ID,
			setAt = os.time(),
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

function LiveData:Update(key, updateFn, ttl)
	ttl = ttl or 300
	pcall(function()
		MemoryLive:UpdateAsync(key, function(old)
			local current = old and old.value or nil
			local newVal = updateFn(current)
			if newVal == nil then return nil end
			return { value = newVal, setBy = SERVER_ID, setAt = os.time() }
		end, ttl)
	end)
end

-- ════════════════════════════════════════════
--         GLOBAL DATA (toàn bộ server)
-- ════════════════════════════════════════════

local GlobalData = {}
GlobalData._cache = {}

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

	-- Lưu vào MemoryStore
	local memOk, memErr = pcall(function()
		MemoryGlobal:SetAsync(fullKey, {
			value = value,
			type  = dataType,
			setBy = SERVER_ID,
			setAt = os.time(),
		}, 86400)
	end)
	if not memOk then
		warn("GlobalData:Set MemoryStore failed — " .. tostring(memErr))
	end

	-- [FIX] Lưu DataStore riêng biệt với pcall + warn đúng
	if dataType == "shopPrice" or dataType == "eventState" then
		local dsOk, dsErr = pcall(function()
			GlobalStore:SetAsync(fullKey, { value = value, setAt = os.time() })
		end)
		if not dsOk then
			warn("GlobalData:Set DataStore failed — " .. tostring(dsErr))
		end
	end

	self._cache[fullKey] = { value = value, time = os.time() }

	pcall(function()
		MessagingService:PublishAsync("GlobalUpdate", {
			type  = dataType,
			key   = key,
			value = value,
			setBy = SERVER_ID,
		})
	end)

	return memOk -- [FIX] trả về đúng kết quả MemoryStore
end

function GlobalData:Get(dataType, key)
	local fullKey = dataType .. "_" .. key

	local cached = self._cache[fullKey]
	if cached and (os.time() - cached.time) < 5 then
		return cached.value
	end

	local ok, result = pcall(function()
		return MemoryGlobal:GetAsync(fullKey)
	end)
	if ok and result then
		self._cache[fullKey] = { value = result.value, time = os.time() }
		return result.value
	end

	local ok2, stored = pcall(function()
		return GlobalStore:GetAsync(fullKey)
	end)
	if ok2 and stored then
		return stored.value
	end

	return nil
end

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

function GlobalData:AdminBroadcast(message, duration)
	duration = duration or 60
	self:Set("adminMessage", "current", {
		message  = message,
		duration = duration,
		sentAt   = os.time(),
	})
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
--         CONFLICT RESOLUTION
-- ════════════════════════════════════════════

local ConflictResolver = {}

function ConflictResolver:SaveExitStamp(player)
	local key = "Exit_" .. tostring(player.UserId)
	pcall(function()
		MemorySession:SetAsync(key, {
			userId   = player.UserId,
			exitTime = os.time(),
			serverId = SERVER_ID,
			placeId  = SERVER_PLACE,
		}, 300)
	end)
end

function ConflictResolver:CheckOnJoin(player)
	local key = "Exit_" .. tostring(player.UserId)
	local ok, exitInfo = pcall(function()
		return MemorySession:GetAsync(key)
	end)
	if not ok or not exitInfo then
		return { conflict = false, reason = "no_exit_stamp" }
	end
	if exitInfo.serverId ~= SERVER_ID then
		local timeDiff = os.time() - exitInfo.exitTime
		if timeDiff < 30 then
			return {
				conflict   = true,
				reason     = "recent_server_switch",
				exitTime   = exitInfo.exitTime,
				fromServer = exitInfo.serverId,
				timeDiff   = timeDiff,
			}
		end
	end
	return { conflict = false, reason = "safe" }
end

-- [FIX] MergeData giờ xử lý cả section remote có mà local không có
function ConflictResolver:MergeData(localData, remoteData)
	if not remoteData then return localData end
	if not localData  then return remoteData end

	local merged = {}

	-- Gom tất cả section từ cả hai phía
	local allSections = {}
	for s in pairs(localData)  do allSections[s] = true end
	for s in pairs(remoteData) do allSections[s] = true end

	for section in pairs(allSections) do
		merged[section] = {}
		local localFields  = localData[section]  or {}
		local remoteFields = remoteData[section] or {}

		-- Gom tất cả key từ cả hai phía
		local allKeys = {}
		for k in pairs(localFields)  do allKeys[k] = true end
		for k in pairs(remoteFields) do allKeys[k] = true end

		for key in pairs(allKeys) do
			local localVal  = localFields[key]
			local remoteVal = remoteFields[key]

			if remoteVal == nil then
				merged[section][key] = localVal
			elseif localVal == nil then
				merged[section][key] = remoteVal -- [FIX] giữ section/key remote mà local không có
			elseif type(localVal) == "number" and type(remoteVal) == "number" then
				merged[section][key] = math.max(localVal, remoteVal)
			else
				merged[section][key] = remoteVal -- remote mới hơn
			end
		end
	end

	return merged
end

-- ════════════════════════════════════════════
--         SCHEDULED DATA [NEW]
-- ════════════════════════════════════════════
-- Data được định nghĩa sẵn, chưa active.
-- Đến đúng startTime → tự bật lên, có thể chỉnh sửa.
-- Đến endTime (nếu có) → tự tắt.
-- Broadcast đến toàn server qua MessagingService khi fired.
--
-- Ví dụ dùng:
--   API.ScheduleData("summer_event", "eventState", {
--       active = true, bonusXP = 2
--   }, os.time() + 3600, os.time() + 7200)
--
--   API.ScheduleData("weekend_sale", "shopPrice", {
--       sword = 50, armor = 80
--   }, 1720000000)  -- Unix timestamp cụ thể

local ScheduledData = {}
ScheduledData._jobs      = {}  -- danh sách job đang theo dõi (local)
ScheduledData._callbacks = {}  -- callback khi job fired: [jobId] = fn(jobData)

-- Tạo hoặc ghi đè một scheduled job
-- jobId     : tên định danh duy nhất
-- dataType  : phải nằm trong GLOBAL_TYPES
-- payload   : giá trị sẽ được set vào GlobalData khi đến giờ
-- startTime : Unix timestamp khi bật
-- endTime   : Unix timestamp khi tắt (nil = không tự tắt)
-- meta      : thông tin thêm (mô tả, tác giả, ...)
function ScheduledData:Register(jobId, dataType, payload, startTime, endTime, meta)
	if not GLOBAL_TYPES[dataType] then
		warn("ScheduledData: dataType không hợp lệ — " .. tostring(dataType))
		return false
	end
	if type(startTime) ~= "number" then
		warn("ScheduledData: startTime phải là Unix timestamp")
		return false
	end
	if endTime and endTime <= startTime then
		warn("ScheduledData: endTime phải sau startTime")
		return false
	end

	local job = {
		jobId     = jobId,
		dataType  = dataType,
		payload   = payload,
		startTime = startTime,
		endTime   = endTime,
		meta      = meta or {},
		status    = "pending",  -- pending | active | ended | cancelled
		createdAt = os.time(),
		createdBy = SERVER_ID,
	}

	-- Lưu vào DataStore (vĩnh viễn, cross-restart)
	local dsOk, dsErr = pcall(function()
		ScheduledStore:SetAsync("Job_" .. jobId, job)
	end)
	if not dsOk then
		warn("ScheduledData:Register DataStore failed — " .. tostring(dsErr))
		return false
	end

	-- Lưu vào MemoryStore (realtime, TTL đến sau endTime hoặc 7 ngày)
	local ttl = endTime and (endTime - os.time() + 300) or (86400 * 7)
	ttl = math.max(ttl, 60) -- tối thiểu 60 giây
	pcall(function()
		MemoryScheduled:SetAsync("Job_" .. jobId, job, ttl)
	end)

	self._jobs[jobId] = job
	print(string.format("ScheduledData: Registered [%s] → fires at %s", jobId, os.date("%Y-%m-%d %H:%M:%S", startTime)))
	return true
end

-- Huỷ một job (chưa fired)
function ScheduledData:Cancel(jobId)
	local job = self._jobs[jobId]
	if not job then
		warn("ScheduledData:Cancel — không tìm thấy job: " .. tostring(jobId))
		return false
	end
	if job.status == "active" or job.status == "ended" then
		warn("ScheduledData:Cancel — job đã " .. job.status .. ", không thể huỷ: " .. jobId)
		return false
	end
	job.status = "cancelled"
	pcall(function() MemoryScheduled:RemoveAsync("Job_" .. jobId) end)
	pcall(function()
		ScheduledStore:UpdateAsync("Job_" .. jobId, function(old)
			if not old then return nil end
			old.status = "cancelled"
			return old
		end)
	end)
	self._jobs[jobId] = nil
	print("ScheduledData: Cancelled — " .. jobId)
	return true
end

-- Chỉnh sửa payload của job ĐANG ACTIVE
function ScheduledData:UpdateActive(jobId, newPayload)
	local job = self._jobs[jobId]
	if not job or job.status ~= "active" then
		warn("ScheduledData:UpdateActive — job không active: " .. tostring(jobId))
		return false
	end
	job.payload = newPayload
	-- Cập nhật GlobalData ngay lập tức
	GlobalData:Set(job.dataType, jobId, newPayload)
	-- Cập nhật lại store
	pcall(function()
		local remaining = job.endTime and (job.endTime - os.time() + 60) or 86400
		MemoryScheduled:SetAsync("Job_" .. jobId, job, math.max(remaining, 60))
	end)
	pcall(function()
		ScheduledStore:UpdateAsync("Job_" .. jobId, function(old)
			if not old then return nil end
			old.payload = newPayload
			return old
		end)
	end)
	print("ScheduledData: Updated active job — " .. jobId)
	return true
end

-- Đăng ký callback khi một job được fired
function ScheduledData:OnFired(jobId, callback)
	self._callbacks[jobId] = callback
end

-- Lấy thông tin một job
function ScheduledData:GetJob(jobId)
	return self._jobs[jobId]
end

-- Lấy tất cả job theo status
function ScheduledData:GetAll(filterStatus)
	local result = {}
	for id, job in pairs(self._jobs) do
		if not filterStatus or job.status == filterStatus then
			result[id] = job
		end
	end
	return result
end

-- Nội bộ: fire một job (bật data lên)
local function _fireJob(job)
	job.status  = "active"
	job.firedAt = os.time()

	-- Set vào GlobalData
	GlobalData:Set(job.dataType, job.jobId, job.payload)

	-- Broadcast đến tất cả server
	pcall(function()
		MessagingService:PublishAsync("ScheduledFired", {
			jobId    = job.jobId,
			dataType = job.dataType,
			payload  = job.payload,
			firedAt  = job.firedAt,
		})
	end)

	-- Gọi callback nếu có
	local cb = ScheduledData._callbacks[job.jobId]
	if cb then
		task.spawn(cb, job)
	end

	-- Thông báo client trong server này
	for _, player in Players:GetPlayers() do
		RE_ScheduledFired:FireClient(player, {
			jobId    = job.jobId,
			dataType = job.dataType,
			payload  = job.payload,
		})
	end

	-- Lưu trạng thái mới
	pcall(function()
		ScheduledStore:UpdateAsync("Job_" .. job.jobId, function(old)
			if not old then return nil end
			old.status  = "active"
			old.firedAt = job.firedAt
			return old
		end)
	end)

	SessionData:Log("SCHEDULED_FIRED", { jobId = job.jobId, dataType = job.dataType })
	print(string.format("ScheduledData: FIRED [%s] (%s)", job.jobId, job.dataType))
end

-- Nội bộ: end một job (tắt data)
local function _endJob(job)
	job.status = "ended"
	job.endedAt = os.time()

	-- Xoá khỏi GlobalData
	GlobalData:Set(job.dataType, job.jobId, nil)

	pcall(function()
		MessagingService:PublishAsync("ScheduledEnded", {
			jobId   = job.jobId,
			endedAt = job.endedAt,
		})
	end)

	pcall(function()
		ScheduledStore:UpdateAsync("Job_" .. job.jobId, function(old)
			if not old then return nil end
			old.status  = "ended"
			old.endedAt = job.endedAt
			return old
		end)
	end)

	SessionData:Log("SCHEDULED_ENDED", { jobId = job.jobId })
	print(string.format("ScheduledData: ENDED [%s]", job.jobId))
end

-- Load lại jobs từ DataStore khi server khởi động
-- (tránh mất jobs sau server restart)
local function _loadPersistedJobs()
	-- Scan MemoryStore trước (nhanh hơn)
	local ok, pages = pcall(function()
		return MemoryScheduled:GetRangeAsync(Enum.SortDirection.Ascending, 50)
	end)
	if ok and pages then
		for _, entry in ipairs(pages) do
			local job = entry.value
			if job and job.jobId and job.status == "pending" then
				ScheduledData._jobs[job.jobId] = job
			elseif job and job.jobId and job.status == "active" then
				-- Job đang active từ server khác → đồng bộ cache
				ScheduledData._jobs[job.jobId] = job
				GlobalData._cache["job_" .. job.dataType .. "_" .. job.jobId] = {
					value = job.payload,
					time  = os.time(),
				}
			end
		end
	end
	print("ScheduledData: Loaded " .. (function()
		local c = 0; for _ in pairs(ScheduledData._jobs) do c += 1 end; return c
	end)() .. " persisted jobs")
end

-- ════════════════════════════════════════════
--     SCHEDULER LOOP (mỗi 5 giây check)
-- ════════════════════════════════════════════

task.spawn(function()
	task.wait(5) -- đợi server init xong
	_loadPersistedJobs()

	while true do
		task.wait(5)
		local now = os.time()

		for jobId, job in pairs(ScheduledData._jobs) do
			if job.status == "pending" and now >= job.startTime then
				_fireJob(job)
			elseif job.status == "active" and job.endTime and now >= job.endTime then
				_endJob(job)
				ScheduledData._jobs[jobId] = nil
			end
		end
	end
end)

-- ════════════════════════════════════════════
--         MESSAGING SUBSCRIPTIONS
-- ════════════════════════════════════════════

pcall(function()
	MessagingService:SubscribeAsync("GlobalUpdate", function(msg)
		local data = msg.Data
		if data.setBy == SERVER_ID then return end
		local fullKey = data.type .. "_" .. data.key
		if data.op == "increment" then
			local cached  = GlobalData._cache[fullKey]
			local current = cached and cached.value or 0
			GlobalData._cache[fullKey] = { value = current + (data.amount or 0), time = os.time() }
		else
			GlobalData._cache[fullKey] = { value = data.value, time = os.time() }
		end
	end)
end)

pcall(function()
	MessagingService:SubscribeAsync("AdminBroadcast", function(msg)
		local data = msg.Data
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

-- [NEW] Nhận broadcast khi job fired từ server khác
pcall(function()
	MessagingService:SubscribeAsync("ScheduledFired", function(msg)
		local data = msg.Data
		-- Cập nhật cache và thông báo client
		GlobalData._cache[data.dataType .. "_" .. data.jobId] = {
			value = data.payload,
			time  = os.time(),
		}
		for _, player in Players:GetPlayers() do
			RE_ScheduledFired:FireClient(player, data)
		end
		-- Đồng bộ trạng thái job nếu biết
		if ScheduledData._jobs[data.jobId] then
			ScheduledData._jobs[data.jobId].status  = "active"
			ScheduledData._jobs[data.jobId].firedAt = data.firedAt
		end
	end)
end)

pcall(function()
	MessagingService:SubscribeAsync("ScheduledEnded", function(msg)
		local data = msg.Data
		if ScheduledData._jobs[data.jobId] then
			ScheduledData._jobs[data.jobId].status = "ended"
			ScheduledData._jobs[data.jobId] = nil
		end
	end)
end)

-- ════════════════════════════════════════════
--         PLAYER LIFECYCLE HOOKS
-- ════════════════════════════════════════════

local function onPlayerAdded(player)
	SessionData:RegisterPlayer(player, true)
	local result = ConflictResolver:CheckOnJoin(player)
	if result.conflict then
		warn("ServerDataManager: Conflict detected for " .. player.Name .. " — " .. result.reason)
		SessionData:Log("CONFLICT_DETECTED", {
			player   = player.Name,
			userId   = player.UserId,
			reason   = result.reason,
			timeDiff = result.timeDiff,
		})
		SessionData:Set("conflict_" .. tostring(player.UserId), result)
	end
end

local function onPlayerRemoving(player)
	SessionData:RegisterPlayer(player, false)
	ConflictResolver:SaveExitStamp(player)
	cleanRateTracker(player) -- [FIX] dọn rate tracker
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
	pcall(function()
		MemorySession:RemoveAsync("Server_" .. SERVER_ID)
	end)
	SessionData:SaveEventLog()
	print("ServerDataManager: Done")
end)

pcall(function()
	MemorySession:SetAsync("Server_" .. SERVER_ID, {
		serverId    = SERVER_ID,
		placeId     = SERVER_PLACE,
		startTime   = SERVER_START,
		playerCount = 0,
	}, 86400)
end)

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

-- [FIX] Thêm rate limit cho tất cả RF
RF_GetGlobal.OnServerInvoke = function(player, dataType, key)
	if not checkRateLimit(player, "GetGlobal") then return nil end
	if dataType == "adminMessage" or dataType == "shopPrice"
		or dataType == "eventState" or dataType == "number" then
		return GlobalData:Get(dataType, key)
	end
	return nil
end

RF_GetLive.OnServerInvoke = function(player, key)
	if not checkRateLimit(player, "GetLive") then return nil, nil end
	return LiveData:Get(key)
end

RF_GetServerInfo.OnServerInvoke = function(player)
	if not checkRateLimit(player, "GetServerInfo") then return nil end
	return {
		serverId    = SERVER_ID,
		placeId     = SERVER_PLACE,
		startTime   = SERVER_START,
		playerCount = #Players:GetPlayers(),
		uptime      = os.time() - SERVER_START,
	}
end

-- [NEW] Client hỏi thông tin scheduled job
RF_GetScheduled.OnServerInvoke = function(player, jobId)
	if not checkRateLimit(player, "GetScheduled") then return nil end
	if jobId then
		return ScheduledData:GetJob(jobId)
	else
		-- Trả về danh sách job public (không có payload nhạy cảm)
		local result = {}
		for id, job in pairs(ScheduledData:GetAll()) do
			result[id] = {
				jobId     = job.jobId,
				dataType  = job.dataType,
				startTime = job.startTime,
				endTime   = job.endTime,
				status    = job.status,
				meta      = job.meta,
			}
		end
		return result
	end
end

-- ════════════════════════════════════════════
--         PUBLIC API
-- ════════════════════════════════════════════

local API = {}

-- Session data
function API.Session(key, value)
	if value ~= nil then SessionData:Set(key, value)
	else return SessionData:Get(key) end
end

function API.Log(eventType, data)
	SessionData:Log(eventType, data)
end

function API.GetEventLog()
	return SessionData._events
end

-- Live data
function API.SetLive(key, value, ttl)  LiveData:Set(key, value, ttl) end
function API.GetLive(key)              return LiveData:Get(key) end
function API.UpdateLive(key, fn, ttl)  LiveData:Update(key, fn, ttl) end
function API.DeleteLive(key)           LiveData:Delete(key) end

-- Global data
function API.SetGlobal(dataType, key, value) return GlobalData:Set(dataType, key, value) end
function API.GetGlobal(dataType, key)        return GlobalData:Get(dataType, key) end
function API.IncrementGlobal(key, amount)    GlobalData:Increment(key, amount) end
function API.AdminBroadcast(message, duration) GlobalData:AdminBroadcast(message, duration) end

-- Conflict
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

function API.GetActiveServers()
	local servers = {}
	local ok, pages = pcall(function()
		return MemorySession:GetRangeAsync(Enum.SortDirection.Ascending, 20)
	end)
	if ok and pages then
		for _, entry in ipairs(pages) do
			-- [FIX] Lọc server cũ: chỉ lấy server ping trong 90 giây gần đây
			local v = entry.value
			if entry.key:sub(1, 7) == "Server_"
				and v and v.lastPing
				and (os.time() - v.lastPing) < 90 then
				table.insert(servers, v)
			end
		end
	end
	return servers
end

-- ════════════════════════════════════════════
-- [NEW] Scheduled Data API
-- ════════════════════════════════════════════

--- Đăng ký data sẽ tự bật lúc startTime
--- @param jobId      string   -- tên định danh duy nhất
--- @param dataType   string   -- "eventState" | "shopPrice" | "number" | "value"
--- @param payload    any      -- giá trị sẽ được set
--- @param startTime  number   -- Unix timestamp (os.time() + giây, hoặc timestamp cụ thể)
--- @param endTime    number?  -- Unix timestamp kết thúc (nil = không tự tắt)
--- @param meta       table?   -- { description, author, ... }
function API.ScheduleData(jobId, dataType, payload, startTime, endTime, meta)
	return ScheduledData:Register(jobId, dataType, payload, startTime, endTime, meta)
end

--- Huỷ job chưa fired
function API.CancelScheduled(jobId)
	return ScheduledData:Cancel(jobId)
end

--- Chỉnh payload của job ĐANG ACTIVE (realtime)
function API.UpdateScheduled(jobId, newPayload)
	return ScheduledData:UpdateActive(jobId, newPayload)
end

--- Lấy thông tin job
function API.GetScheduledJob(jobId)
	return ScheduledData:GetJob(jobId)
end

--- Lấy tất cả jobs (có thể filter theo status)
--- filterStatus: "pending" | "active" | "ended" | "cancelled" | nil (lấy hết)
function API.GetAllScheduled(filterStatus)
	return ScheduledData:GetAll(filterStatus)
end

--- Đăng ký callback khi job fired
--- Dùng để trigger logic game (spawn boss, mở map, ...)
function API.OnScheduledFired(jobId, callback)
	ScheduledData:OnFired(jobId, callback)
end

return API

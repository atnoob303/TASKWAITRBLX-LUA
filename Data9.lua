-- ╔══════════════════════════════════════════════════════════════╗
-- ║            ServerDataManager  —  ModuleScript                ║
-- ║  Đặt trong: ServerScriptService                              ║
-- ║  Yêu cầu:   DataManager đã chạy trước                        ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  Hệ thống:                                                   ║
-- ║   1. SessionData      — data phiên server                    ║
-- ║   2. LiveData         — cross-server TTL                     ║
-- ║   3. GlobalData       — toàn server vĩnh viễn                ║
-- ║   4. ConflictResolver — xử lý xung đột khi đổi server        ║
-- ║   5. ScheduledData    — data tự bật theo lịch                ║
-- ║   6. RandomData       — random có trọng số/seed/bonus        ║
-- ║   7. GameEventLog     — lưu sự kiện & session player         ║
-- ║   8. DataConfig       — đọc config từ Folder trong Studio    ║
-- ║   9. PlayerData       — load/save/migrate data player        ║
-- ║      ├─ 3 hình thức key: Seed / Name / Id                    ║
-- ║      ├─ OldData migration (attribute tên data cũ)            ║
-- ║      ├─ Audit log / version history                          ║
-- ║      ├─ Folder scan: tìm "DataStore" (case-insensitive)      ║
-- ║      └─ Value objects làm schema định nghĩa data player      ║
-- ╚══════════════════════════════════════════════════════════════╝

local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService   = game:GetService("MessagingService")
local DataStoreService   = game:GetService("DataStoreService")
local Players            = game:GetService("Players")
local ServerStorage      = game:GetService("ServerStorage")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- ════════════════════════════════════════════
--  MODULE CON — TÌM CASE-INSENSITIVE
--  DataModule & DataSave nằm trong script này
-- ════════════════════════════════════════════

local function _requireChild(name)
	local nameLower = name:lower()
	for _, child in ipairs(script:GetChildren()) do
		if child:IsA("ModuleScript") and child.Name:lower() == nameLower then
			local ok, mod = pcall(require, child)
			if ok then
				print(string.format("[Data6] Đã require module con '%s' (tìm thấy: '%s')", name, child.Name))
				return mod
			else
				warn(string.format("[Data6] require '%s' thất bại: %s", child.Name, tostring(mod)))
				return nil
			end
		end
	end
	warn(string.format("[Data6] Không tìm thấy ModuleScript tên '%s' trong script", name))
	return nil
end

local DataModule = _requireChild("DataModule")   -- quản lý data container server (shop, event, config…)
local DataSave   = _requireChild("DataSave")     -- quản lý load/save data player theo session

-- ════════════════════════════════════════════
--              SERVICES & STORES
-- ════════════════════════════════════════════

local MemoryLive      = MemoryStoreService:GetSortedMap("LiveData")
local MemoryGlobal    = MemoryStoreService:GetSortedMap("GlobalData")
local MemorySession   = MemoryStoreService:GetSortedMap("SessionRegistry")
local MemoryScheduled = MemoryStoreService:GetSortedMap("ScheduledData")

local EventLogStore   = DataStoreService:GetDataStore("ServerEventLog_v1")
local GlobalStore     = DataStoreService:GetDataStore("GlobalPersist_v1")
local ScheduledStore  = DataStoreService:GetDataStore("ScheduledData_v1")
local GameEventStore  = DataStoreService:GetDataStore("GameEventLog_v1")
local PlayerSnapStore = DataStoreService:GetDataStore("PlayerSnapshot_v1")
local AuditLogStore   = DataStoreService:GetDataStore("PlayerAuditLog_v1")

local SERVER_ID    = game.JobId ~= "" and game.JobId or "STUDIO_" .. tostring(math.random(10000))
local SERVER_START = os.time()
local SERVER_PLACE = tostring(game.PlaceId)

-- ════════════════════════════════════════════
--              REMOTES
-- ════════════════════════════════════════════

-- Tìm hoặc tạo GameSettingUp/Sever trong ReplicatedStorage
local GameSettingUp = ReplicatedStorage:FindFirstChild("GameSettingUp")
	or Instance.new("Folder", ReplicatedStorage)
GameSettingUp.Name = "GameSettingUp"

local Remotes = GameSettingUp:FindFirstChild("Sever")
	or Instance.new("Folder", GameSettingUp)
Remotes.Name = "Sever"

local function makeRemote(name, isFunc)
	local expectedClass = isFunc and "RemoteFunction" or "RemoteEvent"
	local r = Remotes:FindFirstChild(name)
	if r then
		if r.ClassName ~= expectedClass then
			warn(string.format(
				"[ServerDataManager] Remote '%s' sai type (%s, cần %s) — xóa và tạo lại",
				name, r.ClassName, expectedClass
				))
			r:Destroy()
		else
			return r
		end
	end
	r = Instance.new(expectedClass)
	r.Name = name
	r.Parent = Remotes
	return r
end

local RF_GetGlobal      = makeRemote("GetGlobal",     true)
local RF_GetLive        = makeRemote("GetLive",        true)
local RF_GetServerInfo  = makeRemote("GetServerInfo",  true)
local RF_GetScheduled   = makeRemote("GetScheduled",   true)
local RF_GetRandom      = makeRemote("GetRandom",      true)
local RE_AdminMessage      = makeRemote("AdminMessage",      false)
local RE_ScheduledFired    = makeRemote("ScheduledFired",    false)
local RE_GameEvent         = makeRemote("GameEvent",         false)
local RE_DataModuleChanged = makeRemote("DataModuleChanged", false)  -- notify client khi DataModule thay đổi
local RF_GetMyData         = makeRemote("GetMyData",         true)   -- client lấy data của chính mình
local RF_GetOtherData      = makeRemote("GetOtherData",      true)   -- client lấy data player khác (chỉ khi online)

-- ════════════════════════════════════════════
--  DATAMODULE CLIENT SYNC HELPER
-- ════════════════════════════════════════════

-- Wrap onChange để tự động fire RE_DataModuleChanged tới client khi data thay đổi.
-- Server → Client only → an toàn, không cần validate.
local function _wrapOnChange(id, userOnChange)
	return function(key, old, new)
		for _, p in Players:GetPlayers() do
			RE_DataModuleChanged:FireClient(p, { id=id, key=key, old=old, value=new })
		end
		if userOnChange then task.spawn(userOnChange, key, old, new) end
	end
end

-- ════════════════════════════════════════════
--  PLAYER DATA — CLIENT READ HELPERS
-- ════════════════════════════════════════════

-- Lọc bỏ field readOnly=true khỏi data trước khi gửi client
-- readOnly ở đây có nghĩa là "server-only, không expose ra ngoài"
-- ════════════════════════════════════════════
--  PLAYER DATA — VISIBILITY FILTER
--
--  Mỗi field trong meta có thể đặt:
--    visibility = "public"   → bản thân + người khác đều xem được  (mặc định)
--    visibility = "private"  → chỉ bản thân xem được
--    visibility = "secret"   → không ai xem được kể cả bản thân (chỉ server dùng nội bộ)
--
--  readOnly vẫn giữ nguyên ý nghĩa: không cho Set từ bên ngoài
-- ════════════════════════════════════════════

local VISIBILITY_PUBLIC  = "public"
local VISIBILITY_PRIVATE = "private"
local VISIBILITY_SECRET  = "secret"

-- isSelf = true  → lọc cho chính player (bỏ secret)
-- isSelf = false → lọc cho người khác   (bỏ secret + private)
local function _filterByVisibility(data, meta, isSelf)
	if type(data) ~= "table" then return data end
	local result = {}
	for k, v in pairs(data) do
		local fieldMeta   = meta and meta[k]
		local visibility  = fieldMeta and fieldMeta.visibility or VISIBILITY_PUBLIC

		-- secret → không ai xem được
		if visibility == VISIBILITY_SECRET then continue end
		-- private → chỉ bản thân
		if visibility == VISIBILITY_PRIVATE and not isSelf then continue end

		-- Sub-table: lọc đệ quy
		if type(v) == "table" and fieldMeta and fieldMeta.isTable then
			result[k] = _filterByVisibility(v, fieldMeta.subMeta, isSelf)
		else
			result[k] = v
		end
	end
	return result
end

-- Kiểm tra visibility của 1 field path cụ thể (dot-notation)
-- Trả về visibility string hoặc "public" nếu không tìm thấy meta
local function _getFieldVisibility(meta, fieldPath)
	local parts     = fieldPath:split(".")
	local fieldMeta = meta
	for _, part in ipairs(parts) do
		if type(fieldMeta) ~= "table" then return VISIBILITY_PUBLIC end
		fieldMeta = fieldMeta[part] or (fieldMeta.subMeta and fieldMeta.subMeta[part])
	end
	if type(fieldMeta) == "table" then
		return fieldMeta.visibility or VISIBILITY_PUBLIC
	end
	return VISIBILITY_PUBLIC
end

-- Lấy 1 field theo dot-notation, ví dụ "stats.kills"
local function _getField(data, fieldPath)
	local parts = fieldPath:split(".")
	local cur = data
	for _, part in ipairs(parts) do
		if type(cur) ~= "table" then return nil end
		cur = cur[part]
	end
	return cur
end

-- ════════════════════════════════════════════
--           RATE LIMIT PROTECTION
-- ════════════════════════════════════════════

local RemoteCallTracker = {}
local RATE_MAX = 10; local RATE_WINDOW = 5

local function checkRateLimit(player, name)
	local uid = tostring(player.UserId) .. "_" .. name
	local now = os.time()
	if not RemoteCallTracker[uid] then
		RemoteCallTracker[uid] = { count = 0, win = now }
	end
	local t = RemoteCallTracker[uid]
	if now - t.win >= RATE_WINDOW then t.count = 0; t.win = now end
	t.count += 1
	if t.count > RATE_MAX then
		warn("RateLimit: " .. player.Name .. " / " .. name); return false
	end
	return true
end

local function cleanRateTracker(player)
	local uid = tostring(player.UserId)
	for k in pairs(RemoteCallTracker) do
		if k:sub(1, #uid) == uid then RemoteCallTracker[k] = nil end
	end
end

-- ════════════════════════════════════════════
--        HELPERS — THOI GIAN
-- ════════════════════════════════════════════

local TimeUtil = {}

function TimeUtil.toTimestamp(year, month, day, hour, minute, second)
	if type(year) == "string" then
		local s = year
		local y, mo, d, h, mi, se
		y,mo,d,h,mi,se = s:match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):?(%d*)")
		if not y then
			d,mo,y,h,mi,se = s:match("(%d+)/(%d+)/(%d+)%s+(%d+):(%d+):?(%d*)")
		end
		if not y then
			warn("TimeUtil: Khong parse duoc chuoi thoi gian — " .. s)
			return nil
		end
		year=tonumber(y); month=tonumber(mo); day=tonumber(d)
		hour=tonumber(h); minute=tonumber(mi); second=tonumber(se) or 0
	elseif type(year) == "table" then
		local t = year
		year=t.year; month=t.month; day=t.day
		hour=t.hour or 0; minute=t.minute or 0; second=t.second or 0
	end
	second = second or 0
	local ok, ts = pcall(os.time, {
		year=year, month=month, day=day,
		hour=hour, min=minute, sec=second
	})
	if ok then return ts end
	warn("TimeUtil: Ngay thang khong hop le"); return nil
end

function TimeUtil.format(ts)
	return os.date("%d/%m/%Y %H:%M:%S", ts)
end

function TimeUtil.breakdown(ts)
	local d = os.date("*t", ts)
	return { year=d.year, month=d.month, day=d.day,
		hour=d.hour, minute=d.min, second=d.sec }
end

-- ════════════════════════════════════════════
--           SESSION DATA
-- ════════════════════════════════════════════

local SessionData = {}
SessionData._data       = {}
SessionData._events     = {}
SessionData._playerList = {}

function SessionData:Set(key, value)
	self._data[key] = { value = value, updated = os.time() }
end
function SessionData:Get(key)
	local e = self._data[key]; return e and e.value or nil
end
function SessionData:GetAll() return self._data end

function SessionData:Log(eventType, data)
	table.insert(self._events, {
		type=eventType, data=data, time=os.time(), serverId=SERVER_ID
	})
end

function SessionData:RegisterPlayer(player, isJoining)
	local uid = tostring(player.UserId)
	if isJoining then
		self._playerList[uid] = { name=player.Name, userId=player.UserId, joined=os.time() }
		self:Log("PLAYER_JOIN", { name=player.Name, userId=player.UserId })
	else
		if self._playerList[uid] then self._playerList[uid].left = os.time() end
		self:Log("PLAYER_LEAVE", { name=player.Name, userId=player.UserId })
	end
end

function SessionData:SaveEventLog()
	if #self._events == 0 then return end
	local key = "EventLog_" .. SERVER_ID .. "_" .. tostring(SERVER_START)
	local ok, err = pcall(function()
		EventLogStore:SetAsync(key, {
			serverId=SERVER_ID, placeId=SERVER_PLACE,
			startTime=SERVER_START, endTime=os.time(),
			playerList=self._playerList, events=self._events,
		})
	end)
	if ok then print("SessionData: Event log saved — " .. #self._events .. " events")
	else warn("SessionData: Event log save failed — " .. tostring(err)) end
end

-- ════════════════════════════════════════════
--           LIVE DATA
-- ════════════════════════════════════════════

local LiveData = {}

function LiveData:Set(key, value, ttl)
	ttl = ttl or 300
	local ok, err = pcall(function()
		MemoryLive:SetAsync(key, { value=value, setBy=SERVER_ID, setAt=os.time() }, ttl)
	end)
	if not ok then warn("LiveData:Set failed — " .. tostring(err)) end
end
function LiveData:Get(key)
	local ok, r = pcall(function() return MemoryLive:GetAsync(key) end)
	if ok and r then return r.value, r.setAt end
	return nil, nil
end
function LiveData:Delete(key)
	pcall(function() MemoryLive:RemoveAsync(key) end)
end
function LiveData:Update(key, fn, ttl)
	ttl = ttl or 300
	pcall(function()
		MemoryLive:UpdateAsync(key, function(old)
			local cur = old and old.value or nil
			local nv = fn(cur)
			if nv == nil then return nil end
			return { value=nv, setBy=SERVER_ID, setAt=os.time() }
		end, ttl)
	end)
end

-- ════════════════════════════════════════════
--           GLOBAL DATA
-- ════════════════════════════════════════════

local GlobalData = {}
GlobalData._cache = {}

local GLOBAL_TYPES = {
	number=true, value=true, adminMessage=true,
	shopPrice=true, eventState=true,
}

function GlobalData:Set(dataType, key, value)
	if not GLOBAL_TYPES[dataType] then
		warn("GlobalData: Type khong hop le — " .. tostring(dataType)); return false
	end
	local fullKey = dataType .. "_" .. key
	local memOk, memErr = pcall(function()
		MemoryGlobal:SetAsync(fullKey, {
			value=value, type=dataType, setBy=SERVER_ID, setAt=os.time()
		}, 86400)
	end)
	if not memOk then warn("GlobalData:Set Memory failed — " .. tostring(memErr)) end
	if dataType == "shopPrice" or dataType == "eventState" then
		local dsOk, dsErr = pcall(function()
			GlobalStore:SetAsync(fullKey, { value=value, setAt=os.time() })
		end)
		if not dsOk then warn("GlobalData:Set DataStore failed — " .. tostring(dsErr)) end
	end
	self._cache[fullKey] = { value=value, time=os.time() }
	pcall(function()
		MessagingService:PublishAsync("GlobalUpdate",{
			type=dataType, key=key, value=value, setBy=SERVER_ID
		})
	end)
	return memOk
end

function GlobalData:Get(dataType, key)
	local fullKey = dataType .. "_" .. key
	local cached = self._cache[fullKey]
	if cached and (os.time()-cached.time)<5 then return cached.value end
	local ok, r = pcall(function() return MemoryGlobal:GetAsync(fullKey) end)
	if ok and r then self._cache[fullKey]={value=r.value,time=os.time()}; return r.value end
	local ok2, s = pcall(function() return GlobalStore:GetAsync(fullKey) end)
	if ok2 and s then return s.value end
	return nil
end

function GlobalData:Increment(key, amount)
	local fullKey = "number_" .. key
	pcall(function()
		MemoryGlobal:UpdateAsync(fullKey, function(old)
			return { value=(old and old.value or 0)+amount, type="number", setBy=SERVER_ID, setAt=os.time() }
		end, 86400)
	end)
	pcall(function()
		MessagingService:PublishAsync("GlobalUpdate",{
			type="number", key=key, amount=amount, op="increment", setBy=SERVER_ID
		})
	end)
end

function GlobalData:AdminBroadcast(message, duration)
	duration = duration or 60
	self:Set("adminMessage","current",{message=message,duration=duration,sentAt=os.time()})
	pcall(function()
		MessagingService:PublishAsync("AdminBroadcast",{
			message=message, duration=duration, sentAt=os.time()
		})
	end)
end

-- ════════════════════════════════════════════
--           CONFLICT RESOLVER
-- ════════════════════════════════════════════

local ConflictResolver = {}

function ConflictResolver:SaveExitStamp(player)
	pcall(function()
		MemorySession:SetAsync("Exit_"..player.UserId, {
			userId=player.UserId, exitTime=os.time(),
			serverId=SERVER_ID, placeId=SERVER_PLACE,
		}, 300)
	end)
end

function ConflictResolver:CheckOnJoin(player)
	local ok, info = pcall(function()
		return MemorySession:GetAsync("Exit_"..player.UserId)
	end)
	if not ok or not info then return { conflict=false, reason="no_exit_stamp" } end
	if info.serverId ~= SERVER_ID then
		local diff = os.time() - info.exitTime
		if diff < 30 then
			return { conflict=true, reason="recent_server_switch",
				exitTime=info.exitTime, fromServer=info.serverId, timeDiff=diff }
		end
	end
	return { conflict=false, reason="safe" }
end

function ConflictResolver:MergeData(localData, remoteData)
	if not remoteData then return localData end
	if not localData  then return remoteData end
	local merged, allSections = {}, {}
	for s in pairs(localData)  do allSections[s]=true end
	for s in pairs(remoteData) do allSections[s]=true end
	for section in pairs(allSections) do
		merged[section] = {}
		local lf = localData[section]  or {}
		local rf = remoteData[section] or {}
		local allKeys = {}
		for k in pairs(lf) do allKeys[k]=true end
		for k in pairs(rf) do allKeys[k]=true end
		for key in pairs(allKeys) do
			local lv, rv = lf[key], rf[key]
			if rv == nil then merged[section][key] = lv
			elseif lv == nil then merged[section][key] = rv
			elseif type(lv)=="number" and type(rv)=="number" then merged[section][key]=math.max(lv,rv)
			else merged[section][key] = rv end
		end
	end
	return merged
end

-- ════════════════════════════════════════════
--           SCHEDULED DATA
-- ════════════════════════════════════════════

local ScheduledData = {}
ScheduledData._jobs      = {}
ScheduledData._callbacks = {}

local function resolveTime(t)
	if type(t) == "number" then return t end
	if type(t) == "string" then return TimeUtil.toTimestamp(t) end
	if type(t) == "table"  then
		return TimeUtil.toTimestamp(t.year,t.month,t.day,t.hour or 0,t.minute or 0,t.second or 0)
	end
	return nil
end

function ScheduledData:Register(jobId, dataType, payload, startTime, endTime, meta)
	if not GLOBAL_TYPES[dataType] then
		warn("ScheduledData: dataType khong hop le — "..tostring(dataType)); return false
	end
	local st = resolveTime(startTime)
	local et = endTime and resolveTime(endTime) or nil
	if not st then warn("ScheduledData: startTime khong hop le"); return false end
	if et and et <= st then warn("ScheduledData: endTime phai sau startTime"); return false end
	local job = {
		jobId=jobId, dataType=dataType, payload=payload,
		startTime=st, endTime=et, meta=meta or {},
		status="pending", createdAt=os.time(), createdBy=SERVER_ID,
	}
	local dsOk, dsErr = pcall(function() ScheduledStore:SetAsync("Job_"..jobId, job) end)
	if not dsOk then warn("ScheduledData:Register DS failed — "..tostring(dsErr)); return false end
	local ttl = et and math.max(et-os.time()+300,60) or 86400*7
	pcall(function() MemoryScheduled:SetAsync("Job_"..jobId, job, ttl) end)
	self._jobs[jobId] = job
	print(string.format("ScheduledData: [%s] registered -> %s", jobId, TimeUtil.format(st)))
	return true
end

function ScheduledData:Cancel(jobId)
	local job = self._jobs[jobId]
	if not job then warn("ScheduledData: job khong ton tai — "..tostring(jobId)); return false end
	if job.status=="active" or job.status=="ended" then
		warn("ScheduledData: khong the huy job da "..job.status); return false
	end
	job.status = "cancelled"
	pcall(function() MemoryScheduled:RemoveAsync("Job_"..jobId) end)
	pcall(function()
		ScheduledStore:UpdateAsync("Job_"..jobId, function(o)
			if o then o.status="cancelled" end; return o
		end)
	end)
	self._jobs[jobId] = nil
	return true
end

function ScheduledData:UpdateActive(jobId, newPayload)
	local job = self._jobs[jobId]
	if not job or job.status~="active" then
		warn("ScheduledData: job khong active — "..tostring(jobId)); return false
	end
	job.payload = newPayload
	GlobalData:Set(job.dataType, jobId, newPayload)
	local rem = job.endTime and math.max(job.endTime-os.time()+60,60) or 86400
	pcall(function() MemoryScheduled:SetAsync("Job_"..jobId, job, rem) end)
	pcall(function()
		ScheduledStore:UpdateAsync("Job_"..jobId, function(o)
			if o then o.payload=newPayload end; return o
		end)
	end)
	return true
end

function ScheduledData:OnFired(jobId, cb) self._callbacks[jobId] = cb end
function ScheduledData:GetJob(jobId) return self._jobs[jobId] end
function ScheduledData:GetAll(fs)
	local r={}
	for id,j in pairs(self._jobs) do
		if not fs or j.status==fs then r[id]=j end
	end
	return r
end

local function _fireJob(job)
	job.status="active"; job.firedAt=os.time()
	GlobalData:Set(job.dataType, job.jobId, job.payload)
	pcall(function()
		MessagingService:PublishAsync("ScheduledFired",{
			jobId=job.jobId, dataType=job.dataType, payload=job.payload, firedAt=job.firedAt
		})
	end)
	local cb = ScheduledData._callbacks[job.jobId]
	if cb then task.spawn(cb, job) end
	for _, p in Players:GetPlayers() do
		RE_ScheduledFired:FireClient(p,{jobId=job.jobId,dataType=job.dataType,payload=job.payload})
	end
	pcall(function()
		ScheduledStore:UpdateAsync("Job_"..job.jobId, function(o)
			if o then o.status="active"; o.firedAt=job.firedAt end; return o
		end)
	end)
	SessionData:Log("SCHEDULED_FIRED",{jobId=job.jobId,dataType=job.dataType})
	print(string.format("ScheduledData: FIRED [%s]", job.jobId))
end

local function _endJob(job)
	job.status="ended"; job.endedAt=os.time()
	GlobalData:Set(job.dataType, job.jobId, nil)
	pcall(function()
		MessagingService:PublishAsync("ScheduledEnded",{jobId=job.jobId,endedAt=job.endedAt})
	end)
	pcall(function()
		ScheduledStore:UpdateAsync("Job_"..job.jobId, function(o)
			if o then o.status="ended"; o.endedAt=job.endedAt end; return o
		end)
	end)
	SessionData:Log("SCHEDULED_ENDED",{jobId=job.jobId})
	print(string.format("ScheduledData: ENDED [%s]", job.jobId))
end

local function _loadPersistedJobs()
	local ok, pages = pcall(function()
		return MemoryScheduled:GetRangeAsync(Enum.SortDirection.Ascending, 50)
	end)
	if ok and pages then
		for _, e in ipairs(pages) do
			local j = e.value
			if j and j.jobId and (j.status=="pending" or j.status=="active") then
				ScheduledData._jobs[j.jobId] = j
			end
		end
	end
end

task.spawn(function()
	task.wait(5)
	_loadPersistedJobs()
	while true do
		task.wait(5)
		local now = os.time()
		for id, job in pairs(ScheduledData._jobs) do
			if job.status=="pending" and now >= job.startTime then
				_fireJob(job)
			elseif job.status=="active" and job.endTime and now >= job.endTime then
				_endJob(job)
				ScheduledData._jobs[id] = nil
			end
		end
	end
end)

-- ════════════════════════════════════════════
--  RANDOM DATA
-- ════════════════════════════════════════════

local RandomData = {}
RandomData._pools = {}
RandomData._rng   = Random.new()

local function weightedPick(items, rng)
	local total = 0
	for _, item in ipairs(items) do total += (item.weight or 1) end
	local roll = (rng or RandomData._rng):NextNumber() * total
	for _, item in ipairs(items) do
		roll -= (item.weight or 1)
		if roll <= 0 then return item end
	end
	return items[#items]
end

local function makeSeededRng(seed)
	if type(seed) == "string" then
		local h = 0
		for i = 1, #seed do h = h * 31 + string.byte(seed, i) end
		return Random.new(h)
	end
	return Random.new(seed)
end

function RandomData:RegisterPool(poolId, config)
	self._pools[poolId] = config
	print("RandomData: Pool registered — " .. poolId)
end

function RandomData:FromList(items)
	if not items or #items == 0 then return nil end
	return items[self._rng:NextInteger(1, #items)]
end

function RandomData:InRange(min, max, isFloat)
	if isFloat then return self._rng:NextNumber(min, max) end
	return self._rng:NextInteger(math.floor(min), math.floor(max))
end

function RandomData:Weighted(items)
	return weightedPick(items)
end

function RandomData:WeightedMulti(items, count)
	local results = {}
	for i = 1, count do results[i] = weightedPick(items) end
	return results
end

function RandomData:Seeded(seed, mode, args)
	local rng = makeSeededRng(seed)
	if mode == "list" then
		local items = args[1]
		return items[rng:NextInteger(1, #items)]
	elseif mode == "range" then
		if args[3] then return rng:NextNumber(args[1], args[2])
		else return rng:NextInteger(math.floor(args[1]), math.floor(args[2])) end
	elseif mode == "weighted" then
		return weightedPick(args[1], rng)
	end
	return nil
end

function RandomData:BonusStack(config)
	local base = self:InRange(config.base.min, config.base.max, config.base.isFloat)
	local total = base
	local breakdown = { { name="base", value=base } }
	for _, bonus in ipairs(config.bonuses or {}) do
		local bval
		if bonus.weighted then
			local picked = weightedPick(bonus.items)
			bval = picked and (picked.value or 0) or 0
		elseif bonus.min and bonus.max then
			bval = self:InRange(bonus.min, bonus.max, bonus.isFloat)
		else
			bval = bonus.value or 0
		end
		total += bval
		table.insert(breakdown, { name=bonus.name, value=bval })
	end
	return { total=total, base=base, breakdown=breakdown }
end

function RandomData:Roll(poolId, overrides)
	local config = self._pools[poolId]
	if not config then
		warn("RandomData: Pool khong ton tai — " .. tostring(poolId)); return nil
	end
	if overrides then
		config = table.clone(config)
		for k, v in pairs(overrides) do config[k] = v end
	end
	local mode = config.mode
	if mode == "list"         then return self:FromList(config.items)
	elseif mode == "range"    then return self:InRange(config.min, config.max, config.isFloat)
	elseif mode == "weighted" then return self:Weighted(config.items)
	elseif mode == "seeded"   then return self:Seeded(config.seed, config.seedMode, config.args)
	elseif mode == "bonusStack" then return self:BonusStack(config) end
	warn("RandomData: mode khong hop le — " .. tostring(mode)); return nil
end

-- ════════════════════════════════════════════
--  GAME EVENT LOG
-- ════════════════════════════════════════════

local GameEventLog = {}
GameEventLog._sessions = {}

function GameEventLog:StartSession(player)
	local uid = tostring(player.UserId)
	local snapshot = nil
	local ok, snap = pcall(function()
		return PlayerSnapStore:GetAsync("Snap_" .. uid)
	end)
	if ok and snap then snapshot = snap end

	self._sessions[uid] = {
		userId       = player.UserId,
		name         = player.Name,
		sessionStart = os.time(),
		lastSeen     = os.time(),
		events       = {},
		checkpoint   = snapshot and snapshot.checkpoint or nil,
		position     = snapshot and snapshot.position   or nil,
		customData   = snapshot and snapshot.customData or {},
		isResumed    = snapshot ~= nil,
	}

	self:Push(player, "SESSION_START", {
		resumed    = snapshot ~= nil,
		checkpoint = self._sessions[uid].checkpoint,
	})

	if snapshot then
		print(string.format("GameEventLog: [%s] RESUMED tu checkpoint [%s]",
			player.Name, tostring(snapshot.checkpoint)))
	end
	return self._sessions[uid]
end

function GameEventLog:Push(player, eventType, data)
	local uid = tostring(player.UserId)
	local session = self._sessions[uid]
	if not session then
		warn("GameEventLog: Khong co session cho " .. player.Name); return
	end
	local event = {
		type    = eventType,
		data    = data or {},
		time    = os.time(),
		elapsed = os.time() - session.sessionStart,
	}
	table.insert(session.events, event)
	session.lastSeen = os.time()
	RE_GameEvent:FireClient(player, { type=eventType, data=data })
end

function GameEventLog:UpdateSnapshot(player, position, checkpoint, customData)
	local uid = tostring(player.UserId)
	local session = self._sessions[uid]
	if not session then return end
	if position   then session.position   = position   end
	if checkpoint then session.checkpoint = checkpoint end
	if customData then
		for k, v in pairs(customData) do session.customData[k] = v end
	end
	session.lastSeen = os.time()
	task.spawn(function()
		pcall(function()
			PlayerSnapStore:SetAsync("Snap_" .. uid, {
				userId     = player.UserId,
				name       = player.Name,
				checkpoint = session.checkpoint,
				position   = session.position,
				customData = session.customData,
				savedAt    = os.time(),
				serverId   = SERVER_ID,
			})
		end)
	end)
end

function GameEventLog:GetSnapshot(player)
	local uid = tostring(player.UserId)
	local session = self._sessions[uid]
	if session then
		return {
			checkpoint = session.checkpoint,
			position   = session.position,
			customData = session.customData,
			isResumed  = session.isResumed,
		}
	end
	local ok, snap = pcall(function()
		return PlayerSnapStore:GetAsync("Snap_" .. uid)
	end)
	if ok and snap then return snap end
	return nil
end

function GameEventLog:ClearSnapshot(player)
	local uid = tostring(player.UserId)
	if self._sessions[uid] then
		self._sessions[uid].checkpoint = nil
		self._sessions[uid].position   = nil
		self._sessions[uid].customData = {}
	end
	pcall(function() PlayerSnapStore:RemoveAsync("Snap_" .. uid) end)
end

function GameEventLog:EndSession(player)
	local uid = tostring(player.UserId)
	local session = self._sessions[uid]
	if not session then return end
	self:Push(player, "SESSION_END", {
		totalTime = os.time() - session.sessionStart,
		events    = #session.events,
	})
	local sessionKey = string.format("Session_%s_%s", uid, tostring(SERVER_START))
	task.spawn(function()
		local ok, err = pcall(function()
			GameEventStore:SetAsync(sessionKey, {
				userId          = player.UserId,
				name            = player.Name,
				serverId        = SERVER_ID,
				sessionStart    = session.sessionStart,
				sessionEnd      = os.time(),
				totalTime       = os.time() - session.sessionStart,
				events          = session.events,
				finalCheckpoint = session.checkpoint,
				finalPosition   = session.position,
				customData      = session.customData,
			})
		end)
		if not ok then warn("GameEventLog: Save failed — " .. tostring(err)) end
	end)
	self._sessions[uid] = nil
end

function GameEventLog:GetSession(player)
	return self._sessions[tostring(player.UserId)]
end

function GameEventLog:GetSessionTime(player)
	local s = self._sessions[tostring(player.UserId)]
	return s and (os.time() - s.sessionStart) or 0
end

-- ════════════════════════════════════════════
--  PLAYER DATA SYSTEM
-- ════════════════════════════════════════════
--
--  Cấu trúc folder trong script (case-insensitive tên "DataStore"):
--
--  Script
--   └── DataStore/                        ← tên bất kỳ (datastore/DATASTORE/DataStore)
--        [Attr] StoreName   = "CoursePlayer"   ← tên DataStore (bắt buộc)
--        [Attr] KeyMode     = "id"               ← "id" | "name" | "seed"
--        [Attr] KeySeed     = "MySeed2025"       ← chỉ dùng khi KeyMode = "seed"
--        [Attr] AutoSave    = true               ← tự lưu mỗi 60 giây
--        [Attr] MaxHistory  = 20                 ← số version lưu tối đa
--        [Attr] SchemaVersion = 2               ← version hiện tại của schema
--        │
--        ├── coins         (NumberValue = 0)
--        │    [Attr] OldName  = "gold"           ← tên data cũ cần migrate
--        │    [Attr] Min      = 0                ← giới hạn tối thiểu
--        │    [Attr] Max      = 999999           ← giới hạn tối đa
--        │    [Attr] ReadOnly = false            ← không cho phép Set từ client
--        │
--        ├── level         (NumberValue = 1)
--        │    [Attr] Min = 1; [Attr] Max = 100
--        │
--        ├── username      (StringValue = "")
--        │    [Attr] OldName = "playerName"
--        │
--        ├── isPremium     (BoolValue = false)
--        │
--        ├── inventory     (Folder)             ← sub-table
--        │    sword   (BoolValue = false)
--        │    shield  (BoolValue = false)
--        │
--        └── stats         (Folder)
--              kills  (NumberValue = 0)
--              deaths (NumberValue = 0)
--
--  ─────────────────────────────────────────────
--  3 Hình thức KeyMode:
--    "id"   → key = StoreName .. "_" .. UserId
--             Ví dụ: "CoursePlayer_123456789"
--    "name" → key = StoreName .. "_" .. PlayerName (lower)
--             Ví dụ: "CoursePlayer_heroname"
--    "seed" → key = StoreName .. "_" .. hash(KeySeed .. UserId)
--             Ví dụ: "CoursePlayer_a3f9c2" (obfuscated)
--
--  Bạn có thể bật/tắt từng mode bằng [Attr] AllowId / AllowName / AllowSeed
--  và chọn mode active bằng [Attr] KeyMode
-- ════════════════════════════════════════════

local PlayerData = {}
PlayerData._cache       = {}   -- { [userId] = { data, key, storeName, meta } }
PlayerData._schemas     = {}   -- { [storeName] = schemaTable }
PlayerData._stores      = {}   -- { [storeName] = DataStore object }
PlayerData._configs     = {}   -- { [storeName] = configTable }
PlayerData._dirty       = {}   -- { [userId_storeName] = true } cần save
PlayerData._bonuses     = {}   -- { [userId_storeName] = { [fieldPath] = { {name,flat,mult}, ... } } }

-- ────────────────────────────────────────────
--  HELPER: đọc value object
-- ────────────────────────────────────────────
local function _readVal(obj)
	local cn = obj.ClassName
	if cn == "StringValue"  then return obj.Value
	elseif cn == "NumberValue"  then return obj.Value
	elseif cn == "BoolValue"    then return obj.Value
	elseif cn == "IntValue"     then return obj.Value
	elseif cn == "Color3Value"  then return obj.Value
	elseif cn == "Vector3Value" then return { x=obj.Value.X, y=obj.Value.Y, z=obj.Value.Z }
	elseif cn == "CFrameValue"  then
		local cf = obj.Value
		return { px=cf.X, py=cf.Y, pz=cf.Z }
	end
	return nil
end

local function _readAttrs(inst)
	local ok, result = pcall(function() return inst:GetAttributes() end)
	return ok and result or {}
end

-- ────────────────────────────────────────────
--  HELPER: đọc schema từ folder đệ quy
--  Trả về { defaults, meta }
--  defaults = giá trị mặc định
--  meta     = { [fieldName] = { oldName, min, max, readOnly, ... } }
-- ────────────────────────────────────────────
local function _readSchema(folder)
	local defaults = {}
	local meta     = {}

	for _, child in ipairs(folder:GetChildren()) do
		local val = _readVal(child)
		if val ~= nil then
			-- Value object → field đơn giản
			defaults[child.Name] = val
			local attrs = _readAttrs(child)
			meta[child.Name] = {
				oldName   = attrs.OldName   or nil,
				min       = attrs.Min       or nil,
				max       = attrs.Max       or nil,
				readOnly  = attrs.ReadOnly  or false,
				default   = val,
				type      = child.ClassName,
				bonusFlat = attrs.BonusFlat or 0,   -- cộng thêm flat cố định từ schema
				bonusMult = attrs.BonusMult or 1,   -- nhân hệ số cố định từ schema
			}
		elseif child:IsA("Folder") then
			-- Folder → sub-table đệ quy
			local sub, subMeta = _readSchema(child)
			defaults[child.Name] = sub
			meta[child.Name] = {
				isTable  = true,
				subMeta  = subMeta,
				default  = sub,
			}
		end
	end

	return defaults, meta
end

-- ────────────────────────────────────────────
--  HELPER: sinh key theo KeyMode
-- ────────────────────────────────────────────
local function _makeHash(str)
	local h = 5381
	for i = 1, #str do
		h = (h * 33 + string.byte(str, i)) % 2147483647
	end
	return string.format("%x", h)
end

function PlayerData._buildKey(config, player)
	local mode  = (config.keyMode or "id"):lower()
	local store = config.storeName

	-- kiểm tra mode có được bật không
	if mode == "id" and config.allowId == false then
		warn("PlayerData: KeyMode 'id' bị tắt trong config"); return nil
	end
	if mode == "name" and config.allowName == false then
		warn("PlayerData: KeyMode 'name' bị tắt trong config"); return nil
	end
	if mode == "seed" and config.allowSeed == false then
		warn("PlayerData: KeyMode 'seed' bị tắt trong config"); return nil
	end

	if mode == "id" then
		-- Hình thức 1: UserId
		return store .. "_" .. tostring(player.UserId)

	elseif mode == "name" then
		-- Hình thức 2: Tên player (lowercase để nhất quán)
		return store .. "_" .. player.Name:lower()

	elseif mode == "seed" then
		-- Hình thức 3: Hash từ seed + UserId (obfuscated, reproducible)
		local seed = config.keySeed or "DEFAULT_SEED"
		local raw  = seed .. tostring(player.UserId)
		return store .. "_" .. _makeHash(raw)
	end

	-- fallback về id
	return store .. "_" .. tostring(player.UserId)
end

-- ────────────────────────────────────────────
--  HELPER: áp dụng giới hạn min/max
--  Quy ước:
--    Max = -1        → không giới hạn trên (infinite)
--    Max = math.huge → không giới hạn trên (infinite)
--    Min = -1        → không giới hạn dưới (infinite âm)
--    Không đặt attr  → không giới hạn (nil)
-- ────────────────────────────────────────────
local INF = math.huge
local function _isInfinite(v)
	return v == nil or v == -1 or v == INF or v == -INF
end

local function _clamp(value, fieldMeta)
	if not fieldMeta then return value end
	if type(value) ~= "number" then return value end
	-- clamp min
	if not _isInfinite(fieldMeta.min) and value < fieldMeta.min then
		value = fieldMeta.min
	end
	-- clamp max
	if not _isInfinite(fieldMeta.max) and value > fieldMeta.max then
		value = fieldMeta.max
	end
	return value
end

-- ────────────────────────────────────────────
--  HELPER: deep copy table
-- ────────────────────────────────────────────
local function _deepCopy(t)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t) do copy[k] = _deepCopy(v) end
	return copy
end

-- ────────────────────────────────────────────
--  HELPER: merge defaults vào data (điền field còn thiếu)
-- ────────────────────────────────────────────
local function _applyDefaults(data, defaults)
	for k, defaultVal in pairs(defaults) do
		if data[k] == nil then
			data[k] = _deepCopy(defaultVal)
		elseif type(defaultVal) == "table" and type(data[k]) == "table" then
			_applyDefaults(data[k], defaultVal)
		end
	end
	return data
end

-- ────────────────────────────────────────────
--  HELPER: OldData migration
--  Tìm field cũ (oldName) trong raw data và gán sang field mới
-- ────────────────────────────────────────────
local function _migrateOldData(data, meta)
	for newName, fieldMeta in pairs(meta) do
		if fieldMeta.oldName and data[newName] == nil then
			local oldVal = data[fieldMeta.oldName]
			if oldVal ~= nil then
				data[newName] = oldVal
				data[fieldMeta.oldName] = nil  -- xóa key cũ
				print(string.format("PlayerData: Migrated '%s' → '%s'",
					fieldMeta.oldName, newName))
			end
		end
		-- đệ quy vào sub-table
		if fieldMeta.isTable and fieldMeta.subMeta and type(data[newName]) == "table" then
			_migrateOldData(data[newName], fieldMeta.subMeta)
		end
	end
	return data
end

-- ════════════════════════════════════════════
--  BONUS SYSTEM
--  Công thức: (rawValue + totalFlat) × totalMult
--  bonusFlat / bonusMult từ schema = bonus cố định (attribute trong Studio)
--  AddBonus runtime = stack thêm bonus tạm thời (VIP, event, buff...)
-- ════════════════════════════════════════════

-- Tính tổng bonus từ schema + stack runtime
local function _calcBonus(rawValue, fieldMeta, stack)
	if type(rawValue) ~= "number" then return rawValue end
	local totalFlat = fieldMeta and (fieldMeta.bonusFlat or 0) or 0
	local totalMult = fieldMeta and (fieldMeta.bonusMult or 1) or 1
	for _, b in ipairs(stack or {}) do
		totalFlat += (b.flat or 0)
		totalMult *= (b.mult or 1)
	end
	return (rawValue + totalFlat) * totalMult
end

-- Helper: lấy fieldMeta theo dot-notation ("stats.kills")
local function _getFieldMeta(schema, fieldPath)
	local meta = schema.meta
	for part in fieldPath:gmatch("[^%.]+") do
		if not meta then return nil end
		local node = meta[part]
		if not node then return nil end
		if node.isTable then
			meta = node.subMeta
		else
			return node
		end
	end
	return nil
end

-- ── Thêm bonus runtime vào 1 field (stack được nhiều cái) ──
function PlayerData:AddBonus(player, storeName, fieldPath, bonusName, flat, mult)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	if not self._bonuses[cacheKey] then self._bonuses[cacheKey] = {} end
	if not self._bonuses[cacheKey][fieldPath] then self._bonuses[cacheKey][fieldPath] = {} end
	local stack = self._bonuses[cacheKey][fieldPath]
	-- Nếu tên bonus đã có → ghi đè
	for i, b in ipairs(stack) do
		if b.name == bonusName then
			stack[i] = { name=bonusName, flat=flat or 0, mult=mult or 1 }
			print(string.format("[Bonus] ✏️  Cập nhật '%s' trên %s.%s | flat=%s mult=%s",
				bonusName, storeName, fieldPath, tostring(flat), tostring(mult)))
			return
		end
	end
	table.insert(stack, { name=bonusName, flat=flat or 0, mult=mult or 1 })
	print(string.format("[Bonus] ➕ Thêm '%s' vào %s.%s | flat=%s mult=%s",
		bonusName, storeName, fieldPath, tostring(flat), tostring(mult)))
end

-- ── Xóa 1 bonus cụ thể ──
function PlayerData:RemoveBonus(player, storeName, fieldPath, bonusName)
	local uid   = tostring(player.UserId)
	local stack = self._bonuses[uid.."_"..storeName]
		and self._bonuses[uid.."_"..storeName][fieldPath]
	if not stack then return end
	for i, b in ipairs(stack) do
		if b.name == bonusName then
			table.remove(stack, i)
			print(string.format("[Bonus] ➖ Xóa '%s' khỏi %s.%s", bonusName, storeName, fieldPath))
			return
		end
	end
end

-- ── Xóa toàn bộ bonus của 1 field ──
function PlayerData:ClearBonus(player, storeName, fieldPath)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	if self._bonuses[cacheKey] then
		self._bonuses[cacheKey][fieldPath] = nil
		print(string.format("[Bonus] 🗑️  Clear bonus của %s.%s", storeName, fieldPath))
	end
end

-- ── Lấy danh sách bonus hiện tại của 1 field ──
function PlayerData:GetBonusList(player, storeName, fieldPath)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	return (self._bonuses[cacheKey] and self._bonuses[cacheKey][fieldPath]) or {}
end

-- ── Get giá trị đã tính bonus: (raw + flat) × mult ──
function PlayerData:GetWithBonus(player, storeName, fieldPath)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	local schema   = self._schemas[storeName]
	if not cached or not schema then return nil end
	-- Lấy raw value qua dot-notation
	local raw = cached.data
	for part in fieldPath:gmatch("[^%.]+") do
		if type(raw) ~= "table" then return nil end
		raw = raw[part]
	end
	local fieldMeta = _getFieldMeta(schema, fieldPath)
	local stack     = self._bonuses[cacheKey] and self._bonuses[cacheKey][fieldPath] or {}
	return _calcBonus(raw, fieldMeta, stack)
end

-- ── In toàn bộ bonus của player ra Output ──
function PlayerData:PrintBonuses(player, storeName)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local schema   = self._schemas[storeName]
	print("══════════════════════════════════════")
	print(string.format("[Bonus] 📋 %s / %s", player.Name, storeName))
	-- In bonus cố định từ schema
	print("  [Schema Bonus — từ Studio Attributes]")
	if schema then
		local function printSchemaMeta(meta, prefix)
			for fieldName, m in pairs(meta) do
				if m.isTable and m.subMeta then
					printSchemaMeta(m.subMeta, prefix .. fieldName .. ".")
				elseif (m.bonusFlat and m.bonusFlat ~= 0) or (m.bonusMult and m.bonusMult ~= 1) then
					print(string.format("    • %-25s BonusFlat=%-6s BonusMult=%s",
						prefix .. fieldName,
						tostring(m.bonusFlat or 0),
						tostring(m.bonusMult or 1)))
				end
			end
		end
		printSchemaMeta(schema.meta, "")
	end
	-- In bonus runtime
	print("  [Runtime Bonus — AddBonus()]")
	local all = self._bonuses[cacheKey]
	if not all or next(all) == nil then
		print("    (không có bonus runtime nào)")
	else
		for fieldPath, stack in pairs(all) do
			print("    Field: " .. fieldPath)
			for _, b in ipairs(stack) do
				print(string.format("      • %-20s flat=%-6s mult=%s",
					b.name, tostring(b.flat), tostring(b.mult)))
			end
		end
	end
	print("══════════════════════════════════════")
end

-- ────────────────────────────────────────────
--  SCAN FOLDER "DataStore" TRONG SCRIPT
--  Case-insensitive, tìm trong script hiện tại
-- ────────────────────────────────────────────
local function _findDataStoreFolder(script)
	for _, child in ipairs(script:GetChildren()) do
		if child:IsA("Folder") and child.Name:lower() == "datastore" then
			return child
		end
	end
	return nil
end

local function _scanDataStoreFolders(script)
	local results = {}
	-- Tìm tất cả folder tên "datastore" (có thể có nhiều cái)
	for _, child in ipairs(script:GetDescendants()) do
		if child:IsA("Folder") and child.Name:lower() == "datastore" then
			table.insert(results, child)
		end
	end
	return results
end

-- ────────────────────────────────────────────
--  ĐĂNG KÝ DATASTORE TỪ FOLDER
-- ────────────────────────────────────────────
function PlayerData:RegisterFromFolder(folder)
	local attrs = _readAttrs(folder)

	local storeName = attrs.StoreName
	if not storeName or storeName == "" then
		warn("PlayerData: Folder [" .. folder.Name .. "] thiếu attribute StoreName — bỏ qua")
		return false
	end

	local config = {
		storeName     = storeName,
		keyMode       = attrs.KeyMode       or "id",
		keySeed       = attrs.KeySeed       or "DEFAULT_SEED",
		allowId       = attrs.AllowId       ~= false,  -- mặc định true
		allowName     = attrs.AllowName     ~= false,  -- mặc định true
		allowSeed     = attrs.AllowSeed     ~= false,  -- mặc định true
		autoSave      = attrs.AutoSave      ~= false,  -- mặc định true
		maxHistory    = attrs.MaxHistory    or 20,
		schemaVersion = attrs.SchemaVersion or 1,
	}

	-- Đọc schema (defaults + meta) từ children của folder
	local defaults, meta = _readSchema(folder)

	self._configs[storeName] = config
	self._schemas[storeName] = { defaults = defaults, meta = meta }

	-- Tạo hoặc lấy DataStore
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(storeName)
	end)
	if not ok then
		warn("PlayerData: Không tạo được DataStore [" .. storeName .. "]"); return false
	end
	self._stores[storeName] = store

	print(string.format(
		"PlayerData: Đã đăng ký store [%s] | KeyMode=%s | %d fields",
		storeName, config.keyMode, (function()
			local n = 0
			for _ in pairs(defaults) do n += 1 end
			return n
		end)()
		))
	return true
end

-- ────────────────────────────────────────────
--  LOAD DATA PLAYER
-- ────────────────────────────────────────────
function PlayerData:Load(player, storeName)
	local config  = self._configs[storeName]
	local schema  = self._schemas[storeName]
	local store   = self._stores[storeName]

	if not config or not schema or not store then
		warn("PlayerData:Load — store chưa được đăng ký: " .. tostring(storeName))
		return nil
	end

	local key = PlayerData._buildKey(config, player)
	if not key then return nil end

	local uid       = tostring(player.UserId)
	local cacheKey  = uid .. "_" .. storeName

	-- Load từ DataStore
	local ok, raw = pcall(function()
		return store:GetAsync(key)
	end)

	local data
	if ok and raw and type(raw.data) == "table" then
		data = raw.data
		-- Migration OldData
		_migrateOldData(data, schema.meta)
		-- Điền field còn thiếu theo schema mới
		_applyDefaults(data, schema.defaults)
	else
		if not ok then
			warn("PlayerData:Load failed — " .. tostring(raw))
		end
		-- Tạo data mới từ defaults
		data = _deepCopy(schema.defaults)
		print("PlayerData: Tạo data mới cho " .. player.Name .. " / " .. storeName)
	end

	-- Lưu cache
	self._cache[cacheKey] = {
		data      = data,
		key       = key,
		storeName = storeName,
		userId    = player.UserId,
		name      = player.Name,
		loadedAt  = os.time(),
		version   = (ok and raw and raw.version) or 0,
	}

	return data
end

-- ────────────────────────────────────────────
--  SAVE DATA PLAYER
-- ────────────────────────────────────────────
function PlayerData:Save(player, storeName)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	local store    = self._stores[storeName]
	local config   = self._configs[storeName]

	if not cached or not store or not config then
		warn("PlayerData:Save — không có cache cho " .. player.Name .. " / " .. storeName)
		return false
	end

	local newVersion = (cached.version or 0) + 1
	local now        = os.time()

	local payload = {
		data          = cached.data,
		version       = newVersion,
		savedAt       = now,
		savedBy       = SERVER_ID,
		schemaVersion = config.schemaVersion,
		playerName    = player.Name,
		userId        = player.UserId,
	}

	local ok, err = pcall(function()
		store:SetAsync(cached.key, payload)
	end)

	if ok then
		cached.version = newVersion
		self._dirty[cacheKey] = nil
		-- Lưu audit log
		PlayerData:_pushAudit(player, storeName, "SAVE", {
			version = newVersion, savedAt = now
		})
		print(string.format("PlayerData: Saved [%s] v%d", storeName, newVersion))
		return true
	else
		warn("PlayerData:Save failed — " .. tostring(err))
		return false
	end
end

-- ────────────────────────────────────────────
--  GET / SET / INCREMENT / DECREMENT field
-- ────────────────────────────────────────────
function PlayerData:Get(player, storeName, fieldPath)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	if not cached then return nil end

	-- fieldPath có thể là "coins" hoặc "stats.kills" (dot-notation)
	local data = cached.data
	for part in fieldPath:gmatch("[^%.]+") do
		if type(data) ~= "table" then return nil end
		data = data[part]
	end
	return data
end

function PlayerData:Set(player, storeName, fieldPath, value)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	local schema   = self._schemas[storeName]
	if not cached or not schema then return false end

	-- Tìm meta để clamp và check readOnly
	local parts  = {}
	for part in fieldPath:gmatch("[^%.]+") do table.insert(parts, part) end
	local fieldMeta = schema.meta
	for i, part in ipairs(parts) do
		if i == #parts then
			fieldMeta = fieldMeta and fieldMeta[part] or nil
		else
			fieldMeta = fieldMeta and fieldMeta[part] and fieldMeta[part].subMeta or nil
		end
	end

	if fieldMeta and fieldMeta.readOnly then
		warn("PlayerData:Set — field '" .. fieldPath .. "' là readOnly"); return false
	end

	-- Clamp nếu là number
	value = _clamp(value, fieldMeta)

	-- Ghi vào data
	local data = cached.data
	for i, part in ipairs(parts) do
		if i == #parts then
			local old = data[part]
			data[part] = value
			-- Ghi audit
			PlayerData:_pushAudit(player, storeName, "SET", {
				field = fieldPath, old = old, new = value
			})
		else
			if type(data[part]) ~= "table" then data[part] = {} end
			data = data[part]
		end
	end

	self._dirty[cacheKey] = true
	return true
end

function PlayerData:Increment(player, storeName, fieldPath, amount)
	amount = amount or 1
	local current = PlayerData:Get(player, storeName, fieldPath)
	if type(current) ~= "number" then
		warn("PlayerData:Increment — field '" .. fieldPath .. "' không phải number")
		return false
	end
	return PlayerData:Set(player, storeName, fieldPath, current + amount)
end

function PlayerData:Decrement(player, storeName, fieldPath, amount)
	amount = amount or 1
	return PlayerData:Increment(player, storeName, fieldPath, -amount)
end

-- Toggle boolean
function PlayerData:Toggle(player, storeName, fieldPath)
	local current = PlayerData:Get(player, storeName, fieldPath)
	if type(current) ~= "boolean" then
		warn("PlayerData:Toggle — field '" .. fieldPath .. "' không phải boolean")
		return false
	end
	return PlayerData:Set(player, storeName, fieldPath, not current)
end

-- Lấy toàn bộ data của player
function PlayerData:GetAll(player, storeName)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	return cached and _deepCopy(cached.data) or nil
end

-- Reset về defaults
function PlayerData:Reset(player, storeName)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	local schema   = self._schemas[storeName]
	if not cached or not schema then return false end
	cached.data = _deepCopy(schema.defaults)
	self._dirty[cacheKey] = true
	PlayerData:_pushAudit(player, storeName, "RESET", {})
	return true
end

-- Xóa data khỏi DataStore (GDPR / wipe)
function PlayerData:Wipe(player, storeName)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	local store    = self._stores[storeName]
	if not cached or not store then return false end
	local ok, err = pcall(function()
		store:RemoveAsync(cached.key)
	end)
	if ok then
		self._cache[cacheKey] = nil
		self._dirty[cacheKey] = nil
		print("PlayerData: Wiped data cho " .. player.Name .. " / " .. storeName)
		return true
	else
		warn("PlayerData:Wipe failed — " .. tostring(err))
		return false
	end
end

-- ────────────────────────────────────────────
--  HISTORY & AUDIT LOG
-- ────────────────────────────────────────────

-- Lưu audit entry (nội bộ)
function PlayerData:_pushAudit(player, storeName, action, detail)
	local uid       = tostring(player.UserId)
	local auditKey  = "Audit_" .. uid .. "_" .. storeName
	task.spawn(function()
		pcall(function()
			AuditLogStore:UpdateAsync(auditKey, function(old)
				local log = old or { entries = {}, userId = player.UserId, name = player.Name }
				local config = PlayerData._configs[storeName]
				local maxH   = config and config.maxHistory or 20
				table.insert(log.entries, {
					action    = action,
					detail    = detail,
					time      = os.time(),
					serverId  = SERVER_ID,
					storeName = storeName,
				})
				-- cắt bớt nếu vượt maxHistory
				while #log.entries > maxH do
					table.remove(log.entries, 1)
				end
				return log
			end)
		end)
	end)
end

-- Lấy lịch sử thay đổi của player (audit log)
function PlayerData:GetHistory(player, storeName)
	local uid      = tostring(player.UserId)
	local auditKey = "Audit_" .. uid .. "_" .. storeName
	local ok, log  = pcall(function()
		return AuditLogStore:GetAsync(auditKey)
	end)
	if ok and log then return log.entries or {} end
	return {}
end

-- Lấy version hiện tại
function PlayerData:GetVersion(player, storeName)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	return cached and cached.version or nil
end

-- Xem data tại version cũ (dùng DataStore VersionHistory nếu game bật)
function PlayerData:GetVersionedData(player, storeName, timestamp)
	local uid    = tostring(player.UserId)
	local config = self._configs[storeName]
	local store  = self._stores[storeName]
	if not config or not store then return nil end
	local key = PlayerData._buildKey(config, player)
	local ok, pages = pcall(function()
		return store:ListVersionsAsync(key, nil, nil, timestamp, timestamp, 1)
	end)
	if not ok then
		warn("PlayerData:GetVersionedData failed — " .. tostring(pages))
		return nil
	end
	local items = pages:GetCurrentPage()
	if #items == 0 then return nil end
	local vOk, vData = pcall(function()
		return store:GetVersionAsync(key, items[1].Version)
	end)
	return vOk and vData or nil
end

-- ────────────────────────────────────────────
--  CHECK DATA
-- ────────────────────────────────────────────

-- Kiểm tra player đã load data chưa
function PlayerData:IsLoaded(player, storeName)
	local uid = tostring(player.UserId)
	return self._cache[uid .. "_" .. storeName] ~= nil
end

-- Lấy thống kê cache
function PlayerData:GetCacheInfo(player, storeName)
	local uid      = tostring(player.UserId)
	local cacheKey = uid .. "_" .. storeName
	local cached   = self._cache[cacheKey]
	if not cached then return nil end
	return {
		key       = cached.key,
		storeName = cached.storeName,
		version   = cached.version,
		loadedAt  = cached.loadedAt,
		isDirty   = self._dirty[cacheKey] == true,
	}
end

-- ════════════════════════════════════════════
--  INLINE CONFIG — setup ngay trong script
--  (không cần folder trong Studio)
--
--  Cách dùng:
--    1. Sửa PLAYER_STORES bên dưới
--    2. Mỗi entry là 1 DataStore với schema đầy đủ
--    3. Chạy game → tự đăng ký, tự load/save cho player
--
--  Cú pháp field:
--    fieldName = { default=<giá trị>, min=<số/-1>, max=<số/-1>, oldName="<tênCũ>", readOnly=<bool> }
--
--  Sub-table:
--    inventory = { _isTable=true, sword={default=false}, shield={default=false} }
--
--  Giá trị min/max:
--    số cụ thể   → giới hạn thật
--    -1          → không giới hạn (infinite)
--    bỏ trống    → không giới hạn (nil)
-- ════════════════════════════════════════════

local PLAYER_STORES = {

	-- ── Store 1: Data chính của player ──────────────────────────
	{
		-- Cấu hình store
		config = {
			storeName     = "CoursePlayer",  -- tên DataStore thật trên Roblox
			keyMode       = "id",             -- "id" | "name" | "seed"
			keySeed       = "MyGame2025",     -- chỉ dùng khi keyMode = "seed"
			allowId       = true,             -- bật key dạng UserId
			allowName     = true,             -- bật key dạng tên player
			allowSeed     = true,             -- bật key dạng seed hash
			autoSave      = true,             -- tự save mỗi 60s
			maxHistory    = 30,               -- số entry audit giữ lại
			schemaVersion = 1,
		},

		-- Schema: định nghĩa từng field
		-- default = giá trị mặc định khi player mới
		-- min/max = giới hạn (-1 = không giới hạn / bỏ trống = không giới hạn)
		-- oldName = tên field CŨ trong DataStore (tự migrate sang tên mới)
		-- readOnly= true → không cho Set từ bên ngoài
		schema = {
			defaults = {
				coins      = 0,
				gems       = 0,
				level      = 1,
				exp        = 0,
				username   = "",
				isPremium  = false,
				totalKills = 0,
				tradePin   = "",  -- secret: không ai xem được kể cả bản thân
				stats = {
					kills  = 0,
					deaths = 0,
					wins   = 0,
				},
				inventory = {
					sword  = false,
					shield = false,
					bow    = false,
				},
			},
			meta = {
				coins      = { default=0,     min=0,   max=-1,  oldName=nil,          readOnly=false, visibility="public"  },
				gems       = { default=0,     min=0,   max=-1,  oldName="diamonds",   readOnly=false, visibility="public"  },
				level      = { default=1,     min=1,   max=100, oldName=nil,          readOnly=false, visibility="public"  },
				exp        = { default=0,     min=0,   max=-1,  oldName="experience", readOnly=false, visibility="private" },  -- chỉ bản thân xem
				username   = { default="",    min=nil, max=nil, oldName="playerName", readOnly=true,  visibility="public"  },
				isPremium  = { default=false, min=nil, max=nil, oldName=nil,          readOnly=false, visibility="private" },  -- chỉ bản thân xem
				totalKills = { default=0,     min=0,   max=-1,  oldName="kills",      readOnly=false, visibility="public"  },
				tradePin   = { default="",    min=nil, max=nil, oldName=nil,          readOnly=false, visibility="secret"  },  -- không ai xem kể cả bản thân
				stats = {
					isTable = true,
					subMeta = {
						kills  = { default=0, min=0, max=-1, oldName=nil, readOnly=false, visibility="public"  },
						deaths = { default=0, min=0, max=-1, oldName=nil, readOnly=false, visibility="public"  },
						wins   = { default=0, min=0, max=-1, oldName=nil, readOnly=false, visibility="public"  },
					},
				},
				inventory = {
					isTable = true,
					subMeta = {
						sword  = { default=false, readOnly=false, visibility="private" },  -- chỉ bản thân xem
						shield = { default=false, readOnly=false, visibility="private" },
						bow    = { default=false, readOnly=false, visibility="private" },
					},
				},
			},
		},
	},

	-- ── Store 2: Leaderboard / ranking riêng ────────────────────
	-- (Bỏ comment để bật)
	--[[
	{
		config = {
			storeName     = "LeaderData_v1",
			keyMode       = "id",
			autoSave      = true,
			maxHistory    = 10,
			schemaVersion = 1,
		},
		schema = {
			defaults = {
				totalScore = 0,
				rank       = 0,
				badge      = "none",
			},
			meta = {
				totalScore = { default=0,      min=0, max=-1,  oldName="score", readOnly=false },
				rank       = { default=0,      min=0, max=-1,  oldName=nil,     readOnly=true  },
				badge      = { default="none", min=nil,max=nil,oldName=nil,     readOnly=false },
			},
		},
	},
	--]]

}

-- ────────────────────────────────────────────
--  AUTO SCAN KHI KHỞI ĐỘNG
-- ────────────────────────────────────────────
local function _autoScanScript()
	-- Tìm script hiện tại (ModuleScript hoặc Script)
	local script = script
	local folders = _scanDataStoreFolders(script)

	if #folders == 0 then
		print("PlayerData: Không tìm thấy folder 'DataStore' trong script — bỏ qua auto-scan")
		return
	end

	for _, folder in ipairs(folders) do
		print("PlayerData: Tìm thấy folder DataStore — " .. folder:GetFullName())
		PlayerData:RegisterFromFolder(folder)
	end
end

-- ────────────────────────────────────────────
--  AUTO SAVE LOOP
-- ────────────────────────────────────────────
task.spawn(function()
	task.wait(10)  -- chờ server ổn định
	while true do
		task.wait(60)  -- auto save mỗi 60 giây
		for cacheKey, isDirty in pairs(PlayerData._dirty) do
			if isDirty then
				-- parse uid và storeName từ cacheKey
				local uid, storeName = cacheKey:match("^(%d+)_(.+)$")
				if uid and storeName then
					local player = Players:GetPlayerByUserId(tonumber(uid))
					if player then
						PlayerData:Save(player, storeName)
					else
						-- Player đã rời — xóa dirty flag
						PlayerData._dirty[cacheKey] = nil
					end
				end
			end
		end
	end
end)

-- ════════════════════════════════════════════
--  DATA CONFIG — ĐỌC TỪ FOLDER TRONG STUDIO
-- ════════════════════════════════════════════

local DataConfig = {}
DataConfig._loaded = false

local function readValueObject(obj)
	return _readVal(obj)
end

local function readAttributes(inst)
	return _readAttrs(inst)
end

local function readPayloadFolder(folder)
	local payload = {}
	for _, child in ipairs(folder:GetChildren()) do
		local v = readValueObject(child)
		if v ~= nil then
			payload[child.Name] = v
		elseif child:IsA("Folder") then
			payload[child.Name] = readPayloadFolder(child)
		end
	end
	for k, v in pairs(readAttributes(folder)) do
		if payload[k] == nil then payload[k] = v end
	end
	return payload
end

local function loadRandomPools(poolsFolder)
	local attrs    = readAttributes(poolsFolder)
	local autoLoad = attrs.AutoLoad == true

	for _, poolFolder in ipairs(poolsFolder:GetChildren()) do
		if not poolFolder:IsA("Folder") then continue end
		local pa     = readAttributes(poolFolder)
		local mode   = pa.mode or "list"
		local config = { mode=mode }

		if mode == "weighted" or mode == "list" then
			local items = {}
			for _, itemObj in ipairs(poolFolder:GetChildren()) do
				local val = readValueObject(itemObj)
				if val ~= nil then
					local ia = readAttributes(itemObj)
					table.insert(items, { value=val, weight=ia.weight or 1, tier=ia.tier, extra=ia })
				end
			end
			config.items = items

		elseif mode == "range" then
			config.min = pa.min or 0; config.max = pa.max or 100; config.isFloat = pa.isFloat or false

		elseif mode == "seeded" then
			config.seed = pa.seed or poolFolder.Name; config.seedMode = pa.seedMode or "list"
			local items = {}
			for _, itemObj in ipairs(poolFolder:GetChildren()) do
				local val = readValueObject(itemObj)
				if val ~= nil then table.insert(items, val) end
			end
			config.args = { items }

		elseif mode == "bonusStack" then
			config.base = { min=pa.baseMin or 0, max=pa.baseMax or 10, isFloat=pa.baseFloat or false }
			config.bonuses = {}
			local bonusFolder = poolFolder:FindFirstChild("Bonuses")
			if bonusFolder then
				for _, bObj in ipairs(bonusFolder:GetChildren()) do
					local ba    = readAttributes(bObj)
					local bonus = { name=bObj.Name }
					if bObj:IsA("NumberValue") then bonus.value = bObj.Value
					elseif ba.min and ba.max then
						bonus.min = ba.min; bonus.max = ba.max; bonus.isFloat = ba.isFloat
					elseif ba.weighted then
						bonus.weighted = true; bonus.items = {}
						for _, wi in ipairs(bObj:GetChildren()) do
							local wv = readValueObject(wi)
							if wv ~= nil then
								local wa = readAttributes(wi)
								table.insert(bonus.items, { value=wv, weight=wa.weight or 1 })
							end
						end
					end
					table.insert(config.bonuses, bonus)
				end
			end
		end

		if autoLoad then RandomData:RegisterPool(poolFolder.Name, config) end
		print("DataConfig: RandomPool loaded — " .. poolFolder.Name .. " [" .. mode .. "]")
	end
end

local function loadScheduledEvents(schedFolder)
	for _, eventFolder in ipairs(schedFolder:GetChildren()) do
		if not eventFolder:IsA("Folder") then continue end
		local attrs     = readAttributes(eventFolder)
		local dataType  = attrs.dataType  or "eventState"
		local startTime = attrs.startTime
		local endTime   = attrs.endTime

		if not startTime then
			warn("DataConfig: ScheduledEvent [" .. eventFolder.Name .. "] thiếu startTime")
			continue
		end

		local payloadFolder = eventFolder:FindFirstChild("Payload")
		local payload       = payloadFolder and readPayloadFolder(payloadFolder) or {}
		local reserved      = { dataType=true, startTime=true, endTime=true, description=true }
		for k, v in pairs(attrs) do
			if not reserved[k] then payload[k] = v end
		end

		ScheduledData:Register(eventFolder.Name, dataType, payload, startTime, endTime, {
			description = attrs.description or eventFolder.Name,
			source      = "DataConfig",
		})
	end
end

local function loadGlobalDefaults(defaultsFolder)
	for _, obj in ipairs(defaultsFolder:GetChildren()) do
		local v = readValueObject(obj)
		if v == nil then continue end
		local dataType, key = obj.Name:match("^(%w+)_(.+)$")
		if dataType and key and GLOBAL_TYPES[dataType] then
			if GlobalData:Get(dataType, key) == nil then
				GlobalData:Set(dataType, key, v)
				print("DataConfig: GlobalDefault — " .. obj.Name .. " = " .. tostring(v))
			end
		else
			warn("DataConfig: GlobalDefault tên không hợp lệ — " .. obj.Name)
		end
	end
end

-- ── Phần mới: load PlayerDataStores từ DataConfig folder ──
local function loadPlayerDataStores(playerDataFolder)
	for _, storeFolder in ipairs(playerDataFolder:GetChildren()) do
		if storeFolder:IsA("Folder") then
			PlayerData:RegisterFromFolder(storeFolder)
		end
	end
end

function DataConfig:Load()
	if self._loaded then return end
	-- Tìm folder tên "dataconfig" (case-insensitive) ngay trong script
	local root
	for _, child in ipairs(script:GetChildren()) do
		if child:IsA("Folder") and child.Name:lower() == "dataconfig" then
			root = child
			break
		end
	end
	if not root then
		warn("DataConfig: Không tìm thấy folder 'DataConfig' trong script — bỏ qua"); return
	end
	local rootAttrs = readAttributes(root)
	print("DataConfig: Loading... version=" .. tostring(rootAttrs.Version or "?"))

	for _, categoryFolder in ipairs(root:GetChildren()) do
		if not categoryFolder:IsA("Folder") then continue end
		local name = categoryFolder.Name
		if name == "RandomPools" then
			loadRandomPools(categoryFolder)
		elseif name == "ScheduledEvents" then
			loadScheduledEvents(categoryFolder)
		elseif name == "GlobalDefaults" then
			loadGlobalDefaults(categoryFolder)
		elseif name == "PlayerDataStores" then
			-- Mới: đăng ký PlayerData stores từ Studio folder
			loadPlayerDataStores(categoryFolder)
		else
			local data = readPayloadFolder(categoryFolder)
			SessionData:Set("config_" .. name, data)
			print("DataConfig: Custom folder loaded — " .. name)
		end
	end

	self._loaded = true
	print("DataConfig: Load hoàn tất")
end

function DataConfig:Reload()
	self._loaded = false; self:Load()
end

-- ════════════════════════════════════════════
--         MESSAGING SUBSCRIPTIONS
-- ════════════════════════════════════════════

pcall(function()
	MessagingService:SubscribeAsync("GlobalUpdate", function(msg)
		local d = msg.Data
		if d.setBy == SERVER_ID then return end
		local fk = d.type .. "_" .. d.key
		if d.op == "increment" then
			local c = GlobalData._cache[fk]
			GlobalData._cache[fk] = { value=(c and c.value or 0)+(d.amount or 0), time=os.time() }
		else
			GlobalData._cache[fk] = { value=d.value, time=os.time() }
		end
	end)
end)

pcall(function()
	MessagingService:SubscribeAsync("AdminBroadcast", function(msg)
		local d = msg.Data
		for _, p in Players:GetPlayers() do
			RE_AdminMessage:FireClient(p,{message=d.message,duration=d.duration,sentAt=d.sentAt})
		end
	end)
end)

pcall(function()
	MessagingService:SubscribeAsync("ScheduledFired", function(msg)
		local d = msg.Data
		GlobalData._cache[d.dataType.."_"..d.jobId] = { value=d.payload, time=os.time() }
		for _, p in Players:GetPlayers() do RE_ScheduledFired:FireClient(p, d) end
		if ScheduledData._jobs[d.jobId] then
			ScheduledData._jobs[d.jobId].status  = "active"
			ScheduledData._jobs[d.jobId].firedAt = d.firedAt
		end
	end)
end)

pcall(function()
	MessagingService:SubscribeAsync("ScheduledEnded", function(msg)
		local d = msg.Data
		if ScheduledData._jobs[d.jobId] then ScheduledData._jobs[d.jobId] = nil end
	end)
end)

-- ════════════════════════════════════════════
--         PLAYER LIFECYCLE
-- ════════════════════════════════════════════

local function onPlayerAdded(player)
	SessionData:RegisterPlayer(player, true)
	GameEventLog:StartSession(player)

	-- [DataSave] Chờ load session data player xong rồi log
	if DataSave then
		task.spawn(function()
			DataSave:WaitForLoad(player, 10)
			local info = DataSave:GetSessionInfo(player)
			print(string.format("[Data6] DataSave loaded cho %s (phiên %s)",
				player.Name, tostring(info and info.sessionNum or "?")))
		end)
	end

	-- Load data cho tất cả store đã đăng ký (PlayerData hệ thống cũ)
	for storeName in pairs(PlayerData._configs) do
		task.spawn(function()
			PlayerData:Load(player, storeName)
		end)
	end

	local result = ConflictResolver:CheckOnJoin(player)
	if result.conflict then
		warn("Conflict: " .. player.Name .. " — " .. result.reason)
		SessionData:Log("CONFLICT_DETECTED",{
			player=player.Name, userId=player.UserId,
			reason=result.reason, timeDiff=result.timeDiff,
		})
		SessionData:Set("conflict_"..player.UserId, result)
	end
end

local function onPlayerRemoving(player)
	SessionData:RegisterPlayer(player, false)
	ConflictResolver:SaveExitStamp(player)
	GameEventLog:EndSession(player)
	cleanRateTracker(player)

	-- [DataSave] Save session data player (DataSave.PlayerRemoving đã connect sẵn,
	-- gọi thêm :Save() ở đây để đảm bảo save trước khi PlayerData bên dưới chạy)
	if DataSave then
		DataSave:Save(player)
	end

	-- Save & xóa cache tất cả store
	for storeName in pairs(PlayerData._configs) do
		local uid      = tostring(player.UserId)
		local cacheKey = uid .. "_" .. storeName
		if PlayerData._cache[cacheKey] then
			PlayerData:Save(player, storeName)
			PlayerData._cache[cacheKey] = nil
		end
		-- Dọn bonus cache
		PlayerData._bonuses[uid .. "_" .. storeName] = nil
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, p in Players:GetPlayers() do task.spawn(onPlayerAdded, p) end

-- Auto-save snapshot mỗi 60 giây
task.spawn(function()
	while true do
		task.wait(60)
		for _, player in Players:GetPlayers() do
			local s = GameEventLog._sessions[tostring(player.UserId)]
			if s and s.checkpoint then
				GameEventLog:UpdateSnapshot(player, nil, nil, nil)
			end
		end
	end
end)

-- ════════════════════════════════════════════
--         SERVER CLOSE
-- ════════════════════════════════════════════

game:BindToClose(function()
	print("ServerDataManager: Closing...")

	-- [DataModule] Save tất cả container đang dirty
	if DataModule then
		DataModule:SaveAll()
		print("[Data6] DataModule:SaveAll() hoàn tất")
	end

	for _, player in Players:GetPlayers() do
		GameEventLog:EndSession(player)
		for storeName in pairs(PlayerData._configs) do
			PlayerData:Save(player, storeName)
		end
	end
	pcall(function() MemorySession:RemoveAsync("Server_"..SERVER_ID) end)
	SessionData:SaveEventLog()
	print("ServerDataManager: Done")
end)

pcall(function()
	MemorySession:SetAsync("Server_"..SERVER_ID,{
		serverId=SERVER_ID, placeId=SERVER_PLACE,
		startTime=SERVER_START, playerCount=0,
	}, 86400)
end)

task.spawn(function()
	while true do
		task.wait(30)
		pcall(function()
			MemorySession:UpdateAsync("Server_"..SERVER_ID, function(old)
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

RF_GetGlobal.OnServerInvoke = function(player, dataType, key)
	if not checkRateLimit(player,"GetGlobal") then return nil end
	if GLOBAL_TYPES[dataType] then return GlobalData:Get(dataType, key) end
	return nil
end

RF_GetLive.OnServerInvoke = function(player, key)
	if not checkRateLimit(player,"GetLive") then return nil,nil end
	return LiveData:Get(key)
end

RF_GetServerInfo.OnServerInvoke = function(player)
	if not checkRateLimit(player,"GetServerInfo") then return nil end
	return { serverId=SERVER_ID, placeId=SERVER_PLACE, startTime=SERVER_START,
		playerCount=#Players:GetPlayers(), uptime=os.time()-SERVER_START }
end

RF_GetScheduled.OnServerInvoke = function(player, jobId)
	if not checkRateLimit(player,"GetScheduled") then return nil end
	if jobId then return ScheduledData:GetJob(jobId) end
	local r={}
	for id,j in pairs(ScheduledData:GetAll()) do
		r[id]={ jobId=j.jobId, dataType=j.dataType, startTime=j.startTime,
			endTime=j.endTime, status=j.status, meta=j.meta }
	end
	return r
end

RF_GetRandom.OnServerInvoke = function(player, poolId, overrides)
	if not checkRateLimit(player,"GetRandom") then return nil end
	return RandomData:Roll(poolId, overrides)
end

-- ────────────────────────────────────────────
--  GetMyData — client lấy data của chính mình
--  Bỏ qua field visibility = "secret"
--
--  Gọi từ client:
--    local RF = Remotes:WaitForChild("GetMyData")
--
--    -- Lấy toàn bộ 1 store:
--    local data = RF:InvokeServer({ store = "CoursePlayer" })
--
--    -- Lấy 1 field (dot-notation):
--    local coins = RF:InvokeServer({ store = "CoursePlayer", field = "coins" })
--    local kills = RF:InvokeServer({ store = "CoursePlayer", field = "stats.kills" })
--
--    -- Lấy tất cả store cùng lúc:
--    local all = RF:InvokeServer({})
-- ────────────────────────────────────────────
RF_GetMyData.OnServerInvoke = function(player, req)
	if not checkRateLimit(player, "GetMyData") then return nil end
	req = req or {}

	-- Lấy tất cả store cùng lúc
	if not req.store then
		local result = {}
		for storeName in pairs(PlayerData._configs) do
			local cacheKey = tostring(player.UserId) .. "_" .. storeName
			local entry    = PlayerData._cache[cacheKey]
			if entry then
				local schema = PlayerData._schemas[storeName]
				local meta   = schema and schema.meta or nil
				result[storeName] = _filterByVisibility(entry.data, meta, true)
			end
		end
		return result
	end

	-- Lấy 1 store cụ thể
	local storeName = req.store
	if not PlayerData._configs[storeName] then
		warn(string.format("[GetMyData] Store '%s' chưa đăng ký", storeName))
		return nil
	end

	local cacheKey = tostring(player.UserId) .. "_" .. storeName
	local entry    = PlayerData._cache[cacheKey]
	if not entry then
		warn(string.format("[GetMyData] %s chưa load xong store '%s'", player.Name, storeName))
		return nil
	end

	local schema = PlayerData._schemas[storeName]
	local meta   = schema and schema.meta or nil

	-- Lấy 1 field cụ thể
	if req.field then
		local vis = _getFieldVisibility(meta, req.field)
		if vis == VISIBILITY_SECRET then
			warn(string.format("[GetMyData] Field '%s' là secret — không trả về", req.field))
			return nil
		end
		return _getField(entry.data, req.field)
	end

	-- Lấy toàn bộ store (bỏ secret)
	return _filterByVisibility(entry.data, meta, true)
end

-- ────────────────────────────────────────────
--  GetOtherData — client lấy data player khác
--  Chỉ trả field visibility = "public"
--  Target không cần phải online (load từ cache nếu có, DataStore nếu offline)
--
--  Gọi từ client:
--    local RF = Remotes:WaitForChild("GetOtherData")
--
--    -- Lấy toàn bộ public data:
--    local data = RF:InvokeServer({ userId=123456, store="CoursePlayer" })
--
--    -- Lấy 1 field public:
--    local level = RF:InvokeServer({ userId=123456, store="CoursePlayer", field="level" })
-- ────────────────────────────────────────────
RF_GetOtherData.OnServerInvoke = function(player, req)
	if not checkRateLimit(player, "GetOtherData") then return nil end
	req = req or {}

	if not req.userId or not req.store then
		warn("[GetOtherData] Thiếu userId hoặc store")
		return nil
	end

	-- Không cho lấy data của chính mình qua route này
	if tostring(req.userId) == tostring(player.UserId) then
		warn("[GetOtherData] Dùng GetMyData để lấy data của chính mình")
		return nil
	end

	local storeName = req.store
	if not PlayerData._configs[storeName] then return nil end

	local schema = PlayerData._schemas[storeName]
	local meta   = schema and schema.meta or nil

	-- Lấy từ cache nếu target đang online
	local cacheKey = tostring(req.userId) .. "_" .. storeName
	local entry    = PlayerData._cache[cacheKey]
	local data

	if entry then
		-- Target online → lấy từ cache
		data = entry.data
	else
		-- Target offline → load từ DataStore (1 lần, không cache lại)
		local config = PlayerData._configs[storeName]
		local store  = PlayerData._stores[storeName]
		if not store then return nil end

		-- Tạo player giả để build key (chỉ cần UserId)
		local fakePlayer = { UserId = tonumber(req.userId), Name = "" }
		local key = PlayerData._buildKey(config, fakePlayer)
		if not key then return nil end

		local ok, raw = pcall(function() return store:GetAsync(key) end)
		if not ok or not raw then return nil end
		data = raw.data or raw  -- tương thích cả 2 format
	end

	if not data then return nil end

	-- Lấy 1 field
	if req.field then
		local vis = _getFieldVisibility(meta, req.field)
		if vis ~= VISIBILITY_PUBLIC then return nil end
		return _getField(data, req.field)
	end

	-- Chỉ trả public fields
	return _filterByVisibility(data, meta, false)
end

-- ════════════════════════════════════════════
--  KHỞI ĐỘNG
-- ════════════════════════════════════════════

task.spawn(function()
	task.wait(1)

	-- [DataModule] Tạo sẵn các container dùng chung cho GlobalData & SessionData
	if DataModule then
		-- Container cho global server state (persist + shared cross-server)
		DataModule:GetOrCreate("ServerGlobal", {
			persist  = true,
			shared   = true,
			tag      = "global",
			autoSave = true,
			interval = 120,
		})
		-- Container cho session state (chỉ RAM, reset mỗi server)
		DataModule:GetOrCreate("ServerSession", {
			persist = false,
			shared  = false,
			tag     = "session",
		})
		print("[Data6] DataModule containers khởi tạo xong (ServerGlobal, ServerSession)")
	end

	-- Đăng ký tất cả store từ PLAYER_STORES inline config
	for _, entry in ipairs(PLAYER_STORES) do
		PlayerData._configs[entry.config.storeName] = {
			storeName     = entry.config.storeName,
			keyMode       = entry.config.keyMode       or "id",
			keySeed       = entry.config.keySeed       or "DEFAULT_SEED",
			allowId       = entry.config.allowId       ~= false,
			allowName     = entry.config.allowName     ~= false,
			allowSeed     = entry.config.allowSeed     ~= false,
			autoSave      = entry.config.autoSave      ~= false,
			maxHistory    = entry.config.maxHistory    or 20,
			schemaVersion = entry.config.schemaVersion or 1,
		}
		PlayerData._schemas[entry.config.storeName] = entry.schema or { defaults={}, meta={} }
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(entry.config.storeName)
		end)
		if ok then
			PlayerData._stores[entry.config.storeName] = store
			print(string.format("[Data6] PLAYER_STORES: Đăng ký '%s' | KeyMode=%s",
				entry.config.storeName, entry.config.keyMode or "id"))
		else
			warn(string.format("[Data6] PLAYER_STORES: Không tạo được DataStore '%s'", entry.config.storeName))
		end
	end

	-- Scan folder DataStore trong script trước
	_autoScanScript()
	-- Sau đó load DataConfig từ Studio
	DataConfig:Load()
end)

-- ════════════════════════════════════════════
--         PUBLIC API
-- ════════════════════════════════════════════

local API = {}

-- Session
function API.Session(key, value)
	if value ~= nil then SessionData:Set(key, value)
	else return SessionData:Get(key) end
end
function API.Log(t, d)      SessionData:Log(t, d) end
function API.GetEventLog()  return SessionData._events end

-- Live
function API.SetLive(k,v,t)    LiveData:Set(k,v,t) end
function API.GetLive(k)         return LiveData:Get(k) end
function API.UpdateLive(k,f,t)  LiveData:Update(k,f,t) end
function API.DeleteLive(k)      LiveData:Delete(k) end

-- Global
function API.SetGlobal(dt,k,v)   return GlobalData:Set(dt,k,v) end
function API.GetGlobal(dt,k)      return GlobalData:Get(dt,k) end
function API.IncrementGlobal(k,a) GlobalData:Increment(k,a) end
function API.AdminBroadcast(m,d)  GlobalData:AdminBroadcast(m,d) end

-- Conflict
function API.GetConflict(player)
	return SessionData:Get("conflict_"..player.UserId)
end

-- Server
function API.GetServerInfo()
	return { serverId=SERVER_ID, placeId=SERVER_PLACE,
		startTime=SERVER_START, uptime=os.time()-SERVER_START,
		playerCount=#Players:GetPlayers() }
end
function API.GetActiveServers()
	local servers = {}
	local ok, pages = pcall(function()
		return MemorySession:GetRangeAsync(Enum.SortDirection.Ascending, 20)
	end)
	if ok and pages then
		for _, e in ipairs(pages) do
			local v = e.value
			if e.key:sub(1,7)=="Server_" and v and v.lastPing
				and (os.time()-v.lastPing)<90 then
				table.insert(servers, v)
			end
		end
	end
	return servers
end

-- Scheduled
function API.ScheduleData(id,dt,payload,st,et,meta) return ScheduledData:Register(id,dt,payload,st,et,meta) end
function API.CancelScheduled(id)                    return ScheduledData:Cancel(id) end
function API.UpdateScheduled(id,payload)            return ScheduledData:UpdateActive(id,payload) end
function API.GetScheduledJob(id)                    return ScheduledData:GetJob(id) end
function API.GetAllScheduled(fs)                    return ScheduledData:GetAll(fs) end
function API.OnScheduledFired(id,cb)                ScheduledData:OnFired(id,cb) end

-- Random
function API.RegisterPool(poolId, config)           RandomData:RegisterPool(poolId, config) end
function API.Roll(poolId, overrides)                return RandomData:Roll(poolId, overrides) end
function API.RandomList(items)                      return RandomData:FromList(items) end
function API.RandomRange(min, max, isFloat)         return RandomData:InRange(min, max, isFloat) end
function API.RandomWeighted(items)                  return RandomData:Weighted(items) end
function API.RandomWeightedMulti(items, n)          return RandomData:WeightedMulti(items, n) end
function API.RandomSeeded(seed, mode, args)         return RandomData:Seeded(seed, mode, args) end
function API.RandomBonus(config)                    return RandomData:BonusStack(config) end

-- GameEventLog
function API.PushEvent(player, eventType, data)            GameEventLog:Push(player, eventType, data) end
function API.UpdateSnapshot(player, pos, cp, custom)       GameEventLog:UpdateSnapshot(player, pos, cp, custom) end
function API.GetSnapshot(player)                           return GameEventLog:GetSnapshot(player) end
function API.ClearSnapshot(player)                         GameEventLog:ClearSnapshot(player) end
function API.GetGameSession(player)                        return GameEventLog:GetSession(player) end
function API.GetSessionTime(player)                        return GameEventLog:GetSessionTime(player) end

-- TimeUtil
function API.ToTimestamp(y,m,d,h,mi,s) return TimeUtil.toTimestamp(y,m,d,h,mi,s) end
function API.FormatTime(ts)             return TimeUtil.format(ts) end
function API.BreakdownTime(ts)          return TimeUtil.breakdown(ts) end

-- DataConfig
function API.ReloadConfig() DataConfig:Reload() end

-- ══════════════════════════════════════════════
--  PLAYER DATA API  (phần mới)
-- ══════════════════════════════════════════════

-- Đăng ký store thủ công (không qua folder)
-- config = { storeName, keyMode, keySeed, allowId, allowName, allowSeed, autoSave, maxHistory, schemaVersion }
-- schema = { defaults = {...}, meta = {...} }
function API.RegisterPlayerStore(config, schema)
	local storeName = config.storeName
	PlayerData._configs[storeName] = {
		storeName     = storeName,
		keyMode       = config.keyMode       or "id",
		keySeed       = config.keySeed       or "DEFAULT_SEED",
		allowId       = config.allowId       ~= false,
		allowName     = config.allowName     ~= false,
		allowSeed     = config.allowSeed     ~= false,
		autoSave      = config.autoSave      ~= false,
		maxHistory    = config.maxHistory    or 20,
		schemaVersion = config.schemaVersion or 1,
	}
	PlayerData._schemas[storeName] = schema or { defaults={}, meta={} }
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(storeName)
	end)
	if ok then
		PlayerData._stores[storeName] = store
		print("PlayerData: Registered store — " .. storeName)
		return true
	end
	return false
end

-- Đăng ký store từ folder (manual)
function API.RegisterPlayerStoreFromFolder(folder)
	return PlayerData:RegisterFromFolder(folder)
end

-- Load / Save
function API.LoadPlayerData(player, storeName)   return PlayerData:Load(player, storeName) end
function API.SavePlayerData(player, storeName)   return PlayerData:Save(player, storeName) end

-- Get / Set / Increment / Decrement / Toggle
-- fieldPath hỗ trợ dot-notation: "stats.kills"
function API.GetData(player, storeName, fieldPath)          return PlayerData:Get(player, storeName, fieldPath) end
function API.SetData(player, storeName, fieldPath, value)   return PlayerData:Set(player, storeName, fieldPath, value) end
function API.IncrementData(player, storeName, field, amt)   return PlayerData:Increment(player, storeName, field, amt) end
function API.DecrementData(player, storeName, field, amt)   return PlayerData:Decrement(player, storeName, field, amt) end
function API.ToggleData(player, storeName, fieldPath)       return PlayerData:Toggle(player, storeName, fieldPath) end
function API.GetAllData(player, storeName)                  return PlayerData:GetAll(player, storeName) end

-- Reset / Wipe
function API.ResetPlayerData(player, storeName) return PlayerData:Reset(player, storeName) end
function API.WipePlayerData(player, storeName)  return PlayerData:Wipe(player, storeName) end

-- Lịch sử & version
function API.GetDataHistory(player, storeName)          return PlayerData:GetHistory(player, storeName) end
function API.GetDataVersion(player, storeName)          return PlayerData:GetVersion(player, storeName) end
function API.GetDataAtTime(player, storeName, timestamp) return PlayerData:GetVersionedData(player, storeName, timestamp) end

-- Kiểm tra
function API.IsDataLoaded(player, storeName)  return PlayerData:IsLoaded(player, storeName) end
function API.GetCacheInfo(player, storeName)  return PlayerData:GetCacheInfo(player, storeName) end

-- Key utilities
function API.GetPlayerKey(player, storeName)
	local config = PlayerData._configs[storeName]
	if not config then return nil end
	return PlayerData._buildKey(config, player)
end

-- ══════════════════════════════════════════════
--  DATASAVE API  — truy cập trực tiếp DataSave
--  (data player theo session, đơn giản & nhẹ)
-- ══════════════════════════════════════════════

-- Đăng ký fields cần lưu (gọi trước khi player join)
-- API.DSRegisterField("coins", 0)
-- API.DSRegisterFields({ coins=0, level=1 })
function API.DSRegisterField(field, default)
	if not DataSave then warn("[Data6] DataSave chưa được load"); return end
	DataSave:RegisterField(field, default)
end
function API.DSRegisterFields(fields)
	if not DataSave then warn("[Data6] DataSave chưa được load"); return end
	DataSave:RegisterFields(fields)
end

-- Đọc / ghi data player qua DataSave
function API.DSGet(player, field)            if DataSave then return DataSave:Get(player, field) end end
function API.DSSet(player, field, value)     if DataSave then return DataSave:Set(player, field, value) end end
function API.DSGetAll(player)                if DataSave then return DataSave:GetAll(player) end end
function API.DSIncrement(player, field, amt) if DataSave then return DataSave:Increment(player, field, amt) end end
function API.DSDecrement(player, field, amt) if DataSave then return DataSave:Decrement(player, field, amt) end end
function API.DSToggle(player, field)         if DataSave then return DataSave:Toggle(player, field) end end
function API.DSUpdateTable(player, field, fn)if DataSave then return DataSave:UpdateTable(player, field, fn) end end
function API.DSReset(player, field)          if DataSave then return DataSave:Reset(player, field) end end
function API.DSSave(player)                  if DataSave then return DataSave:Save(player) end end
function API.DSWipe(player)                  if DataSave then return DataSave:Wipe(player) end end
function API.DSWaitForLoad(player, timeout)  if DataSave then return DataSave:WaitForLoad(player, timeout) end end
function API.DSIsLoaded(player)              if DataSave then return DataSave:IsLoaded(player) end end
function API.DSSessionInfo(player)           if DataSave then return DataSave:GetSessionInfo(player) end end
function API.DSAllSessions()                 if DataSave then return DataSave:GetAllSessions() end end

-- ══════════════════════════════════════════════
--  DATAMODULE API  — truy cập trực tiếp DataModule
--  (data container server: shop, event, config…)
-- ══════════════════════════════════════════════

-- Tạo hoặc lấy container
-- API.DMCreate("ShopPrices", { persist=true, shared=true, tag="shop" })
function API.DMCreate(id, setting)
	if not DataModule then return end
	setting = setting or {}
	-- Tự động wrap onChange để fire RE_DataModuleChanged tới client
	setting.onChange = _wrapOnChange(id, setting.onChange)
	return DataModule:Create(id, setting)
end
function API.DMGetOrCreate(id, s)
	if not DataModule then return end
	if DataModule:Get(id) then return DataModule:Get(id) end
	return API.DMCreate(id, s)
end
function API.DMGet(id)                if DataModule then return DataModule:Get(id) end end
function API.DMList()                 if DataModule then return DataModule:List() end end
function API.DMDestroy(id)            if DataModule then return DataModule:Destroy(id) end end
function API.DMSaveAll()              if DataModule then return DataModule:SaveAll() end end

-- Truy cập trực tiếp vào container (shortcut)
-- API.DMSet("ShopPrices", "sword", 150)
function API.DMSet(id, key, value)
	if not DataModule then return false end
	local obj = DataModule:Get(id)
	if not obj then warn("[Data6] DataModule container '" .. id .. "' chưa tồn tại"); return false end
	return obj:Set(key, value)
end
function API.DMGetVal(id, key)
	if not DataModule then return nil end
	local obj = DataModule:Get(id)
	return obj and obj:Get(key) or nil
end
function API.DMIncrement(id, key, amt)
	if not DataModule then return false end
	local obj = DataModule:Get(id)
	return obj and obj:Increment(key, amt) or false
end
function API.DMGetAll(id)
	if not DataModule then return nil end
	local obj = DataModule:Get(id)
	return obj and obj:GetAll() or nil
end

-- Expose module thô (nếu muốn dùng trực tiếp)
API._DataSave   = DataSave
API._DataModule = DataModule

return API

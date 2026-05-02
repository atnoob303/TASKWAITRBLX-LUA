-- ╔══════════════════════════════════════════════════════════════╗
-- ║            ServerDataManager  —  ModuleScript               ║
-- ║  Đặt trong: ServerScriptService                             ║
-- ║  Yêu cầu:   DataManager đã chạy trước                      ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  Hệ thống:                                                  ║
-- ║   1. SessionData      — data phiên server                   ║
-- ║   2. LiveData         — cross-server TTL                    ║
-- ║   3. GlobalData       — toàn server vĩnh viễn               ║
-- ║   4. ConflictResolver — xử lý xung đột khi đổi server      ║
-- ║   5. ScheduledData    — data tự bật theo lịch               ║
-- ║   6. RandomData       — random có trọng số/seed/bonus       ║
-- ║   7. GameEventLog     — lưu sự kiện & session player        ║
-- ║   8. DataConfig       — đọc config từ Folder trong Studio   ║
-- ╚══════════════════════════════════════════════════════════════╝

local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService   = game:GetService("MessagingService")
local DataStoreService   = game:GetService("DataStoreService")
local Players            = game:GetService("Players")
local ServerStorage      = game:GetService("ServerStorage")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

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

local SERVER_ID    = game.JobId ~= "" and game.JobId or "STUDIO_" .. tostring(math.random(10000))
local SERVER_START = os.time()
local SERVER_PLACE = tostring(game.PlaceId)

-- ════════════════════════════════════════════
--              REMOTES
-- ════════════════════════════════════════════

local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	or Instance.new("Folder", ReplicatedStorage)
Remotes.Name = "Remotes"

local function makeRemote(name, isFunc)
	local r = Remotes:FindFirstChild(name)
	if r then return r end
	r = Instance.new(isFunc and "RemoteFunction" or "RemoteEvent")
	r.Name = name; r.Parent = Remotes
	return r
end

local RF_GetGlobal      = makeRemote("GetGlobal",     true)
local RF_GetLive        = makeRemote("GetLive",        true)
local RF_GetServerInfo  = makeRemote("GetServerInfo",  true)
local RF_GetScheduled   = makeRemote("GetScheduled",   true)
local RF_GetRandom      = makeRemote("GetRandom",      true)
local RE_AdminMessage   = makeRemote("AdminMessage",   false)
local RE_ScheduledFired = makeRemote("ScheduledFired", false)
local RE_GameEvent      = makeRemote("GameEvent",      false)

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
-- Chuyen doi ngay thang nam gio phut sang Unix timestamp
--
-- Ho tro:
--   TimeUtil.toTimestamp(2025, 12, 25, 20, 30)
--   TimeUtil.toTimestamp("2025-12-25 20:30")
--   TimeUtil.toTimestamp("25/12/2025 20:30")
--   TimeUtil.toTimestamp({ year=2025, month=12, day=25, hour=20, minute=30 })

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
--
-- startTime / endTime ho tro:
--   so Unix timestamp
--   chuoi "YYYY-MM-DD HH:MM" hoac "DD/MM/YYYY HH:MM"
--   table { year, month, day, hour, minute }

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
--
--  5 kieu random:
--  1. List      — chon 1 item tu danh sach
--  2. Range     — so ngau nhien trong [min, max]
--  3. Weighted  — co trong so, ho tro tier (common/rare/epic...)
--  4. Seeded    — cung seed → cung ket qua
--  5. BonusStack— random base roi cong cac bonus chong len nhau

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

-- 1. Danh sach
function RandomData:FromList(items)
	if not items or #items == 0 then return nil end
	return items[self._rng:NextInteger(1, #items)]
end

-- 2. Khoang so
function RandomData:InRange(min, max, isFloat)
	if isFloat then return self._rng:NextNumber(min, max) end
	return self._rng:NextInteger(math.floor(min), math.floor(max))
end

-- 3. Co trong so
-- items = { { value="sword", weight=60, tier="common" }, ... }
function RandomData:Weighted(items)
	return weightedPick(items)
end

function RandomData:WeightedMulti(items, count)
	local results = {}
	for i = 1, count do results[i] = weightedPick(items) end
	return results
end

-- 4. Seeded
-- mode: "list" | "range" | "weighted"
-- args: tuy mode — list:{items} | range:{min,max,isFloat} | weighted:{items}
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

-- 5. BonusStack — random base + cong bonus chong len nhau
-- config = {
--   base    = { min=10, max=20 },
--   bonuses = {
--     { name="event_bonus",  value=5 },
--     { name="level_bonus",  min=1, max=3 },
--     { name="rare_bonus",   weighted=true, items={ {value=10,weight=20}, {value=5,weight=80} } },
--   }
-- }
-- Tra ve { total, base, breakdown }
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

-- Roll tu pool da dang ky
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
	if mode == "list"       then return self:FromList(config.items)
	elseif mode == "range"  then return self:InRange(config.min, config.max, config.isFloat)
	elseif mode == "weighted" then return self:Weighted(config.items)
	elseif mode == "seeded" then return self:Seeded(config.seed, config.seedMode, config.args)
	elseif mode == "bonusStack" then return self:BonusStack(config) end
	warn("RandomData: mode khong hop le — " .. tostring(mode)); return nil
end

-- ════════════════════════════════════════════
--  GAME EVENT LOG
-- ════════════════════════════════════════════
--
--  Luu toan bo su kien phien choi cua tung player:
--    * Resume        — tiep tuc dung cho neu bi vang
--    * Position snap — dung dung vi tri khi reconnect
--    * Session timer — tong thoi gian choi
--    * Checkpoint    — khong bi gian doan tien trinh
--    * Custom event  — bat ky su kien nao trong game
--
--  Snapshot position + checkpoint -> DataStore (survive crash)
--  Event log -> luu khi session ket thuc

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

-- Push su kien vao session
-- eventType: string tu do — "KILL", "QUEST_DONE", "BOSS_ENTER", "DAMAGE", ...
-- data: table bat ky
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

-- Cap nhat vi tri + checkpoint (luu DataStore ngay)
-- position: { x, y, z }
-- checkpoint: string hoac so dinh danh checkpoint
-- customData: bat ky data game them vao
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
--  DATA CONFIG — DOC TU FOLDER TRONG STUDIO
-- ════════════════════════════════════════════
--
--  Cau truc ServerStorage/DataConfig:
--
--  DataConfig/                             <- root (Folder)
--   [Attr] Version = "1.0"
--   |
--   +-- RandomPools/                       <- category folder
--   |    [Attr] AutoLoad = true
--   |    |
--   |    +-- LootBox_Common/              <- ten pool (Folder)
--   |         [Attr] mode = "weighted"
--   |         Item_Sword  (StringValue = "common_sword")
--   |          [Attr] weight = 60
--   |          [Attr] tier   = "common"
--   |         Item_Bow    (StringValue = "rare_bow")
--   |          [Attr] weight = 30
--   |          [Attr] tier   = "rare"
--   |
--   +-- ScheduledEvents/                  <- scheduled jobs
--   |    SummerEvent/                     <- ten job (Folder)
--   |     [Attr] dataType  = "eventState"
--   |     [Attr] startTime = "2025-07-01 00:00"
--   |     [Attr] endTime   = "2025-07-31 23:59"
--   |     Payload/                        <- sub-folder chua payload
--   |      active   (BoolValue = true)
--   |      bonusXP  (NumberValue = 2)
--   |      mapName  (StringValue = "Beach")
--   |
--   +-- GlobalDefaults/                   <- gia tri mac dinh GlobalData
--        shopPrice_sword  (NumberValue = 100)
--        shopPrice_armor  (NumberValue = 200)

local DataConfig = {}
DataConfig._loaded = false

local function readValueObject(obj)
	local cn = obj.ClassName
	if cn == "StringValue"  then return obj.Value
	elseif cn == "NumberValue"  then return obj.Value
	elseif cn == "BoolValue"    then return obj.Value
	elseif cn == "IntValue"     then return obj.Value
	elseif cn == "Color3Value"  then return obj.Value
	elseif cn == "Vector3Value" then
		return { x=obj.Value.X, y=obj.Value.Y, z=obj.Value.Z }
	elseif cn == "CFrameValue" then
		local cf = obj.Value
		return { px=cf.X, py=cf.Y, pz=cf.Z }
	end
	return nil
end

local function readAttributes(inst)
	local attrs = {}
	local ok, result = pcall(function() return inst:GetAttributes() end)
	if ok then for k, v in pairs(result) do attrs[k] = v end end
	return attrs
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
	local attrs = readAttributes(poolsFolder)
	local autoLoad = attrs.AutoLoad == true

	for _, poolFolder in ipairs(poolsFolder:GetChildren()) do
		if not poolFolder:IsA("Folder") then continue end
		local pa = readAttributes(poolFolder)
		local mode = pa.mode or "list"
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
					local ba = readAttributes(bObj)
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
		local attrs = readAttributes(eventFolder)
		local dataType  = attrs.dataType  or "eventState"
		local startTime = attrs.startTime
		local endTime   = attrs.endTime

		if not startTime then
			warn("DataConfig: ScheduledEvent [" .. eventFolder.Name .. "] thieu startTime")
			continue
		end

		local payloadFolder = eventFolder:FindFirstChild("Payload")
		local payload = payloadFolder and readPayloadFolder(payloadFolder) or {}
		local reserved = { dataType=true, startTime=true, endTime=true, description=true }
		for k, v in pairs(attrs) do
			if not reserved[k] then payload[k] = v end
		end

		ScheduledData:Register(eventFolder.Name, dataType, payload, startTime, endTime, {
			description = attrs.description or eventFolder.Name,
			source = "DataConfig",
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
			warn("DataConfig: GlobalDefault ten khong hop le — " .. obj.Name)
		end
	end
end

function DataConfig:Load()
	if self._loaded then return end
	local root = ServerStorage:FindFirstChild("DataConfig")
	if not root then
		warn("DataConfig: Khong tim thay ServerStorage/DataConfig — bo qua"); return
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
		else
			-- Folder custom → doc thanh table, luu vao SessionData
			local data = readPayloadFolder(categoryFolder)
			SessionData:Set("config_" .. name, data)
			print("DataConfig: Custom folder loaded — " .. name)
		end
	end

	self._loaded = true
	print("DataConfig: Load hoan tat")
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
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, p in Players:GetPlayers() do task.spawn(onPlayerAdded, p) end

-- Auto-save snapshot moi 60 giay
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
	for _, player in Players:GetPlayers() do
		GameEventLog:EndSession(player)
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

-- ════════════════════════════════════════════
--  KHOI DONG
-- ════════════════════════════════════════════

task.spawn(function()
	task.wait(1)
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

-- ──────────────────────────────────────────
--  RandomData API
-- ──────────────────────────────────────────

-- Dang ky pool thu cong (khong qua Folder)
-- config.mode: "list" | "range" | "weighted" | "seeded" | "bonusStack"
function API.RegisterPool(poolId, config)
	RandomData:RegisterPool(poolId, config)
end

-- Roll tu pool da dang ky
function API.Roll(poolId, overrides)
	return RandomData:Roll(poolId, overrides)
end

-- Random nhanh — khong can dang ky pool
function API.RandomList(items)              return RandomData:FromList(items) end
function API.RandomRange(min, max, isFloat) return RandomData:InRange(min, max, isFloat) end
function API.RandomWeighted(items)          return RandomData:Weighted(items) end
function API.RandomWeightedMulti(items, n)  return RandomData:WeightedMulti(items, n) end
function API.RandomSeeded(seed, mode, args) return RandomData:Seeded(seed, mode, args) end
function API.RandomBonus(config)            return RandomData:BonusStack(config) end

-- ──────────────────────────────────────────
--  GameEventLog API
-- ──────────────────────────────────────────

-- Ghi su kien vao log cua player
-- eventType: string tu do — "KILL", "CRAFT", "BOSS_ENTER", "QUEST_DONE" ...
function API.PushEvent(player, eventType, data)
	GameEventLog:Push(player, eventType, data)
end

-- Cap nhat vi tri + checkpoint (de resume khi vang)
-- position: { x, y, z }  |  checkpoint: string/so
-- customData: data game them (HP, inventory slot, map state ...)
function API.UpdateSnapshot(player, position, checkpoint, customData)
	GameEventLog:UpdateSnapshot(player, position, checkpoint, customData)
end

-- Lay snapshot de resume khi player reconnect
-- Tra ve: { checkpoint, position, customData, isResumed }
function API.GetSnapshot(player)
	return GameEventLog:GetSnapshot(player)
end

-- Xoa snapshot (player hoan thanh binh thuong)
function API.ClearSnapshot(player)
	GameEventLog:ClearSnapshot(player)
end

-- Lay session hien tai
function API.GetGameSession(player)
	return GameEventLog:GetSession(player)
end

-- Tong thoi gian choi phien nay (giay)
function API.GetSessionTime(player)
	return GameEventLog:GetSessionTime(player)
end

-- ──────────────────────────────────────────
--  TimeUtil API
-- ──────────────────────────────────────────

-- Chuyen ngay gio → Unix timestamp
-- Ho tro: (year,month,day,hour,minute) | "YYYY-MM-DD HH:MM" | { year,...}
function API.ToTimestamp(y, m, d, h, mi, s) return TimeUtil.toTimestamp(y,m,d,h,mi,s) end
function API.FormatTime(ts)                  return TimeUtil.format(ts) end
function API.BreakdownTime(ts)               return TimeUtil.breakdown(ts) end

-- ──────────────────────────────────────────
--  DataConfig API
-- ──────────────────────────────────────────

-- Tai lai config tu Folder (dung khi test, khong can restart)
function API.ReloadConfig() DataConfig:Reload() end

return API

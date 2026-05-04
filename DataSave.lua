-- ╔══════════════════════════════════════════════════════════════╗
-- ║                   DataSave  —  ModuleScript                  ║
-- ║  Đặt trong: ServerScriptService (cùng nơi Data6)             ║
-- ║  Mục đích:  Lưu data player trong RAM suốt session,          ║
-- ║             auto-save khi thoát, dọn data cũ tự động.        ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  Vòng đời data player:                                       ║
-- ║                                                              ║
-- ║   [Lần 1 vào]  → Load data cũ (nếu có) từ DataStore         ║
-- ║                → Giữ trong RAM suốt session                  ║
-- ║   [Lần 1 thoát]→ Save data phiên này vào DataStore           ║
-- ║                → Data trong RAM bị xóa                       ║
-- ║                                                              ║
-- ║   [Lần 2 vào]  → Load data phiên 1 + merge data mới         ║
-- ║   [Lần 2 thoát]→ Save data phiên 2                           ║
-- ║                → Data phiên 1 (cũ) bị xóa khỏi DataStore    ║
-- ║                → Chỉ giữ lại phiên mới nhất                  ║
-- ║                                                              ║
-- ║  Kết quả: DataStore luôn chỉ có 1 bản save duy nhất/player   ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  Cách dùng:                                                  ║
-- ║                                                              ║
-- ║   local DataSave = require(path.to.DataSave)                 ║
-- ║                                                              ║
-- ║   -- Đăng ký field cần lưu (gọi trước khi game bắt đầu)     ║
-- ║   DataSave:RegisterField("coins",    0)                      ║
-- ║   DataSave:RegisterField("level",    1)                      ║
-- ║   DataSave:RegisterField("inventory",{})                     ║
-- ║                                                              ║
-- ║   -- Trong game                                              ║
-- ║   DataSave:Set(player, "coins", 500)                         ║
-- ║   DataSave:Get(player, "coins")   --> 500                    ║
-- ║   DataSave:Increment(player, "coins", 100)                   ║
-- ║   DataSave:GetAll(player)         --> { coins=600, ... }     ║
-- ║                                                              ║
-- ║   -- Player tự động được load khi join, save khi thoát       ║
-- ╚══════════════════════════════════════════════════════════════╝

local DataStoreService = game:GetService("DataStoreService")
local Players          = game:GetService("Players")

-- ════════════════════════════════════════════
--  CONFIG
-- ════════════════════════════════════════════

local STORE_NAME    = "DataSave_v1"      -- tên DataStore chính
local AUTO_SAVE_INT = 60                  -- tự save RAM → không save DS, chỉ đánh dấu dirty
local MAX_RETRIES   = 3                   -- số lần thử lại khi DataStore lỗi
local RETRY_DELAY   = 2                   -- giây giữa mỗi lần retry

-- ════════════════════════════════════════════
--  INTERNAL
-- ════════════════════════════════════════════

local _store      = DataStoreService:GetDataStore(STORE_NAME)
local _schema     = {}     -- { [field] = defaultValue }  — đăng ký trước
local _sessions   = {}     -- { [userId] = SessionObject }
local _loadedFlag = {}     -- { [userId] = true } — đã load xong chưa

-- ════════════════════════════════════════════
--  HELPERS
-- ════════════════════════════════════════════

local function _deepCopy(t)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t) do copy[k] = _deepCopy(v) end
	return copy
end

-- Merge: lấy data cũ làm gốc, ghi đè bằng data mới (giữ field cũ nếu mới không có)
local function _merge(old, new)
	if type(old) ~= "table" or type(new) ~= "table" then
		return new ~= nil and new or old
	end
	local result = _deepCopy(old)
	for k, v in pairs(new) do
		if type(v) == "table" and type(result[k]) == "table" then
			result[k] = _merge(result[k], v)
		else
			result[k] = v
		end
	end
	return result
end

-- Điền field còn thiếu theo schema
local function _applySchema(data)
	for field, defaultVal in pairs(_schema) do
		if data[field] == nil then
			data[field] = _deepCopy(defaultVal)
		end
	end
	return data
end

-- Build DataStore key cho player
local function _key(userId)
	return "Player_" .. tostring(userId)
end

-- DataStore SetAsync với retry
local function _dsSet(key, value)
	for i = 1, MAX_RETRIES do
		local ok, err = pcall(function()
			_store:SetAsync(key, value)
		end)
		if ok then return true end
		warn(string.format("[DataSave] SetAsync thất bại (lần %d/%d): %s", i, MAX_RETRIES, tostring(err)))
		if i < MAX_RETRIES then task.wait(RETRY_DELAY) end
	end
	return false
end

-- DataStore GetAsync với retry
local function _dsGet(key)
	for i = 1, MAX_RETRIES do
		local ok, result = pcall(function()
			return _store:GetAsync(key)
		end)
		if ok then return result end
		warn(string.format("[DataSave] GetAsync thất bại (lần %d/%d): %s", i, MAX_RETRIES, tostring(result)))
		if i < MAX_RETRIES then task.wait(RETRY_DELAY) end
	end
	return nil
end

-- DataStore RemoveAsync với retry
local function _dsRemove(key)
	for i = 1, MAX_RETRIES do
		local ok, err = pcall(function()
			_store:RemoveAsync(key)
		end)
		if ok then return true end
		warn(string.format("[DataSave] RemoveAsync thất bại (lần %d/%d): %s", i, MAX_RETRIES, tostring(err)))
		if i < MAX_RETRIES then task.wait(RETRY_DELAY) end
	end
	return false
end

-- ════════════════════════════════════════════
--  SESSION OBJECT — đại diện 1 phiên của player
-- ════════════════════════════════════════════

--[[
  Mỗi player khi join tạo 1 SessionObject:
    .userId      UserId
    .name        tên player
    .data        table data hiện tại (RAM)
    .joinTime    os.time() khi join
    .saveTime    os.time() của lần save gần nhất
    .sessionNum  số thứ tự phiên (1, 2, 3, ...)
    .prevKey     key DataStore của phiên TRƯỚC (để xóa sau khi save xong)
    .currentKey  key DataStore của phiên NÀY
    .dirty       cần save không
    .loaded      load xong chưa (dùng để chờ)
]]

local function _newSession(player)
	local uid      = player.UserId
	local joinTime = os.time()
	-- currentKey = key chính, sẽ tạo ra khi save
	-- phiên trước sẽ được tìm trong DataStore
	return {
		userId     = uid,
		name       = player.Name,
		data       = {},
		joinTime   = joinTime,
		saveTime   = 0,
		sessionNum = 1,
		prevKey    = nil,     -- sẽ điền sau khi load
		currentKey = _key(uid),
		dirty      = false,
		loaded     = false,
	}
end

-- ════════════════════════════════════════════
--  LOAD — khi player join
-- ════════════════════════════════════════════

local function _loadPlayer(player)
	local uid     = player.UserId
	local session = _newSession(player)
	_sessions[uid] = session

	task.spawn(function()
		local key = _key(uid)
		local raw = _dsGet(key)

		if raw and type(raw) == "table" then
			-- Có data cũ → merge với schema mới
			session.data       = _applySchema(_merge({}, raw.data or {}))
			session.sessionNum = (raw.sessionNum or 0) + 1
			session.prevKey    = raw.prevKey    -- key của phiên trước phiên cũ (để dọn chuỗi)
			print(string.format("[DataSave] %s loaded (phiên %d, %d fields)",
				player.Name, session.sessionNum, (function()
					local n = 0; for _ in pairs(session.data) do n += 1 end; return n
				end)()))
		else
			-- Player mới → tạo data từ schema
			session.data       = _applySchema({})
			session.sessionNum = 1
			print(string.format("[DataSave] %s — data mới (schema: %d fields)",
				player.Name, (function()
					local n = 0; for _ in pairs(session.data) do n += 1 end; return n
				end)()))
		end

		session.loaded = true
		_loadedFlag[uid] = true
	end)
end

-- ════════════════════════════════════════════
--  SAVE — khi player thoát (hoặc thủ công)
-- ════════════════════════════════════════════

local function _savePlayer(player, isLeaving)
	local uid     = player.UserId
	local session = _sessions[uid]
	if not session then return end

	-- Chờ load xong nếu chưa xong
	local waited = 0
	while not session.loaded and waited < 10 do
		task.wait(0.5)
		waited += 0.5
	end
	if not session.loaded then
		warn("[DataSave] " .. player.Name .. " chưa load xong, bỏ qua save")
		return
	end

	local key     = session.currentKey
	local now     = os.time()

	-- Payload lưu vào DataStore
	local payload = {
		userId     = session.userId,
		name       = session.name,
		data       = session.data,
		sessionNum = session.sessionNum,
		savedAt    = now,
		joinTime   = session.joinTime,
		prevKey    = nil,   -- không cần lưu prevKey nữa (đã xóa)
	}

	local ok = _dsSet(key, payload)

	if ok then
		session.saveTime = now
		session.dirty    = false
		print(string.format("[DataSave] %s saved (phiên %d, %d fields)",
			player.Name, session.sessionNum,
			(function() local n=0; for _ in pairs(session.data) do n+=1 end; return n end)()))

		-- ══ DỌN DẸP: xóa data phiên trước (nếu có) ══
		-- Sau khi save phiên 2 xong → xóa record phiên 1
		-- Logic: phiên cũ và phiên mới dùng cùng 1 key (Player_userId)
		-- nên DataStore tự ghi đè. Không cần xóa key riêng.
		-- Tuy nhiên nếu có prevKey riêng từ hệ thống cũ thì xóa luôn.
		if session.prevKey and session.prevKey ~= key then
			task.spawn(function()
				local removed = _dsRemove(session.prevKey)
				if removed then
					print(string.format("[DataSave] Đã xóa data cũ (key: %s)", session.prevKey))
				end
			end)
		end
	else
		warn("[DataSave] " .. player.Name .. " SAVE THẤT BẠI sau " .. MAX_RETRIES .. " lần thử!")
	end

	-- Dọn RAM nếu player đang thoát
	if isLeaving then
		_sessions[uid]   = nil
		_loadedFlag[uid] = nil
	end
end

-- ════════════════════════════════════════════
--  MODULE CHÍNH
-- ════════════════════════════════════════════

local DataSave = {}

-- ────────────────────────────────────────────
--  RegisterField — đăng ký field và giá trị mặc định
--  Gọi trước khi player nào join (thường trong Script init)
-- ────────────────────────────────────────────
function DataSave:RegisterField(field, defaultValue)
	assert(type(field) == "string", "[DataSave] field phải là string")
	if _schema[field] ~= nil then
		warn("[DataSave] Field '" .. field .. "' đã đăng ký — ghi đè default")
	end
	_schema[field] = defaultValue
	print(string.format("[DataSave] Registered field '%s' (default: %s)",
		field, tostring(defaultValue)))
end

-- Đăng ký nhiều field cùng lúc
-- DataSave:RegisterFields({ coins=0, level=1, inventory={} })
function DataSave:RegisterFields(fields)
	assert(type(fields) == "table", "[DataSave] fields phải là table")
	for field, defaultVal in pairs(fields) do
		self:RegisterField(field, defaultVal)
	end
end

-- ────────────────────────────────────────────
--  WaitForLoad — yield cho tới khi player load xong
-- ────────────────────────────────────────────
function DataSave:WaitForLoad(player, timeout)
	timeout = timeout or 10
	local uid     = player.UserId
	local waited  = 0
	while not _loadedFlag[uid] and waited < timeout do
		task.wait(0.1)
		waited += 0.1
	end
	return _loadedFlag[uid] == true
end

-- ────────────────────────────────────────────
--  IsLoaded
-- ────────────────────────────────────────────
function DataSave:IsLoaded(player)
	return _loadedFlag[player.UserId] == true
end

-- ────────────────────────────────────────────
--  SET
-- ────────────────────────────────────────────
function DataSave:Set(player, field, value)
	local session = _sessions[player.UserId]
	if not session or not session.loaded then
		warn("[DataSave] Set: " .. player.Name .. " chưa load xong"); return false
	end
	session.data[field] = value
	session.dirty = true
	return true
end

-- ────────────────────────────────────────────
--  GET
-- ────────────────────────────────────────────
function DataSave:Get(player, field)
	local session = _sessions[player.UserId]
	if not session or not session.loaded then return nil end
	local v = session.data[field]
	-- Trả default từ schema nếu nil
	if v == nil and _schema[field] ~= nil then
		return _deepCopy(_schema[field])
	end
	return v
end

-- ────────────────────────────────────────────
--  GET ALL — lấy toàn bộ data player (deep copy)
-- ────────────────────────────────────────────
function DataSave:GetAll(player)
	local session = _sessions[player.UserId]
	if not session or not session.loaded then return nil end
	return _deepCopy(session.data)
end

-- ────────────────────────────────────────────
--  INCREMENT / DECREMENT
-- ────────────────────────────────────────────
function DataSave:Increment(player, field, amount)
	amount = amount or 1
	local cur = self:Get(player, field)
	if type(cur) ~= "number" then
		warn("[DataSave] Increment: '" .. field .. "' không phải number"); return false
	end
	return self:Set(player, field, cur + amount)
end

function DataSave:Decrement(player, field, amount)
	amount = amount or 1
	return self:Increment(player, field, -amount)
end

-- ────────────────────────────────────────────
--  TOGGLE
-- ────────────────────────────────────────────
function DataSave:Toggle(player, field)
	local cur = self:Get(player, field)
	if type(cur) ~= "boolean" then
		warn("[DataSave] Toggle: '" .. field .. "' không phải boolean"); return false
	end
	return self:Set(player, field, not cur)
end

-- ────────────────────────────────────────────
--  UPDATE TABLE FIELD — cập nhật sub-table
--  DataSave:UpdateTable(player, "inventory", function(inv)
--      inv.sword = true
--      return inv
--  end)
-- ────────────────────────────────────────────
function DataSave:UpdateTable(player, field, fn)
	local cur = self:Get(player, field)
	if type(cur) ~= "table" then cur = {} end
	local updated = fn(_deepCopy(cur))
	if updated ~= nil then
		return self:Set(player, field, updated)
	end
	return false
end

-- ────────────────────────────────────────────
--  RESET — về giá trị default trong schema
-- ────────────────────────────────────────────
function DataSave:Reset(player, field)
	if field then
		-- Reset 1 field
		local session = _sessions[player.UserId]
		if not session or not session.loaded then return false end
		session.data[field] = _deepCopy(_schema[field])
		session.dirty = true
		return true
	else
		-- Reset toàn bộ
		local session = _sessions[player.UserId]
		if not session or not session.loaded then return false end
		session.data  = _applySchema({})
		session.dirty = true
		return true
	end
end

-- ────────────────────────────────────────────
--  SAVE — save thủ công (không phải lúc thoát)
-- ────────────────────────────────────────────
function DataSave:Save(player)
	if not player or not player.Parent then return end
	_savePlayer(player, false)  -- false = không xóa khỏi RAM
end

-- ────────────────────────────────────────────
--  GET SESSION INFO — debug
-- ────────────────────────────────────────────
function DataSave:GetSessionInfo(player)
	local session = _sessions[player.UserId]
	if not session then return nil end
	return {
		userId     = session.userId,
		name       = session.name,
		sessionNum = session.sessionNum,
		joinTime   = session.joinTime,
		saveTime   = session.saveTime,
		dirty      = session.dirty,
		loaded     = session.loaded,
		fieldCount = (function()
			local n = 0; for _ in pairs(session.data) do n += 1 end; return n
		end)(),
	}
end

-- ────────────────────────────────────────────
--  GET ALL SESSIONS — liệt kê tất cả player đang online
-- ────────────────────────────────────────────
function DataSave:GetAllSessions()
	local result = {}
	for uid, session in pairs(_sessions) do
		table.insert(result, {
			userId     = session.userId,
			name       = session.name,
			sessionNum = session.sessionNum,
			loaded     = session.loaded,
			dirty      = session.dirty,
		})
	end
	return result
end

-- ────────────────────────────────────────────
--  WIPE — xóa hoàn toàn data player khỏi DataStore
--  (GDPR / admin reset)
-- ────────────────────────────────────────────
function DataSave:Wipe(player)
	local uid = player.UserId
	local ok  = _dsRemove(_key(uid))
	if ok then
		-- Reset RAM về default
		local session = _sessions[uid]
		if session then
			session.data  = _applySchema({})
			session.dirty = false
		end
		print("[DataSave] Wiped data: " .. player.Name)
		return true
	end
	return false
end

-- ════════════════════════════════════════════
--  PLAYER LIFECYCLE
-- ════════════════════════════════════════════

Players.PlayerAdded:Connect(function(player)
	_loadPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
	_savePlayer(player, true)  -- true = thoát, xóa RAM sau khi save
end)

-- Load player đang online lúc module được require
for _, player in Players:GetPlayers() do
	task.spawn(_loadPlayer, player)
end

-- ════════════════════════════════════════════
--  AUTO DIRTY TRACKER (log, không save DS)
--  Save thực sự chỉ xảy ra khi thoát hoặc gọi :Save()
-- ════════════════════════════════════════════
task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_INT)
		local dirtyCount = 0
		for uid, session in pairs(_sessions) do
			if session.dirty then dirtyCount += 1 end
		end
		if dirtyCount > 0 then
			print(string.format("[DataSave] %d player có data chưa được save (sẽ save khi thoát)", dirtyCount))
		end
	end
end)

-- ════════════════════════════════════════════
--  SERVER CLOSE — save tất cả player đang online
-- ════════════════════════════════════════════

game:BindToClose(function()
	print("[DataSave] Server đóng — đang save tất cả player...")
	local saveTasks = {}
	for _, player in Players:GetPlayers() do
		table.insert(saveTasks, task.spawn(function()
			_savePlayer(player, true)
		end))
	end
	-- Chờ tất cả task hoàn thành (tối đa 25 giây)
	local waited = 0
	while #_sessions > 0 and waited < 25 do
		task.wait(0.5)
		waited += 0.5
	end
	print("[DataSave] Save hoàn tất")
end)

return DataSave

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VÍ DỤ SỬ DỤNG ĐẦY ĐỦ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

── Script khởi tạo (chạy trước mọi thứ) ──────────

local DataSave = require(game.ServerScriptService.DataSave)

-- Đăng ký các field cần lưu
DataSave:RegisterFields({
    coins     = 0,
    gems      = 0,
    level     = 1,
    exp       = 0,
    isPremium = false,
    inventory = { sword=false, shield=false },
    stats     = { kills=0, deaths=0, wins=0 },
})

── Trong game script ──────────────────────────────

local DataSave = require(game.ServerScriptService.DataSave)

game.Players.PlayerAdded:Connect(function(player)
    -- Chờ load xong trước khi dùng
    DataSave:WaitForLoad(player)

    -- Đọc data
    local coins = DataSave:Get(player, "coins")   --> 0 (lần đầu)
    print(player.Name .. " có " .. coins .. " coins")

    -- Ghi data
    DataSave:Set(player, "coins", 500)
    DataSave:Increment(player, "level", 1)
    DataSave:Toggle(player, "isPremium")

    -- Cập nhật sub-table
    DataSave:UpdateTable(player, "inventory", function(inv)
        inv.sword = true
        return inv
    end)

    -- Đọc toàn bộ
    local all = DataSave:GetAll(player)
    print(all.coins, all.level)

    -- Info session
    local info = DataSave:GetSessionInfo(player)
    print("Phiên:", info.sessionNum, "| Fields:", info.fieldCount)
end)

-- Save thủ công giữa game (optional)
DataSave:Save(player)

-- Reset 1 field về default
DataSave:Reset(player, "coins")

-- Reset toàn bộ
DataSave:Reset(player)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VÒNG ĐỜI DỌN DẸP DATA
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Vào lần 1:  Load từ DS  →  RAM: { coins=0 }
  Thoát lần 1: Save vào DS key "Player_123"  →  Xóa RAM
  Vào lần 2:  Load "Player_123" → merge schema mới → RAM
  Thoát lần 2: Save vào DS key "Player_123" (ghi đè lần 1) → Xóa RAM
               ↳ DataStore chỉ luôn giữ 1 bản duy nhất mỗi player

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

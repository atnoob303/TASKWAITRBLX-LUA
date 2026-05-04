-- ╔══════════════════════════════════════════════════════════════╗
-- ║                   DataModule  —  ModuleScript                ║
-- ║  Đặt trong: ServerScriptService (hoặc cùng nơi Data6)        ║
-- ║  Mục đích:  Cho phép bất kỳ script server nào tạo và quản    ║
-- ║             lý các "data container" theo kiểu đơn giản,      ║
-- ║             không cần biết cấu trúc phức tạp của Data6.      ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  Cách dùng nhanh:                                            ║
-- ║                                                              ║
-- ║   local DataModule = require(path.to.DataModule)             ║
-- ║                                                              ║
-- ║   -- Tạo data container                                      ║
-- ║   local ShopData = DataModule:Create("ShopData")             ║
-- ║                                                              ║
-- ║   -- Cấu hình                                                ║
-- ║   ShopData.setting.persist    = true   -- lưu DataStore      ║
-- ║   ShopData.setting.shared     = true   -- share giữa server  ║
-- ║   ShopData.setting.ttl        = 300    -- TTL (giây)         ║
-- ║   ShopData.setting.default    = {}     -- giá trị mặc định   ║
-- ║   ShopData.setting.readOnly   = false  -- cho phép ghi       ║
-- ║   ShopData.setting.onChange   = function(key,old,new) end    ║
-- ║                                                              ║
-- ║   -- Thao tác data                                           ║
-- ║   ShopData:Set("sword_price", 100)                           ║
-- ║   ShopData:Get("sword_price")   --> 100                      ║
-- ║   ShopData:Increment("sword_price", 10)                      ║
-- ║   ShopData:Delete("sword_price")                             ║
-- ║   ShopData:GetAll()             --> { sword_price = 110 }    ║
-- ║   ShopData:Reset()              -- về default                ║
-- ║   ShopData:Destroy()            -- xóa hoàn toàn             ║
-- ╚══════════════════════════════════════════════════════════════╝

local DataStoreService  = game:GetService("DataStoreService")
local MessagingService  = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService       = game:GetService("HttpService")

-- ════════════════════════════════════════════
--  INTERNAL REGISTRY
-- ════════════════════════════════════════════

local _registry = {}         -- { [id] = DataObject }
local _stores   = {}         -- { [storeName] = DataStoreObject }
local _memory   = {}         -- { [id] = MemorySortedMap }

-- ════════════════════════════════════════════
--  HELPERS
-- ════════════════════════════════════════════

local function _deepCopy(t)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t) do copy[k] = _deepCopy(v) end
	return copy
end

local function _getStore(storeName)
	if not _stores[storeName] then
		local ok, s = pcall(function()
			return DataStoreService:GetDataStore("DataModule_" .. storeName)
		end)
		if ok then _stores[storeName] = s end
	end
	return _stores[storeName]
end

local function _getMemory(id)
	if not _memory[id] then
		local ok, m = pcall(function()
			return MemoryStoreService:GetSortedMap("DataModule_" .. id)
		end)
		if ok then _memory[id] = m end
	end
	return _memory[id]
end

-- ════════════════════════════════════════════
--  DATA OBJECT CLASS
-- ════════════════════════════════════════════

local DataObject = {}
DataObject.__index = DataObject

--[[
	DataObject.setting — toàn bộ cấu hình:

	.persist    [bool]     Lưu vào DataStore (tồn tại qua server restart)
	.shared     [bool]     Sync qua MessagingService tới server khác
	.ttl        [number]   Giây sống trong MemoryStore (nếu shared)
	.readOnly   [bool]     Không cho ghi sau khi tạo xong (dùng :Lock())
	.default    [any]      Giá trị mặc định khi key không tồn tại
	.tag        [string]   Nhãn phân loại tự do (ví dụ "shop", "event")
	.autoSave   [bool]     Tự save mỗi interval giây (khi persist=true)
	.interval   [number]   Giây giữa mỗi auto-save (mặc định 60)
	.maxKeys    [number]   Giới hạn số lượng key (-1 = không giới hạn)
	.onChange   [function] Callback(key, oldValue, newValue) khi có thay đổi
	.onReset    [function] Callback() khi Reset được gọi
	.onDestroy  [function] Callback() khi Destroy được gọi
--]]

-- ────────────────────────────────────────────
--  Tạo DataObject
-- ────────────────────────────────────────────
local function _newDataObject(id, setting)
	local self = setmetatable({}, DataObject)

	self._id       = id
	self._data     = {}     -- data thực tế
	self._dirty    = false  -- cần save không
	self._locked   = false  -- readOnly sau Lock()
	self._alive    = true   -- chưa bị Destroy

	-- Setting với giá trị mặc định hợp lý
	self.setting = {
		persist   = setting.persist   ~= nil and setting.persist   or false,
		shared    = setting.shared    ~= nil and setting.shared    or false,
		ttl       = setting.ttl       or 300,
		readOnly  = setting.readOnly  ~= nil and setting.readOnly  or false,
		default   = setting.default   ~= nil and _deepCopy(setting.default) or nil,
		tag       = setting.tag       or "general",
		autoSave  = setting.autoSave  ~= nil and setting.autoSave  or false,
		interval  = setting.interval  or 60,
		maxKeys   = setting.maxKeys   or -1,
		onChange  = setting.onChange  or nil,
		onReset   = setting.onReset   or nil,
		onDestroy = setting.onDestroy or nil,
	}

	-- Nếu persist → load data từ DataStore ngay
	if self.setting.persist then
		self:_loadFromStore()
	end

	-- Auto save loop
	if self.setting.persist and self.setting.autoSave then
		task.spawn(function()
			while self._alive do
				task.wait(self.setting.interval)
				if self._dirty and self._alive then
					self:Save()
				end
			end
		end)
	end

	return self
end

-- ────────────────────────────────────────────
--  Internal: Load từ DataStore
-- ────────────────────────────────────────────
function DataObject:_loadFromStore()
	local store = _getStore(self._id)
	if not store then return end
	local ok, raw = pcall(function()
		return store:GetAsync("data")
	end)
	if ok and raw and type(raw) == "table" then
		self._data = raw
		print(string.format("[DataModule] '%s' loaded from DataStore (%d keys)", self._id, (function()
			local n = 0; for _ in pairs(raw) do n += 1 end; return n
		end)()))
	end
end

-- ────────────────────────────────────────────
--  Internal: Publish tới server khác
-- ────────────────────────────────────────────
function DataObject:_publish(key, value)
	if not self.setting.shared then return end
	pcall(function()
		MessagingService:PublishAsync("DataModule_Sync", {
			id    = self._id,
			key   = key,
			value = value,
		})
	end)
end

-- ────────────────────────────────────────────
--  SET
-- ────────────────────────────────────────────
function DataObject:Set(key, value)
	assert(type(key) == "string", "[DataModule] key phải là string")
	if not self._alive then warn("[DataModule] DataObject đã bị Destroy"); return false end
	if self._locked or self.setting.readOnly then
		warn("[DataModule] '" .. self._id .. "' là readOnly — không thể Set"); return false
	end

	-- Kiểm tra giới hạn key
	local s = self.setting
	if s.maxKeys > 0 and self._data[key] == nil then
		local count = 0
		for _ in pairs(self._data) do count += 1 end
		if count >= s.maxKeys then
			warn(string.format("[DataModule] '%s' đã đạt maxKeys=%d", self._id, s.maxKeys))
			return false
		end
	end

	local old = self._data[key]
	self._data[key] = value
	self._dirty = true

	-- Callback onChange
	if s.onChange then
		task.spawn(s.onChange, key, old, value)
	end

	-- Publish cross-server
	self:_publish(key, value)

	return true
end

-- ────────────────────────────────────────────
--  GET
-- ────────────────────────────────────────────
function DataObject:Get(key)
	if not self._alive then return nil end
	local v = self._data[key]
	if v == nil and self.setting.default ~= nil then
		-- Trả default nhưng không ghi vào data
		if type(self.setting.default) == "table" then
			return _deepCopy(self.setting.default)
		end
		return self.setting.default
	end
	return v
end

-- ────────────────────────────────────────────
--  GET ALL
-- ────────────────────────────────────────────
function DataObject:GetAll()
	if not self._alive then return {} end
	return _deepCopy(self._data)
end

-- ────────────────────────────────────────────
--  DELETE
-- ────────────────────────────────────────────
function DataObject:Delete(key)
	if not self._alive then return false end
	if self._locked or self.setting.readOnly then
		warn("[DataModule] '" .. self._id .. "' là readOnly"); return false
	end
	if self._data[key] ~= nil then
		local old = self._data[key]
		self._data[key] = nil
		self._dirty = true
		if self.setting.onChange then
			task.spawn(self.setting.onChange, key, old, nil)
		end
		self:_publish(key, nil)
	end
	return true
end

-- ────────────────────────────────────────────
--  INCREMENT / DECREMENT
-- ────────────────────────────────────────────
function DataObject:Increment(key, amount)
	amount = amount or 1
	local cur = self._data[key]
	if cur == nil then cur = 0 end
	if type(cur) ~= "number" then
		warn("[DataModule] Increment: '" .. key .. "' không phải number"); return false
	end
	return self:Set(key, cur + amount)
end

function DataObject:Decrement(key, amount)
	amount = amount or 1
	return self:Increment(key, -amount)
end

-- ────────────────────────────────────────────
--  TOGGLE
-- ────────────────────────────────────────────
function DataObject:Toggle(key)
	local cur = self._data[key]
	if type(cur) ~= "boolean" then
		warn("[DataModule] Toggle: '" .. key .. "' không phải boolean"); return false
	end
	return self:Set(key, not cur)
end

-- ────────────────────────────────────────────
--  HAS
-- ────────────────────────────────────────────
function DataObject:Has(key)
	return self._data[key] ~= nil
end

-- ────────────────────────────────────────────
--  COUNT
-- ────────────────────────────────────────────
function DataObject:Count()
	local n = 0
	for _ in pairs(self._data) do n += 1 end
	return n
end

-- ────────────────────────────────────────────
--  RESET — về default hoặc clear hết
-- ────────────────────────────────────────────
function DataObject:Reset()
	if self._locked or self.setting.readOnly then
		warn("[DataModule] '" .. self._id .. "' là readOnly"); return false
	end
	self._data  = {}
	self._dirty = true
	if self.setting.onReset then
		task.spawn(self.setting.onReset)
	end
	return true
end

-- ────────────────────────────────────────────
--  LOCK — đặt readOnly runtime
-- ────────────────────────────────────────────
function DataObject:Lock()
	self._locked = true
end

function DataObject:Unlock()
	self._locked = false
end

-- ────────────────────────────────────────────
--  SAVE — lưu vào DataStore thủ công
-- ────────────────────────────────────────────
function DataObject:Save()
	if not self.setting.persist then
		warn("[DataModule] '" .. self._id .. "' không bật persist"); return false
	end
	local store = _getStore(self._id)
	if not store then return false end
	local ok, err = pcall(function()
		store:SetAsync("data", self._data)
	end)
	if ok then
		self._dirty = false
		print(string.format("[DataModule] '%s' saved (%d keys)", self._id, self:Count()))
		return true
	else
		warn("[DataModule] Save failed: " .. tostring(err))
		return false
	end
end

-- ────────────────────────────────────────────
--  DESTROY — xóa khỏi registry, save nếu cần
-- ────────────────────────────────────────────
function DataObject:Destroy()
	if not self._alive then return end
	if self._dirty and self.setting.persist then
		self:Save()
	end
	if self.setting.onDestroy then
		task.spawn(self.setting.onDestroy)
	end
	self._alive = false
	self._data  = {}
	_registry[self._id] = nil
	_memory[self._id]   = nil
	print("[DataModule] '" .. self._id .. "' destroyed")
end

-- ────────────────────────────────────────────
--  INFO — thông tin debug
-- ────────────────────────────────────────────
function DataObject:Info()
	return {
		id       = self._id,
		keys     = self:Count(),
		dirty    = self._dirty,
		locked   = self._locked,
		alive    = self._alive,
		setting  = _deepCopy(self.setting),
	}
end

-- ════════════════════════════════════════════
--  MODULE CHÍNH
-- ════════════════════════════════════════════

local DataModule = {}

-- ────────────────────────────────────────────
--  Create — tạo DataObject mới
--
--  Cách dùng:
--    local D = DataModule:Create("MyData")
--    local D = DataModule:Create("MyData", { persist=true, tag="shop" })
--
--  Nếu đã tồn tại cùng id → trả về cái cũ (không tạo mới)
-- ────────────────────────────────────────────
function DataModule:Create(id, setting)
	assert(type(id) == "string" and id ~= "", "[DataModule] id phải là string không rỗng")
	setting = setting or {}

	if _registry[id] then
		warn("[DataModule] '" .. id .. "' đã tồn tại — trả về instance cũ")
		return _registry[id]
	end

	local obj = _newDataObject(id, setting)
	_registry[id] = obj
	print(string.format("[DataModule] Created '%s' | persist=%s | shared=%s | tag=%s",
		id,
		tostring(obj.setting.persist),
		tostring(obj.setting.shared),
		tostring(obj.setting.tag)
	))
	return obj
end

-- ────────────────────────────────────────────
--  Get — lấy DataObject đã tạo theo id
-- ────────────────────────────────────────────
function DataModule:Get(id)
	return _registry[id]
end

-- ────────────────────────────────────────────
--  GetOrCreate — lấy nếu có, tạo nếu chưa có
-- ────────────────────────────────────────────
function DataModule:GetOrCreate(id, setting)
	return _registry[id] or self:Create(id, setting)
end

-- ────────────────────────────────────────────
--  List — liệt kê tất cả DataObject đang sống
-- ────────────────────────────────────────────
function DataModule:List()
	local list = {}
	for id, obj in pairs(_registry) do
		table.insert(list, obj:Info())
	end
	return list
end

-- ────────────────────────────────────────────
--  Destroy — xóa 1 DataObject theo id
-- ────────────────────────────────────────────
function DataModule:Destroy(id)
	local obj = _registry[id]
	if obj then obj:Destroy() end
end

-- ────────────────────────────────────────────
--  SaveAll — lưu tất cả dirty object
-- ────────────────────────────────────────────
function DataModule:SaveAll()
	for _, obj in pairs(_registry) do
		if obj._dirty and obj.setting.persist then
			obj:Save()
		end
	end
end

-- ════════════════════════════════════════════
--  CROSS-SERVER SYNC (nhận update từ server khác)
-- ════════════════════════════════════════════

pcall(function()
	MessagingService:SubscribeAsync("DataModule_Sync", function(msg)
		local d = msg.Data
		local obj = _registry[d.id]
		if not obj then return end
		-- Cập nhật trực tiếp vào _data (không trigger onChange lần nữa)
		if d.value == nil then
			obj._data[d.key] = nil
		else
			obj._data[d.key] = d.value
		end
	end)
end)

-- ════════════════════════════════════════════
--  SERVER CLOSE — save tất cả
-- ════════════════════════════════════════════

game:BindToClose(function()
	DataModule:SaveAll()
end)

return DataModule

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VÍ DỤ SỬ DỤNG ĐẦY ĐỦ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local DataModule = require(game.ServerScriptService.DataModule)

────────────────────────────────────────────────────
 Ví dụ 1: Shop prices — persist + shared giữa server
────────────────────────────────────────────────────
local ShopData = DataModule:Create("ShopPrices", {
    persist  = true,     -- lưu qua server restart
    shared   = true,     -- sync tới server khác
    tag      = "shop",
    onChange = function(key, old, new)
        print("Giá thay đổi:", key, old, "→", new)
    end,
})

ShopData:Set("sword",  150)
ShopData:Set("shield", 300)
ShopData:Increment("sword", 50)    -- sword = 200
ShopData:Get("sword")              --> 200
ShopData:GetAll()                  --> { sword=200, shield=300 }

────────────────────────────────────────────────────
 Ví dụ 2: Event state — chỉ RAM, không persist
────────────────────────────────────────────────────
local EventData = DataModule:Create("CurrentEvent", {
    persist = false,
    tag     = "event",
    default = false,    -- Get key nào không có → trả false
})

EventData:Set("doubleXP",    true)
EventData:Set("bonusCoins",  false)
EventData:Toggle("doubleXP")       -- → false
EventData:Get("randomKey")         --> false (default)

────────────────────────────────────────────────────
 Ví dụ 3: Config với readOnly sau khi setup
────────────────────────────────────────────────────
local GameConfig = DataModule:Create("GameConfig", {
    persist  = true,
    tag      = "config",
    maxKeys  = 20,
    autoSave = true,
    interval = 120,
})

GameConfig:Set("maxPlayers",  50)
GameConfig:Set("mapName",     "City")
GameConfig:Lock()    -- sau đây không ai Set được nữa

────────────────────────────────────────────────────
 Ví dụ 4: Lấy lại object từ script khác
────────────────────────────────────────────────────
local ShopData = DataModule:Get("ShopPrices")
if ShopData then
    print(ShopData:Get("sword"))
end

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

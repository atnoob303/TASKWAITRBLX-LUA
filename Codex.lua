-- ============================================================
--  SliderModule.Code  |  Reward Code Redeem Component
--
--  Dán đoạn này vào Setting13.lua, TRƯỚC dòng "return SliderModule"
--  Sau đó thêm "or t == "Code"" vào assert trong SliderModule.New
--
--  Cấu trúc template (CodeTemplate):
--    CodeTemplate (Frame)
--    ├── UIAspectRatioConstraint
--    ├── UICorner
--    ├── UIGradient
--    ├── BoxFrame (Frame)
--    │   ├── UICorner
--    │   ├── UIGradient
--    │   ├── Decor              ← (optional) ImageLabel/TextLabel icon
--    │   └── CodeEnter          ← TextBox nhập code
--    ├── InfoFrame (Frame)
--    │   ├── UICorner
--    │   ├── NameSetting        ← TextLabel title
--    │   │   └── InfoSetting    ← TextLabel trạng thái / lịch sử
--    └── ButtonDelta            ← hover effect tự động
--
--  Config:
--    template      (Frame)     : CodeTemplate
--    parent        (Frame)     : frame cha
--    title         (string)    : tên hiển thị — default "Reward Code"
--    tag           (any)       : gửi kèm callback
--    placeholder   (string)    : placeholder TextBox — default "ENTER CODE..."
--    caseSensitive (bool)      : phân biệt hoa/thường — default false
--    cooldown      (number)    : giây chờ giữa 2 lần redeem — default 5
--    maxHistory    (number)    : số code lưu trong lịch sử — default 20
--
--  ── Nguồn code (1 trong 2 hoặc cả hai) ─────────────────────
--    codes         (table)     : danh sách code trực tiếp
--                                {
--                                  ["SUMMER2025"] = {
--                                      reward  = "100 Coins",
--                                      maxUses = 50,          -- nil = unlimited
--                                      onRedeem = function(player) end  -- optional
--                                  },
--                                  ...
--                                }
--    codeModule    (table)     : require(ModuleScript) — cùng format như codes
--                                config ưu tiên codes trước, fallback codeModule
--
--  ── Callbacks ───────────────────────────────────────────────
--    onRedeem  (function) : onRedeem(code, reward, info, tag)
--                             code   = string code đã nhập
--                             reward = giá trị reward từ table
--                             info   = { title, timestamp, uses, maxUses }
--    onInvalid (function) : onInvalid(code, reason, info, tag)
--                             reason = "NOT_FOUND" | "ALREADY_USED" | "MAX_USES" | "COOLDOWN"
--    onCheck   (function) : onCheck(code, result, info, tag)
--                             result = { valid, reward, uses, maxUses, reason }
--
--  ── Public API ──────────────────────────────────────────────
--    inst:redeem(code)         -- redeem thủ công
--    inst:check(code)          -- chỉ kiểm tra, không redeem — trả về result table
--    inst:addCode(key, data)   -- thêm code runtime
--    inst:removeCode(key)      -- xóa code runtime
--    inst:resetUses(key)       -- reset số lần dùng của 1 code
--    inst:resetAllUses()       -- reset toàn bộ
--    inst:getHistory()         -- trả về table lịch sử redeem
--    inst:clearHistory()       -- xóa lịch sử
--    inst:getUsedCodes()       -- trả về set code đã dùng (per-player)
--    inst:setVisible(bool)
--    inst:destroy()
-- ============================================================

-- ════════════════════════════════════════════════════════════
--  CODE REGISTRY  —  theo dõi uses toàn cục (shared giữa instances)
--  codeUsageRegistry[normalizedKey] = { uses = N }
-- ════════════════════════════════════════════════════════════
local codeUsageRegistry = {}

function SliderModule.Code(config)
	assert(config.parent, "[SliderModule.Code] Thiếu 'parent'")

	local template = config.template
		or script:FindFirstChild("CodeTemplate")
	assert(template, "[SliderModule.Code] Không tìm thấy template — truyền vào hoặc đặt 'CodeTemplate' trong ModuleScript")

	-- ── Config ───────────────────────────────────────────────
	local title         = config.title        or "Reward Code"
	local placeholder   = config.placeholder  or "ENTER CODE..."
	local caseSensitive = config.caseSensitive or false
	local cooldownTime  = config.cooldown      or 5
	local maxHistory    = config.maxHistory    or 20

	-- Gộp nguồn code: config.codes ưu tiên, fallback codeModule
	local function buildCodeTable()
		local merged = {}
		if config.codeModule and type(config.codeModule) == "table" then
			for k, v in pairs(config.codeModule) do
				merged[k] = v
			end
		end
		-- codes trực tiếp ghi đè codeModule
		if config.codes and type(config.codes) == "table" then
			for k, v in pairs(config.codes) do
				merged[k] = v
			end
		end
		return merged
	end

	-- ── Clone template ────────────────────────────────────────
	local frame = template:Clone()
	frame.Name    = "Setting_" .. title
	frame.Visible = true
	frame.Parent  = config.parent

	-- ── Find children ─────────────────────────────────────────
	local BoxFrame   = frame:FindFirstChild("BoxFrame")
	local InfoFrame  = frame:FindFirstChild("InfoFrame")
	local TitleLabel = InfoFrame  and InfoFrame:FindFirstChild("NameSetting")
	local RangeLabel = TitleLabel and TitleLabel:FindFirstChild("InfoSetting")
	local CodeEnter  = BoxFrame   and BoxFrame:FindFirstChild("CodeEnter")
	local Decor      = BoxFrame   and BoxFrame:FindFirstChild("Decor")

	assert(BoxFrame,  "[SliderModule.Code] Thiếu 'BoxFrame'")
	assert(CodeEnter, "[SliderModule.Code] Thiếu 'CodeEnter' (TextBox) trong BoxFrame")

	-- Init UI
	if TitleLabel then TitleLabel.Text = title end
	if RangeLabel then RangeLabel.Text = "READY" end
	CodeEnter.PlaceholderText = placeholder
	CodeEnter.Text            = ""

	-- ButtonDelta hover
	setupButtonDelta(frame)

	-- ── State ─────────────────────────────────────────────────
	local codes        = buildCodeTable()      -- live code table
	local history      = {}                    -- { {code, reward, timestamp} }
	local usedByPlayer = {}                    -- set: normalizedCode đã dùng session này
	local lastRedeemTime = -math.huge          -- cooldown tracking
	local statusTween  = nil

	-- ── Helpers ───────────────────────────────────────────────
	local function normalizeCode(raw)
		if caseSensitive then
			return raw:match("^%s*(.-)%s*$")  -- chỉ trim
		end
		return raw:match("^%s*(.-)%s*$"):upper()
	end

	local function getUsageEntry(key)
		if not codeUsageRegistry[key] then
			codeUsageRegistry[key] = { uses = 0 }
		end
		return codeUsageRegistry[key]
	end

	-- Tween màu InfoSetting để báo kết quả
	local COLOR_OK      = Color3.fromRGB(100, 220, 100)
	local COLOR_FAIL    = Color3.fromRGB(220, 80,  80 )
	local COLOR_WARN    = Color3.fromRGB(220, 180, 60 )
	local COLOR_DEFAULT = RangeLabel and RangeLabel.TextColor3 or Color3.fromRGB(180, 180, 180)

	local function flashStatus(text, color, duration)
		if not RangeLabel then return end
		if statusTween then statusTween:Cancel() end
		RangeLabel.Text       = text
		RangeLabel.TextColor3 = color
		-- Reset về default sau duration
		statusTween = TweenService:Create(RangeLabel,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out,
				0, false, duration or 2.5),
			{ TextColor3 = COLOR_DEFAULT }
		)
		statusTween:Play()
		statusTween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then
				if RangeLabel then
					RangeLabel.TextColor3 = COLOR_DEFAULT
				end
			end
		end)
	end

	local function addToHistory(code, reward)
		table.insert(history, 1, {
			code      = code,
			reward    = reward,
			timestamp = makeTimestamp(title),
		})
		if #history > maxHistory then
			table.remove(history, #history)
		end
	end

	-- ════════════════════════════════════════════════════════════
	--  CORE: check(code) — kiểm tra không redeem
	--  Trả về: { valid, reward, uses, maxUses, reason }
	-- ════════════════════════════════════════════════════════════
	local function checkCode(raw)
		local key  = normalizeCode(raw)
		local data = codes[key]

		if not data then
			return { valid=false, reason="NOT_FOUND", uses=0, maxUses=nil, reward=nil }
		end

		local entry   = getUsageEntry(key)
		local maxUses = data.maxUses  -- nil = unlimited

		-- Đã dùng trong session này chưa?
		if usedByPlayer[key] then
			return { valid=false, reason="ALREADY_USED", uses=entry.uses, maxUses=maxUses, reward=data.reward }
		end

		-- Vượt maxUses chưa?
		if maxUses and entry.uses >= maxUses then
			return { valid=false, reason="MAX_USES", uses=entry.uses, maxUses=maxUses, reward=data.reward }
		end

		return { valid=true, reason=nil, uses=entry.uses, maxUses=maxUses, reward=data.reward }
	end

	-- ════════════════════════════════════════════════════════════
	--  CORE: redeem(code) — thực thi đổi thưởng
	-- ════════════════════════════════════════════════════════════
	local function redeemCode(raw)
		local key  = normalizeCode(raw)

		-- Cooldown check
		local now = tick()
		if (now - lastRedeemTime) < cooldownTime then
			local remaining = math.ceil(cooldownTime - (now - lastRedeemTime))
			flashStatus("COOLDOWN: Wait " .. remaining .. "s", COLOR_WARN)
			if config.onInvalid then
				config.onInvalid(key, "COOLDOWN", {
					title     = title,
					timestamp = makeTimestamp(title),
					remaining = remaining,
				}, config.tag)
			end
			if config.onCheck then
				config.onCheck(key, { valid=false, reason="COOLDOWN", remaining=remaining }, {
					title = title, timestamp = makeTimestamp(title)
				}, config.tag)
			end
			return false
		end

		local result = checkCode(raw)

		-- Fire onCheck dù valid hay không
		if config.onCheck then
			config.onCheck(key, result, {
				title     = title,
				timestamp = makeTimestamp(title),
			}, config.tag)
		end

		if not result.valid then
			-- Hiện lý do thất bại
			local messages = {
				NOT_FOUND    = "INVALID: Code not found",
				ALREADY_USED = "ALREADY REDEEMED",
				MAX_USES     = "CODE EXPIRED (max uses reached)",
			}
			flashStatus(messages[result.reason] or "INVALID CODE", COLOR_FAIL)
			lastRedeemTime = now  -- vẫn tính cooldown kể cả fail (chống spam)

			if config.onInvalid then
				config.onInvalid(key, result.reason, {
					title     = title,
					timestamp = makeTimestamp(title),
					uses      = result.uses,
					maxUses   = result.maxUses,
				}, config.tag)
			end
			return false
		end

		-- ✅ VALID — thực hiện redeem
		local entry = getUsageEntry(key)
		entry.uses        = entry.uses + 1
		usedByPlayer[key] = true
		lastRedeemTime    = now

		local data   = codes[key]
		local reward = data.reward

		-- Cập nhật RangeLabel
		local rewardStr = tostring(reward or "Reward")
		local usesStr   = data.maxUses
			and (" [" .. entry.uses .. "/" .. data.maxUses .. "]")
			or  (" [" .. entry.uses .. " uses]")
		flashStatus("✓ REDEEMED: " .. rewardStr .. usesStr, COLOR_OK, 4)

		-- Lưu lịch sử
		addToHistory(key, reward)

		-- Gọi onRedeem riêng của từng code (nếu có)
		if data.onRedeem then
			local ok, err = pcall(data.onRedeem, key, reward)
			if not ok then
				warn("[SliderModule.Code] onRedeem error for '" .. key .. "': " .. tostring(err))
			end
		end

		-- Gọi onRedeem global
		if config.onRedeem then
			config.onRedeem(key, reward, {
				title     = title,
				timestamp = makeTimestamp(title),
				uses      = entry.uses,
				maxUses   = data.maxUses,
			}, config.tag)
		end

		return true
	end

	-- ── Self / instance ───────────────────────────────────────
	local self = setmetatable({
		Frame  = frame,
		_title = title,
		_tag   = config.tag,
		_conns = {},
	}, SliderModule)

	-- ── Input: Enter key (FocusLost) ─────────────────────────
	table.insert(self._conns, CodeEnter.FocusLost:Connect(function(enterPressed)
		if not enterPressed then return end
		local raw = CodeEnter.Text
		if raw == "" or raw == placeholder then return end
		redeemCode(raw)
		CodeEnter.Text = ""
	end))

	-- ── Input: Decor bấm được (nếu là Button) ────────────────
	if Decor and Decor:IsA("TextButton") or (Decor and Decor:IsA("ImageButton")) then
		table.insert(self._conns, Decor.MouseButton1Click:Connect(function()
			local raw = CodeEnter.Text
			if raw == "" or raw == placeholder then return end
			redeemCode(raw)
			CodeEnter.Text = ""
		end))
	end

	-- ── Input: Decor là Frame có con Button ──────────────────
	if Decor and Decor:IsA("Frame") then
		local innerBtn = Decor:FindFirstChildWhichIsA("TextButton")
			or Decor:FindFirstChildWhichIsA("ImageButton")
		if innerBtn then
			table.insert(self._conns, innerBtn.MouseButton1Click:Connect(function()
				local raw = CodeEnter.Text
				if raw == "" or raw == placeholder then return end
				redeemCode(raw)
				CodeEnter.Text = ""
			end))
		end
	end

	-- ════════════════════════════════════════════════════════════
	--  PUBLIC API
	-- ════════════════════════════════════════════════════════════

	--- Redeem thủ công (không cần UI)
	function self:redeem(code)
		return redeemCode(tostring(code))
	end

	--- Chỉ kiểm tra — không tốn lượt, không cooldown, không lịch sử
	function self:check(code)
		local result = checkCode(tostring(code))
		if config.onCheck then
			config.onCheck(normalizeCode(tostring(code)), result, {
				title = title, timestamp = makeTimestamp(title),
			}, config.tag)
		end
		return result
	end

	--- Thêm code runtime
	function self:addCode(key, data)
		assert(type(key) == "string", "[SliderModule.Code:addCode] key phải là string")
		local normalized = caseSensitive and key or key:upper()
		codes[normalized] = data
	end

	--- Xóa code runtime
	function self:removeCode(key)
		local normalized = caseSensitive and key or key:upper()
		codes[normalized] = nil
	end

	--- Reset số lần dùng của 1 code (và xóa khỏi usedByPlayer)
	function self:resetUses(key)
		local normalized = caseSensitive and key or key:upper()
		if codeUsageRegistry[normalized] then
			codeUsageRegistry[normalized].uses = 0
		end
		usedByPlayer[normalized] = nil
		if RangeLabel then
			RangeLabel.Text = "RESET: " .. normalized
		end
	end

	--- Reset toàn bộ codes
	function self:resetAllUses()
		for k in pairs(codes) do
			local normalized = caseSensitive and k or k:upper()
			if codeUsageRegistry[normalized] then
				codeUsageRegistry[normalized].uses = 0
			end
		end
		usedByPlayer = {}
		if RangeLabel then RangeLabel.Text = "ALL CODES RESET" end
	end

	--- Lấy lịch sử redeem
	--- Trả về: { {code, reward, timestamp}, ... } (mới nhất trước)
	function self:getHistory()
		local copy = {}
		for i, v in ipairs(history) do copy[i] = v end
		return copy
	end

	--- Xóa lịch sử
	function self:clearHistory()
		history = {}
		if RangeLabel then RangeLabel.Text = "HISTORY CLEARED" end
	end

	--- Lấy set code đã dùng trong session
	function self:getUsedCodes()
		local copy = {}
		for k, v in pairs(usedByPlayer) do copy[k] = v end
		return copy
	end

	--- Cập nhật toàn bộ code table runtime
	function self:setCodes(newCodes)
		codes = newCodes or {}
	end

	function self:setOnChange(fn)
		config.onRedeem = fn
	end

	function self:setVisible(bool)
		frame.Visible = bool
	end

	function self:getValue()
		-- Trả về code cuối cùng được redeem thành công
		return history[1] and history[1].code or nil
	end

	function self:destroy()
		for _, conn in ipairs(self._conns) do conn:Disconnect() end
		self._conns = {}
		if statusTween then statusTween:Cancel() end
		createdSliders[frame] = nil
		if frame.Parent then frame:Destroy() end
	end

	-- Đăng ký vào registry
	createdSliders[frame] = self

	return self
end

-- ════════════════════════════════════════════════════════════
--  Cập nhật SliderModule.New — thêm "Code" vào assert:
--
--  assert(t == "Slider" or t == "SliderButton" or t == "Enabled"
--      or t == "Selected" or t == "Color" or t == "Gradient"
--      or t == "Key" or t == "Code",
--      '[SliderModule.New] type phải là ... hoặc "Code"')
-- ════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════
--  VÍ DỤ SỬ DỤNG (xóa trước khi deploy)
-- ════════════════════════════════════════════════════════════
--[[

-- ── Cách 1: Truyền codes trực tiếp ──────────────────────────
local RewardCode = SliderModule.New({
    type     = "Code",
    template = script.Parent.CodeTemplate,
    parent   = script.Parent.SettingFrame,
    title    = "REWARD CODE",
    cooldown = 3,

    codes = {
        ["SUMMER2025"] = {
            reward  = "100 Coins",
            maxUses = 50,
            onRedeem = function(code, reward)
                -- xử lý phần thưởng cho player
                print("Player redeemed:", code, "→", reward)
            end,
        },
        ["FREEGIFT"] = {
            reward  = "VIP Badge",
            maxUses = nil,  -- unlimited
        },
        ["BETA100"] = {
            reward = "500 Gems",
            maxUses = 100,
        },
    },

    onRedeem = function(code, reward, info, tag)
        print("✓ Redeemed:", code, "| Reward:", reward)
        print("Timestamp:", info.timestamp)
        print("Uses:", info.uses, "/", info.maxUses or "∞")
    end,

    onInvalid = function(code, reason, info, tag)
        print("✗ Failed:", code, "| Reason:", reason)
    end,

    onCheck = function(code, result, info, tag)
        -- fired mỗi lần attempt (kể cả cooldown)
        print("Check:", code, "→", result.valid and "VALID" or result.reason)
    end,
})

-- ── Cách 2: Dùng require Module ─────────────────────────────
-- local CodeData = require(game.ReplicatedStorage.RewardCodes)
-- local RewardCode = SliderModule.New({
--     type       = "Code",
--     template   = ...,
--     parent     = ...,
--     title      = "REWARD CODE",
--     codeModule = CodeData,   -- table từ module
--     onRedeem   = function(code, reward, info) ... end,
-- })

-- ── Runtime operations ───────────────────────────────────────
-- RewardCode:addCode("NEWCODE2025", { reward = "50 Coins", maxUses = 10 })
-- RewardCode:removeCode("FREEGIFT")
-- RewardCode:resetUses("SUMMER2025")
-- RewardCode:resetAllUses()

-- local history = RewardCode:getHistory()
-- for _, entry in ipairs(history) do
--     print(entry.code, entry.reward, entry.timestamp)
-- end

-- local result = RewardCode:check("SUMMER2025")
-- print(result.valid, result.reason, result.uses, result.maxUses)

-- RewardCode:redeem("BETA100")  -- redeem thủ công
--]]

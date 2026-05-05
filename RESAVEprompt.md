Tôi muốn xây dựng một hệ thống save/load data cho game Roblox 
với thiết kế như sau:

═══════════════════════════════════════
CẤU TRÚC TỔNG QUAN
═══════════════════════════════════════
- 1 ModuleScript duy nhất (đặt trong ServerScriptService)
- 1 Remote duy nhất xử lý tất cả (1 RemoteEvent hoặc RemoteFunction)
- Tích hợp vào Data9.lua (ServerDataManager) có sẵn

═══════════════════════════════════════
1. PLAYER DATA
═══════════════════════════════════════
Lưu:
- status: "alive" hoặc "dead"
- inventory: danh sách seed của item
  (seed → tự reconstruct toàn bộ thuộc tính, chức năng, 
   không cần lưu từng thuộc tính riêng)

═══════════════════════════════════════
2. MAP DATA — FOLDER STRUCTURE
═══════════════════════════════════════
Cấu trúc:
  ChapterName/
    └─ ZoneName/
         └─ trigger_1, trigger_2, progress_x ...

Seed:
- Mỗi Zone có seed riêng (không phải seed chung cả Chapter)
- Seed của Zone → recreate toàn bộ: quái, coin, 
  model random trong zone đó
- Chỉ cần lưu seed + list trigger đã kích hoạt

Khi load lại:
- Dùng seed recreate map y chang
- Replay toàn bộ trigger đã kích hoạt với player = nil
  → cửa/tiến trình vẫn giữ ✅
  → coin/item không được nhặt lại ✅
  → map load đúng ✅
- Xóa map cũ trước khi load map mới

═══════════════════════════════════════
3. IDLE SAVE SYSTEM
═══════════════════════════════════════
Logic:
- Player đang di chuyển → KHÔNG save
- Player dừng lại ≥ 1 giây → FORCE SAVE ngay lập tức
  (bất kể cooldown, vì dừng đột ngột = có thể bị crack/lag)
- Cooldown bình thường: 30 giây giữa 2 lần save thông thường
- Mỗi lần save mới → xóa save cũ (chỉ giữ 1 bản mới nhất)

Lý do: crack game thường pause game → character đứng yên tại chỗ
→ detect được khoảnh khắc đó và save ngay trước khi văng

Detect bằng: HumanoidRootPart.Velocity hoặc Humanoid.MoveDirection

═══════════════════════════════════════
4. LOD SYSTEM (Level of Detail)
═══════════════════════════════════════
Load priority theo khoảng cách:
- Zone player đang đứng  → load FULL
- Zone kề bên            → load skeleton (không texture)
- Zone xa                → KHÔNG load

3 chế độ hiển thị:
- 🔴 Giảm lag   : không texture, model cơ bản (mặc định khi load)
- 🟡 Cơ bản     : texture thấp, model đầy đủ
- 🟢 Nâng cao   : texture cao, full detail

Auto mode (có nút bật/tắt):
- FPS > 45 ổn định 10 giây → tự nâng lên Cơ bản
- FPS > 60 ổn định 10 giây → tự nâng lên Nâng cao  
- FPS < 30                 → tự giảm xuống Giảm lag
- Player có thể tắt auto và chọn thủ công

═══════════════════════════════════════
YÊU CẦU KỸ THUẬT
═══════════════════════════════════════
- Dùng UpdateAsync (không dùng SetAsync)
- Session lock chống 2 server ghi đè nhau
- BindToClose để save khi server shutdown
- pcall bọc toàn bộ DataStore call
- Rate limit: tối đa 10 calls / 5 giây mỗi player
- Tương thích với Data9.lua (ServerDataManager) có sẵn

═══════════════════════════════════════
FILE CÓ SẴN
═══════════════════════════════════════
[Paste nội dung Data9.lua vào đây khi dùng prompt này]

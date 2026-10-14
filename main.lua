--========================================================
-- Data Exporter v1.1 (Script — วางใน ServerScriptService)
-- เก็บข้อมูล Player (Items + Wen + Lv + Rep + Icon URL) → JSON → POST ทุก 5 วิ
--========================================================

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--────────── CONFIG — แก้ 3 ค่านี้ ──────────
local WEBHOOK_URL = "https://sl2.temp-th.net/webhook" -- <-- URL ปลายทาง
local POST_INTERVAL = 5                                    -- ทุกกี่วินาที
local TARGET_USERID = "auto"                                -- ★ "auto" = ตรวจจาก LocalPlayer/CreatorId อัตโนมัติ / ใส่เลข UserId เฉพาะเจาะจง / 0 = ทุกคน
--───────────────────────────────────────────

--────────────────────────────────────────
-- ★ Auto-detect UserId ของเจ้าของเครื่อง — cache ค่าที่ตรวจพบครั้งแรก
--────────────────────────────────────────
local DETECTED_USERID: number?  -- nil = ยังไม่ตรวจ, 0 = ตรวจแล้วแต่ไม่พบ

local function getTargetUserId(): number
    -- cache ถ้าเคยตรวจแล้ว
    if DETECTED_USERID ~= nil then
        return DETECTED_USERID
    end

    -- กรณี 1: ผู้ใช้ใส่เลข UserId ตรงๆ มา
    if type(TARGET_USERID) == "number" and TARGET_USERID > 0 then
        DETECTED_USERID = TARGET_USERID
        print("[Export] ใช้ UserId ที่กำหนดตรงๆ:", DETECTED_USERID)
        return DETECTED_USERID
    end

    -- กรณี 2: โหมด auto (string "auto" หรือ number 0)
    -- ลอง Players.LocalPlayer ก่อน — ใช้ได้เฉพาะฝั่ง client (LocalScript / Executor)
    -- บน server LocalPlayer จะเป็น nil
    local LocalPlayer = Players.LocalPlayer
    if LocalPlayer then
        DETECTED_USERID = LocalPlayer.UserId
        print("[Export] Auto-detect สำเร็จ (LocalPlayer):", DETECTED_USERID,
              "| DisplayName:", LocalPlayer.DisplayName, "| Name:", LocalPlayer.Name)
        return DETECTED_USERID
    end

    -- กรณี 3: ฝั่ง server — ใช้ game.CreatorId (เจ้าของ place)
    -- ตรวจว่า place นี้เป็นของ User หรือ Group ก่อน
    if game.CreatorType == Enum.CreatorType.User then
        DETECTED_USERID = game.CreatorId
        print("[Export] Auto-detect สำเร็จ (game.CreatorId):", DETECTED_USERID)
        return DETECTED_USERID
    end

    -- กรณี 4: place เป็นของ Group → ไม่สามารถ auto-detect user คนใดคนหนึ่งได้
    if game.CreatorType == Enum.CreatorType.Group then
        warn("[Export] ⚠️ Auto-detect ไม่สำเร็จ — place นี้เป็นของ Group ID:", game.CreatorId)
        warn("[Export] กรุณาใส่ TARGET_USERID เป็นเลข UserId ตรงๆ (เช่น TARGET_USERID = 123456789)")
    else
        warn("[Export] ⚠️ ไม่สามารถตรวจสอบ UserId ได้ — ไม่มี LocalPlayer และ CreatorType =", game.CreatorType)
    end

    DETECTED_USERID = 0  -- 0 = โหมด "ไม่กรอง" (ทุกคน) — เพื่อความปลอดภัยถ้า auto ล้มเหลว
    return DETECTED_USERID
end

--────────────────────────────────────────
-- ★ กรองเฉพาะเจ้าของบัญชี — คืน true ถ้า player คือเป้าหมาย
--────────────────────────────────────────
local function isTargetPlayer(player: Player): boolean
    local targetId = getTargetUserId()
    -- targetId == 0 → โหมดไม่กรอง (เก็บข้อมูลทุกคน)
    if targetId == 0 then
        return true
    end
    return player.UserId == targetId
end

-- ค่าคงที่จาก gameSettings.lua
local EXP_PER_LEVEL = 60
local MAX_LEVEL = 225

-- ★ เพิ่ม: require ItemIcon module (ฝั่ง shared — server ใช้ได้)
-- ไฟล์นี้อยู่ที่ ReplicatedStorage/CAM/Global/Collectibles/ItemIcon.lua
-- ฟังก์ชัน ItemIcon.For(player, itemName) → return string "rbxassetid://XXX" หรือ "" ถ้าไม่เจอ
local ItemIcon = require(ReplicatedStorage:WaitForChild("CAM")
    :WaitForChild("Global")
    :WaitForChild("Collectibles")
    :WaitForChild("ItemIcon"))

--────────────────────────────────────────
-- Helper
--────────────────────────────────────────
local function safeWaitPath(root: Instance, names: {string}, timeout: number?): Instance?
    local current = root
    for _, name in ipairs(names) do
        local found = current:WaitForChild(name, timeout or 10)
        if not found then return nil end
        current = found
    end
    return current
end

local function getItemCount(item: Instance): number
    local amount = item:FindFirstChild("Amount")
    if amount and amount:IsA("ValueBase") then
        return amount.Value
    end
    return 1
end

-- ★ เพิ่ม: แปลง "rbxassetid://XXX" → URL ภาพ thumbnail ของ Roblox
-- รองรับทั้ง format ใหม่ (rbxassetid://) และ format เก่า (http://www.roblox.com/asset/?id=)
local function rbxIconToUrl(icon: string?, width: number?, height: number?): string?
    if not icon or icon == "" then return nil end
    local assetId = string.match(icon, "rbxassetid://(%d+)")
    if not assetId then
        -- ลอง format เก่า: "http://www.roblox.com/asset/?id=XXX"
        assetId = string.match(icon, "id=(%d+)")
    end
    if not assetId then return nil end
    local w = width or 420
    local h = height or 420
    return string.format(
        "https://thumbnails.roblox.com/v1/assets?assetIds=%s&size=%dx%d&format=Png",
        assetId, w, h
    )
end

--────────────────────────────────────────
-- เก็บข้อมูล: Items → table (เพิ่ม icon + iconUrl)
--────────────────────────────────────────
-- ★ เพิ่มพารามิเตอร์ player เพื่อส่งให้ ItemIcon.For
local function collectItems(inv: Instance, player: Player): {any}
    local items = {}
    for _, item in ipairs(inv:GetChildren()) do
        local entry: any = {
            name = item.Name,
            class = item.ClassName,
            amount = getItemCount(item),
        }

        -- ★ เพิ่ม: ดึง icon จาก catalog (ReplicatedStorage.Items/<Cat>/<Name>.Icon)
        local ok, iconStr = pcall(function()
            return ItemIcon.For(player, item.Name)
        end)
        if ok and iconStr and iconStr ~= "" then
            entry.icon = iconStr                       -- "rbxassetid://XXX" (raw string)
            entry.iconUrl = rbxIconToUrl(iconStr)      -- URL สำหรับดึง thumbnail
        else
            -- กรณี item ไม่อยู่ใน catalog (เช่น entry แปลก ๆ) ปล่อยให้ไม่มี field นี้
            entry.icon = ""
            entry.iconUrl = nil
        end

        local refine = item:FindFirstChild("RefineLevel")
        if refine and refine:IsA("ValueBase") and refine.Value > 0 then
            entry.refine = refine.Value
        end
        if item:FindFirstChild("QuestGrant") then entry.questGrant = true end
        if item:FindFirstChild("NoSave") then entry.noSave = true end
        if item:FindFirstChild("SetMaterial") then entry.setMaterial = true end
        table.insert(items, entry)
    end
    return items
end

--────────────────────────────────────────
-- เก็บข้อมูลทั้งหมดของ Player → table เดียว
--────────────────────────────────────────
local function collectPlayerData(player: Player): any
    local playerName = player.Name

    local dataRoot = safeWaitPath(ReplicatedStorage, { "Player_Service", "Data", playerName }, 15)
    if not dataRoot then return nil end

    local slotEquipped = dataRoot:FindFirstChild("slotEquipped")
    if not slotEquipped then return nil end

    local slotNumber = slotEquipped.Value
    local slotRoot = safeWaitPath(dataRoot, { "slots", "Slot" .. slotNumber }, 10)
    if not slotRoot then return nil end

    -- Stats (per-character)
    local wen = slotRoot:FindFirstChild("Wen")
    local expFolder = slotRoot:FindFirstChild("Exp")
    local goal = expFolder and expFolder:FindFirstChild("Goal")
    local current = expFolder and expFolder:FindFirstChild("Current")

    local payload: any = {
        playerName = playerName,
        userId = player.UserId,
        timestamp = os.time(),
        slot = slotNumber,
        stats = {
            wen = wen and wen.Value or 0,
            level = goal and math.floor(goal.Value / EXP_PER_LEVEL) or 0,
            maxLevel = MAX_LEVEL,
            expCurrent = current and current.Value or 0,
            expGoal = goal and goal.Value or 0,
        },
        inventory = {},
        accountItems = {},
        reputation = nil,
    }

    -- ★ Inventory ของ Slot — ส่ง player เข้าไปด้วย
    local inv = slotRoot:FindFirstChild("Inventory")
    local bag = inv and inv:FindFirstChild("Inventory")
    if bag then
        payload.inventory = collectItems(bag, player)
    end

    -- ★ Account-wide bag — ส่ง player เข้าไปด้วย
    local accInv = safeWaitPath(dataRoot, { "AccountItems", "Inventory" }, 2)
    if accInv then
        payload.accountItems = collectItems(accInv, player)
    end

    -- Reputation (per-account → leaderstats)
    local leaderstats = player:FindFirstChild("leaderstats")
    local reputation = leaderstats and leaderstats:FindFirstChild("Reputation")
    if reputation and reputation:IsA("ValueBase") then
        payload.reputation = reputation.Value
    end

    return payload
end

--────────────────────────────────────────
-- ส่ง POST 1 ครั้ง (มี pcall กันเกมพังถ้า URL ล่ม)
--────────────────────────────────────────
local function postData(player: Player)
    local ok, err = pcall(function()
        local payload = collectPlayerData(player)
        if not payload then
            warn("[Export] เก็บข้อมูลไม่ได้ (Data ยังไม่พร้อม)")
            return
        end

        local json = HttpService:JSONEncode(payload)

        local response = HttpService:RequestAsync({
            Url = WEBHOOK_URL,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
            },
            Body = json,
        })

        if response.Success then
            print("[Export] POST OK |", payload.playerName,
                "| Lv", payload.stats.level,
                "| Wen", payload.stats.wen,
                "| items", #payload.inventory,
                "| len", #json)
        else
            warn("[Export] POST ล้มเหลว:", response.StatusCode, response.StatusMessage)
        end
    end)

    if not ok then
        warn("[Export] RequestAsync error:", err)
    end
end

--────────────────────────────────────────
-- Loop หลัก: ทำงานต่อเนื่องทุก 5 วินาที ต่อ 1 Player
--────────────────────────────────────────
local function startLoop(player: Player)
    -- ★ กรองเฉพาะเจ้าของบัญชี — ถ้าไม่ใช่ target ให้ข้ามไปเลย
    if not isTargetPlayer(player) then
        return
    end

    task.spawn(function()
        -- รอให้ Server สร้าง Data ของผู้เล่นเสร็จก่อน (สูงสุด 30 วิ)
        local ready = safeWaitPath(ReplicatedStorage, { "Player_Service", "Data", player.Name }, 30)
        if not ready then
            warn("[Export] ไม่มี Data ของ", player.Name, "→ ยกเลิก loop")
            return
        end

        print("[Export] เริ่มส่งข้อมูลของ", player.Name, "ทุก", POST_INTERVAL, "วินาที")

        while player.Parent do -- ยังอยู่ในเกมไหม
            postData(player)
            task.wait(POST_INTERVAL)
        end

        print("[Export]", player.Name, "ออกจากเกม → หยุด loop")
    end)
end

Players.PlayerAdded:Connect(startLoop)
for _, p in ipairs(Players:GetPlayers()) do -- กัน Player เข้าก่อนสคริปต์รัน
    startLoop(p)
end

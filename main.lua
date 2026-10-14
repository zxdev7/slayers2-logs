--========================================================
-- Data Exporter v1.0 (Script — วางใน ServerScriptService)
-- เก็บข้อมูล Player (Items + Wen + Lv + Rep) → JSON → POST ทุก 5 วิ
--========================================================

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--────────── CONFIG — แก้ 2 ค่านี้ ──────────
local WEBHOOK_URL = "https://example.com/api/player-data" -- <-- URL ปลายทาง
local POST_INTERVAL = 5                                    -- ทุกกี่วินาที
--───────────────────────────────────────────

-- ค่าคงที่จาก gameSettings.lua
local EXP_PER_LEVEL = 60
local MAX_LEVEL = 225

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

--────────────────────────────────────────
-- เก็บข้อมูล: Items → table
--────────────────────────────────────────
local function collectItems(inv: Instance): {any}
    local items = {}
    for _, item in ipairs(inv:GetChildren()) do
        local entry: any = {
            name = item.Name,
            class = item.ClassName,
            amount = getItemCount(item),
        }
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

    -- Inventory ของ Slot
    local inv = slotRoot:FindFirstChild("Inventory")
    local bag = inv and inv:FindFirstChild("Inventory")
    if bag then
        payload.inventory = collectItems(bag)
    end

    -- Account-wide bag
    local accInv = safeWaitPath(dataRoot, { "AccountItems", "Inventory" }, 2)
    if accInv then
        payload.accountItems = collectItems(accInv)
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
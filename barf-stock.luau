-- ==========================================================
-- LAYER 0: IMPORT LIB
-- ==========================================================

local Library = loadstring(game:HttpGet("https://github.com/lamduck2005/Fluent-Renewed-Plus/releases/download/v0.1/Fluent.luau"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/lamduck2005/Fluent-Renewed-Plus/main/Addons/SaveManager.luau"))()

-- ==========================================================
-- LAYER 1: DATA & STATE
-- ==========================================================

local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Player = game.Players.LocalPlayer

local State = {
    Data = {
        GearItems = {},
        EggItems = {},
        BeeMerchantItems = {},
    },
    Cache = {
        LastGearKey = "",
        LastEggKey = "",
        LastBeeMerchantKey = "",
        GearCooldown = 0,
        EggCooldown = 0,
        BeeMerchantCooldown = 0,
    },
}

-- ==========================================================
-- LAYER 2: REGISTRY LOADERS
-- ==========================================================

local function LoadGearRegistry()
    local ok, mod = pcall(function()
        return require(RS:WaitForChild("Shared", 5):WaitForChild("Registry", 5):WaitForChild("Gear", 5))
    end)
    if ok and type(mod) == "table" and type(mod[2]) == "table" then
        for name, data in pairs(mod[2]) do
            State.Data.GearItems[name] = {
                Cost = data.Cost,
                MaxStock = data.MaxStock,
                DisplayName = data.DisplayName,
                Chance = data.Chance,
            }
        end
    end
end

local function LoadEggConfig()
    local ok, mod = pcall(function()
        return require(RS:WaitForChild("Shared", 5):WaitForChild("EggConfig", 5))
    end)
    if ok and type(mod) == "table" and mod.Prices then
        for k, v in pairs(mod.Prices) do
            State.Data.EggItems[k] = {
                Price = tonumber(v) or 0,
                RestockChance = mod.RestockChances and mod.RestockChances[k] or 0,
            }
        end
    end
end

local function LoadBeeMerchantItems()
    local ok, mod = pcall(function()
        return require(RS:WaitForChild("Shared", 5):WaitForChild("BeeHiveEventConfig", 5))
    end)
    if ok and type(mod) == "table" and mod.Merchant and mod.Merchant.Items then
        for _, item in ipairs(mod.Merchant.Items) do
            State.Data.BeeMerchantItems[item.Id] = {
                DisplayName = item.DisplayName or item.Id,
                HoneyCost = item.HoneyCost or 0,
                Stock = item.Stock or 0,
            }
        end
    end
end

-- ==========================================================
-- LAYER 3: UTILITY FUNCTIONS
-- ==========================================================

local Suffixes = {"", "K", "M", "B", "T", "QA", "QI", "SX", "SP", "OC", "NO", "DE"}
local function FormatMoney(n)
    if not n or n == 0 then return "?" end
    local exp = math.floor(math.log10(math.abs(n)) / 3)
    if exp < 1 then return "$" .. tostring(math.floor(n)) end
    local suffix = Suffixes[math.min(exp + 1, #Suffixes)] or "??"
    local divisor = 10 ^ (exp * 3)
    local val = n / divisor
    local fmt = (val == math.floor(val)) and "$%.0f%s" or "$%.2f%s"
    return string.format(fmt, val, suffix)
end

local EMBED_COLOR = tonumber("57F287", 16)

local function BuildEmbed(data)
    return {{
        color = data.color or EMBED_COLOR,
        title = data.title,
        description = data.description,
        footer = { text = "BARF Monitor | " .. os.date("%H:%M:%S") },
        timestamp = DateTime.now():ToIsoDate(),
    }}
end

local function SendWebhook(url, embeds)
    if not url or url == "" then return false end
    local data = HttpService:JSONEncode({ embeds = embeds })
    local headers = { ["Content-Type"] = "application/json" }
    local requestFunc = (syn and syn.request) or http_request or request
    if requestFunc then
        local ok = pcall(requestFunc, { Url = url, Method = "POST", Headers = headers, Body = data })
        if ok then return true end
    end
    local ok = pcall(HttpService.PostAsync, HttpService, url, data, "application/json", false)
    return ok
end

-- ==========================================================
-- LAYER 4: DATA FETCHERS
-- ==========================================================

local BeeRep = nil
pcall(function()
    local dr = require(RS:WaitForChild("Packages", 5):WaitForChild("DataReplicator", 5))
    BeeRep = dr.GetReplicator()
end)

local function FetchGearData()
    local folder = RS:FindFirstChild("GearStocks") and RS.GearStocks:FindFirstChild(Player.Name)
    if not folder then
        return {
            title = "Gear Restock!",
            color = EMBED_COLOR,
            description = "No gear data",
            _plain = "No gear data",
        }
    end
    local descParts = {}
    local plainParts = {}
    for name, info in pairs(State.Data.GearItems) do
        local stock = folder:FindFirstChild(name)
        local s = stock and stock.Value or 0
        if s > 0 then
            local displayName = info.DisplayName or name
            local priceStr = FormatMoney(info.Cost)
            table.insert(descParts, string.format("` %sx ` **%s** — %s", s, displayName, priceStr))
            table.insert(plainParts, string.format("%dx %s (%s)", s, displayName, priceStr))
        end
    end
    table.sort(descParts)
    table.sort(plainParts)
    local description = #descParts > 0 and table.concat(descParts, "\n") or "No gear in stock"
    local plain = #plainParts > 0 and table.concat(plainParts, "\n") or "No gear in stock"
    return {
        title = "Gear Restock!",
        color = EMBED_COLOR,
        description = description,
        _plain = plain,
    }
end

local function FetchEggData()
    local petMerchant = workspace:FindFirstChild("PetMerchant")
    if not petMerchant then
        return {
            title = "Egg Restock!",
            color = EMBED_COLOR,
            description = "No egg shop found",
            _plain = "No egg shop found",
        }
    end
    local descParts = {}
    local plainParts = {}
    for slot = 1, 5 do
        local podium = petMerchant:FindFirstChild("Podium" .. slot .. "Stock") or petMerchant:FindFirstChild("Podium" .. slot)
        if podium then
            local label = podium:FindFirstChild("EggLabel", true)
            if label and label.Text and label.Text ~= "" then
                local raw = label.Text
                local matched = raw
                for realName in pairs(State.Data.EggItems) do
                    local safeRaw = string.gsub(string.lower(raw), " ", "")
                    local safeReal = string.gsub(string.lower(realName), " ", "")
                    if string.find(safeRaw, safeReal, 1, true) then
                        matched = realName
                        break
                    end
                end
                local price = (State.Data.EggItems[matched] and State.Data.EggItems[matched].Price) or 0
                local priceStr = FormatMoney(price)
                table.insert(descParts, string.format("` Slot %d ` **%s** — %s", slot, matched, priceStr))
                table.insert(plainParts, string.format("Slot %d: %s (%s)", slot, matched, priceStr))
            end
        end
    end
    local description = #descParts > 0 and table.concat(descParts, "\n") or "No eggs available"
    local plain = #plainParts > 0 and table.concat(plainParts, "\n") or "No eggs available"
    return {
        title = "Egg Restock!",
        color = EMBED_COLOR,
        description = description,
        _plain = plain,
    }
end

local function FetchBeeMerchantData()
    local snap = BeeRep and BeeRep:GetSnapshot()
    local stock = (snap and snap.BeeHiveEvent and snap.BeeHiveEvent.MerchantStock) or {}
    local descParts = {}
    local plainParts = {}
    for id, info in pairs(State.Data.BeeMerchantItems) do
        local s = stock[id]
        if s == nil then s = info.Stock end
        if s > 0 then
            local displayName = info.DisplayName or id
            local honeyCost = info.HoneyCost
            local costStr = honeyCost >= 1000 and string.format("%.0fK", honeyCost / 1000) or tostring(honeyCost)
            table.insert(descParts, string.format("` %sx ` **%s** — 🍯 %s", s, displayName, costStr))
            table.insert(plainParts, string.format("%dx %s (🍯 %s)", s, displayName, costStr))
        end
    end
    table.sort(descParts)
    table.sort(plainParts)
    local description = #descParts > 0 and table.concat(descParts, "\n") or "No bee merchant items in stock"
    local plain = #plainParts > 0 and table.concat(plainParts, "\n") or "No bee merchant items in stock"
    return {
        title = "Bee Merchant Restock!",
        color = EMBED_COLOR,
        description = description,
        _plain = plain,
    }
end

-- ==========================================================
-- LAYER 5: BUILD UI
-- ==========================================================

local Window = Library:Window{
    Title = "BARF Stock",
    SubTitle = "[Lamduck]",
    TabWidth = 140,
    Size = UDim2.fromOffset(580, 400),
    Acrylic = false,
    Transparency = false,
    Theme = "Vynixu",
    MinimizeKey = Enum.KeyCode.RightControl,
    MinimizeButton = true,
    MinimizeButtonIcon = "bone",
}

local Tabs = {
    Gear = Window:Tab{ Title = "Gear Watch", Icon = "shopping-cart" },
    Egg = Window:Tab{ Title = "Egg Watch", Icon = "egg" },
    BeeMerchant = Window:Tab{ Title = "Bee Merchant", Icon = "hexagon" },
    Settings = Window:Tab{ Title = "Settings", Icon = "settings" },
}

local function SendGearSnapshot(manual)
    local data = FetchGearData()
    local url = Library.Options.GearWebhookURL.Value
    if url ~= "" then
        SendWebhook(url, BuildEmbed(data))
    end
    if manual then
        Library:Notify({ Title = "Gear", Content = "Snapshot sent!", Duration = 5 })
    end
end

local function SendEggSnapshot(manual)
    local data = FetchEggData()
    local url = Library.Options.EggWebhookURL.Value
    if url ~= "" then
        SendWebhook(url, BuildEmbed(data))
    end
    if manual then
        Library:Notify({ Title = "Egg", Content = "Snapshot sent!", Duration = 5 })
    end
end

local function SendBeeMerchantSnapshot(manual)
    local data = FetchBeeMerchantData()
    local url = Library.Options.BeeMerchantWebhookURL.Value
    if url ~= "" then
        SendWebhook(url, BuildEmbed(data))
    end
    if manual then
        Library:Notify({ Title = "Bee Merchant", Content = "Snapshot sent!", Duration = 5 })
    end
end

Tabs.Gear:Input("GearWebhookURL", {
    Title = "Gear Webhook URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    Default = "",
})
Tabs.Gear:Toggle("EnableGearWatch", {
    Title = "Enable Gear Watch",
    Default = true,
})
Tabs.Gear:Button({
    Title = "Send Current Gear Stock",
    Callback = function()
        if Library.Options.GearWebhookURL.Value == "" then
            Library:Notify({ Title = "Error", Content = "No gear webhook URL set", Duration = 5 })
            return
        end
        SendGearSnapshot(true)
    end,
})
Tabs.Gear:Paragraph("GearLog", {
    Title = "Gear Status",
    Content = "Waiting for gear data...",
})

Tabs.Egg:Input("EggWebhookURL", {
    Title = "Egg Webhook URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    Default = "",
})
Tabs.Egg:Toggle("EnableEggWatch", {
    Title = "Enable Egg Watch",
    Default = true,
})
Tabs.Egg:Button({
    Title = "Send Current Egg Stock",
    Callback = function()
        if Library.Options.EggWebhookURL.Value == "" then
            Library:Notify({ Title = "Error", Content = "No egg webhook URL set", Duration = 5 })
            return
        end
        SendEggSnapshot(true)
    end,
})
Tabs.Egg:Paragraph("EggLog", {
    Title = "Egg Status",
    Content = "Waiting for egg data...",
})

Tabs.BeeMerchant:Input("BeeMerchantWebhookURL", {
    Title = "Bee Merchant Webhook URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    Default = "",
})
Tabs.BeeMerchant:Toggle("EnableBeeMerchantWatch", {
    Title = "Enable Bee Merchant Watch",
    Default = true,
})
Tabs.BeeMerchant:Button({
    Title = "Send Current Bee Merchant Stock",
    Callback = function()
        if Library.Options.BeeMerchantWebhookURL.Value == "" then
            Library:Notify({ Title = "Error", Content = "No bee merchant webhook URL set", Duration = 5 })
            return
        end
        SendBeeMerchantSnapshot(true)
    end,
})
Tabs.BeeMerchant:Paragraph("BeeMerchantLog", {
    Title = "Bee Merchant Status",
    Content = "Waiting for bee merchant data...",
})

SaveManager:SetLibrary(Library)
SaveManager:BuildConfigSection(Tabs.Settings)

-- ==========================================================
-- LAYER 6: MONITORING
-- ==========================================================

local function UpdateGearUI(data)
    local text = string.format("Gear Restock (%s)\n%s", os.date("%H:%M:%S"), data._plain)
    local nrt = RS:FindFirstChild("GearStocks") and RS.GearStocks:FindFirstChild(Player.Name) and RS.GearStocks[Player.Name]:FindFirstChild("NextRestockTime")
    if nrt and nrt.Value > 0 then
        local left = math.max(0, nrt.Value - workspace:GetServerTimeNow())
        local mins = math.floor(left / 60)
        local secs = math.floor(left % 60)
        text = text .. string.format("\nNext Restock In: %dm %ds", mins, secs)
    end
    Library.Options.GearLog:SetValue(text)
end

local function UpdateEggUI(data)
    local now = workspace:GetServerTimeNow()
    local left = math.max(0, now - now % 300 + 300 - now)
    local mins = math.floor(left / 60)
    local secs = math.floor(left % 60)
    local text = string.format("Egg Restock (%s)\n%s\nNext Restock In: %dm %ds", os.date("%H:%M:%S"), data._plain, mins, secs)
    Library.Options.EggLog:SetValue(text)
end

local function UpdateBeeMerchantUI(data)
    local text = string.format("Bee Merchant Restock (%s)\n%s", os.date("%H:%M:%S"), data._plain)
    if next(State.Data.BeeMerchantItems) ~= nil then
        local now = workspace:GetServerTimeNow()
        local left = math.max(0, now - now % 3600 + 3600 - now)
        local mins = math.floor(left / 60)
        local secs = math.floor(left % 60)
        text = text .. string.format("\nNext Restock In: %dm %ds", mins, secs)
    end
    Library.Options.BeeMerchantLog:SetValue(text)
end

local function DataToKey(data)
    return data._plain
end

local function OnGearChange()
    if not Library.Options.EnableGearWatch.Value then return end
    if next(State.Data.GearItems) == nil then return end
    local now = os.clock()
    if now - State.Cache.GearCooldown < 3 then return end
    State.Cache.GearCooldown = now
    local data = FetchGearData()
    local key = DataToKey(data)
    if key == State.Cache.LastGearKey then return end
    State.Cache.LastGearKey = key
    SendGearSnapshot(false)
    UpdateGearUI(data)
end

local function OnEggChange()
    if not Library.Options.EnableEggWatch.Value then return end
    if next(State.Data.EggItems) == nil then return end
    local now = os.clock()
    if now - State.Cache.EggCooldown < 3 then return end
    State.Cache.EggCooldown = now
    local data = FetchEggData()
    local key = DataToKey(data)
    if key == State.Cache.LastEggKey then return end
    State.Cache.LastEggKey = key
    SendEggSnapshot(false)
    UpdateEggUI(data)
end

local function OnBeeMerchantChange()
    if not Library.Options.EnableBeeMerchantWatch.Value then return end
    if next(State.Data.BeeMerchantItems) == nil then return end
    local now = os.clock()
    if now - State.Cache.BeeMerchantCooldown < 3 then return end
    State.Cache.BeeMerchantCooldown = now
    local data = FetchBeeMerchantData()
    local key = DataToKey(data)
    if key == State.Cache.LastBeeMerchantKey then return end
    State.Cache.LastBeeMerchantKey = key
    SendBeeMerchantSnapshot(false)
    UpdateBeeMerchantUI(data)
end

local function SetupGearWatcher()
    local folder = RS:FindFirstChild("GearStocks") and RS.GearStocks:FindFirstChild(Player.Name)
    if not folder then
        task.wait(5)
        SetupGearWatcher()
        return
    end
    State.Cache.LastGearKey = DataToKey(FetchGearData())
    folder.ChildAdded:Connect(function(child)
        task.wait(1)
        OnGearChange()
        if child:IsA("IntValue") then
            child:GetPropertyChangedSignal("Value"):Connect(function()
                task.wait(0.5)
                OnGearChange()
            end)
        end
    end)
    folder.ChildRemoved:Connect(function()
        task.wait(1)
        OnGearChange()
    end)
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("IntValue") then
            child:GetPropertyChangedSignal("Value"):Connect(function()
                task.wait(0.5)
                OnGearChange()
            end)
        end
    end
end

task.spawn(SetupGearWatcher)

task.spawn(function()
    while true do
        task.wait(3)
        OnEggChange()
    end
end)

task.spawn(function()
    while true do
        task.wait(5)
        OnBeeMerchantChange()
    end
end)

-- ==========================================================
-- LAYER 7: BOOTSTRAP
-- ==========================================================

task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
    LoadGearRegistry()
    LoadEggConfig()
    LoadBeeMerchantItems()
    local gearData = FetchGearData()
    State.Cache.LastGearKey = DataToKey(gearData)
    UpdateGearUI(gearData)
    local eggData = FetchEggData()
    State.Cache.LastEggKey = DataToKey(eggData)
    UpdateEggUI(eggData)
    local beeData = FetchBeeMerchantData()
    State.Cache.LastBeeMerchantKey = DataToKey(beeData)
    UpdateBeeMerchantUI(beeData)
end)

Window:SelectTab(1)

SaveManager:LoadAutoloadConfig()

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_FOLDER_NAME = "InventoryRemotes"
local SYNC_EVENT_NAME = "InventorySync"

local remotes = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME)
if not remotes then
    remotes = Instance.new("Folder")
    remotes.Name = REMOTE_FOLDER_NAME
    remotes.Parent = ReplicatedStorage
end

local syncEvent = remotes:FindFirstChild(SYNC_EVENT_NAME)
if not syncEvent then
    syncEvent = Instance.new("RemoteEvent")
    syncEvent.Name = SYNC_EVENT_NAME
    syncEvent.Parent = remotes
end

local collectionZone

local inventories = {}

local function getDisplayName(templateName, rarity)
    if rarity and rarity ~= "" then
        return string.format("%s Shard", rarity)
    end
    if not templateName or templateName == "" then
        return "Shard"
    end
    local cleaned = string.gsub(templateName, "LightShard", "Shard")
    cleaned = string.gsub(cleaned, "Light", " ")
    return cleaned
end

local function sendInventory(player)
    local inv = inventories[player] or {}
    local payload = {}
    for templateName, entry in pairs(inv) do
        table.insert(payload, {
            templateName = templateName,
            count = entry.count or 0,
            rarity = entry.rarity or "Shard",
            displayName = entry.displayName or getDisplayName(templateName, entry.rarity),
        })
    end
    syncEvent:FireClient(player, payload)
end

local function addShard(player, templateName, rarity)
    if not templateName or templateName == "" then
        return
    end
    inventories[player] = inventories[player] or {}
    local inv = inventories[player]
    local entry = inv[templateName]
    if not entry then
        entry = {
            count = 0,
            rarity = rarity or "Shard",
            displayName = getDisplayName(templateName, rarity),
        }
        inv[templateName] = entry
    end
    entry.count += 1
end

local function stripShardTools(container)
    if not container then
        return {}
    end
    local removed = {}
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") and child:GetAttribute("ShardTemplate") then
            table.insert(removed, child)
            child:Destroy()
        end
    end
    return removed
end

local function bankShardTools(player)
    local backpack = player:FindFirstChildOfClass("Backpack")
    local character = player.Character
    local collected = {}

    for _, tool in ipairs((backpack and backpack:GetChildren()) or {}) do
        if tool:IsA("Tool") and tool:GetAttribute("ShardTemplate") then
            table.insert(collected, tool)
        end
    end
    for _, tool in ipairs((character and character:GetChildren()) or {}) do
        if tool:IsA("Tool") and tool:GetAttribute("ShardTemplate") then
            table.insert(collected, tool)
        end
    end

    for _, tool in ipairs(collected) do
        local templateName = tool:GetAttribute("ShardTemplate")
        local rarity = tool:GetAttribute("ShardRarity") or "Shard"
        addShard(player, templateName, rarity)
        tool:Destroy()
    end

    if #collected > 0 then
        sendInventory(player)
    end
end

local function clearShardTools(player)
    local backpack = player:FindFirstChildOfClass("Backpack")
    local character = player.Character
    stripShardTools(backpack)
    stripShardTools(character)
end

local debounce = {}
local function onCollectionTouched(hit)
    local character = hit and hit.Parent
    if not character then
        return
    end
    local player = Players:GetPlayerFromCharacter(character)
    if not player then
        return
    end

    if debounce[player] then
        return
    end
    debounce[player] = true
    bankShardTools(player)
    task.delay(0.5, function()
        debounce[player] = nil
    end)
end

local function locateCollectionZone()
    local map = Workspace:FindFirstChild("Map")
    local groundMain = map and map:FindFirstChild("GroundMainGame")
    local baseStructure = groundMain and groundMain:FindFirstChild("BaseStructure")
    return baseStructure and baseStructure:FindFirstChild("CollectionZone")
end

collectionZone = locateCollectionZone()
if collectionZone then
    collectionZone.Touched:Connect(onCollectionTouched)
else
    warn("[ShardInventory] CollectionZone not found at Workspace.Map.GroundMainGame.BaseStructure.CollectionZone")
end

Players.PlayerAdded:Connect(function(player)
    inventories[player] = {}
    player.CharacterAdded:Connect(function(character)
        local humanoid = character:WaitForChild("Humanoid", 5)
        if humanoid then
            humanoid.Died:Connect(function()
                clearShardTools(player)
            end)
        end
        task.defer(function()
            sendInventory(player)
        end)
    end)
    player.CharacterRemoving:Connect(function()
        clearShardTools(player)
    end)
    sendInventory(player)
end)

Players.PlayerRemoving:Connect(function(player)
    inventories[player] = nil
end)

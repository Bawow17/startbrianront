local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local BASE_TEMPLATES_FOLDER_NAME = "Bases"
local WORKSPACE_BASES_FOLDER_NAME = "Bases"
local MANAGED_ATTRIBUTE = "ManagedByBaseOwnership"

local baseTemplatesFolder = ServerStorage:WaitForChild(BASE_TEMPLATES_FOLDER_NAME)

local workspaceBasesFolder = Workspace:FindFirstChild(WORKSPACE_BASES_FOLDER_NAME)
if not workspaceBasesFolder or not workspaceBasesFolder:IsA("Folder") then
    workspaceBasesFolder = Instance.new("Folder")
    workspaceBasesFolder.Name = WORKSPACE_BASES_FOLDER_NAME
    workspaceBasesFolder.Parent = Workspace
end

for _, child in ipairs(workspaceBasesFolder:GetChildren()) do
    if child:GetAttribute(MANAGED_ATTRIBUTE) then
        child:Destroy()
    end
end

local baseSlots = {}

for _, template in ipairs(baseTemplatesFolder:GetChildren()) do
    if template:IsA("Model") or template:IsA("Folder") or template:IsA("BasePart") then
        table.insert(baseSlots, {
            template = template,
            owner = nil,
            clone = nil,
        })
    end
end

table.sort(baseSlots, function(a, b)
    return string.lower(a.template.Name) < string.lower(b.template.Name)
end)

if #baseSlots == 0 then
    warn(string.format("BaseOwnershipManager could not find any templates inside ServerStorage.%s", BASE_TEMPLATES_FOLDER_NAME))
    return
end

local playerAssignments = {}
local waitingQueue = {}
local rng = Random.new()

local function formatOwnerText(player)
    return string.format("Owned By: %s", player.Name)
end

local function setOwnershipText(model, ownerText)
    local updated = false

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("TextLabel") then
            if descendant.Name == "OwnershipLabel" or descendant.Text:find("Owned By") then
                descendant.Text = ownerText
                updated = true
            end
        end
    end

    if not updated then
        warn(string.format("BaseOwnershipManager could not find an OwnershipLabel inside %s", model.Name))
    end
end

local function removeFromQueue(player)
    for index, queued in ipairs(waitingQueue) do
        if queued == player then
            table.remove(waitingQueue, index)
            return true
        end
    end

    return false
end

local function enqueueWaitingPlayer(player)
    for _, queued in ipairs(waitingQueue) do
        if queued == player then
            return
        end
    end

    table.insert(waitingQueue, player)
end

local function getAvailableSlot()
    local availableIndexes = {}

    for index, slot in ipairs(baseSlots) do
        if not slot.owner then
            table.insert(availableIndexes, index)
        end
    end

    if #availableIndexes == 0 then
        return nil
    end

    local randomIndex = availableIndexes[rng:NextInteger(1, #availableIndexes)]
    return baseSlots[randomIndex]
end

local function assignBaseToPlayer(player, skipQueue)
    if playerAssignments[player] then
        return true
    end

    local slot = getAvailableSlot()
    if not slot then
        if not skipQueue then
            enqueueWaitingPlayer(player)
        end
        return false
    end

    removeFromQueue(player)

    local clone = slot.template:Clone()
    clone:SetAttribute(MANAGED_ATTRIBUTE, true)
    setOwnershipText(clone, formatOwnerText(player))
    clone.Parent = workspaceBasesFolder

    slot.owner = player
    slot.clone = clone
    playerAssignments[player] = slot

    return true
end

local function assignNextWaitingPlayer()
    while #waitingQueue > 0 do
        local player = table.remove(waitingQueue, 1)
        if player and player.Parent == Players and not playerAssignments[player] then
            local assigned = assignBaseToPlayer(player, true)
            if not assigned then
                table.insert(waitingQueue, 1, player)
            end
            return
        end
    end
end

local function releaseBase(player)
    local slot = playerAssignments[player]
    if slot then
        if slot.clone then
            slot.clone:Destroy()
            slot.clone = nil
        end

        slot.owner = nil
        playerAssignments[player] = nil
    else
        removeFromQueue(player)
    end

    task.defer(assignNextWaitingPlayer)
end

local function onPlayerAdded(player)
    assignBaseToPlayer(player, false)

    player.AncestryChanged:Connect(function(_, parent)
        if not parent then
            releaseBase(player)
        end
    end)
end

Players.PlayerAdded:Connect(onPlayerAdded)

for _, player in ipairs(Players:GetPlayers()) do
    task.defer(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
    releaseBase(player)
end)

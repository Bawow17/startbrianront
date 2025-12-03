local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local REMOTE_FOLDER_NAME = "StarSystemRemotes"
local GET_STATE_NAME = "GetStarState"
local EQUIP_EVENT_NAME = "EquipStar"
local UNEQUIP_EVENT_NAME = "UnequipStar"
local STATE_UPDATE_EVENT_NAME = "StarStateUpdate"

local remotes = ReplicatedStorage:WaitForChild(REMOTE_FOLDER_NAME)
local getStateFn = remotes:WaitForChild(GET_STATE_NAME)
local equipEvent = remotes:WaitForChild(EQUIP_EVENT_NAME)
local unequipEvent = remotes:WaitForChild(UNEQUIP_EVENT_NAME)
local stateUpdate = remotes:FindFirstChild(STATE_UPDATE_EVENT_NAME)

local lastState
local starsPanel
local starList
local template

local function resetUiRefs()
    starsPanel = nil
    starList = nil
    template = nil
    lastState = nil
end

local function ensureUi()
    if starsPanel and starList and template then
        return true
    end

    local screenGui = playerGui:FindFirstChild("IngameScreenGui") or playerGui:WaitForChild("IngameScreenGui", 5)
    if not screenGui then
        return false
    end

    starsPanel = screenGui:FindFirstChild("StarsPanel", true)
    starList = starsPanel and starsPanel:FindFirstChild("StarList", true)
    if not starsPanel or not starList then
        return false
    end

    if not template then
        local found = starList:FindFirstChild("StarItem")
        if found then
            template = found:Clone()
            found:Destroy()
        end
    end

    if template then
        template.Visible = false
    end

    return starsPanel ~= nil and starList ~= nil and template ~= nil
end

local function clearItems()
    if not starList then
        return
    end
    for _, child in ipairs(starList:GetChildren()) do
        if child:IsA("Frame") and child.Name:match("^StarItem") then
            child:Destroy()
        end
    end
end

local function render(state)
    if not ensureUi() then
        return
    end
    clearItems()
    if not state or not state.owned then
        return
    end

    -- state.owned is a list of entries: { id, starType, equipped }
    for index, entry in ipairs(state.owned) do
        local card = template:Clone()
        card.Visible = true
        card.Name = "StarItem_" .. tostring(index)
        card.Parent = starList

        local nameLabel = card:FindFirstChild("NameTextLabel", true)
        if nameLabel and nameLabel:IsA("TextLabel") then
            nameLabel.Text = string.format("%s Star", entry.starType or "Unknown")
        end

        local qty = card:FindFirstChild("QuantityTextLabel", true)
        if qty and qty:IsA("TextLabel") then
            qty.Text = ""
        end

        local equippedLabel = card:FindFirstChild("EquippedLabel", true) or card:FindFirstChild("EquippedTextLabel", true)
        if equippedLabel and equippedLabel:IsA("TextLabel") then
            if entry.equipped then
                equippedLabel.Text = "Equipped"
                equippedLabel.Visible = true
            else
                equippedLabel.Text = ""
                equippedLabel.Visible = false
            end
        end

        local equipBtn = card:FindFirstChild("EquipTextButton", true)
        local unequipBtn = card:FindFirstChild("UnequipTextButton", true)

        if equipBtn and equipBtn:IsA("TextButton") then
            equipBtn.Visible = not entry.equipped
            equipBtn.MouseButton1Click:Connect(function()
                equipEvent:FireServer(entry.id or entry.starType)
            end)
        end

        if unequipBtn and unequipBtn:IsA("TextButton") then
            unequipBtn.Visible = entry.equipped
            unequipBtn.MouseButton1Click:Connect(function()
                unequipEvent:FireServer(entry.id or entry.starType)
            end)
        end
    end
end

local function refreshState()
    local ok, data = pcall(function()
        return getStateFn:InvokeServer()
    end)
    if ok and data then
        lastState = data
        render(data)
    end
end

refreshState()

playerGui.ChildAdded:Connect(function(child)
    if child.Name == "IngameScreenGui" then
        task.defer(function()
            resetUiRefs()
            refreshState()
        end)
    end
end)

player.CharacterAdded:Connect(function()
    task.defer(function()
        resetUiRefs()
        refreshState()
    end)
end)

if stateUpdate then
    stateUpdate.OnClientEvent:Connect(function(data)
        if data then
            lastState = data
            render(data)
        end
    end)
end

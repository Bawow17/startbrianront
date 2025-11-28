local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local REMOTE_FOLDER_NAME = "InventoryRemotes"
local SYNC_EVENT_NAME = "InventorySync"

local remotes = ReplicatedStorage:WaitForChild(REMOTE_FOLDER_NAME)
local syncEvent = remotes:WaitForChild(SYNC_EVENT_NAME)

local function waitForDescendant(parent, name, timeout)
    local elapsed = 0
    while parent and parent.Parent and elapsed < (timeout or 5) do
        local found = parent:FindFirstChild(name, true)
        if found then
            return found
        end
        task.wait(0.1)
        elapsed += 0.1
    end
    return nil
end

local function locateUi()
    local screenGui = playerGui:FindFirstChild("IngameScreenGui") or playerGui:WaitForChild("IngameScreenGui", 5)
    if not screenGui then
        return nil, nil
    end
    local panel = waitForDescendant(screenGui, "InventoryPanel", 5)
    local list = panel and waitForDescendant(panel, "InventoryList", 5)
    return panel, list
end

local panel, inventoryList
local template
local lastData

local function buildFallbackTemplate()
    if not inventoryList then
        return nil
    end
    local card = Instance.new("Frame")
    card.Name = "InventoryItem"
    card.Size = UDim2.new(0, 200, 0, 120)
    card.BackgroundColor3 = Color3.fromRGB(32, 35, 42)
    card.BackgroundTransparency = 0.25
    card.BorderSizePixel = 0

    local inner = Instance.new("Frame")
    inner.Name = "Frame"
    inner.Size = UDim2.new(0.95, 0, 0.94, 0)
    inner.Position = UDim2.new(0.5, 0, 0.5, 0)
    inner.AnchorPoint = Vector2.new(0.5, 0.5)
    inner.BackgroundColor3 = Color3.fromRGB(32, 35, 42)
    inner.BackgroundTransparency = 0.4
    inner.Parent = card

    local viewport = Instance.new("ViewportFrame")
    viewport.Name = "ViewportFrame"
    viewport.Size = UDim2.new(0.6, 0, 0.5, 0)
    viewport.Position = UDim2.new(0.4, 0, 0.5, 0)
    viewport.AnchorPoint = Vector2.new(0, 0.5)
    viewport.BackgroundTransparency = 1
    viewport.Parent = inner

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "NameTextLabel"
    nameLabel.Size = UDim2.new(0.35, 0, 0.5, 0)
    nameLabel.Position = UDim2.new(0.02, 0, 0.05, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextColor3 = Color3.new(1, 1, 1)
    nameLabel.TextScaled = true
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextWrapped = true
    nameLabel.Font = Enum.Font.GothamSemibold
    nameLabel.Text = "Shard"
    nameLabel.Parent = inner

    local qtyLabel = Instance.new("TextLabel")
    qtyLabel.Name = "QuantityTextLabel"
    qtyLabel.Size = UDim2.new(0.35, 0, 0.3, 0)
    qtyLabel.Position = UDim2.new(0.02, 0, 0.6, 0)
    qtyLabel.BackgroundTransparency = 1
    qtyLabel.TextColor3 = Color3.new(1, 1, 1)
    qtyLabel.TextScaled = true
    qtyLabel.TextXAlignment = Enum.TextXAlignment.Left
    qtyLabel.Font = Enum.Font.Gotham
    qtyLabel.Text = "x0"
    qtyLabel.Parent = inner

    return card
end

local function ensureUi()
    if inventoryList and inventoryList.Parent == nil then
        inventoryList = nil
        template = nil
    end
    if template and template.Parent == nil then
        template = nil
    end

    if inventoryList and template then
        template.Visible = false
        return true
    end

    panel, inventoryList = locateUi()
    if not inventoryList then
        return false
    end

    template = inventoryList:FindFirstChild("InventoryItem")
    if not template then
        template = buildFallbackTemplate()
        if not template then
            return false
        end
        template.Parent = inventoryList
    end
    template.Visible = false
    return true
end

local function clearRendered()
    for _, child in ipairs(inventoryList:GetChildren()) do
        if child:IsA("Frame") and child ~= template and child.Name:match("^InventoryItem") then
            child:Destroy()
        end
    end
end

local function fitModelToViewport(model, viewport)
    if not model or not viewport then
        return
    end

    local primary = model.PrimaryPart
    if not primary then
        primary = model:FindFirstChildWhichIsA("BasePart")
        if primary then
            model.PrimaryPart = primary
        end
    end

    if model.ScaleTo then
        pcall(function()
            model:ScaleTo(0.5)
        end)
    end

    model:SetPrimaryPartCFrame(CFrame.new())
    model.Parent = viewport

    local size = model:GetExtentsSize()
    local maxDim = math.max(size.X, size.Y, size.Z)
    local distance = math.max(6, maxDim * 2)
    local cam = Instance.new("Camera")
    cam.FieldOfView = 35
    cam.CFrame = CFrame.new(Vector3.new(distance, distance, distance), Vector3.new())
    cam.Parent = viewport
    viewport.CurrentCamera = cam
end

local function renderInventory(data)
    if not ensureUi() then
        return
    end
    if not data then
        return
    end
    clearRendered()
    if template then
        template.Visible = false
    end

    for index, entry in ipairs(data) do
        local card = template:Clone()
        card.Visible = true
        card.Name = "InventoryItem_" .. tostring(index)
        card.LayoutOrder = index
        card.Parent = inventoryList

        local nameLabel = card:FindFirstChild("NameTextLabel", true)
        if nameLabel and nameLabel:IsA("TextLabel") then
            nameLabel.Text = entry.displayName or entry.templateName or "Shard"
        end

        local qtyLabel = card:FindFirstChild("QuantityTextLabel", true)
        if qtyLabel and qtyLabel:IsA("TextLabel") then
            qtyLabel.Text = string.format("x%d", tonumber(entry.count) or 0)
        end

        local viewport = card:FindFirstChild("ViewportFrame", true)
        if viewport and viewport:IsA("ViewportFrame") then
            for _, child in ipairs(viewport:GetChildren()) do
                child:Destroy()
            end
            local templatesFolder = ReplicatedStorage:FindFirstChild("LightShardTemplates")
            if templatesFolder and entry.templateName then
                local shardTemplate = templatesFolder:FindFirstChild(entry.templateName)
                if shardTemplate then
                    local clone = shardTemplate:Clone()
                    fitModelToViewport(clone, viewport)
                end
            end
        end
    end
end

syncEvent.OnClientEvent:Connect(function(data)
    lastData = data
    renderInventory(lastData)
end)

playerGui.ChildAdded:Connect(function(child)
    if child.Name == "IngameScreenGui" then
        task.defer(function()
            if ensureUi() and lastData then
                renderInventory(lastData)
            end
        end)
    end
end)

Players.LocalPlayer.CharacterAdded:Connect(function()
    task.defer(function()
        if ensureUi() and lastData then
            renderInventory(lastData)
        end
    end)
end)

task.spawn(function()
    while not ensureUi() do
        task.wait(0.5)
    end
    if lastData then
        renderInventory(lastData)
    end
end)

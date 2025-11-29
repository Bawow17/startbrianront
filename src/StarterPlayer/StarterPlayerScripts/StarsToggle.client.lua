local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Config = require(ReplicatedStorage:WaitForChild("LightSystemConfig"))
local CHUNK_SIZE = Config.ChunkSize
local WORLD_ORIGIN = Config.WorldOrigin
local HEIGHT_TOLERANCE = Config.ChunkHeightTolerance

local activeConnections = {}
local retrying = false
local connectToggle
local onPanelOpened
local inventoryToggle
local starUiMod
local toggleButtonRef
local panelRef

local function worldToChunk(position)
    local dx = position.X - WORLD_ORIGIN.X
    local dz = position.Z - WORLD_ORIGIN.Z
    local cx = math.floor(dx / CHUNK_SIZE + 0.5)
    local cz = math.floor(dz / CHUNK_SIZE + 0.5)
    return cx, cz
end

local function locateChunkFolder()
    local clientWorld = workspace:FindFirstChild("ClientWorld")
    if clientWorld then
        local clientChunks = clientWorld:FindFirstChild("ClientChunks")
        if clientChunks then
            return clientChunks
        end
    end
    return workspace:FindFirstChild("GeneratedChunks")
end

local function chunkExists(cx, cz)
    -- Treat origin/teleporter chunk as part of chunk world
    if cx == 0 and cz == 0 then
        return true
    end
    local folder = locateChunkFolder()
    if not folder then
        return false
    end
    local name = string.format("Chunk_%d_%d", cx, cz)
    if folder:FindFirstChild(name) then
        return true
    end
    -- fallback: check attributes if present
    for _, child in ipairs(folder:GetChildren()) do
        if child:GetAttribute("ChunkX") == cx and child:GetAttribute("ChunkZ") == cz then
            return true
        end
    end
    return false
end

local function isInChunkWorld(position)
    if math.abs(position.Y - WORLD_ORIGIN.Y) > HEIGHT_TOLERANCE then
        return false
    end
    local cx, cz = worldToChunk(position)
    return chunkExists(cx, cz)
end

local function updateVisibility()
    if not toggleButtonRef then
        return
    end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        toggleButtonRef.Visible = true
        return
    end
    local inChunk = isInChunkWorld(root.Position)
    toggleButtonRef.Visible = not inChunk
    if inChunk and panelRef then
        panelRef.Visible = false
    end
end

local function disconnectAll()
    for _, conn in ipairs(activeConnections) do
        if conn and conn.Connected then
            conn:Disconnect()
        end
    end
    table.clear(activeConnections)
end

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

local function scheduleRetry()
    if retrying then
        return
    end
    retrying = true
    task.delay(1, function()
        retrying = false
        if connectToggle then
            connectToggle()
        end
    end)
end

local function connectToggleInternal()
    disconnectAll()

    local screenGui = playerGui:FindFirstChild("IngameScreenGui") or playerGui:WaitForChild("IngameScreenGui", 2)
    if not screenGui then
        scheduleRetry()
        return
    end

    local toggleButton = waitForDescendant(screenGui, "StarsToggle", 2)
    local panel = waitForDescendant(screenGui, "StarsPanel", 2)
    toggleButtonRef = toggleButton
    panelRef = panel

    if not toggleButton or not panel then
        scheduleRetry()
        return
    end

    local function setOpen(open)
        panel.Visible = open
        if open and onPanelOpened then
            onPanelOpened("Stars")
            if inventoryToggle and inventoryToggle.closePanel then
                inventoryToggle.closePanel()
            end
            if starUiMod and starUiMod.refreshState then
                starUiMod.refreshState()
            end
        end
    end

    local conn = toggleButton.Activated:Connect(function()
        -- If Inventory panel is open, close it before opening stars
        local screen = playerGui:FindFirstChild("IngameScreenGui")
        if screen then
            local invPanel = screen:FindFirstChild("InventoryPanel", true)
            if invPanel then
                invPanel.Visible = false
            end
        end
        setOpen(not panel.Visible)
    end)
    table.insert(activeConnections, conn)

    -- Close buttons inside panel (names containing "close" or "x")
    for _, descendant in ipairs(panel:GetDescendants()) do
        if descendant:IsA("GuiButton") then
            local lowerName = string.lower(descendant.Name or "")
            local text = (descendant:IsA("TextButton") or descendant:IsA("ImageButton")) and (descendant.Text or "")
            local lowerText = string.lower(text or "")
            local isClose = lowerName:find("close") or lowerName == "x" or lowerText == "x" or lowerText:find("close")
            if isClose then
                local c = descendant.Activated:Connect(function()
                    setOpen(false)
                end)
                table.insert(activeConnections, c)
            end
        end
    end
end

connectToggle = connectToggleInternal
connectToggle()

playerGui.ChildAdded:Connect(function(child)
    if child.Name == "IngameScreenGui" then
        task.defer(connectToggle)
    end
end)

player.CharacterAdded:Connect(function()
    task.defer(connectToggle)
end)

player.CharacterRemoving:Connect(function()
    disconnectAll()
end)

RunService.Heartbeat:Connect(function()
    updateVisibility()
end)

return {
    setOnPanelOpened = function(callback)
        onPanelOpened = callback
    end,
    closePanel = function()
        local screenGui = playerGui:FindFirstChild("IngameScreenGui")
        if not screenGui then
            return
        end
        local panel = waitForDescendant(screenGui, "StarsPanel", 0.1)
        if panel then
            panel.Visible = false
        end
    end,
    setInventoryToggle = function(mod)
        inventoryToggle = mod
    end,
    setStarUi = function(mod)
        starUiMod = mod
    end,
}

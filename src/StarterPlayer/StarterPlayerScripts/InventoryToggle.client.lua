local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local activeConnections = {}
local retrying = false
local connectToggle
local onPanelOpened

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

local function connectToggle()
    disconnectAll()

    local screenGui = playerGui:FindFirstChild("IngameScreenGui") or playerGui:WaitForChild("IngameScreenGui", 2)
    if not screenGui then
        scheduleRetry()
        return
    end

    local toggleButton = waitForDescendant(screenGui, "InventoryToggle", 2)
    local panel = waitForDescendant(screenGui, "InventoryPanel", 2)

    if not toggleButton or not panel then
        warn("[InventoryToggle] Missing UI pieces. toggleButton:", toggleButton, "panel:", panel)
        scheduleRetry()
        return
    end

local function setOpen(open)
    panel.Visible = open
    if open and onPanelOpened then
        onPanelOpened("Inventory")
        -- Close stars panel if open
        local starsToggle = require(script.Parent:FindFirstChild("StarsToggle"))
        if starsToggle and starsToggle.closePanel then
            starsToggle.closePanel()
        end
    end
end

    local conn = toggleButton.Activated:Connect(function()
        -- If Stars panel is open, close it before opening inventory
        local screen = playerGui:FindFirstChild("IngameScreenGui")
    if screen then
        local starsPanel = screen:FindFirstChild("StarsPanel", true)
        if starsPanel then
            starsPanel.Visible = false
        end
    end
        setOpen(not panel.Visible)
    end)
    table.insert(activeConnections, conn)

    -- Also wire up any close/X buttons inside the panel by common names.
    for _, descendant in ipairs(panel:GetDescendants()) do
        if descendant:IsA("GuiButton") then
            local lowerName = string.lower(descendant.Name or "")
            local text = (descendant:IsA("TextButton") or descendant:IsA("ImageButton")) and (descendant.Text or "")
            local lowerText = string.lower(text or "")
            local isClose = lowerName == "close"
                or lowerName == "closebutton"
                or lowerName == "x"
                or lowerName == "xbutton"
                or string.find(lowerName, "close")
                or lowerText == "x"
                or string.find(lowerText, "close")

            if isClose then
                local conn = descendant.Activated:Connect(function()
                    setOpen(false)
                end)
                table.insert(activeConnections, conn)
            end
        end
    end
end

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

-- Expose a simple signal hook for cross-panel coordination
return {
    setOnPanelOpened = function(callback)
        onPanelOpened = callback
    end,
    closePanel = function()
        local screenGui = playerGui:FindFirstChild("IngameScreenGui")
        if not screenGui then
            return
        end
        local panel = waitForDescendant(screenGui, "InventoryPanel", 0.1)
        if panel then
            panel.Visible = false
        end
    end,
}

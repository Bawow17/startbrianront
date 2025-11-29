local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local activeConnections = {}
local retrying = false

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

local function scheduleRetry(connectFn)
    if retrying then
        return
    end
    retrying = true
    task.delay(1, function()
        retrying = false
        connectFn()
    end)
end

local function connectToggle()
    disconnectAll()

    local screenGui = playerGui:FindFirstChild("IngameScreenGui") or playerGui:WaitForChild("IngameScreenGui", 5)
    if not screenGui then
        scheduleRetry(connectToggle)
        return
    end

    local toggleButton = waitForDescendant(screenGui, "StarsToggle", 5)
    local panel = waitForDescendant(screenGui, "StarsPanel", 5)

    if not toggleButton or not panel then
        scheduleRetry(connectToggle)
        return
    end

    local isOpen = panel.Visible

    local function setOpen(open)
        isOpen = open
        panel.Visible = open
    end

    local conn = toggleButton.Activated:Connect(function()
        setOpen(not isOpen)
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

connectToggle()

playerGui.ChildAdded:Connect(function(child)
    if child.Name == "IngameScreenGui" then
        task.defer(connectToggle)
    end
end)

player.CharacterAdded:Connect(function()
    task.defer(connectToggle)
end)

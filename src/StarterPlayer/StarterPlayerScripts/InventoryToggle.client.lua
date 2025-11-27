local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

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

local function connectToggle()
    local screenGui = playerGui:FindFirstChild("IngameScreenGui") or playerGui:WaitForChild("IngameScreenGui", 5)
    if not screenGui then
        warn("[InventoryToggle] IngameScreenGui not found")
        return
    end

    local toggleButton = waitForDescendant(screenGui, "InventoryToggle", 5)
    local panel = waitForDescendant(screenGui, "InventoryPanel", 5)

    if not toggleButton or not panel then
        warn("[InventoryToggle] Missing UI pieces. toggleButton:", toggleButton, "panel:", panel)
        return
    end

    local isOpen = panel.Visible

    local function setOpen(open)
        isOpen = open
        panel.Visible = open
    end

    toggleButton.MouseButton1Click:Connect(function()
        setOpen(not isOpen)
    end)

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
                descendant.Activated:Connect(function()
                    setOpen(false)
                end)
            end
        end
    end
end

connectToggle()

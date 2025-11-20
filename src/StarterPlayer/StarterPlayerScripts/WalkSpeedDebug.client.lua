local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local INCREMENT = 10
local DEFAULT_WALKSPEED = 24

local player = Players.LocalPlayer

local function getHumanoid()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    while not humanoid do
        humanoid = character:WaitForChild("Humanoid")
    end
    return humanoid
end

local function adjustWalkSpeed(delta)
    local humanoid = getHumanoid()
    humanoid.WalkSpeed = math.max(0, humanoid.WalkSpeed + delta)
end

local function resetWalkSpeed()
    local humanoid = getHumanoid()
    humanoid.WalkSpeed = DEFAULT_WALKSPEED
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.KeyCode == Enum.KeyCode.LeftBracket then
        adjustWalkSpeed(-INCREMENT)
    elseif input.KeyCode == Enum.KeyCode.RightBracket then
        adjustWalkSpeed(INCREMENT)
    elseif input.KeyCode == Enum.KeyCode.Semicolon then
        resetWalkSpeed()
    end
end)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local VOID_Y_POSITION = -515
local UPDATE_INTERVAL = 0.2 -- 5 FPS

local followFolder = ServerStorage:WaitForChild("FollowThePlayerVfx")
local voidFolder = followFolder:WaitForChild("Void")
local onPlayerFolder = followFolder:WaitForChild("OnPlayer")

local effectConfigs = {
    {
        template = voidFolder:WaitForChild("Clouds"),
        nameSuffix = "VoidClouds",
        position = function(rootPosition)
            return Vector3.new(rootPosition.X, VOID_Y_POSITION, rootPosition.Z)
        end,
    },
    {
        template = onPlayerFolder:WaitForChild("Stars"),
        nameSuffix = "OnPlayerStars",
        position = function(rootPosition)
            return rootPosition
        end,
    },
}

local playerStates = {}

local function positionInstance(instance, position)
    if instance:IsA("Model") then
        instance:PivotTo(CFrame.new(position))
    elseif instance:IsA("BasePart") then
        instance.CFrame = CFrame.new(position)
    elseif instance:IsA("Attachment") then
        instance.WorldCFrame = CFrame.new(position)
    end
end

local function anchorInstance(instance)
    if instance:IsA("BasePart") then
        instance.Anchored = true
        instance.CanCollide = false
    elseif instance:IsA("Model") then
        for _, descendant in ipairs(instance:GetDescendants()) do
            if descendant:IsA("BasePart") then
                descendant.Anchored = true
                descendant.CanCollide = false
            end
        end
    end
end

local function clearConnection(state)
    if state.connection then
        state.connection:Disconnect()
        state.connection = nil
    end
    state.elapsed = 0
end

local function cleanupPlayer(player, destroyEffects)
    local state = playerStates[player]
    if not state then
        return
    end

    clearConnection(state)

    if destroyEffects then
        if state.effects then
            for _, effect in pairs(state.effects) do
                if effect.instance and effect.instance.Parent then
                    effect.instance:Destroy()
                end
            end
        end
        playerStates[player] = nil
    end
end

local function ensureEffects(player, state)
    state.effects = state.effects or {}

    for _, config in ipairs(effectConfigs) do
        local effect = state.effects[config.nameSuffix]
        if not effect or not effect.instance or not effect.instance.Parent then
            local clone = config.template:Clone()
            clone.Name = string.format("%s_%s", player.Name, config.nameSuffix)
            clone.Parent = workspace

            anchorInstance(clone)

            effect = {
                instance = clone,
                positionFunc = config.position,
            }

            state.effects[config.nameSuffix] = effect
        else
            anchorInstance(effect.instance)
        end
    end
end

local function updateEffectPositions(state, rootPosition)
    if not state.effects then
        return
    end

    for _, effect in pairs(state.effects) do
        if effect.instance and effect.instance.Parent and effect.positionFunc then
            local targetPosition = effect.positionFunc(rootPosition)
            positionInstance(effect.instance, targetPosition)
        end
    end
end

local function onCharacterAdded(player, character)
    local state = playerStates[player]

    if not state then
        state = {}
        playerStates[player] = state
    else
        clearConnection(state)
    end

    local rootPart = character:WaitForChild("HumanoidRootPart", 5)
    if not rootPart then
        return
    end

    state.rootPart = rootPart

    ensureEffects(player, state)

    if state.effects then
        updateEffectPositions(state, rootPart.Position)
    end

    state.elapsed = 0

    state.connection = RunService.Heartbeat:Connect(function(dt)
        local currentRoot = state.rootPart

        if not currentRoot or not currentRoot.Parent then
            clearConnection(state)
            return
        end

        state.elapsed += dt
        if state.elapsed < UPDATE_INTERVAL then
            return
        end

        state.elapsed -= UPDATE_INTERVAL

        updateEffectPositions(state, currentRoot.Position)
    end)
end

local function onPlayerAdded(player)
    playerStates[player] = playerStates[player] or {}

    player.CharacterAdded:Connect(function(character)
        onCharacterAdded(player, character)
    end)

    player.CharacterRemoving:Connect(function()
        cleanupPlayer(player, false)
    end)

    player.AncestryChanged:Connect(function(_, parent)
        if not parent then
            cleanupPlayer(player, true)
        end
    end)

    if player.Character then
        task.spawn(onCharacterAdded, player, player.Character)
    end
end

Players.PlayerAdded:Connect(onPlayerAdded)

for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
    cleanupPlayer(player, true)
end)

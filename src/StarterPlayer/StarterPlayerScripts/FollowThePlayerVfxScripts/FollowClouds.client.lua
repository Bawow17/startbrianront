local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VOID_Y_POSITION = -515
local UPDATE_INTERVAL = 0.2

local player = Players.LocalPlayer

local templateRoot = ReplicatedStorage:WaitForChild("FollowThePlayerVfx")
local voidFolder = templateRoot:WaitForChild("Void")
local onPlayerFolder = templateRoot:WaitForChild("OnPlayer")

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
            return rootPosition - Vector3.new(0, 50, 0)
        end,
    },
}

local state = {
    effects = {},
    connection = nil,
    rootPart = nil,
    elapsed = 0,
}

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

local function ensureEffects()
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

local function updateEffectPositions(rootPosition)
    for _, effect in pairs(state.effects) do
        if effect.instance and effect.instance.Parent and effect.positionFunc then
            local targetPosition = effect.positionFunc(rootPosition)
            positionInstance(effect.instance, targetPosition)
        end
    end
end

local function clearConnection()
    if state.connection then
        state.connection:Disconnect()
        state.connection = nil
    end
    state.elapsed = 0
end

local function cleanup(destroyEffects)
    clearConnection()

    if destroyEffects then
        for _, effect in pairs(state.effects) do
            if effect.instance and effect.instance.Parent then
                effect.instance:Destroy()
            end
        end
        state.effects = {}
    end
end

local function onCharacterAdded(character)
    cleanup(false)

    local root = character:WaitForChild("HumanoidRootPart", 5)
    if not root then
        return
    end

    state.rootPart = root

    ensureEffects()
    updateEffectPositions(root.Position)

    state.connection = RunService.Heartbeat:Connect(function(dt)
        if not state.rootPart or not state.rootPart.Parent then
            cleanup(false)
            return
        end

        state.elapsed += dt
        if state.elapsed < UPDATE_INTERVAL then
            return
        end

        state.elapsed -= UPDATE_INTERVAL

        updateEffectPositions(state.rootPart.Position)
    end)
end

player.CharacterAdded:Connect(onCharacterAdded)

if player.Character then
    task.spawn(onCharacterAdded, player.Character)
end

player.CharacterRemoving:Connect(function()
    cleanup(false)
end)

player.AncestryChanged:Connect(function(_, parent)
    if not parent then
        cleanup(true)
    end
end)

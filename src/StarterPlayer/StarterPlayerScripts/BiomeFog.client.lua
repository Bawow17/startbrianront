local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local CHUNK_SIZE = 128
local WORLD_ORIGIN = Vector3.new(7500, 7500, 7500)
local player = Players.LocalPlayer
local CENTRAL_BIOME_RADIUS = 6
local CENTRAL_BIOME_RADIUS_SQR = CENTRAL_BIOME_RADIUS * CENTRAL_BIOME_RADIUS

local function updateCentralRadius()
    local value = workspace:GetAttribute("CentralBiomeRadius")
    if typeof(value) == "number" and value > 0 then
        CENTRAL_BIOME_RADIUS = value
        CENTRAL_BIOME_RADIUS_SQR = value * value
    end
end

updateCentralRadius()

workspace:GetAttributeChangedSignal("CentralBiomeRadius"):Connect(updateCentralRadius)

local biomeFogSettings = {
    Flatlands = {
        color = Color3.fromRGB(100, 255, 83),
        fogEnd = 2000,
        fogStart = 450,
    },
    Forest = {
        color = Color3.fromRGB(30, 255, 37),
        fogEnd = 1800,
        fogStart = 400,
    },
    Desert = {
        color = Color3.fromRGB(255, 189, 76),
        fogEnd = 3500,
        fogStart = 450,
    },
    Swamp = {
        color = Color3.fromRGB(12, 31, 10),
        fogEnd = 900,
        fogStart = 120,
    },
    Tundra = {
        color = Color3.fromRGB(255, 255, 255),
        fogEnd = 800,
        fogStart = 75,
    },
}

local defaultFog = {
    color = Color3.fromRGB(0, 0, 0),
    fogEnd = 2000,
    fogStart = 300,
}

local currentTween

local function chunkKey(cx, cz)
    return string.format("%d_%d", cx, cz)
end

local function worldToChunk(position)
    local dx = position.X - WORLD_ORIGIN.X
    local dz = position.Z - WORLD_ORIGIN.Z
    local cx = math.floor(dx / CHUNK_SIZE + 0.5)
    local cz = math.floor(dz / CHUNK_SIZE + 0.5)
    return cx, cz
end

local function tweenFog(settings)
    if currentTween then
        currentTween:Cancel()
        currentTween = nil
    end

    local tweenInfo = TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
    local goal = {
        FogColor = settings.color,
        FogEnd = settings.fogEnd,
        FogStart = settings.fogStart,
    }

    currentTween = TweenService:Create(Lighting, tweenInfo, goal)
    currentTween:Play()
end

local function applyFogSettings(biomeName)
    local settings = biomeFogSettings[biomeName] or defaultFog
    tweenFog(settings)
end

applyFogSettings(nil)

local function findChunkBiome(cx, cz)
    local chunkFolder = workspace:FindFirstChild("GeneratedChunks")
    local chunkModel = chunkFolder and chunkFolder:FindFirstChild("Chunk_" .. cx .. "_" .. cz)
    if chunkModel then
        return chunkModel:GetAttribute("Biome")
    end

    if chunkFolder then
        for _, model in ipairs(chunkFolder:GetChildren()) do
            if model:GetAttribute("ChunkX") == cx and model:GetAttribute("ChunkZ") == cz then
                return model:GetAttribute("Biome")
            end
        end
    end

    if cx * cx + cz * cz <= CENTRAL_BIOME_RADIUS_SQR then
        return workspace:GetAttribute("CentralBiome")
    end

    return nil
end

local lastBiome

local function updateFog()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return
    end

    local cx, cz = worldToChunk(root.Position)
    local biome = findChunkBiome(cx, cz)

    if biome ~= lastBiome then
        lastBiome = biome
        applyFogSettings(biome)
    end
end

task.spawn(function()
    while true do
        updateFog()
        task.wait(1)
    end
end)

player.CharacterAdded:Connect(function()
    task.delay(2, function()
        lastBiome = nil
        updateFog()
    end)
end)

player.CharacterRemoving:Connect(function()
    lastBiome = nil
    applyFogSettings(nil)
end)

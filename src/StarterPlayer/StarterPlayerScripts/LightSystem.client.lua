local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Config = require(ReplicatedStorage:WaitForChild("LightSystemConfig"))

local remotesFolder = ReplicatedStorage:WaitForChild(Config.RemoteFolderName)
local reportEvent = remotesFolder:WaitForChild(Config.ReportEventName)
local broadcastEvent = remotesFolder:WaitForChild(Config.BroadcastEventName)

local CHUNK_SIZE = Config.ChunkSize
local WORLD_ORIGIN = Config.WorldOrigin
local HEIGHT_TOLERANCE = Config.ChunkHeightTolerance

local MAX_LIGHT = Config.BaseMaxLight -- Hook: multiply this when upgrades increase max light.
local lightValue = MAX_LIGHT
local lastServerSend = 0
local lastFullTimestamp = nil

local barFrame
local barFill
local initialBarTransparency = 0
local initialFillTransparency = 0
local targetBarTransparency = 0
local targetFillTransparency = 0
local currentBarTransparency = 0
local currentFillTransparency = 0

local playerLights = {}
local publishedRatios = {}
local regenZone

local function findUi()
    if barFrame and barFrame.Parent and barFill and barFill.Parent then
        return
    end

    local screenGui = playerGui:FindFirstChild("IngameScreenGui")
        or playerGui:WaitForChild("IngameScreenGui", 5)
    if not screenGui then
        return
    end

    local ingameFrame = screenGui:FindFirstChild("IngameFrame")
        or screenGui:WaitForChild("IngameFrame", 5)
    local upperFrame = ingameFrame and (ingameFrame:FindFirstChild("UpperFrame")
        or ingameFrame:WaitForChild("UpperFrame", 5))
    local lightBarFrame = upperFrame and (upperFrame:FindFirstChild("LightBarFrame")
        or upperFrame:WaitForChild("LightBarFrame", 5))
    local lightBarFill = lightBarFrame and (lightBarFrame:FindFirstChild("LightBarFill")
        or lightBarFrame:WaitForChild("LightBarFill", 5))

    if lightBarFrame and lightBarFill then
        barFrame = lightBarFrame
        barFill = lightBarFill
        initialBarTransparency = barFrame.BackgroundTransparency
        initialFillTransparency = barFill.BackgroundTransparency
        currentBarTransparency = initialBarTransparency
        currentFillTransparency = initialFillTransparency
        targetBarTransparency = initialBarTransparency
        targetFillTransparency = initialFillTransparency
    end
end

local function refreshRegenZone()
    local map = Workspace:FindFirstChild("Map")
    local groundMain = map and map:FindFirstChild("GroundMainGame")
    local baseStructure = groundMain and groundMain:FindFirstChild("BaseStructure")
    regenZone = baseStructure and baseStructure:FindFirstChild("RegenZone")
end

refreshRegenZone()

local function worldToChunk(position)
    local dx = position.X - WORLD_ORIGIN.X
    local dz = position.Z - WORLD_ORIGIN.Z
    local cx = math.floor(dx / CHUNK_SIZE + 0.5)
    local cz = math.floor(dz / CHUNK_SIZE + 0.5)
    return cx, cz
end

local function locateChunkFolder()
    local clientWorld = Workspace:FindFirstChild("ClientWorld")
    if clientWorld then
        local clientChunks = clientWorld:FindFirstChild("ClientChunks")
        if clientChunks then
            return clientChunks
        end
    end
    return Workspace:FindFirstChild("GeneratedChunks")
end

local function chunkExists(cx, cz)
    local folder = locateChunkFolder()
    if not folder then
        return true -- If chunks are not present locally, assume chunk world to avoid safe exploits.
    end

    local name = string.format("Chunk_%d_%d", cx, cz)
    if folder:FindFirstChild(name) then
        return true
    end

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

local function isInRegenZone(position)
    if not regenZone or not regenZone.Parent then
        refreshRegenZone()
    end

    if not regenZone or not regenZone.Parent then
        return false
    end

    local localPos = regenZone.CFrame:PointToObjectSpace(position)
    local halfSize = regenZone.Size * 0.5
    return math.abs(localPos.X) <= halfSize.X
        and math.abs(localPos.Y) <= halfSize.Y
        and math.abs(localPos.Z) <= halfSize.Z
end

local function findTorso(character)
    return character and (character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
        or character:FindFirstChild("HumanoidRootPart"))
end

local function ensureLightForCharacter(plr, character)
    local torso = findTorso(character)
    if not torso then
        return
    end

    local existing = playerLights[plr]
    if existing and existing.Parent ~= torso then
        existing:Destroy()
        existing = nil
    end

    if not existing then
        local pointLight = Instance.new("PointLight")
        pointLight.Name = "PlayerLight"
        pointLight.Brightness = 0
        pointLight.Range = Config.LightRange
        pointLight.Shadows = Config.ShadowsEnabled
        pointLight.Enabled = true
        pointLight.Parent = torso
        playerLights[plr] = pointLight
    end
end

local function setLightRatio(plr, ratio)
    local pointLight = playerLights[plr]
    if not pointLight or not pointLight.Parent then
        local character = plr.Character
        if character then
            ensureLightForCharacter(plr, character)
            pointLight = playerLights[plr]
        end
    end

    if not pointLight then
        return
    end

    local clamped = math.clamp(ratio or 0, 0, 1)
    pointLight.Brightness = Config.FullBrightness * clamped
    pointLight.Range = Config.LightRange
    pointLight.Shadows = Config.ShadowsEnabled
end

local function onCharacterAdded(plr, character)
    ensureLightForCharacter(plr, character)
    character.ChildAdded:Connect(function()
        ensureLightForCharacter(plr, character)
    end)
end

local function trackPlayer(plr)
    if plr == player then
        plr.CharacterAdded:Connect(function(character)
            onCharacterAdded(plr, character)
        end)
        plr.CharacterRemoving:Connect(function()
            local existing = playerLights[plr]
            if existing then
                existing:Destroy()
                playerLights[plr] = nil
            end
        end)
        if plr.Character then
            onCharacterAdded(plr, plr.Character)
        end
        return
    end

    plr.CharacterAdded:Connect(function(character)
        onCharacterAdded(plr, character)
    end)
    plr.CharacterRemoving:Connect(function()
        local existing = playerLights[plr]
        if existing then
            existing:Destroy()
            playerLights[plr] = nil
        end
    end)

    if plr.Character then
        onCharacterAdded(plr, plr.Character)
    end
end

for _, plr in ipairs(Players:GetPlayers()) do
    trackPlayer(plr)
end

Players.PlayerAdded:Connect(trackPlayer)
Players.PlayerRemoving:Connect(function(plr)
    local existing = playerLights[plr]
    if existing then
        existing:Destroy()
    end
    playerLights[plr] = nil
    publishedRatios[plr.UserId] = nil
end)

local function updateUi(ratio, dt)
    findUi()
    if not barFrame or not barFill then
        return
    end

    local clamped = math.clamp(ratio, 0, 1)
    barFill.Size = UDim2.new(clamped, 0, 1, 0)

    local now = os.clock()
    if clamped >= 0.999 then
        if not lastFullTimestamp then
            lastFullTimestamp = now
        elseif now - lastFullTimestamp >= Config.FadeDelaySeconds then
            targetBarTransparency = 1
            targetFillTransparency = 1
        end
    else
        lastFullTimestamp = nil
        targetBarTransparency = initialBarTransparency
        targetFillTransparency = initialFillTransparency
    end

    local alpha = math.clamp(dt * Config.FadeStepsPerSecond, 0, 1)
    currentBarTransparency += (targetBarTransparency - currentBarTransparency) * alpha
    currentFillTransparency += (targetFillTransparency - currentFillTransparency) * alpha

    barFrame.BackgroundTransparency = currentBarTransparency
    barFill.BackgroundTransparency = currentFillTransparency
end

local function sendUpdate(now)
    if now - lastServerSend < Config.ValidationInterval then
        return
    end

    lastServerSend = now
    reportEvent:FireServer({
        light = lightValue,
        maxLight = MAX_LIGHT,
    })
end

broadcastEvent.OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "table" then
        return
    end

    local userId = payload.userId
    local amount = tonumber(payload.light)
    local max = tonumber(payload.maxLight) or Config.BaseMaxLight
    if not userId or not amount or amount < 0 then
        return
    end

    local ratio = math.clamp(amount / math.max(1, max), 0, 1)
    publishedRatios[userId] = ratio

    local plr = Players:GetPlayerByUserId(userId)
    if plr then
        setLightRatio(plr, ratio)
    end
end)

local function getLocalRatio()
    return lightValue / math.max(1, MAX_LIGHT)
end

RunService.RenderStepped:Connect(function(dt)
    dt = math.clamp(dt, 0, 1)
    local now = os.clock()

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root then
        local inChunk = isInChunkWorld(root.Position)
        local inRegen = isInRegenZone(root.Position)

        if not inChunk or inRegen then
            lightValue = math.min(MAX_LIGHT, lightValue + Config.RegenPerSecond * dt)
        else
            lightValue = math.max(0, lightValue - Config.BaseDrainPerSecond * dt)
        end
    end

    updateUi(getLocalRatio(), dt)
    setLightRatio(player, getLocalRatio())
    sendUpdate(now)
end)

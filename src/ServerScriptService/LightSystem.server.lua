local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("LightSystemConfig"))

local remotesFolder = ReplicatedStorage:FindFirstChild(Config.RemoteFolderName)
if not remotesFolder then
    remotesFolder = Instance.new("Folder")
    remotesFolder.Name = Config.RemoteFolderName
    remotesFolder.Parent = ReplicatedStorage
end

local reportEvent = remotesFolder:FindFirstChild(Config.ReportEventName)
if not reportEvent then
    reportEvent = Instance.new("RemoteEvent")
    reportEvent.Name = Config.ReportEventName
    reportEvent.Parent = remotesFolder
end

local broadcastEvent = remotesFolder:FindFirstChild(Config.BroadcastEventName)
if not broadcastEvent then
    broadcastEvent = Instance.new("RemoteEvent")
    broadcastEvent.Name = Config.BroadcastEventName
    broadcastEvent.Parent = remotesFolder
end

local bonusEvent = remotesFolder:FindFirstChild(Config.LightBonusBindableName)
if not bonusEvent then
    bonusEvent = Instance.new("BindableEvent")
    bonusEvent.Name = Config.LightBonusBindableName
    bonusEvent.Parent = remotesFolder
end

local WORLD_ORIGIN = Config.WorldOrigin
local HEIGHT_TOLERANCE = Config.ChunkHeightTolerance
local MAX_BASE = Config.BaseMaxLight
local regenZone

local playerState = {}

local function refreshRegenZone()
    local map = Workspace:FindFirstChild("Map")
    local groundMain = map and map:FindFirstChild("GroundMainGame")
    local baseStructure = groundMain and groundMain:FindFirstChild("BaseStructure")
    regenZone = baseStructure and baseStructure:FindFirstChild("RegenZone")
end

refreshRegenZone()

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

local function isInChunkWorld(position)
    return math.abs(position.Y - WORLD_ORIGIN.Y) <= HEIGHT_TOLERANCE
end

local function resetState(player)
    playerState[player] = {
        light = MAX_BASE,
        maxLight = MAX_BASE,
        lastUpdate = os.clock(),
        healthAccumulator = 0,
    }
end

local function broadcast(player, light, maxLight)
    broadcastEvent:FireAllClients({
        userId = player.UserId,
        light = light,
        maxLight = maxLight,
    })
end

local function applyExpected(state, dt, inChunk, inRegen)
    local value = state.light or MAX_BASE
    if not inChunk or inRegen then
        value = math.min(state.maxLight, value + Config.RegenPerSecond * dt)
    else
        value = math.max(0, value - Config.BaseDrainPerSecond * dt)
    end
    return value
end

local function applyBonus(player, percent)
    if not player then
        return
    end
    local state = playerState[player]
    if not state then
        resetState(player)
        state = playerState[player]
    end
    local maxLight = state.maxLight or MAX_BASE
    local bonus = maxLight * math.max(0, percent or 0) * 0.01
    state.light = math.clamp((state.light or 0) + bonus, 0, maxLight)
    state.lastUpdate = os.clock()
    broadcast(player, state.light, maxLight)
end

reportEvent.OnServerEvent:Connect(function(player, payload)
    if typeof(payload) ~= "table" then
        return
    end

    local state = playerState[player]
    if not state then
        resetState(player)
        state = playerState[player]
    end

    local now = os.clock()
    local dt = math.clamp(now - (state.lastUpdate or now), 0, 5)
    state.lastUpdate = now

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local inChunk = root and isInChunkWorld(root.Position) or false
    local inRegen = root and isInRegenZone(root.Position) or false

    -- When upgrades exist, compute maxLight here; do not trust client-reported caps.
    local maxLight = state.maxLight or MAX_BASE
    local expected = applyExpected(state, dt, inChunk, inRegen)

    local reported = tonumber(payload.light)
    local clamped = expected
    if reported then
        local bounded = math.clamp(reported, 0, maxLight)
        local tolerance = 2
        if math.abs(bounded - expected) <= tolerance then
            clamped = bounded
        end
    end

    state.light = clamped
    broadcast(player, clamped, maxLight)

    -- Apply health drain when light is empty.
    if clamped <= 0 then
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 then
            local dmgPerSecond = math.max(0, Config.HealthDrainPercentPerSecondAtZero or 0) * 0.01 * humanoid.MaxHealth
            local damage = dmgPerSecond * dt
            if damage > 0 then
                humanoid:TakeDamage(damage)
            end
        end
    end
end)

bonusEvent.Event:Connect(function(player, percent)
    applyBonus(player, percent)
end)

Players.PlayerAdded:Connect(function(player)
    resetState(player)
    player.CharacterAdded:Connect(function()
        resetState(player)
        broadcast(player, playerState[player].light, playerState[player].maxLight)
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    playerState[player] = nil
end)

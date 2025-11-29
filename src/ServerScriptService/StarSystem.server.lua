local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BASES_FOLDER_NAME = "Bases"
local STAR_TEMPLATES_FOLDER = ServerStorage:WaitForChild("StarVFXModels")
local REMOTE_FOLDER_NAME = "StarSystemRemotes"
local GET_STATE_NAME = "GetStarState"
local EQUIP_EVENT_NAME = "EquipStar"
local UNEQUIP_EVENT_NAME = "UnequipStar"
local SET_MAIN_EVENT_NAME = "SetMainStar"
local MAIN_UPDATE_EVENT_NAME = "MainStarUpdate"
local STATE_UPDATE_EVENT_NAME = "StarStateUpdate"

-- Ensure templates are available to clients.
local clientStarFolder = ReplicatedStorage:FindFirstChild("StarVFXModels")
if not clientStarFolder then
    clientStarFolder = STAR_TEMPLATES_FOLDER:Clone()
    clientStarFolder.Parent = ReplicatedStorage
end

local remotes = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME)
if not remotes then
    remotes = Instance.new("Folder")
    remotes.Name = REMOTE_FOLDER_NAME
    remotes.Parent = ReplicatedStorage
end

local getStateFn = remotes:FindFirstChild(GET_STATE_NAME)
if not getStateFn then
    getStateFn = Instance.new("RemoteFunction")
    getStateFn.Name = GET_STATE_NAME
    getStateFn.Parent = remotes
end

local equipEvent = remotes:FindFirstChild(EQUIP_EVENT_NAME)
if not equipEvent then
    equipEvent = Instance.new("RemoteEvent")
    equipEvent.Name = EQUIP_EVENT_NAME
    equipEvent.Parent = remotes
end

local unequipEvent = remotes:FindFirstChild(UNEQUIP_EVENT_NAME)
if not unequipEvent then
    unequipEvent = Instance.new("RemoteEvent")
    unequipEvent.Name = UNEQUIP_EVENT_NAME
    unequipEvent.Parent = remotes
end

local setMainEvent = remotes:FindFirstChild(SET_MAIN_EVENT_NAME)
if not setMainEvent then
    setMainEvent = Instance.new("RemoteEvent")
    setMainEvent.Name = SET_MAIN_EVENT_NAME
    setMainEvent.Parent = remotes
end

local mainUpdate = remotes:FindFirstChild(MAIN_UPDATE_EVENT_NAME)
if not mainUpdate then
    mainUpdate = Instance.new("RemoteEvent")
    mainUpdate.Name = MAIN_UPDATE_EVENT_NAME
    mainUpdate.Parent = remotes
end

local stateUpdate = remotes:FindFirstChild(STATE_UPDATE_EVENT_NAME)
if not stateUpdate then
    stateUpdate = Instance.new("RemoteEvent")
    stateUpdate.Name = STATE_UPDATE_EVENT_NAME
    stateUpdate.Parent = remotes
end

local workspaceBasesFolder = Workspace:WaitForChild(BASES_FOLDER_NAME)

local DEFAULT_STARS = { "Flame", "Water", "Nature" }
local MAX_SLOTS = 10
local MODEL_SCALE = 0.33

local state = {}

-- Forward declarations
local broadcastMain
local broadcastState

local function compactSlots(s)
    local packed = {}
    for i = 1, MAX_SLOTS do
        local v = s.slots[i]
        if v then
            table.insert(packed, v)
        end
    end
    for i = 1, MAX_SLOTS do
        s.slots[i] = packed[i]
    end
end

-- Light-weight debug with simple rate limiting per player to avoid spam.
local lastDebug = {}
local function debugLog(player, force, ...)
    local now = os.clock()
    local key = player and player.UserId or 0
    if not force then
        if lastDebug[key] and now - lastDebug[key] < 1 then
            return
        end
        lastDebug[key] = now
    end
    warn("[StarSystem]", player and player.Name or "server", ...)
end

local function slotsToString(slots)
    local parts = {}
    for i = 1, MAX_SLOTS do
        parts[i] = slots[i] or "-"
    end
    return table.concat(parts, ",")
end

local function getPlayerBase(player)
    for _, base in ipairs(workspaceBasesFolder:GetChildren()) do
        if base:GetAttribute("ManagedByBaseOwnership") then
            for _, descendant in ipairs(base:GetDescendants()) do
                if descendant:IsA("TextLabel") then
                    local text = descendant.Text or ""
                    if text:find(player.Name) then
                        return base
                    end
                end
            end
        end
    end
    return nil
end

local function collectAnchors(baseModel)
    local anchors = {}
    if not baseModel then
        return anchors
    end
    for _, descendant in ipairs(baseModel:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Name:match("^Star%d+$") then
            local starNum = tonumber(string.match(descendant.Name, "%d+")) or 0
            local platformNum = 999
            local anc = descendant
            while anc and anc ~= baseModel do
                if anc.Name:match("^DisplayPlatform%d+$") then
                    platformNum = tonumber(string.match(anc.Name, "%d+")) or platformNum
                    break
                end
                anc = anc.Parent
            end
            table.insert(anchors, { part = descendant, platform = platformNum, star = starNum })
        end
    end
    table.sort(anchors, function(a, b)
        if a.platform == b.platform then
            return a.star < b.star
        end
        return a.platform < b.platform
    end)
    local ordered = {}
    for i, entry in ipairs(anchors) do
        if i > MAX_SLOTS then
            break
        end
        table.insert(ordered, entry.part)
    end
    return ordered
end

local function clearDisplays(player)
    local s = state[player]
    if s and s.displayModels then
        for _, inst in ipairs(s.displayModels) do
            if inst and inst.Parent then
                inst:Destroy()
            end
        end
        s.displayModels = {}
    end
end

local function clearPrompts(player)
    local s = state[player]
    if s and s.promptConns then
        for _, conn in ipairs(s.promptConns) do
            if conn and conn.Connected then
                conn:Disconnect()
            end
        end
    end
    if s and s.prompts then
        for _, prompt in ipairs(s.prompts) do
            if prompt and prompt.Parent then
                prompt:Destroy()
            end
        end
    end
    if s then
        s.promptConns = {}
        s.prompts = {}
    end
end

local function cloneStarTemplate(starType, scale)
    local template = STAR_TEMPLATES_FOLDER:FindFirstChild(starType) or clientStarFolder:FindFirstChild(starType)
    if not template then
        return nil
    end
    local clone = template:Clone()
    scale = scale or 1
    local function scaleModel(model, scaleValue)
        if model.ScaleTo then
            local ok = pcall(function()
                model:ScaleTo(scaleValue)
            end)
            if ok then
                return
            end
        end
        for _, p in ipairs(model:GetDescendants()) do
            if p:IsA("BasePart") then
                p.Size = p.Size * scaleValue
            end
        end
    end
    scaleModel(clone, scale)
    for _, p in ipairs(clone:GetDescendants()) do
        if p:IsA("BasePart") then
            p.Anchored = true
            p.CanCollide = false
            p.CanTouch = false
        end
        if p:IsA("ParticleEmitter") or p:IsA("Beam") or p:IsA("Trail") or p:IsA("PointLight") or p:IsA("SpotLight") or p:IsA("SurfaceLight") then
            p.Enabled = true
        end
    end
    return clone
end

local function renderBaseDisplays(player)
    clearDisplays(player)
    clearPrompts(player)
    local s = state[player]
    if not s then
        return
    end
    local baseModel = getPlayerBase(player)
    if not baseModel then
        return
    end
    local anchors = collectAnchors(baseModel)
    s.displayModels = {}
    s.promptConns = s.promptConns or {}
    s.prompts = s.prompts or {}
    for index, starId in ipairs(s.slots) do
        local anchor = anchors[index]
        local entry = starId and s.ownedMap and s.ownedMap[starId]
        local promptStarType = entry and entry.starType
        if promptStarType and anchor then
            local model = cloneStarTemplate(promptStarType, 1)
            if model then
                model.Parent = baseModel
                model:PivotTo(anchor.CFrame)
                table.insert(s.displayModels, model)

                -- Equip-to-main prompt on the anchor
                local prompt = Instance.new("ProximityPrompt")
                prompt.ActionText = "Equip Main"
                prompt.ObjectText = promptStarType .. " Star"
                prompt.HoldDuration = 1.5
                prompt.RequiresLineOfSight = false
                prompt.MaxActivationDistance = 10
                prompt.KeyboardKeyCode = Enum.KeyCode.E
                prompt.Parent = anchor

                local conn = prompt.Triggered:Connect(function(plr)
                    -- Only allow the owner to set main.
                    local ownerBase = getPlayerBase(plr)
                    if ownerBase and ownerBase ~= baseModel then
                        return
                    end
                    -- clear previous main and set new
                    s.mainId = starId
                    broadcastMain(plr)
                    broadcastState(plr)
                    -- disable this prompt, but re-render will create fresh ones
                    prompt.Enabled = false
                    debugLog(plr, true, "Main set to", promptStarType)
                    renderBaseDisplays(plr)
                end)
                table.insert(s.promptConns, conn)
                table.insert(s.prompts, prompt)
            end
        end
    end
end

function broadcastMain(player)
    local s = state[player]
    mainUpdate:FireAllClients({
        userId = player.UserId,
        starType = s and s.mainId and s.ownedMap[s.mainId] and s.ownedMap[s.mainId].starType or nil,
    })
end

function broadcastState(player)
    local s = state[player]
    if not s then
        return
    end
    stateUpdate:FireClient(player, {
        owned = s.ownedList,
        slots = s.slots,
        mainId = s.mainId,
    })
end

local function initPlayer(player)
    state[player] = {
        ownedList = {},
        ownedMap = {},
        slots = {},
        displayModels = {},
        mainId = nil,
        promptConns = {},
        prompts = {},
    }
    for _, t in ipairs(DEFAULT_STARS) do
        for i = 1, 3 do
            local id = string.format("%s_%s_%d", t, player.UserId, i)
            local entry = { id = id, starType = t, equipped = false }
            table.insert(state[player].ownedList, entry)
            state[player].ownedMap[id] = entry
        end
    end
    renderBaseDisplays(player)
    broadcastMain(player)
    broadcastState(player)
end

local function equipStar(player, starId, starType)
    local s = state[player]
    if not s then
        return
    end
    local entry = starId and s.ownedMap[starId]
    if not entry then
        for _, e in ipairs(s.ownedList) do
            if not e.equipped and (not starType or e.starType == starType) then
                entry = e
                break
            end
        end
    end
    if not entry or entry.equipped then
        return
    end
    local placed = false
    for i = 1, MAX_SLOTS do
        if not s.slots[i] then
            s.slots[i] = entry.id
            entry.equipped = true
            placed = true
            break
        end
    end
    if not placed then
        return
    end
    debugLog(player, true, "Equipped", entry.starType, "slots:", slotsToString(s.slots))
    renderBaseDisplays(player)
    broadcastState(player)
end

local function unequipStar(player, starId, starType)
    local s = state[player]
    if not s then
        return
    end
    local removedId
    for i = MAX_SLOTS, 1, -1 do
        local id = s.slots[i]
        local entry = id and s.ownedMap[id]
        if id and entry and (starId == id or (starType and entry.starType == starType)) then
            s.slots[i] = nil
            entry.equipped = false
            removedId = id
            break
        end
    end
    if not removedId then
        debugLog(player, true, "Unequip requested but none found for", starType or starId or "?")
        return
    end
    if s.mainId == removedId then
        s.mainId = nil
        broadcastMain(player)
    end
    local packed = {}
    for i = 1, MAX_SLOTS do
        local id = s.slots[i]
        if id then
            table.insert(packed, id)
        end
    end
    for i = 1, MAX_SLOTS do
        s.slots[i] = packed[i]
    end
    debugLog(player, true, "Unequipped", starType or starId or "?", "slots:", slotsToString(s.slots))
    renderBaseDisplays(player)
    broadcastState(player)
end

local function setMain(player, starId)
    local s = state[player]
    if not s then
        return
    end
    if not starId or not s.ownedMap[starId] then
        s.mainId = nil
    else
        s.mainId = starId
    end
    broadcastMain(player)
end

getStateFn.OnServerInvoke = function(player)
    local s = state[player]
    if not s then
        initPlayer(player)
        s = state[player]
    end
    return {
        owned = s.ownedList,
        slots = s.slots,
        mainId = s.mainId,
    }
end

equipEvent.OnServerEvent:Connect(function(player, starIdOrType)
    equipStar(player, starIdOrType, starIdOrType)
end)

unequipEvent.OnServerEvent:Connect(function(player, starIdOrType)
    unequipStar(player, starIdOrType, starIdOrType)
end)

-- Main star is now chosen via proximity prompts on tube stars; ignore direct remote.

Players.PlayerAdded:Connect(function(player)
    initPlayer(player)
    player.CharacterAdded:Connect(function()
        broadcastMain(player)
        broadcastState(player)
    end)
    player.AncestryChanged:Connect(function(_, parent)
        if not parent then
            state[player] = nil
        end
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    clearDisplays(player)
    state[player] = nil
end)

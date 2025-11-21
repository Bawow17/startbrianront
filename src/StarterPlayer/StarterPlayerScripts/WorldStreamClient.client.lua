local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Protocol = require(ReplicatedStorage:WaitForChild("WorldStreamProtocol"))
local RemotesFolder = ReplicatedStorage:WaitForChild(Protocol.RemoteFolderName)
local ChunkEvent = RemotesFolder:WaitForChild(Protocol.ChunkEventName)
local DecorationEvent = RemotesFolder:WaitForChild(Protocol.DecorationEventName)
local ShardEvent = RemotesFolder:WaitForChild(Protocol.ShardEventName)
local SnapshotEvent = RemotesFolder:WaitForChild(Protocol.SnapshotEventName)

local AssetReplicationFunction = ReplicatedStorage:FindFirstChild("RequestAssetReplication")

local clientWorldFolder = Instance.new("Folder")
clientWorldFolder.Name = "ClientWorld"
clientWorldFolder.Parent = Workspace

local clientChunksFolder = Instance.new("Folder")
clientChunksFolder.Name = "ClientChunks"
clientChunksFolder.Parent = clientWorldFolder

local clientDecorationsFolder = Instance.new("Folder")
clientDecorationsFolder.Name = "ClientDecorations"
clientDecorationsFolder.Parent = clientWorldFolder

local clientShardsFolder = Instance.new("Folder")
clientShardsFolder.Name = "ClientShards"
clientShardsFolder.Parent = clientWorldFolder

local chunkVisuals = {}
local decorationVisuals = {}
local shardVisuals = {}

local function cacheInFlightVFX(entry)
    if not entry or entry.vfx then
        return
    end
    local holder
    if entry.model then
        holder = entry.model:FindFirstChild("InFlight", true)
    end
    if not holder then
        entry.vfx = false
        return
    end

    entry.vfx = {}
    for _, descendant in ipairs(holder:GetDescendants()) do
        if descendant:IsA("ParticleEmitter")
            or descendant:IsA("Beam")
            or descendant:IsA("Trail")
            or descendant:IsA("PointLight")
            or descendant:IsA("SpotLight")
            or descendant:IsA("SurfaceLight") then
            table.insert(entry.vfx, descendant)
        end
    end
end

local function setShardVFX(entry, enabled)
    if not entry then
        return
    end
    if entry.vfx == nil then
        cacheInFlightVFX(entry)
    end
    if type(entry.vfx) ~= "table" then
        return
    end
    for _, vfx in ipairs(entry.vfx) do
        if vfx:IsA("ParticleEmitter") or vfx:IsA("Beam") or vfx:IsA("Trail") then
            vfx.Enabled = enabled
        elseif vfx:IsA("PointLight") or vfx:IsA("SpotLight") or vfx:IsA("SurfaceLight") then
            vfx.Enabled = enabled
        end
    end
end

local function applyShardTransform(entry, now)
    if not entry or not entry.model then
        return
    end

    if entry.lastUpdate and now - entry.lastUpdate > 0.2 then
        return
    end

    local state = entry.state or "horizontal"
    if state == "landed" then
        local pos = entry.currPos or entry.model:GetPivot().Position
        entry.model:PivotTo(CFrame.new(pos))
        setShardVFX(entry, false)
        return
    end

    local prevPos = entry.prevPos or entry.currPos or entry.model:GetPivot().Position
    local currPos = entry.currPos or prevPos
    local prevDir = entry.prevDir or entry.currDir or Vector3.new(0, -1, 0)
    local currDir = entry.currDir or prevDir

    local t0 = entry.lastUpdate or now
    local duration = entry.lerpDuration or 0.12
    local alpha = duration > 0 and math.clamp((now - t0) / duration, 0, 1) or 1

    local pos = prevPos:Lerp(currPos, alpha)
    local dir = prevDir:Lerp(currDir, alpha)
    if dir.Magnitude < 1e-4 then
        dir = Vector3.new(0, -1, 0)
    else
        dir = dir.Unit
    end

    local base = CFrame.lookAt(pos, pos + dir, Vector3.yAxis)
    local cframe = base * CFrame.Angles(math.rad(90), 0, 0)
    entry.model:PivotTo(cframe)
    setShardVFX(entry, true)
end

local function ensureAsset(path)
    if not path or path == "" then
        return nil
    end

    local segments = {}
    for segment in string.gmatch(path, "[^/]+") do
        table.insert(segments, segment)
    end

    if #segments == 0 then
        return nil
    end

    local current = ReplicatedStorage
    local builtPath = {}
    for _, segment in ipairs(segments) do
        table.insert(builtPath, segment)
        local child = current:FindFirstChild(segment)
        if not child then
            if AssetReplicationFunction then
                local requestPath = table.concat(builtPath, "/")
                pcall(function()
                    AssetReplicationFunction:InvokeServer(requestPath)
                end)
                child = current:FindFirstChild(segment)
            end
        end

        if not child then
            return nil
        end
        current = child
    end

    return current
end

local function sanitizeModel(model, canCollide)
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
            descendant.CanCollide = canCollide or false
            descendant.CanTouch = false
            descendant.CanQuery = false
        end
    end
end

local function cloneTemplate(path)
    if not path then
        return nil
    end
    local asset = ensureAsset(path)
    if not asset then
        warn("[WorldStreamClient] Missing asset for path:", path)
        return nil
    end
    local clone = asset:Clone()
    return clone
end

local function removeModelEntry(entry)
    if not entry then
        return
    end
    if entry.model then
        entry.model:Destroy()
    end
end

local function renderChunk(key, data)
    if not data then
        return
    end

    local entry = chunkVisuals[key]
    local desiredPath = data.templatePath or (data.templateName and string.format("%s/%s", Protocol.TemplateRootName or "ChunkTemplates", data.templateName))

    if entry and entry.templatePath ~= desiredPath then
        removeModelEntry(entry)
        chunkVisuals[key] = nil
        entry = nil
    end

    if not entry then
        local clone = cloneTemplate(desiredPath)
        if not clone then
            return
        end
        sanitizeModel(clone, true)
        clone.Name = string.format("Chunk_%d_%d", data.chunkX or 0, data.chunkZ or 0)
        clone.Parent = clientChunksFolder
        entry = {
            model = clone,
            templatePath = desiredPath,
        }
        chunkVisuals[key] = entry
    end

    local pivot = CFrame.new(data.center or Vector3.zero)
    entry.model:PivotTo(pivot)
    entry.model:SetAttribute("ChunkX", data.chunkX)
    entry.model:SetAttribute("ChunkZ", data.chunkZ)
    entry.model:SetAttribute("Biome", data.biome or "Unknown")
    entry.model:SetAttribute("Template", data.templateName or "Unknown")
end

local function removeChunk(key)
    local entry = chunkVisuals[key]
    if entry then
        removeModelEntry(entry)
        chunkVisuals[key] = nil
    end
end

local function renderDecorations(key, data)
    local existing = decorationVisuals[key]
    if existing then
        for _, model in ipairs(existing) do
            model:Destroy()
        end
    end

    local visuals = {}
    decorationVisuals[key] = visuals

    if type(data) ~= "table" then
        return
    end

    for index, entry in ipairs(data) do
        local clone = cloneTemplate(entry.templatePath)
        if clone then
            sanitizeModel(clone, entry.collidable ~= false)
            clone.Name = string.format("%s_%d", key, index)
            local cf = entry.cframe or CFrame.new(entry.position or Vector3.zero)
            clone:PivotTo(cf)
            clone.Parent = clientDecorationsFolder
            table.insert(visuals, clone)
        end
    end
end

local function removeDecorations(key)
    local visuals = decorationVisuals[key]
    if not visuals then
        return
    end
    for _, model in ipairs(visuals) do
        model:Destroy()
    end
    decorationVisuals[key] = nil
end

local function renderShard(id, data)
    if not data then
        return
    end

    local desiredPath = data.templatePath
    local entry = shardVisuals[id]

    if entry and entry.templatePath ~= desiredPath then
        removeModelEntry(entry)
        shardVisuals[id] = nil
        entry = nil
    end

    if not entry then
        local clone = cloneTemplate(desiredPath)
        if not clone then
            return
        end
        sanitizeModel(clone, false)
        clone.Name = tostring(id)
        clone.Parent = clientShardsFolder
        entry = {
            model = clone,
            templatePath = desiredPath,
            vfx = nil,
        }
        shardVisuals[id] = entry
    end

    local position = data.position or Vector3.zero
    local direction = data.direction or Vector3.new(0, -1, 0)
    local now = time()
    entry.prevPos = entry.currPos or position
    entry.currPos = position
    entry.prevDir = entry.currDir or direction
    entry.currDir = direction
    entry.lastUpdate = now
    entry.lerpDuration = 0.12
    entry.state = data.state or "horizontal"
    applyShardTransform(entry, now)
    entry.model:SetAttribute("Rarity", data.rarity or "Unknown")
    entry.model:SetAttribute("State", data.state or "Unknown")
end

local function removeShard(id)
    local entry = shardVisuals[id]
    if entry then
        removeModelEntry(entry)
        shardVisuals[id] = nil
    end
end

local function handleChunkMessage(message)
    if message.action == "set" then
        renderChunk(message.key, message.data or {})
    elseif message.action == "remove" then
        removeChunk(message.key)
    elseif message.action == "reset" then
        for key in pairs(chunkVisuals) do
            removeChunk(key)
        end
    end
end

local function handleDecorationMessage(message)
    if message.action == "set" then
        renderDecorations(message.key, message.data or {})
    elseif message.action == "remove" then
        removeDecorations(message.key)
    elseif message.action == "reset" then
        for key in pairs(decorationVisuals) do
            removeDecorations(key)
        end
    end
end

local function handleShardMessage(message)
    if message.action == "set" then
        renderShard(message.id, message.data or {})
    elseif message.action == "remove" then
        removeShard(message.id)
    elseif message.action == "reset" then
        for id in pairs(shardVisuals) do
            removeShard(id)
        end
    end
end

local function applySnapshot(snapshot)
    if typeof(snapshot) ~= "table" then
        return
    end

    if snapshot.chunks then
        for key in pairs(chunkVisuals) do
            removeChunk(key)
        end
        for key, data in pairs(snapshot.chunks) do
            renderChunk(key, data)
        end
    end

    if snapshot.decorations then
        for key in pairs(decorationVisuals) do
            removeDecorations(key)
        end
        for key, data in pairs(snapshot.decorations) do
            renderDecorations(key, data)
        end
    end

    if snapshot.shards then
        for id in pairs(shardVisuals) do
            removeShard(id)
        end
        for id, data in pairs(snapshot.shards) do
            renderShard(id, data)
        end
    end
end

ChunkEvent.OnClientEvent:Connect(handleChunkMessage)
DecorationEvent.OnClientEvent:Connect(handleDecorationMessage)
ShardEvent.OnClientEvent:Connect(handleShardMessage)
SnapshotEvent.OnClientEvent:Connect(applySnapshot)

RunService.RenderStepped:Connect(function()
    local now = time()
    for _, entry in pairs(shardVisuals) do
        applyShardTransform(entry, now)
    end
end)

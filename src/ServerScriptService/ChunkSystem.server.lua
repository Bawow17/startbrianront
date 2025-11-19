local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local BiomeConfig = require(script.Parent:WaitForChild("ChunkBiomeConfig"))

local CHUNK_SIZE = 128
local LOAD_RADIUS = 10
local UPDATE_INTERVAL = 1

local WORLD_ORIGIN = Vector3.new(7500, 7500, 7500)
local MAIN_WORLD_HEIGHT_TOLERANCE = 750
local PRIME_X = 73856093
local PRIME_Z = 19349663
local BASE_PATCH_SIZE = BiomeConfig.PatchSizeInChunks or 10
local CENTRAL_BIOME_RADIUS_CHUNKS = math.max(4, math.ceil(BASE_PATCH_SIZE / 3))
local CENTRAL_BIOME_RADIUS_SQR = CENTRAL_BIOME_RADIUS_CHUNKS * CENTRAL_BIOME_RADIUS_CHUNKS

local FOREST_TREE_COUNT_MIN = 3
local FOREST_TREE_COUNT_MAX = 10
local FOREST_TREE_MIN_SPACING = 35
local FOREST_TREE_EDGE_MARGIN = 6
local FOREST_GRASS_COUNT_MIN = 8
local FOREST_GRASS_COUNT_MAX = 16
local FOREST_GRASS_MIN_SPACING = 37
local FOREST_GRASS_EDGE_MARGIN = 4

local TEMPLATE_ROOT_NAME = BiomeConfig.TemplateRootName or "ChunkTemplates"

local function locateTemplatesRoot()
    return ServerStorage:FindFirstChild(TEMPLATE_ROOT_NAME) or Workspace:FindFirstChild(TEMPLATE_ROOT_NAME)
end

local templatesRoot = locateTemplatesRoot()

local chunksFolder = Workspace:FindFirstChild("GeneratedChunks")
if not chunksFolder then
    chunksFolder = Instance.new("Folder")
    chunksFolder.Name = "GeneratedChunks"
    chunksFolder.Parent = Workspace
end

local rng = Random.new()
local templateCache = {}
local centralBiomeName

local function shallowCopy(source)
    local target = {}
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

local function getBiomeSurfaceColor(biomeName)
    if not biomeName then
        return nil
    end

    templatesRoot = templatesRoot or locateTemplatesRoot()
    if not templatesRoot then
        return nil
    end

    local biomeDef = BiomeConfig.Biomes[biomeName]
    if not biomeDef then
        return nil
    end

    local folder = biomeDef.templateFolder and templatesRoot:FindFirstChild(biomeDef.templateFolder)
    if not folder then
        return nil
    end

    local templateName = biomeDef.templates and biomeDef.templates[1]
    if not templateName then
        return nil
    end

    local template = folder:FindFirstChild(templateName)
    if not template then
        return nil
    end

    local primary = template.PrimaryPart
    local candidates = {}
    for _, child in ipairs(template:GetDescendants()) do
        if child:IsA("BasePart") then
            table.insert(candidates, child)
        end
    end

    table.sort(candidates, function(a, b)
        if a == primary then
            return false
        elseif b == primary then
            return true
        else
            return a.Size.Y < b.Size.Y
        end
    end)

    local surface = candidates[1]
    return surface and surface.Color or nil
end

local function updateCentralGroundColors()
    local centralModel = Workspace:FindFirstChild("Map")
    if centralModel then
        centralModel = centralModel:FindFirstChild("GroundMainGame")
    else
        centralModel = Workspace:FindFirstChild("GroundMainGame")
    end
    if not centralModel then
        return
    end

    local targetColor = getBiomeSurfaceColor(centralBiomeName)

    if not targetColor then
        local centralChunk = chunksFolder:FindFirstChild("Chunk_1_0") or chunksFolder:FindFirstChild("Chunk_0_1")
        if not centralChunk then
            for _, model in ipairs(chunksFolder:GetChildren()) do
                if model:GetAttribute("Biome") == centralBiomeName then
                    centralChunk = model
                    break
                end
            end
        end

        if centralChunk then
            for _, child in ipairs(centralChunk:GetChildren()) do
                if child:IsA("BasePart") and child ~= centralChunk.PrimaryPart then
                    targetColor = child.Color
                    break
                end
            end

            if not targetColor and centralChunk.PrimaryPart then
                targetColor = centralChunk.PrimaryPart.Color
            end
        end
    end

    if not targetColor then
        return
    end

    for _, name in ipairs({ "Grass", "Grass2" }) do
        local part = centralModel:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            part.Color = targetColor
        end
    end
end

local function chunkKey(cx, cz)
    return tostring(cx) .. ":" .. tostring(cz)
end

local function worldToChunk(position)
    local dx = position.X - WORLD_ORIGIN.X
    local dz = position.Z - WORLD_ORIGIN.Z

    local cx = math.floor(dx / CHUNK_SIZE + 0.5)
    local cz = math.floor(dz / CHUNK_SIZE + 0.5)

    return cx, cz
end

local function chunkCenterWorldPosition(cx, cz, height)
    return Vector3.new(
        WORLD_ORIGIN.X + cx * CHUNK_SIZE,
        height,
        WORLD_ORIGIN.Z + cz * CHUNK_SIZE
    )
end

local loadedChunks = {}
local chunkHeights = {}

local function selectCentralBiome()
    local entries = {}
    local totalWeight = 0
    for name, data in pairs(BiomeConfig.Biomes) do
        local weight = data.weight or 1
        totalWeight += weight
        table.insert(entries, { name = name, weight = weight })
    end

    local roll = rng:NextNumber() * totalWeight
    local cumulative = 0
    for _, entry in ipairs(entries) do
        cumulative += entry.weight
        if roll <= cumulative then
            return entry.name
        end
    end

    return entries[1] and entries[1].name or "Flatlands"
end

centralBiomeName = selectCentralBiome()
Workspace:SetAttribute("CentralBiome", centralBiomeName)
Workspace:SetAttribute("CentralBiomeRadius", CENTRAL_BIOME_RADIUS_CHUNKS)
task.defer(updateCentralGroundColors)

chunkHeights[chunkKey(0, 0)] = WORLD_ORIGIN.Y

local function getNeighborHeights(cx, cz)
    local neighbors = {}

    local function addNeighbor(nx, nz)
        local key = chunkKey(nx, nz)
        local height = chunkHeights[key]
        if height then
            table.insert(neighbors, height)
        end
    end

    addNeighbor(cx + 1, cz)
    addNeighbor(cx - 1, cz)
    addNeighbor(cx, cz + 1)
    addNeighbor(cx, cz - 1)

    return neighbors
end

local function chooseChunkHeight(cx, cz)
    local key = chunkKey(cx, cz)
    local existing = chunkHeights[key]
    if existing then
        return existing
    end

    local neighbors = getNeighborHeights(cx, cz)
    local baseHeight

    if #neighbors > 0 then
        local sum = 0
        for _, h in ipairs(neighbors) do
            sum += h
        end
        baseHeight = math.floor((sum / #neighbors) + 0.5)
    else
        baseHeight = WORLD_ORIGIN.Y
    end

    local candidates = {}
    local offsets = { 0, 1, -1, 2, -2, 3, -3 }

    for _, offset in ipairs(offsets) do
        table.insert(candidates, baseHeight + offset)
    end

    for i = #candidates, 2, -1 do
        local j = rng:NextInteger(1, i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end

    local function isValidHeight(height)
        for _, neighborHeight in ipairs(neighbors) do
            if math.abs(height - neighborHeight) > 3 then
                return false
            end
        end
        return true
    end

    local chosen = baseHeight

    if #neighbors == 0 then
        chosen = baseHeight
    else
        for _, candidate in ipairs(candidates) do
            if isValidHeight(candidate) then
                chosen = candidate
                break
            end
        end
    end

    chunkHeights[key] = chosen
    return chosen
end

local function seededRandom(seed, cx, cz)
    return Random.new(seed + cx * PRIME_X + cz * PRIME_Z)
end

local function getTemplatesForPath(path)
    local cached = templateCache[path]
    if cached ~= nil then
        return cached
    end

    templatesRoot = templatesRoot or locateTemplatesRoot()
    if not templatesRoot then
        templateCache[path] = {}
        return templateCache[path]
    end

    local node = templatesRoot
    for segment in string.gmatch(path, "[^/]+") do
        node = node and node:FindFirstChild(segment)
        if not node then
            break
        end
    end

    local models = {}
    if node then
        if node:IsA("Folder") then
            for _, child in ipairs(node:GetChildren()) do
                if child:IsA("Model") then
                    table.insert(models, child)
                end
            end
        elseif node:IsA("Model") then
            table.insert(models, node)
        end
    end

    templateCache[path] = models
    return models
end

local function scatterModels(chunkModel, centerPosition, config)
    local templates = config.templates
    if not templates then
        if config.templatePath then
            templates = getTemplatesForPath(config.templatePath)
        end
    end

    if not templates or #templates == 0 then
        return
    end

    local randomSource = config.seed and seededRandom(config.seed, chunkModel:GetAttribute("ChunkX") or 0, chunkModel:GetAttribute("ChunkZ") or 0) or rng

    local desiredCount = randomSource:NextInteger(config.countMin, config.countMax)
    local placedPositions = {}
    local attempts = 0
    local maxAttempts = desiredCount * 15
    local halfSize = CHUNK_SIZE * 0.5 - (config.edgeMargin or 0)

    local function isBlocked(instance)
        local ancestor = instance:FindFirstAncestorWhichIsA("Model")
        if not ancestor then
            return false
        end

        if config.blockAttribute and ancestor:GetAttribute(config.blockAttribute) then
            return true
        end

        if config.blockAttributes then
            for attrName in pairs(config.blockAttributes) do
                if ancestor:GetAttribute(attrName) then
                    return true
                end
            end
        end

        return false
    end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include
    rayParams.FilterDescendantsInstances = { chunkModel }
    rayParams.IgnoreWater = false

    while #placedPositions < desiredCount and attempts < maxAttempts do
        attempts += 1

        local offsetX = randomSource:NextNumber(-halfSize, halfSize)
        local offsetZ = randomSource:NextNumber(-halfSize, halfSize)

        local origin = Vector3.new(centerPosition.X + offsetX, centerPosition.Y + 200, centerPosition.Z + offsetZ)
        local direction = Vector3.new(0, -400, 0)
        local result = Workspace:Raycast(origin, direction, rayParams)

        if result and not isBlocked(result.Instance) then
            local position2D = Vector2.new(result.Position.X, result.Position.Z)
            local tooClose = false

            for _, pos in ipairs(placedPositions) do
                if (pos - position2D).Magnitude < config.minSpacing then
                    tooClose = true
                    break
                end
            end

            if not tooClose then
                local template = templates[randomSource:NextInteger(1, #templates)]
                local clone = template:Clone()
                clone:SetAttribute(config.attributeName, true)

                for _, descendant in ipairs(clone:GetDescendants()) do
                    if descendant:IsA("BasePart") then
                        descendant.Anchored = true
                        descendant.CanCollide = config.collidable ~= false
                    end
                end

                local basePivot = clone:GetPivot()
                local rotation = randomSource:NextNumber(0, math.pi * 2)
                local rotationCF = CFrame.Angles(0, rotation, 0)

                local xVector = rotationCF:VectorToWorldSpace(basePivot.XVector)
                local yVector = rotationCF:VectorToWorldSpace(basePivot.YVector)
                local zVector = rotationCF:VectorToWorldSpace(basePivot.ZVector)

                local finalCFrame = CFrame.fromMatrix(result.Position - Vector3.new(0, 0.1, 0), xVector, yVector, zVector)
                clone:PivotTo(finalCFrame)
                clone.Parent = chunkModel

                table.insert(placedPositions, position2D)
            end
        end
    end
end

local biomeDecorations = {
    Forest = {
        {
            templatePath = "Forest/Trees",
            seed = 12345,
            countMin = FOREST_TREE_COUNT_MIN,
            countMax = FOREST_TREE_COUNT_MAX,
            minSpacing = FOREST_TREE_MIN_SPACING,
            edgeMargin = FOREST_TREE_EDGE_MARGIN,
            attributeName = "ForestTreeDecoration",
            blockAttributes = { ForestTreeDecoration = true },
        },
        {
            templatePath = "Forest/Grass",
            seed = 23456,
            countMin = FOREST_GRASS_COUNT_MIN,
            countMax = FOREST_GRASS_COUNT_MAX,
            minSpacing = FOREST_GRASS_MIN_SPACING,
            edgeMargin = FOREST_GRASS_EDGE_MARGIN,
            attributeName = "ForestGrassDecoration",
            blockAttributes = { ForestTreeDecoration = true, ForestGrassDecoration = true },
            collidable = false,
        },
    },
    Flatlands = {
        {
            templatePath = "Flatlands/Grass",
            seed = 34567,
            countMin = 10,
            countMax = 24,
            minSpacing = 37,
            edgeMargin = 6,
            attributeName = "FlatlandsGrassDecoration",
            blockAttributes = { FlatlandsGrassDecoration = true },
            collidable = false,
        },
    },
    Desert = {
        {
            templatePath = "Desert/Cactus",
            seed = 45678,
            countMin = 4,
            countMax = 8,
            minSpacing = 32,
            edgeMargin = 8,
            attributeName = "DesertCactusDecoration",
            blockAttributes = { DesertCactusDecoration = true },
        },
        {
            templatePath = "Desert/Tumbleweed",
            seed = 56789,
            countMin = 2,
            countMax = 4,
            minSpacing = 50,
            edgeMargin = 8,
            attributeName = "DesertTumbleweedDecoration",
            blockAttributes = { DesertCactusDecoration = true, DesertTumbleweedDecoration = true },
            collidable = false,
        },
    },
    Swamp = {
        {
            templatePath = "Swamp/Trees",
            seed = 67890,
            countMin = 3,
            countMax = 7,
            minSpacing = 42,
            edgeMargin = 10,
            attributeName = "SwampTreeDecoration",
            blockAttributes = { SwampTreeDecoration = true },
        },
        {
            templatePath = "Swamp/Ponds",
            seed = 78901,
            countMin = 1,
            countMax = 2,
            minSpacing = 28,
            edgeMargin = 12,
            attributeName = "SwampPondDecoration",
            blockAttributes = { SwampTreeDecoration = true, SwampPondDecoration = true },
        },
    },
    Tundra = {
        {
            templatePath = "Tundra/Trees",
            seed = 89012,
            countMin = 3,
            countMax = 6,
            minSpacing = 39,
            edgeMargin = 10,
            attributeName = "TundraTreeDecoration",
            blockAttributes = { TundraTreeDecoration = true },
        },
    },
}

local function decorateChunk(chunkModel, cx, cz, centerPosition, biomeName)
    local configs = biomeDecorations[biomeName]
    if not configs then
        return
    end

    chunkModel:SetAttribute("ChunkX", chunkModel:GetAttribute("ChunkX") or cx)
    chunkModel:SetAttribute("ChunkZ", chunkModel:GetAttribute("ChunkZ") or cz)

    for _, config in ipairs(configs) do
        scatterModels(chunkModel, centerPosition, config)
    end
end

local function spawnChunk(cx, cz)
    templatesRoot = templatesRoot or locateTemplatesRoot()
    if not templatesRoot then
        return
    end
    if cx == 0 and cz == 0 then
        local key = chunkKey(cx, cz)
        if not loadedChunks[key] then
            local height = chunkHeights[key] or WORLD_ORIGIN.Y
            local center = chunkCenterWorldPosition(cx, cz, height)
            loadedChunks[key] = {
                model = nil,
                height = height,
                biome = centralBiomeName,
                center = center,
                chunkX = cx,
                chunkZ = cz,
            }
        end
        return
    end

    local key = chunkKey(cx, cz)
    if loadedChunks[key] then
        return
    end

    local biome = BiomeConfig.getBiomeForChunk(cx, cz)
    local distSq = cx * cx + cz * cz
    if distSq <= CENTRAL_BIOME_RADIUS_SQR and centralBiomeName then
        local overrideDef = BiomeConfig.Biomes[centralBiomeName]
        if overrideDef then
            biome = shallowCopy(overrideDef)
            biome.name = centralBiomeName
        end
    end

    local template = BiomeConfig.getTemplateForChunk(templatesRoot, biome, cx, cz)
    if not template then
        return
    end

    local height = chooseChunkHeight(cx, cz)

    local clone = template:Clone()
    clone.Name = string.format("Chunk_%d_%d", cx, cz)
    local biomeName = biome and biome.name or nil
    if biomeName then
        clone:SetAttribute("Biome", biomeName)
    end
    clone:SetAttribute("ChunkX", cx)
    clone:SetAttribute("ChunkZ", cz)

    local center = chunkCenterWorldPosition(cx, cz, height)
    clone:PivotTo(CFrame.new(center))
    clone.Parent = chunksFolder

    loadedChunks[key] = {
        model = clone,
        height = height,
        biome = biomeName,
        center = center,
        chunkX = cx,
        chunkZ = cz,
    }

    if biomeName then
        decorateChunk(clone, cx, cz, center, biomeName)
    end

    if biomeName == centralBiomeName and cx == 1 and cz == 0 then
        task.defer(updateCentralGroundColors)
    end
end

local function unloadChunk(key)
    local data = loadedChunks[key]
    if not data then
        return
    end

    if data.model and data.model.Parent then
        data.model:Destroy()
    end

    loadedChunks[key] = nil
end

local function updateChunks()
    local needed = {}

    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        if character then
            local rootPart = character:FindFirstChild("HumanoidRootPart")
            if rootPart then
                local position = rootPart.Position
                local heightDelta = math.abs(position.Y - WORLD_ORIGIN.Y)

                if heightDelta <= MAIN_WORLD_HEIGHT_TOLERANCE then
                    local cx, cz = worldToChunk(position)

                    for dx = -LOAD_RADIUS, LOAD_RADIUS do
                        for dz = -LOAD_RADIUS, LOAD_RADIUS do
                            local chunkX = cx + dx
                            local chunkZ = cz + dz
                            local key = chunkKey(chunkX, chunkZ)

                            needed[key] = needed[key] or { x = chunkX, z = chunkZ }
                        end
                    end
                end
            end
        end
    end

    for key, info in pairs(needed) do
        spawnChunk(info.x, info.z)
    end

    for key in pairs(loadedChunks) do
        if not needed[key] then
            unloadChunk(key)
        end
    end
end

while true do
    updateChunks()
    task.wait(UPDATE_INTERVAL)
end

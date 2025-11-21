local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")
local BiomeConfig = require(script.Parent:WaitForChild("ChunkBiomeConfig"))
local DailyWorldCycle = require(script.Parent:WaitForChild("DailyWorldCycle"))
local WorldStreamServer = require(script.Parent:WaitForChild("WorldStreamServer"))

WorldStreamServer.init()

local CHUNK_SIZE = 128
local LOAD_RADIUS = 10
local MAX_CHUNK_SPAWNS_PER_STEP = 7
local UPDATE_INTERVAL = 0.1
local REFRESH_CHECK_INTERVAL = 30
local TELEPORT_OFFSET = Vector3.new(0, 5, 0)
local CYCLE_SEED_STORE_NAME = "ChunkWorldCycleSeeds"
local MEMORY_SEED_MAP_NAME = "ChunkWorldCycleSeeds"
local MEMORY_SEED_TTL_SECONDS = 48 * 60 * 60
local CYCLE_STATE_KEY = "CurrentState"
local MAX_SEED_VALUE = 2000000000
local SCHEDULE_VERSION = DailyWorldCycle.getScheduleVersion()

local WORLD_ORIGIN = Vector3.new(7500, 7500, 7500)
local MAIN_WORLD_HEIGHT_TOLERANCE = 750
local PRIME_X = 73856093
local PRIME_Z = 19349663
local BASE_PATCH_SIZE = BiomeConfig.PatchSizeInChunks or 10
local CENTRAL_BIOME_RADIUS_CHUNKS = math.max(4, math.ceil(BASE_PATCH_SIZE / 3))
local CENTRAL_BIOME_RADIUS_SQR = CENTRAL_BIOME_RADIUS_CHUNKS * CENTRAL_BIOME_RADIUS_CHUNKS
local BASE_BIOME_SEED = BiomeConfig.BaseBiomeRandomSeed or BiomeConfig.BiomeRandomSeed
local BASE_TEMPLATE_SEED = BiomeConfig.BaseTemplateRandomSeed or BiomeConfig.TemplateRandomSeed
local RNG_BASE_SEED = 987654321

local FOREST_TREE_COUNT_MIN = 3
local FOREST_TREE_COUNT_MAX = 10
local FOREST_TREE_MIN_SPACING = 52
local FOREST_TREE_EDGE_MARGIN = 6
local FOREST_GRASS_COUNT_MIN = 8
local FOREST_GRASS_COUNT_MAX = 16
local FOREST_GRASS_MIN_SPACING = 41
local FOREST_GRASS_EDGE_MARGIN = 4

local LIGHT_SHARD_TEMPLATE_FOLDER_NAME = "LightShardTemplates"
local LIGHT_SHARD_MODEL_NAME = "CommonLightShard"
local LIGHT_SHARD_RARITIES = {
    {
        name = "Common",
        templateName = "CommonLightShard",
        weight = 0.70,
    },
    {
        name = "Uncommon",
        templateName = "UncommonLightShard",
        weight = 0.24,
    },
    {
        name = "Rare",
        templateName = "RareLightShard",
        weight = 0.05,
    },
    {
        name = "Epic",
        templateName = "EpicLightShard",
        weight = 0.008,
    },
    {
        name = "Legendary",
        templateName = "LegendaryLightShard",
        weight = 0.0015,
    },
    {
        name = "Mythical",
        templateName = "MythicalLightShard",
        weight = 0.0005,
    },
}
local LIGHT_SHARD_BASE_SEED = RNG_BASE_SEED + 13579
local LIGHT_SHARD_SPAWN_INTERVAL = 0.5
local LIGHT_SHARD_MAX_ACTIVE = 10000
local LIGHT_SHARD_SPAWN_RADIUS_MIN_CHUNKS = 0
local LIGHT_SHARD_SPAWN_RADIUS_MAX_CHUNKS = 300
local LIGHT_SHARD_SPAWNS_PER_INTERVAL = 5
local LIGHT_SHARD_VISIBILITY_RADIUS_CHUNKS = 10
local LIGHT_SHARD_FORCE_VISIBILITY = false
local LIGHT_SHARD_MIN_ALTITUDE = 175
local LIGHT_SHARD_HORIZONTAL_DURATION = 30
local LIGHT_SHARD_HORIZONTAL_SPEED = 45
local LIGHT_SHARD_LAND_HEIGHT_OFFSET = 2
local LIGHT_SHARD_LAND_DETECTION_TOLERANCE = 0.5
local LIGHT_SHARD_LIFETIME_AFTER_LAND = 10
local LIGHT_SHARD_DEBUG = false

local TEMPLATE_ROOT_NAME = BiomeConfig.TemplateRootName or "ChunkTemplates"
local cycleSeedStore = DataStoreService:GetDataStore(CYCLE_SEED_STORE_NAME)
local memorySeedMap = MemoryStoreService:GetSortedMap(MEMORY_SEED_MAP_NAME)
local authoritativeCycleState
local currentCycleStartUnix = 0
local currentCycleStartMillis = 0.0
local currentCycleId
local currentStateSignature = ""
local nextRefreshUnix = 0
local chunkHeights = {}
local function locateTemplatesRoot()
    return ServerStorage:FindFirstChild(TEMPLATE_ROOT_NAME) or Workspace:FindFirstChild(TEMPLATE_ROOT_NAME)
end

local function getRelativeTemplatePath(root, descendant)
    if not root or not descendant then
        return nil
    end

    local segments = {}
    local current = descendant
    while current and current ~= root do
        table.insert(segments, 1, current.Name)
        current = current.Parent
    end

    if current ~= root then
        return descendant.Name
    end

    table.insert(segments, 1, root.Name)
    return table.concat(segments, "/")
end

local templatesRoot = locateTemplatesRoot()

local lightShardFolder = Workspace:FindFirstChild("LightShards")
if not lightShardFolder then
    lightShardFolder = Instance.new("Folder")
    lightShardFolder.Name = "LightShards"
    lightShardFolder.Parent = Workspace
end

local spawnLocationCache
local function clearArray(list)
    for index = #list, 1, -1 do
        list[index] = nil
    end
end

local function clearDictionary(map)
    for key in pairs(map) do
        map[key] = nil
    end
end

local function shardDebugPrint(...)
    if LIGHT_SHARD_DEBUG then
        warn("[LightShard]", ...)
    end
end

local function formatVector3(vec)
    return string.format("(%.1f, %.1f, %.1f)", vec.X, vec.Y, vec.Z)
end

local function horizontalDescentEase(t, finalSlope)
    finalSlope = finalSlope or 0
    local clampedT = math.clamp(t or 0, 0, 1)
    local coeff = math.clamp(finalSlope, 0, 1)
    local value = (-1 + coeff) * clampedT * clampedT * clampedT + (1 - coeff) * clampedT * clampedT + clampedT
    return math.clamp(value, 0, 1)
end

local function getLightShardSpawnStep()
    local perInterval = math.max(1, math.floor(LIGHT_SHARD_SPAWNS_PER_INTERVAL + 0.5))
    local step = LIGHT_SHARD_SPAWN_INTERVAL / perInterval
    if step <= 0 then
        step = 0.05
    end
    return perInterval, step
end

local function selectLightShardRarity(randomSource)
    if not LIGHT_SHARD_RARITIES or #LIGHT_SHARD_RARITIES == 0 then
        return {
            name = "Default",
            templateName = LIGHT_SHARD_MODEL_NAME,
            weight = 1,
        }
    end

    local roll = randomSource and randomSource:NextNumber() or math.random()
    local cumulative = 0
    local last = LIGHT_SHARD_RARITIES[#LIGHT_SHARD_RARITIES]
    for _, rarity in ipairs(LIGHT_SHARD_RARITIES) do
        cumulative += rarity.weight or 0
        if roll <= cumulative then
            return rarity
        end
        last = rarity
    end
    return last
end

local function estimateDescentDuration()
    local descentSpeed = math.max(LIGHT_SHARD_HORIZONTAL_SPEED, 0.1)
    return (LIGHT_SHARD_MIN_ALTITUDE + 100) / descentSpeed
end

local function getLightShardLifetimeWindow()
    local totalAirTime = math.max(0, LIGHT_SHARD_HORIZONTAL_DURATION + estimateDescentDuration())
    local buffer = math.max(LIGHT_SHARD_SPAWN_INTERVAL * 2, 1)
    return totalAirTime + LIGHT_SHARD_LIFETIME_AFTER_LAND + buffer
end

local function locateSpawnLocation()
    if spawnLocationCache and spawnLocationCache.Parent then
        return spawnLocationCache
    end

    local spawn = Workspace:FindFirstChild("SpawnLocation")
    if spawn and spawn:IsA("BasePart") then
        spawnLocationCache = spawn
        return spawn
    end

    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant:IsA("SpawnLocation") or descendant.Name == "SpawnLocation" then
            spawnLocationCache = descendant
            return descendant
        end
    end

    return nil
end

local function getSpawnTeleportCFrame()
    local spawnPart = locateSpawnLocation()
    if not spawnPart or not spawnPart.CFrame then
        return nil
    end
    local sizeY = spawnPart.Size and spawnPart.Size.Y or 1
    return spawnPart.CFrame + Vector3.new(0, sizeY * 0.5, 0) + TELEPORT_OFFSET
end

local function teleportPlayersToSpawn()
    local targetCFrame = getSpawnTeleportCFrame()
    if not targetCFrame then
        warn("SpawnLocation not found; cannot teleport players after chunk reset.")
        return
    end

    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        if character then
            local root = character:FindFirstChild("HumanoidRootPart")
            if root then
                root.CFrame = targetCFrame
            else
                player:LoadCharacter()
            end
        else
            player:LoadCharacter()
        end
    end
end

local function getUnixMillis()
    local ok, value = pcall(function()
        return DateTime.now().UnixTimestampMillis
    end)
    if ok then
        return value
    end
    return DateTime.now().UnixTimestamp * 1000
end

local function computeJobEntropy()
    local jobId = game.JobId or ""
    local accumulator = 0
    for index = 1, #jobId do
        accumulator = (accumulator + string.byte(jobId, index) * index) % MAX_SEED_VALUE
    end
    if accumulator == 0 then
        accumulator = math.random(1, MAX_SEED_VALUE - 1)
    end
    return accumulator
end

local function generateCycleSeedSet(cycleId)
    local entropy = getUnixMillis() + computeJobEntropy() + cycleId * 977
    local rng = Random.new(entropy)

    local function nextSeed()
        return rng:NextInteger(1, MAX_SEED_VALUE)
    end

    return {
        version = 3,
        signature = HttpService:GenerateGUID(false),
        rngSeed = nextSeed(),
        biomeSeed = nextSeed(),
        templateSeed = nextSeed(),
        decorationSeed = nextSeed(),
    }
end

local function isValidSeedSet(data)
    return typeof(data) == "table"
        and typeof(data.rngSeed) == "number"
        and typeof(data.biomeSeed) == "number"
        and typeof(data.templateSeed) == "number"
        and typeof(data.decorationSeed) == "number"
end

local function isValidCycleState(state)
    return typeof(state) == "table"
        and typeof(state.cycleId) == "number"
        and typeof(state.cycleStartUnix) == "number"
        and typeof(state.nextRefreshUnix) == "number"
        and isValidSeedSet(state.seeds)
end

local function storeCycleStateInMemory(state)
    if not isValidCycleState(state) then
        return
    end

    local success, err = pcall(function()
        memorySeedMap:SetAsync(CYCLE_STATE_KEY, state, MEMORY_SEED_TTL_SECONDS)
    end)

    if not success and err then
        warn(string.format("Failed to store chunk cycle state in memory: %s", err))
    end
end

local function readCycleStateFromMemory()
    local success, data = pcall(function()
        return memorySeedMap:GetAsync(CYCLE_STATE_KEY)
    end)

    if success and isValidCycleState(data) then
        return data
    elseif not success and data then
        warn(string.format("Failed to read chunk cycle state from memory: %s", data))
    end

    return nil
end

local function buildCycleState(cycleInfo)
    local seeds = generateCycleSeedSet(cycleInfo.cycleId)
    return {
        cycleId = cycleInfo.cycleId,
        cycleStartUnix = cycleInfo.cycleStartUnix,
        nextRefreshUnix = cycleInfo.nextRefreshUnix,
        scheduleVersion = SCHEDULE_VERSION,
        seeds = seeds,
        version = seeds.version,
        signature = seeds.signature,
    }
end

local function resolveAuthoritativeCycleState()
    local candidate = DailyWorldCycle.getCycleInfo()

    if isValidCycleState(authoritativeCycleState)
        and authoritativeCycleState.scheduleVersion == SCHEDULE_VERSION
        and (authoritativeCycleState.cycleStartUnix or 0) >= candidate.cycleStartUnix then
        return authoritativeCycleState
    end

    local memoryState = readCycleStateFromMemory()
    if isValidCycleState(memoryState)
        and memoryState.scheduleVersion == SCHEDULE_VERSION
        and (memoryState.cycleStartUnix or 0) >= candidate.cycleStartUnix then
        authoritativeCycleState = memoryState
        return memoryState
    end

    local success, result = pcall(function()
        return cycleSeedStore:UpdateAsync(CYCLE_STATE_KEY, function(current)
            local currentValid = isValidCycleState(current) and current.scheduleVersion == SCHEDULE_VERSION
            local currentStart = currentValid and current.cycleStartUnix or -math.huge

            if not currentValid or candidate.cycleStartUnix > currentStart then
                return buildCycleState(candidate)
            end

            return current
        end)
    end)

    if success and isValidCycleState(result) then
        authoritativeCycleState = result
        storeCycleStateInMemory(result)
        return result
    elseif not success and result then
        warn(string.format("Failed to update chunk cycle state: %s", result))
    end

    if isValidCycleState(memoryState) and memoryState.scheduleVersion == SCHEDULE_VERSION then
        authoritativeCycleState = memoryState
        return memoryState
    end

    local fallback = buildCycleState(candidate)
    authoritativeCycleState = fallback
    storeCycleStateInMemory(fallback)
    return fallback
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

local function getCycleElapsedSeconds()
    if currentCycleStartMillis and currentCycleStartMillis > 0 then
        local ok, nowMillis = pcall(function()
            return DateTime.now().UnixTimestampMillis
        end)
        if ok then
            return math.max(0, (nowMillis - currentCycleStartMillis) / 1000)
        end
    end

    if currentCycleStartUnix and currentCycleStartUnix > 0 then
        local ok, nowSeconds = pcall(function()
            return DateTime.now().UnixTimestamp
        end)
        if ok then
            return math.max(0, nowSeconds - currentCycleStartUnix)
        end
    end

    return 0
end

local loadedChunks = {}
local playerChunkPositions = {}
local lightShardSchedule = {}
local activeLightShards = {}
local chunkDecorationRecords = {}
local lightShardLastScheduledOrdinal = -1
local lightShardCenterChunkX = 0
local lightShardCenterChunkZ = 0

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

local function getChunkHeight(cx, cz)
    local key = chunkKey(cx, cz)
    local height = chunkHeights[key]
    if height ~= nil then
        return height
    end
    return chooseChunkHeight(cx, cz)
end

local function getChunkGroundHeightAt(position)
    local cx, cz = worldToChunk(position)
    return getChunkHeight(cx, cz)
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
                    table.insert(models, {
                        instance = child,
                        templatePath = string.format("%s/%s/%s", TEMPLATE_ROOT_NAME, path, child.Name),
                    })
                end
            end
        elseif node:IsA("Model") then
            table.insert(models, {
                instance = node,
                templatePath = string.format("%s/%s", TEMPLATE_ROOT_NAME, path),
            })
        end
    end

    templateCache[path] = models
    return models
end

local function scatterModels(chunkContext, centerPosition, config, targetPosition, recordList)
    local templates = config.templates
    if not templates then
        if config.templatePath then
            templates = getTemplatesForPath(config.templatePath)
            config.templates = templates
        end
    end

    if not templates or #templates == 0 then
        return
    end

    local chunkX = chunkContext and chunkContext.chunkX or 0
    local chunkZ = chunkContext and chunkContext.chunkZ or 0
    local chunkBiome = chunkContext and chunkContext.biome or nil
    local randomSource = config.seed and seededRandom(config.seed, chunkX, chunkZ) or rng

    local desiredCount = randomSource:NextInteger(config.countMin, config.countMax)
    local placedPositions = {}
    local placements = {}
    local attempts = 0
    local maxAttempts = desiredCount * 15
    local halfSize = CHUNK_SIZE * 0.5 - (config.edgeMargin or 0)

    while #placedPositions < desiredCount and attempts < maxAttempts do
        attempts += 1

        local offsetX = randomSource:NextNumber(-halfSize, halfSize)
        local offsetZ = randomSource:NextNumber(-halfSize, halfSize)

        local worldX = centerPosition.X + offsetX
        local worldZ = centerPosition.Z + offsetZ
        local heightSample = getChunkGroundHeightAt(Vector3.new(worldX, centerPosition.Y, worldZ))
        local position = Vector3.new(worldX, heightSample, worldZ)
        local position2D = Vector2.new(worldX, worldZ)
        local tooClose = false

        for _, pos in ipairs(placedPositions) do
            if (pos - position2D).Magnitude < config.minSpacing then
                tooClose = true
                break
            end
        end

        if not tooClose then
            local templateEntry = templates[randomSource:NextInteger(1, #templates)]
            local template = templateEntry.instance
            local rotation = randomSource:NextNumber(0, math.pi * 2)
            local distSq = targetPosition and (targetPosition - position).Magnitude ^ 2 or 0

            table.insert(placements, {
                template = template,
                templatePath = templateEntry.templatePath,
                position = position,
                rotation = rotation,
                distSq = distSq,
            })

            table.insert(placedPositions, position2D)
        end
    end

    table.sort(placements, function(a, b)
        return a.distSq < b.distSq
    end)

    for _, placement in ipairs(placements) do
        local basePivot = placement.template and placement.template:GetPivot() or CFrame.new()
        local rotationCF = CFrame.Angles(0, placement.rotation, 0)
        local xVector = rotationCF:VectorToWorldSpace(basePivot.XVector)
        local yVector = rotationCF:VectorToWorldSpace(basePivot.YVector)
        local zVector = rotationCF:VectorToWorldSpace(basePivot.ZVector)
        local finalCFrame = CFrame.fromMatrix(placement.position - Vector3.new(0, 0.1, 0), xVector, yVector, zVector)

        if recordList then
            table.insert(recordList, {
                attribute = config.attributeName,
                template = placement.template and placement.template.Name or "Unknown",
                templatePath = placement.templatePath,
                cframe = finalCFrame,
                position = placement.position,
                rotation = placement.rotation,
                biome = chunkBiome,
                collidable = config.collidable ~= false,
            })
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
            minSpacing = 43,
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
            minSpacing = 50,
            edgeMargin = 8,
            attributeName = "DesertCactusDecoration",
            blockAttributes = { DesertCactusDecoration = true },
        },
        {
            templatePath = "Desert/Tumbleweed",
            seed = 56789,
            countMin = 2,
            countMax = 4,
            minSpacing = 57,
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
            minSpacing = 68,
            edgeMargin = 10,
            attributeName = "SwampTreeDecoration",
            blockAttributes = { SwampTreeDecoration = true },
        },
        {
            templatePath = "Swamp/Ponds",
            seed = 78901,
            countMin = 1,
            countMax = 2,
            minSpacing = 36,
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
            minSpacing = 53,
            edgeMargin = 10,
            attributeName = "TundraTreeDecoration",
            blockAttributes = { TundraTreeDecoration = true },
        },
    },
}

local function resolveShardLandingPosition(shard)
    if shard.landingPosition and shard.landingPositionAccurate then
        return shard.landingPosition
    end

    local basePosition = shard.spawnPosition or WORLD_ORIGIN
    local travelDuration = LIGHT_SHARD_HORIZONTAL_DURATION + estimateDescentDuration()
    local travel = shard.horizontalDirection * shard.horizontalSpeed * travelDuration
    local referencePosition = basePosition + travel

    local groundHeight = getChunkGroundHeightAt(referencePosition)
    shard.landingPosition = Vector3.new(referencePosition.X, groundHeight, referencePosition.Z)
    shard.landingPositionAccurate = true
    return shard.landingPosition
end

local function setDecorationSeedsForCycle(cycleId, seedSet)
    for _, configs in pairs(biomeDecorations) do
        for _, config in ipairs(configs) do
            config._baseSeed = config._baseSeed or config.seed or (config.attributeName and #config.attributeName * 7919) or 1

            local baseSeed = seedSet and seedSet.decorationSeed or DailyWorldCycle.makeSeed(config._baseSeed, cycleId)
            local mixed = (baseSeed + config._baseSeed * 977 + cycleId * 131071) % MAX_SEED_VALUE
            if mixed == 0 then
                mixed = baseSeed
            end

            config.seed = mixed
        end
    end
end

local lightShardTemplates = {}
local lightShardTemplateMissingWarned = {}

local function getLightShardTemplate(templateName)
    templateName = templateName or LIGHT_SHARD_MODEL_NAME

    local cached = lightShardTemplates[templateName]
    if cached and cached.Parent then
        return cached
    end
    lightShardTemplates[templateName] = nil

    local container = ServerStorage:FindFirstChild(LIGHT_SHARD_TEMPLATE_FOLDER_NAME) or ServerStorage
    if not container then
        if not lightShardTemplateMissingWarned[templateName] then
            warn(string.format("Light shard template folder '%s' not found in ServerStorage.", LIGHT_SHARD_TEMPLATE_FOLDER_NAME))
            lightShardTemplateMissingWarned[templateName] = true
        end
        return nil
    end

    local template = container:FindFirstChild(templateName)
    if not template or not template:IsA("Model") then
        if not lightShardTemplateMissingWarned[templateName] then
            warn(string.format("Light shard model '%s' not found under %s.", templateName, container:GetFullName()))
            lightShardTemplateMissingWarned[templateName] = true
        end
        return nil
    end

    lightShardTemplates[templateName] = template
    lightShardTemplateMissingWarned[templateName] = nil
    return template
end

local function resetLightShardState()
    clearDictionary(lightShardSchedule)
    for id, instance in pairs(activeLightShards) do
        if instance.model then
            instance.model:Destroy()
        end
        activeLightShards[id] = nil
    end
    lightShardLastScheduledOrdinal = -1

    if lightShardFolder then
        lightShardFolder:ClearAllChildren()
    end

    if WorldStreamServer.isEnabled() then
        WorldStreamServer.resetShards()
    end
end

local function initializeLightShardScheduler()
    local _, spawnStep = getLightShardSpawnStep()
    if spawnStep <= 0 then
        lightShardLastScheduledOrdinal = -1
        return
    end

    local elapsed = getCycleElapsedSeconds()
    local lookback = getLightShardLifetimeWindow()
    local startTime = math.max(0, elapsed - lookback)
    local startOrdinal = math.floor(startTime / spawnStep) - 1
    if startOrdinal < -1 then
        startOrdinal = -1
    end

    lightShardLastScheduledOrdinal = startOrdinal
    shardDebugPrint(string.format(
        "Shard scheduler initialized at ordinal %d (elapsed %.1fs, lookback %.1fs)",
        lightShardLastScheduledOrdinal,
        elapsed,
        lookback
    ))
end

local function makeLightShardRandom(shardOrdinal)
    local cycleId = currentCycleId or 0
    local baseSeed = LIGHT_SHARD_BASE_SEED + shardOrdinal * 8191 + cycleId * 131 + shardOrdinal * cycleId
    local seed = DailyWorldCycle.makeSeed(baseSeed, cycleId)
    return Random.new(seed)
end

local function buildLightShardEntry(shardOrdinal, spawnStep)
    if shardOrdinal < 0 then
        return nil
    end

    local randomSource = makeLightShardRandom(shardOrdinal)
    if not randomSource then
        return nil
    end

    local rarity = selectLightShardRarity(randomSource)
    local templateName = rarity and rarity.templateName or LIGHT_SHARD_MODEL_NAME

    local _, effectiveSpawnStep = getLightShardSpawnStep()
    if spawnStep and spawnStep > 0 then
        effectiveSpawnStep = spawnStep
    end

    local minRadius = math.min(LIGHT_SHARD_SPAWN_RADIUS_MIN_CHUNKS, LIGHT_SHARD_SPAWN_RADIUS_MAX_CHUNKS)
    local maxRadius = math.max(LIGHT_SHARD_SPAWN_RADIUS_MIN_CHUNKS, LIGHT_SHARD_SPAWN_RADIUS_MAX_CHUNKS)
    local spawnRadius = randomSource:NextNumber(minRadius, maxRadius)
    local spawnAngle = randomSource:NextNumber(0, math.pi * 2)
    local offsetX = math.cos(spawnAngle) * spawnRadius
    local offsetZ = math.sin(spawnAngle) * spawnRadius

    local withinChunkX = randomSource:NextNumber(-CHUNK_SIZE * 0.5, CHUNK_SIZE * 0.5)
    local withinChunkZ = randomSource:NextNumber(-CHUNK_SIZE * 0.5, CHUNK_SIZE * 0.5)
    local spawnHeightOffset = randomSource:NextNumber(-20, 60)
    local spawnCenterWorldX = WORLD_ORIGIN.X + lightShardCenterChunkX * CHUNK_SIZE
    local spawnCenterWorldZ = WORLD_ORIGIN.Z + lightShardCenterChunkZ * CHUNK_SIZE
    local spawnPosition = Vector3.new(
        spawnCenterWorldX + offsetX * CHUNK_SIZE + withinChunkX,
        WORLD_ORIGIN.Y + LIGHT_SHARD_MIN_ALTITUDE + spawnHeightOffset,
        spawnCenterWorldZ + offsetZ * CHUNK_SIZE + withinChunkZ
    )

    local horizontalAngle = randomSource:NextNumber(0, math.pi * 2)
    local horizontalDirection = Vector3.new(math.cos(horizontalAngle), 0, math.sin(horizontalAngle))
    if horizontalDirection.Magnitude < 1e-4 then
        horizontalDirection = Vector3.new(1, 0, 0)
    else
        horizontalDirection = horizontalDirection.Unit
    end

    local speedMin = LIGHT_SHARD_HORIZONTAL_SPEED * 0.85
    local speedMax = LIGHT_SHARD_HORIZONTAL_SPEED * 1.15
    local horizontalSpeed = randomSource:NextNumber(speedMin, speedMax)
    local expectedLandingPosition = spawnPosition + horizontalDirection * horizontalSpeed * LIGHT_SHARD_HORIZONTAL_DURATION

    local spawnOffset = shardOrdinal * effectiveSpawnStep

    local entry = {
        id = shardOrdinal,
        spawnOffset = spawnOffset,
        spawnPosition = spawnPosition,
        horizontalDirection = horizontalDirection,
        horizontalSpeed = horizontalSpeed,
        descentSpeed = math.abs(horizontalSpeed),
        expectedLandingPosition = expectedLandingPosition,
        rarity = rarity and rarity.name or "Default",
        templateName = templateName,
    }
    return entry
end

local function computeShardLandingPosition(shard)
    if shard.landingPosition and shard.landingPositionAccurate then
        return shard.landingPosition
    end

    local groundHeight = getChunkGroundHeightAt(shard.expectedLandingPosition)
    shard.landingPosition = Vector3.new(shard.expectedLandingPosition.X, groundHeight, shard.expectedLandingPosition.Z)
    shard.landingPositionAccurate = true
    return shard.landingPosition
end

local function evaluateLightShard(shard, elapsed)
    if elapsed < 0 then
        return nil
    end

if elapsed < LIGHT_SHARD_HORIZONTAL_DURATION then
    local displacement = shard.horizontalDirection * shard.horizontalSpeed * elapsed
    local position = shard.spawnPosition + displacement
    return {
        state = "horizontal",
        position = position,
            direction = shard.horizontalDirection,
        }
    end

    local landingPosition = resolveShardLandingPosition(shard)
    local descentSpeed = math.max(shard.descentSpeed or shard.horizontalSpeed, 0.1)
    local initialHeight = shard.spawnPosition.Y
    local dropDistance = math.max(math.abs(initialHeight - landingPosition.Y), 4)
    local descentDuration = dropDistance / descentSpeed
    local totalLifetime = LIGHT_SHARD_HORIZONTAL_DURATION + descentDuration + LIGHT_SHARD_LIFETIME_AFTER_LAND
    if elapsed > totalLifetime then
        return nil
    end

    local descentElapsed = math.max(0, elapsed - LIGHT_SHARD_HORIZONTAL_DURATION)
    local descentT = math.clamp(descentElapsed / math.max(descentDuration, 0.001), 0, 1)
    local horizontalEase = horizontalDescentEase(descentT, 0.65)
    local verticalEase = descentT * descentT

    local startHorizontal = shard.spawnPosition + shard.horizontalDirection * shard.horizontalSpeed * LIGHT_SHARD_HORIZONTAL_DURATION
    local horizontalTarget = Vector3.new(landingPosition.X, startHorizontal.Y, landingPosition.Z)
    local horizontalPosition = startHorizontal:Lerp(horizontalTarget, horizontalEase)
    local currentHeight = initialHeight - (initialHeight - landingPosition.Y) * verticalEase
    local position = Vector3.new(horizontalPosition.X, currentHeight, horizontalPosition.Z)

    if position.Y <= landingPosition.Y + LIGHT_SHARD_LAND_DETECTION_TOLERANCE then
        return {
            state = "landed",
            position = Vector3.new(landingPosition.X, landingPosition.Y + LIGHT_SHARD_LAND_HEIGHT_OFFSET, landingPosition.Z),
            direction = Vector3.new(0, -1, 0),
        }
    end

    local aheadElapsed = math.min(descentElapsed + math.max(0.05 * descentDuration, 0.01), descentDuration)
    local aheadT = math.clamp(aheadElapsed / math.max(descentDuration, 0.001), 0, 1)
    local aheadHorizontalEase = horizontalDescentEase(aheadT, 0.65)
    local aheadVerticalEase = aheadT * aheadT
    local aheadHorizontal = startHorizontal:Lerp(horizontalTarget, aheadHorizontalEase)
    local aheadHeight = initialHeight - (initialHeight - landingPosition.Y) * aheadVerticalEase
    local aheadPos = Vector3.new(aheadHorizontal.X, aheadHeight, aheadHorizontal.Z)
    local direction = aheadPos - position
    if direction.Magnitude < 1e-4 then
        direction = Vector3.new(0, -1, 0)
    else
        direction = direction.Unit
    end
    return {
        state = "descent",
        position = position,
        direction = direction,
    }
end

local function shouldShardBeVisible(position)
    if LIGHT_SHARD_FORCE_VISIBILITY then
        return true
    end

    if LIGHT_SHARD_VISIBILITY_RADIUS_CHUNKS <= 0 then
        return true
    end

    if #playerChunkPositions == 0 then
        return false
    end

    local shardChunkX, shardChunkZ = worldToChunk(position)
    local radius = LIGHT_SHARD_VISIBILITY_RADIUS_CHUNKS
    local radiusSq = radius * radius
    for _, chunk in ipairs(playerChunkPositions) do
        local dx = shardChunkX - chunk.x
        local dz = shardChunkZ - chunk.z
        if dx * dx + dz * dz <= radiusSq then
            return true
        end
    end

    return false
end

local function setInFlightVFXEnabled(instance, enabled)
    if not instance or not instance.model then
        return
    end

    if not instance.inFlightVFX then
        local holder = instance.model:FindFirstChild("InFlight", true)
        if holder then
            instance.inFlightVFX = {}
            for _, descendant in ipairs(holder:GetDescendants()) do
                if descendant:IsA("ParticleEmitter")
                    or descendant:IsA("Beam")
                    or descendant:IsA("Trail")
                    or descendant:IsA("PointLight")
                    or descendant:IsA("SpotLight")
                    or descendant:IsA("SurfaceLight") then
                    table.insert(instance.inFlightVFX, descendant)
                end
            end
        end
    end

    if not instance.inFlightVFX then
        return
    end

    for _, vfx in ipairs(instance.inFlightVFX) do
        if vfx:IsA("ParticleEmitter") or vfx:IsA("Beam") or vfx:IsA("Trail") then
            vfx.Enabled = enabled
        elseif vfx:IsA("PointLight") or vfx:IsA("SpotLight") or vfx:IsA("SurfaceLight") then
            vfx.Enabled = enabled
        end
    end
end

local function spawnLightShardInstance(shard)
    if WorldStreamServer.isEnabled() then
        return {
            model = nil,
        }
    end

    local template = getLightShardTemplate(shard and shard.templateName)
    if not template then
        return nil
    end

    local clone = template:Clone()
    local primary = clone.PrimaryPart
    local core = clone:FindFirstChild("Core", true)
    if core and core:IsA("BasePart") then
        clone.PrimaryPart = core
        primary = core
    end
    if not primary then
        for _, descendant in ipairs(clone:GetDescendants()) do
            if descendant:IsA("BasePart") then
                clone.PrimaryPart = descendant
                primary = descendant
                break
            end
        end
    end

    if not primary then
        shardDebugPrint("Unable to spawn light shard; template missing BasePart.")
        clone:Destroy()
        return nil
    end

    for _, descendant in ipairs(clone:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = true
        end
    end

    clone:SetAttribute("LightShardId", shard.id)
    clone.Name = string.format("LightShard_%d", shard.id)
    clone.Parent = lightShardFolder

    local instanceData = {
        model = clone,
    }
    setInFlightVFXEnabled(instanceData, true)
    return instanceData
end

local function destroyLightShardInstance(identifier)
    local instance = activeLightShards[identifier]
    if not instance then
        return false
    end

    if instance.model then
        instance.model:Destroy()
    end

    activeLightShards[identifier] = nil
    if WorldStreamServer.isEnabled() then
        WorldStreamServer.removeShard(identifier)
    end
    return true
end

local function streamShardState(shard, evaluation)
    if not WorldStreamServer.isEnabled() then
        return
    end
    if not shard or not evaluation then
        return
    end

    local payload = {
        id = shard.id,
        state = evaluation.state,
        position = evaluation.position,
        direction = evaluation.direction,
        rarity = shard.rarity or "Common",
        templateName = shard.templateName or LIGHT_SHARD_MODEL_NAME,
        templatePath = string.format("%s/%s", LIGHT_SHARD_TEMPLATE_FOLDER_NAME, shard.templateName or LIGHT_SHARD_MODEL_NAME),
        spawnPosition = shard.spawnPosition,
        spawnOffset = shard.spawnOffset,
        landingPosition = shard.landingPosition or resolveShardLandingPosition(shard),
        horizontalSpeed = shard.horizontalSpeed,
        horizontalDirection = shard.horizontalDirection,
        descentSpeed = shard.descentSpeed,
    }

    WorldStreamServer.setShardState(shard.id, payload)
end

local function updateLightShardInstanceTransform(shard, instance, evaluation)
    streamShardState(shard, evaluation)

    if not instance or not instance.model then
        return
    end

    if evaluation.state == "landed" then
        setInFlightVFXEnabled(instance, false)
        local landingPosition = resolveShardLandingPosition(shard)
        local pivotCFrame = CFrame.new(landingPosition + Vector3.new(0, LIGHT_SHARD_LAND_HEIGHT_OFFSET, 0))
        if not instance.landed or not shard.landingPositionAccurate then
            instance.model:PivotTo(pivotCFrame)
        end
        instance.lastPitch = 0
        instance.landed = shard.landingPositionAccurate
        return
    end

    setInFlightVFXEnabled(instance, true)
    local direction = evaluation.direction
    local planarDirection = Vector3.new(direction.X, 0, direction.Z)
    if planarDirection.Magnitude < 1e-4 then
        planarDirection = Vector3.new(0, 0, -1)
    else
        planarDirection = planarDirection.Unit
    end
    local baseCFrame = CFrame.lookAt(
        evaluation.position,
        evaluation.position + planarDirection,
        Vector3.yAxis
    )
    local pivotCFrame = baseCFrame * CFrame.Angles(math.rad(90), 0, 0)
    instance.model:PivotTo(pivotCFrame)
    local _, pitch, _ = pivotCFrame:ToOrientation()
    instance.lastPitch = pitch
end

local function syncLightShardSchedule(elapsed)
    if LIGHT_SHARD_SPAWN_INTERVAL <= 0 then
        return
    end

    local _, spawnStep = getLightShardSpawnStep()
    if spawnStep <= 0 then
        return
    end

    local targetOrdinal = math.floor(math.max(0, elapsed) / spawnStep)
    local lookback = getLightShardLifetimeWindow()
    local minOrdinal = math.max(0, targetOrdinal - math.ceil(lookback / spawnStep) - 2)
    if lightShardLastScheduledOrdinal < minOrdinal - 1 then
        lightShardLastScheduledOrdinal = minOrdinal - 1
    end

    if targetOrdinal <= lightShardLastScheduledOrdinal then
        return
    end

    for ordinal = lightShardLastScheduledOrdinal + 1, targetOrdinal do
        local entry = buildLightShardEntry(ordinal, spawnStep)
        if entry then
            lightShardSchedule[ordinal] = entry
        end
    end

    lightShardLastScheduledOrdinal = targetOrdinal
end

local function countActiveMovingShards()
    local count = 0
    for _, instance in pairs(activeLightShards) do
        if instance.state ~= "landed" then
            count += 1
        end
    end
    return count
end

local function updateLightShards(dt)
    if not currentCycleId or LIGHT_SHARD_SPAWN_INTERVAL <= 0 then
        shardDebugPrint(string.format(
            "Skipping light shard update; cycleId=%s interval=%.2f",
            tostring(currentCycleId),
            LIGHT_SHARD_SPAWN_INTERVAL
        ))
        return
    end

    local elapsed = getCycleElapsedSeconds()
    syncLightShardSchedule(elapsed)

    local totalAirTime = LIGHT_SHARD_HORIZONTAL_DURATION + estimateDescentDuration()
    local totalLifetime = totalAirTime + LIGHT_SHARD_LIFETIME_AFTER_LAND
    local activeMovingCount = countActiveMovingShards()

    for id, shard in pairs(lightShardSchedule) do
        local shardElapsed = elapsed - shard.spawnOffset
        if shardElapsed > totalLifetime then
            local instance = activeLightShards[id]
            if destroyLightShardInstance(id) then
                if instance and instance.state ~= "landed" then
                    activeMovingCount = math.max(0, activeMovingCount - 1)
                end
            end
            lightShardSchedule[id] = nil
            shardDebugPrint(string.format("Shard %d expired after %.2fs", id, shardElapsed))
        elseif shardElapsed >= 0 then
            local evaluation = evaluateLightShard(shard, shardElapsed)
            if evaluation then
                local visible = shouldShardBeVisible(evaluation.position)
                local instance = activeLightShards[id]

                if visible then
                    local movingState = evaluation.state ~= "landed"
                    local hasCapacity = (not movingState) or activeMovingCount < LIGHT_SHARD_MAX_ACTIVE

                    if not instance and hasCapacity then
                        instance = spawnLightShardInstance(shard)
                        if instance then
                            activeLightShards[id] = instance
                            instance.state = evaluation.state
                            if movingState then
                                activeMovingCount += 1
                            end
                            if evaluation.state ~= "landed" then
                                shardDebugPrint(string.format(
                                    "Shard %d instantiated in state '%s' at %s",
                                    id,
                                    evaluation.state,
                                    formatVector3(evaluation.position)
                                ))
                            end
                        end
                    end
                    if instance then
                        local previousState = instance.state or evaluation.state
                        updateLightShardInstanceTransform(shard, instance, evaluation)
                        if previousState ~= evaluation.state then
                            if previousState ~= "landed" and evaluation.state == "landed" then
                                activeMovingCount = math.max(0, activeMovingCount - 1)
                            elseif previousState == "landed" and evaluation.state ~= "landed" then
                                activeMovingCount += 1
                            end
                            if evaluation.state ~= "landed" then
                                shardDebugPrint(string.format(
                                    "Shard %d transitioned to '%s' at %s",
                                    id,
                                    evaluation.state,
                                    formatVector3(evaluation.position)
                                ))
                            end
                            instance.state = evaluation.state
                        end
                    end
                else
                    if destroyLightShardInstance(id) then
                        if instance and instance.state ~= "landed" then
                            activeMovingCount = math.max(0, activeMovingCount - 1)
                        end
                        shardDebugPrint(string.format(
                            "Shard %d hidden (players tracked: %d)",
                            id,
                            #playerChunkPositions
                        ))
                    end
                end
            end
        end
    end
end

local function decorateChunk(cx, cz, centerPosition, biomeName, targetPosition)
    local configs = biomeDecorations[biomeName]
    if not configs then
        if WorldStreamServer.isEnabled() then
            local key = chunkKey(cx, cz)
            chunkDecorationRecords[key] = {}
            WorldStreamServer.setDecorationState(key, {})
        end
        return
    end

    local decorationRecords
    if WorldStreamServer.isEnabled() then
        decorationRecords = {}
        chunkDecorationRecords[chunkKey(cx, cz)] = decorationRecords
    end

    local chunkContext = {
        chunkX = cx,
        chunkZ = cz,
        biome = biomeName,
    }

    for _, config in ipairs(configs) do
        scatterModels(chunkContext, centerPosition, config, targetPosition, decorationRecords)
    end

    if decorationRecords then
        WorldStreamServer.setDecorationState(chunkKey(cx, cz), decorationRecords)
    end
end

local function spawnChunk(cx, cz, sourcePosition)
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
    local templatePath = getRelativeTemplatePath(templatesRoot, template)
    local biomeName = biome and biome.name or nil
    local center = chunkCenterWorldPosition(cx, cz, height)

    loadedChunks[key] = {
        model = nil,
        height = height,
        biome = biomeName,
        center = center,
        chunkX = cx,
        chunkZ = cz,
        templatePath = templatePath,
    }

    if WorldStreamServer.isEnabled() then
        WorldStreamServer.setChunkState(key, {
            chunkX = cx,
            chunkZ = cz,
            height = height,
            center = center,
            biome = biomeName,
            templateName = template.Name,
            templatePath = templatePath,
        })
    end

    if biomeName then
        decorateChunk(cx, cz, center, biomeName, sourcePosition)
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

    chunkDecorationRecords[key] = nil

    if WorldStreamServer.isEnabled() then
        WorldStreamServer.removeChunk(key)
        WorldStreamServer.removeDecorationState(key)
    end

    loadedChunks[key] = nil
end

local function clearAllChunks()
    for key in pairs(loadedChunks) do
        unloadChunk(key)
    end
    loadedChunks = {}
    chunkDecorationRecords = {}
end

local function resetChunkState()
    chunkHeights = {}
    chunkHeights[chunkKey(0, 0)] = WORLD_ORIGIN.Y
    templateCache = {}
    chunkDecorationRecords = {}
end

local function applyCycleState(cycleState, isInitial)
    if not isValidCycleState(cycleState) then
        return
    end

    currentCycleId = cycleState.cycleId
    currentCycleStartUnix = cycleState.cycleStartUnix or 0
    currentCycleStartMillis = (cycleState.cycleStartUnix or 0) * 1000
    nextRefreshUnix = cycleState.nextRefreshUnix or 0

    Workspace:SetAttribute("ChunkCycleId", currentCycleId)
    Workspace:SetAttribute("ChunkCycleNextRefreshUnix", nextRefreshUnix)
    Workspace:SetAttribute("CentralBiomeRadius", CENTRAL_BIOME_RADIUS_CHUNKS)
    Workspace:SetAttribute("ChunkScheduleVersion", SCHEDULE_VERSION)
    Workspace:SetAttribute("LightShardCycleStart", currentCycleStartUnix)

    local cycleSeeds = cycleState.seeds or generateCycleSeedSet(currentCycleId)
    Workspace:SetAttribute("ChunkCycleSeedVersion", cycleSeeds.version or 0)
    Workspace:SetAttribute("ChunkCycleSeedSignature", cycleSeeds.signature or "")

    rng = Random.new((cycleSeeds and cycleSeeds.rngSeed) or DailyWorldCycle.makeSeed(RNG_BASE_SEED, currentCycleId))

    BiomeConfig.configureSeeds({
        BiomeRandomSeed = (cycleSeeds and cycleSeeds.biomeSeed) or DailyWorldCycle.makeSeed(BASE_BIOME_SEED, currentCycleId),
        TemplateRandomSeed = (cycleSeeds and cycleSeeds.templateSeed) or DailyWorldCycle.makeSeed(BASE_TEMPLATE_SEED, currentCycleId),
    })

    setDecorationSeedsForCycle(currentCycleId, cycleSeeds)
    resetLightShardState()
    initializeLightShardScheduler()
    resetChunkState()

    centralBiomeName = selectCentralBiome()
    Workspace:SetAttribute("CentralBiome", centralBiomeName)
    currentStateSignature = cycleSeeds.signature or ""

    if not isInitial then
        clearAllChunks()
    end

    task.defer(updateCentralGroundColors)
    teleportPlayersToSpawn()
end

local function updateChunks()
    local chunkEntries = {}
    local chunkMap = {}

    clearArray(playerChunkPositions)

    local function enqueueChunk(chunkX, chunkZ, distSq, sourcePosition)
        local key = chunkKey(chunkX, chunkZ)
        local existing = chunkMap[key]
        if existing then
            if distSq < existing.distSq then
                existing.distSq = distSq
                existing.sourcePosition = sourcePosition
            end
            return
        end

        local entry = {
            key = key,
            x = chunkX,
            z = chunkZ,
            distSq = distSq,
            sourcePosition = sourcePosition,
        }

        chunkMap[key] = entry
        table.insert(chunkEntries, entry)
    end

    local function processPlayer(player)
        local character = player.Character
        if not character then
            return
        end

        local rootPart = character:FindFirstChild("HumanoidRootPart")
        if not rootPart then
            return
        end

        local position = rootPart.Position
        local heightDelta = math.abs(position.Y - WORLD_ORIGIN.Y)
        if heightDelta > MAIN_WORLD_HEIGHT_TOLERANCE then
            return
        end

        local playerChunkX, playerChunkZ = worldToChunk(position)
        table.insert(playerChunkPositions, {
            x = playerChunkX,
            z = playerChunkZ,
        })
        for dx = -LOAD_RADIUS, LOAD_RADIUS do
            for dz = -LOAD_RADIUS, LOAD_RADIUS do
                local chunkX = playerChunkX + dx
                local chunkZ = playerChunkZ + dz

                local chunkWorldX = WORLD_ORIGIN.X + chunkX * CHUNK_SIZE
                local chunkWorldZ = WORLD_ORIGIN.Z + chunkZ * CHUNK_SIZE
                local diffX = position.X - chunkWorldX
                local diffZ = position.Z - chunkWorldZ
                local distSq = diffX * diffX + diffZ * diffZ

                enqueueChunk(chunkX, chunkZ, distSq, position)
            end
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        processPlayer(player)
    end

    table.sort(chunkEntries, function(a, b)
        return a.distSq < b.distSq
    end)

    local seen = {}
    local spawnedThisStep = 0
    for _, entry in ipairs(chunkEntries) do
        if not seen[entry.key] then
            seen[entry.key] = true

            if not loadedChunks[entry.key] then
                spawnChunk(entry.x, entry.z, entry.sourcePosition)
                spawnedThisStep += 1

                if spawnedThisStep >= MAX_CHUNK_SPAWNS_PER_STEP then
                    break
                end
            end
        end
    end

    for key in pairs(loadedChunks) do
        if not chunkMap[key] then
            unloadChunk(key)
        end
    end
end

applyCycleState(resolveAuthoritativeCycleState(), true)
shardDebugPrint(string.format("Initial cycle applied; cycleId=%s", tostring(currentCycleId)))

RunService.Heartbeat:Connect(function(dt)
    updateLightShards(dt or 0)
end)

local cycleCheckElapsed = 0

while true do
    updateChunks()
    cycleCheckElapsed += UPDATE_INTERVAL

    if cycleCheckElapsed >= REFRESH_CHECK_INTERVAL then
        cycleCheckElapsed = 0
        local cycleState = resolveAuthoritativeCycleState()
        if not currentCycleId
            or cycleState.cycleId ~= currentCycleId
            or (cycleState.seeds and cycleState.seeds.signature ~= currentStateSignature)
            or (cycleState.signature and cycleState.signature ~= currentStateSignature) then
            applyCycleState(cycleState, false)
        end
    end

    task.wait(UPDATE_INTERVAL)
end

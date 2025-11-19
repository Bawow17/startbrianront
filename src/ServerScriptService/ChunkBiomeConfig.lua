local ChunkBiomes = {}

ChunkBiomes.TemplateRootName = "ChunkTemplates"
ChunkBiomes.BiomeRandomSeed = 53298571
ChunkBiomes.TemplateRandomSeed = 80235813
ChunkBiomes.PatchSizeInChunks = 16
ChunkBiomes.PatchJitterRatio = 0.15
ChunkBiomes.PrimeX = 73856093
ChunkBiomes.PrimeZ = 19349663

ChunkBiomes.Biomes = {
    Flatlands = {
        priority = 1,
        weight = 1,
        templateFolder = "Flatlands",
        templates = { "FlatGrassChunk" },
    },
    Forest = {
        priority = 2,
        weight = 1,
        templateFolder = "Forest",
        templates = { "ForestChunk" },
    },
    Desert = {
        priority = 3,
        weight = 1,
        templateFolder = "Desert",
        templates = { "SandChunk" },
    },
    Tundra = {
        priority = 4,
        weight = 1,
        templateFolder = "Tundra",
        templates = { "SnowChunk" },
    },
    Swamp = {
        priority = 5,
        weight = 1,
        templateFolder = "Swamp",
        templates = { "SwampChunk" },
    },
}

local orderedBiomes = {}
local totalWeight = 0

local function copyTable(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

for name, data in pairs(ChunkBiomes.Biomes) do
    local entry = copyTable(data)
    entry.name = name
    entry.weight = data.weight or 1
    table.insert(orderedBiomes, entry)
    totalWeight += entry.weight
end

table.sort(orderedBiomes, function(a, b)
    return (a.priority or 0) < (b.priority or 0)
end)

ChunkBiomes._orderedBiomes = orderedBiomes
ChunkBiomes._totalWeight = totalWeight

local function randomForChunk(seed, cx, cz)
    local value = seed + cx * ChunkBiomes.PrimeX + cz * ChunkBiomes.PrimeZ
    return Random.new(value)
end

local patchCache = {}

local function getPatchData(patchX, patchZ)
    local key = patchX .. ":" .. patchZ
    local patch = patchCache[key]
    if patch then
        return patch
    end

    local rng = randomForChunk(ChunkBiomes.BiomeRandomSeed, patchX, patchZ)
    local roll = rng:NextNumber() * ChunkBiomes._totalWeight
    local biome = orderedBiomes[#orderedBiomes]
    local cumulative = 0
    for _, candidate in ipairs(orderedBiomes) do
        cumulative += candidate.weight
        if roll <= cumulative then
            biome = candidate
            break
        end
    end

    local patchSize = math.max(1, ChunkBiomes.PatchSizeInChunks or 1)
    local jitterRatio = math.clamp(ChunkBiomes.PatchJitterRatio or 0, 0, 0.5)
    local jitterAmount = patchSize * jitterRatio

    local centerX = (patchX + 0.5) * patchSize + rng:NextNumber(-jitterAmount, jitterAmount)
    local centerZ = (patchZ + 0.5) * patchSize + rng:NextNumber(-jitterAmount, jitterAmount)

    patch = {
        biome = biome,
        centerX = centerX,
        centerZ = centerZ,
    }

    patchCache[key] = patch
    return patch
end

function ChunkBiomes.getBiomeForChunk(cx, cz)
    if ChunkBiomes._totalWeight <= 0 then
        return orderedBiomes[1]
    end

    local patchSize = math.max(1, ChunkBiomes.PatchSizeInChunks or 1)
    local offset = patchSize * 0.5
    local shiftedCx = cx + offset
    local shiftedCz = cz + offset
    local patchX = math.floor(shiftedCx / patchSize)
    local patchZ = math.floor(shiftedCz / patchSize)

    local nearestPatch
    local nearestDistSq

    for dx = -1, 1 do
        for dz = -1, 1 do
            local px = patchX + dx
            local pz = patchZ + dz
            local patch = getPatchData(px, pz)

            local deltaX = cx - patch.centerX
            local deltaZ = cz - patch.centerZ
            local distSq = deltaX * deltaX + deltaZ * deltaZ

            if not nearestPatch or distSq < nearestDistSq then
                nearestPatch = patch
                nearestDistSq = distSq
            end
        end
    end

    local result = nearestPatch
    if result then
        local clampRadius = patchSize * 0.55
        if nearestDistSq > clampRadius * clampRadius then
            result = getPatchData(patchX, patchZ)
        end
    end

    return (result and result.biome) or orderedBiomes[1]
end

local function resolveTemplateFolder(root, folderName)
    if not root or not folderName then
        return nil
    end
    return root:FindFirstChild(folderName)
end

function ChunkBiomes.getTemplateForChunk(templatesRoot, biome, cx, cz)
    if not biome then
        return nil
    end

    local folder = resolveTemplateFolder(templatesRoot, biome.templateFolder)
    if not folder then
        return nil
    end

    local templateNames = biome.templates or {}
    if #templateNames == 0 then
        return nil
    end

    local templateName
    if #templateNames == 1 then
        templateName = templateNames[1]
    else
        local rng = randomForChunk(ChunkBiomes.TemplateRandomSeed, cx, cz)
        local index = rng:NextInteger(1, #templateNames)
        templateName = templateNames[index]
    end

    return folder:FindFirstChild(templateName)
end

return ChunkBiomes

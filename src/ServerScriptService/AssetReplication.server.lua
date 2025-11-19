local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local requestFunction = Instance.new("RemoteFunction")
requestFunction.Name = "RequestAssetReplication"
requestFunction.Parent = ReplicatedStorage

local function findInHierarchy(root, segments)
    local current = root
    for _, segment in ipairs(segments) do
        current = current and current:FindFirstChild(segment)
        if not current then
            return nil
        end
    end
    return current
end

local function ensurePath(rootParent, serverParent, segments)
    local currentParent = rootParent
    local currentServer = serverParent

    for _, segment in ipairs(segments) do
        local serverChild = currentServer:FindFirstChild(segment)
        if not serverChild then
            return nil
        end

        local child = currentParent:FindFirstChild(segment)
        if not child then
            local className = serverChild.ClassName
            local ok, newChild = pcall(function()
                return Instance.new(className)
            end)
            if not ok or not newChild then
                newChild = Instance.new("Folder")
            end
            newChild.Name = segment
            newChild.Parent = currentParent
            child = newChild
        end

        currentParent = child
        currentServer = serverChild
    end

    return currentParent, currentServer
end

local function replicateAsset(relativePath)
    if type(relativePath) ~= "string" or relativePath == "" then
        return nil, "Invalid path"
    end

    local segments = {}
    for segment in string.gmatch(relativePath, "[^/]+") do
        table.insert(segments, segment)
    end

    if #segments == 0 then
        return nil, "Invalid path"
    end

    local target = findInHierarchy(ServerStorage, segments)
    if not target then
        return nil, string.format("Asset '%s' not found in ServerStorage", relativePath)
    end

    local parentSegments = table.clone(segments)
    local assetName = table.remove(parentSegments, #parentSegments)

    local parent
    if #parentSegments == 0 then
        parent = ReplicatedStorage
    else
        parent = ensurePath(ReplicatedStorage, ServerStorage, parentSegments)
    end

    if not parent then
        return nil, "Failed to create replication path"
    end

    if typeof(parent) == "table" then
        parent = parent
    end

    local existing = parent:FindFirstChild(assetName)
    if existing then
        return existing, nil
    end

    local clone = target:Clone()
    clone.Parent = parent

    return clone, nil
end

requestFunction.OnServerInvoke = function(_, relativePath)
    local clone, err = replicateAsset(relativePath)
    if not clone then
        warn("[AssetReplication] " .. (err or "Unknown error"))
        return false
    end
    return true
end

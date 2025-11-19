local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SOURCE_FOLDER_NAME = "FollowThePlayerVfx"

local sourceFolder = ServerStorage:WaitForChild(SOURCE_FOLDER_NAME)

local function getOrCreateReplicaFolder()
    local replica = ReplicatedStorage:FindFirstChild(SOURCE_FOLDER_NAME)
    if not replica then
        replica = Instance.new("Folder")
        replica.Name = SOURCE_FOLDER_NAME
        replica.Parent = ReplicatedStorage
    end
    return replica
end

local replicaFolder = getOrCreateReplicaFolder()

local function rebuildReplica()
    replicaFolder:ClearAllChildren()
    for _, child in ipairs(sourceFolder:GetChildren()) do
        child:Clone().Parent = replicaFolder
    end
end

rebuildReplica()

sourceFolder.ChildAdded:Connect(function(child)
    task.defer(rebuildReplica)
end)

sourceFolder.ChildRemoved:Connect(function()
    task.defer(rebuildReplica)
end)

sourceFolder:GetPropertyChangedSignal("Name"):Connect(function()
    replicaFolder.Name = sourceFolder.Name
end)

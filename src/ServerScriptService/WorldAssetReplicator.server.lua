local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ASSET_FOLDERS = {
    "ChunkTemplates",
    "LightShardTemplates",
}

for _, folderName in ipairs(ASSET_FOLDERS) do
    local source = ServerStorage:FindFirstChild(folderName)
    if source then
        local existing = ReplicatedStorage:FindFirstChild(folderName)
        if existing then
            existing:Destroy()
        end
        local clone = source:Clone()
        clone.Parent = ReplicatedStorage
    end
end

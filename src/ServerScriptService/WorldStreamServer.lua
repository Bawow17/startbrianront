local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage:WaitForChild("WorldStreamProtocol"))

local REMOTE_FOLDER_NAME = Protocol.RemoteFolderName
local CHUNK_EVENT_NAME = Protocol.ChunkEventName
local DECOR_EVENT_NAME = Protocol.DecorationEventName
local SHARD_EVENT_NAME = Protocol.ShardEventName
local SNAPSHOT_EVENT_NAME = Protocol.SnapshotEventName
local SHARD_UPDATE_INTERVAL = 0.1

local WorldStreamServer = {}
WorldStreamServer._initialized = false
WorldStreamServer._enabled = true

local chunkState = {}
local decorationState = {}
local shardState = {}
local lastShardBroadcast = {}

local remotesFolder
local chunkEvent
local decorationEvent
local shardEvent
local snapshotEvent

local function deepClone(source)
    local clone = {}
    for key, value in pairs(source) do
        clone[key] = value
    end
    return clone
end

local function ensureRemotes()
    if remotesFolder then
        return
    end

    remotesFolder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME)
    if not remotesFolder then
        remotesFolder = Instance.new("Folder")
        remotesFolder.Name = REMOTE_FOLDER_NAME
        remotesFolder.Parent = ReplicatedStorage
    end

    local function getOrCreateRemote(name, className)
        local remote = remotesFolder:FindFirstChild(name)
        if remote and remote.ClassName == className then
            return remote
        end

        if remote then
            remote:Destroy()
        end

        remote = Instance.new(className)
        remote.Name = name
        remote.Parent = remotesFolder
        return remote
    end

    chunkEvent = getOrCreateRemote(CHUNK_EVENT_NAME, "RemoteEvent")
    decorationEvent = getOrCreateRemote(DECOR_EVENT_NAME, "RemoteEvent")
    shardEvent = getOrCreateRemote(SHARD_EVENT_NAME, "RemoteEvent")
    snapshotEvent = getOrCreateRemote(SNAPSHOT_EVENT_NAME, "RemoteEvent")
end

function WorldStreamServer.isEnabled()
    return WorldStreamServer._enabled
end

local function fireChunkEvent(message)
    if not chunkEvent then
        return
    end
    chunkEvent:FireAllClients(message)
end

local function fireDecorationEvent(message)
    if not decorationEvent then
        return
    end
    decorationEvent:FireAllClients(message)
end

local function fireShardEvent(message)
    if not shardEvent then
        return
    end
    shardEvent:FireAllClients(message)
end

function WorldStreamServer.sendSnapshot(player)
    if not WorldStreamServer._enabled or not snapshotEvent then
        return
    end

    local payload = {
        version = Protocol.Version,
        chunks = deepClone(chunkState),
        decorations = deepClone(decorationState),
        shards = deepClone(shardState),
    }

    snapshotEvent:FireClient(player, payload)
end

function WorldStreamServer.init()
    if WorldStreamServer._initialized then
        return
    end

    if not WorldStreamServer._enabled then
        WorldStreamServer._initialized = true
        return
    end

    ensureRemotes()

    Players.PlayerAdded:Connect(function(player)
        WorldStreamServer.sendSnapshot(player)
    end)

    WorldStreamServer._initialized = true
end

function WorldStreamServer.setChunkState(key, payload)
    if not WorldStreamServer._enabled then
        return
    end

    chunkState[key] = payload
    fireChunkEvent({
        version = Protocol.Version,
        action = "set",
        key = key,
        data = payload,
    })
end

function WorldStreamServer.removeChunk(key)
    if not WorldStreamServer._enabled then
        return
    end
    chunkState[key] = nil
    fireChunkEvent({
        version = Protocol.Version,
        action = "remove",
        key = key,
    })
end

function WorldStreamServer.resetChunks()
    if not WorldStreamServer._enabled then
        return
    end
    chunkState = {}
    fireChunkEvent({
        version = Protocol.Version,
        action = "reset",
    })
end

function WorldStreamServer.setDecorationState(key, payload)
    if not WorldStreamServer._enabled then
        return
    end

    decorationState[key] = payload
    fireDecorationEvent({
        version = Protocol.Version,
        action = "set",
        key = key,
        data = payload,
    })
end

function WorldStreamServer.removeDecorationState(key)
    if not WorldStreamServer._enabled then
        return
    end
    decorationState[key] = nil
    fireDecorationEvent({
        version = Protocol.Version,
        action = "remove",
        key = key,
    })
end

function WorldStreamServer.resetDecorations()
    if not WorldStreamServer._enabled then
        return
    end
    decorationState = {}
    fireDecorationEvent({
        version = Protocol.Version,
        action = "reset",
    })
end

local function shouldBroadcastShard(id)
    local now = os.clock()
    local last = lastShardBroadcast[id] or 0
    if now - last >= SHARD_UPDATE_INTERVAL then
        lastShardBroadcast[id] = now
        return true
    end
    return false
end

function WorldStreamServer.setShardState(id, payload)
    if not WorldStreamServer._enabled then
        return
    end

    shardState[id] = payload
    if shouldBroadcastShard(id) then
        fireShardEvent({
            version = Protocol.Version,
            action = "set",
            id = id,
            data = payload,
        })
    end
end

function WorldStreamServer.removeShard(id)
    if not WorldStreamServer._enabled then
        return
    end

    shardState[id] = nil
    lastShardBroadcast[id] = nil
    fireShardEvent({
        version = Protocol.Version,
        action = "remove",
        id = id,
    })
end

function WorldStreamServer.resetShards()
    if not WorldStreamServer._enabled then
        return
    end
    shardState = {}
    lastShardBroadcast = {}
    fireShardEvent({
        version = Protocol.Version,
        action = "reset",
    })
end

return WorldStreamServer

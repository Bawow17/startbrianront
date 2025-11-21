local WorldStreamProtocol = {
    Version = 1,
    RemoteFolderName = "WorldStreamRemotes",
    ChunkEventName = "ChunkStream",
    DecorationEventName = "DecorationStream",
    ShardEventName = "ShardStream",
    SnapshotEventName = "WorldStreamSnapshot",
    SnapshotRequestEventName = "RequestWorldStreamSnapshot",
    TemplateRootName = "ChunkTemplates",
    Constants = {
        ChunkSize = 128,
    },
}

return WorldStreamProtocol

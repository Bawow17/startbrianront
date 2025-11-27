local LightSystemConfig = {
    RemoteFolderName = "LightSystemRemotes",
    ReportEventName = "LightReport",
    BroadcastEventName = "LightBroadcast",

    -- Tuning knobs
    BaseMaxLight = 100, -- Hook: apply future upgrade multipliers to this base value.
    BaseDrainPerSecond = 0.7,
    RegenPerSecond = 33.33,
    ValidationInterval = 0.5,
    HealthDrainPercentPerSecondAtZero = 5, -- Percent of max health drained per second when light is empty.

    -- Lighting visuals
    FullBrightness = 0.3,
    LightRange = 45,
    ShadowsEnabled = true,

    -- World layout (mirrors ChunkSystem settings)
    ChunkSize = 128,
    WorldOrigin = Vector3.new(7500, 7500, 7500),
    ChunkHeightTolerance = 750,
    FadeDelaySeconds = 3,
    FadeStepsPerSecond = 10,
}

return LightSystemConfig

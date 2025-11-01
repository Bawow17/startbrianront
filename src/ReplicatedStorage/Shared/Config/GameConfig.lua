local GameConfig = {}

GameConfig.FixedUpdateRate = 30 -- ticks per second for deterministic simulation
GameConfig.MaxDeltaTime = 1 -- clamp runaway dt when the server stalls
GameConfig.LogHeartbeat = false -- enable for profiling during early bring-up

function GameConfig.getFixedTimeStep()
	return 1 / GameConfig.FixedUpdateRate
end

return GameConfig


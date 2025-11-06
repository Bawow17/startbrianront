local GameConfig = {}

GameConfig.FixedUpdateRate = 60 -- ticks per second for deterministic simulation
GameConfig.MaxDeltaTime = 1 -- clamp runaway dt when the server stalls
GameConfig.LogHeartbeat = false -- enable for profiling during early bring-up

GameConfig.Debug = {
	AutoSpawnBots = 0, -- number of simulated bots to spawn for profiling (0 disables)
	BotFireInterval = 1.5, -- seconds between debug projectile bursts
}

function GameConfig.getFixedTimeStep()
	return 1 / GameConfig.FixedUpdateRate
end

return GameConfig


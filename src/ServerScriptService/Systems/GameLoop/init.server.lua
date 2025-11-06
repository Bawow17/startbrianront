local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local GameLoopSignals = require(Shared.Signals.GameLoopSignals)
local systemsFolder = script.Parent
local TankSystem = require(systemsFolder:WaitForChild("TankSystem"))
local ProjectileSystem = require(systemsFolder:WaitForChild("ProjectileSystem"))

local accumulator = 0
local fixedTimeStep = GameConfig.getFixedTimeStep()
local lastLogged = os.clock()

local function clampDelta(deltaTime)
	local maxDelta = GameConfig.MaxDeltaTime or 0
	if maxDelta <= 0 then
		return deltaTime
	end
	return math.min(deltaTime, maxDelta)
end

local function updateFixedStep()
	fixedTimeStep = GameConfig.getFixedTimeStep()
end

local function onHeartbeat(deltaTime)
	deltaTime = clampDelta(deltaTime)
	GameLoopSignals._fireHeartbeat(deltaTime)
	accumulator += deltaTime
	while accumulator >= fixedTimeStep do
		accumulator -= fixedTimeStep
		GameLoopSignals._fireFixedStep(fixedTimeStep)
	end

	local refreshedStep = GameConfig.getFixedTimeStep()
	if refreshedStep ~= fixedTimeStep then
		fixedTimeStep = refreshedStep
	end

	if GameConfig.LogHeartbeat and os.clock() - lastLogged >= 5 then
		lastLogged = os.clock()
		local projectileCount = 0
		if typeof(ProjectileSystem.getActiveCount) == "function" then
			projectileCount = ProjectileSystem.getActiveCount()
		end
		local tankCount = #TankSystem.getActiveTanks()
		print(string.format("[GameLoop] dt=%.4f accumulator=%.4f tanks=%d projectiles=%d", deltaTime, accumulator, tankCount, projectileCount))
	end
end

updateFixedStep()

RunService.Heartbeat:Connect(onHeartbeat)

TankSystem.start()
ProjectileSystem.start()

local debugConfig = GameConfig.Debug or {}
if debugConfig.AutoSpawnBots and debugConfig.AutoSpawnBots > 0 then
	local debugTools = ServerStorage:FindFirstChild("DebugTools")
	if debugTools and debugTools:FindFirstChild("SpawnBots") then
		local success, harness = pcall(require, debugTools.SpawnBots)
		if success and harness then
			task.defer(function()
				harness.start(debugConfig.AutoSpawnBots)
			end)
		else
			warn("[GameLoop] Failed to load debug bot harness:", harness)
		end
	end
end


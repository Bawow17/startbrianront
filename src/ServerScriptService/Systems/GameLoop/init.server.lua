local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local GameLoopSignals = require(Shared.Signals.GameLoopSignals)
local systemsFolder = script.Parent.Parent
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
		print(string.format("[GameLoop] dt=%.4f accumulator=%.4f", deltaTime, accumulator))
	end
end

updateFixedStep()

RunService.Heartbeat:Connect(onHeartbeat)

TankSystem.start()
ProjectileSystem.start()


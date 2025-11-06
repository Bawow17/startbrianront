local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local systemsFolder = ServerScriptService:WaitForChild("Systems")
local TankSystem = require(systemsFolder:WaitForChild("TankSystem"))
local ProjectileSystem = require(systemsFolder:WaitForChild("ProjectileSystem"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local GameLoopSignals = require(Shared.Signals.GameLoopSignals)
local ProjectileConfig = require(Shared.Config.ProjectileConfig)

local DebugBots = {}
local connections = {}
local isRunning = false

local function randomOrbitRadius()
	return 35 + math.random() * 20
end

local function randomOrbitSpeed()
	return 0.5 + math.random() * 1.2
end

local function spawnBots(count)
	for index = 1, count do
		local record = TankSystem.spawnDebugBot(index, {
			position = Vector3.new(math.random(-40, 40), 2, math.random(-40, 40)),
			color = Color3.fromRGB(198, 255, 120),
		})

		DebugBots[#DebugBots + 1] = {
			key = record.key,
			angle = math.random() * math.pi * 2,
			radius = randomOrbitRadius(),
			speed = randomOrbitSpeed(),
			fireTimer = math.random(),
		}
	end
end

local function clearBots()
	for _, bot in ipairs(DebugBots) do
		TankSystem.removeTankByKey(bot.key)
	end
	table.clear(DebugBots)
end

local centerPosition = Vector3.new(0, 2, 0)

local function updateBot(bot, deltaTime)
	local tank = TankSystem.getTankByKey(bot.key)
	if not tank then
		return
	end

	bot.angle = (bot.angle + bot.speed * deltaTime) % (math.pi * 2)
	local desiredPos = centerPosition + Vector3.new(math.cos(bot.angle) * bot.radius, 0, math.sin(bot.angle) * bot.radius)
	local currentPos = tank.movement.Position
	local direction = (desiredPos - currentPos)
	local planar = Vector3.new(direction.X, 0, direction.Z)
	if planar.Magnitude < 1e-3 then
		planar = Vector3.new(math.cos(bot.angle), 0, math.sin(bot.angle))
	end
	local moveDir = planar.Unit

	TankSystem.applyInputByKey(bot.key, {
		Move = moveDir,
		AimDirection = moveDir,
	})

	bot.fireTimer += deltaTime
	local fireInterval = GameConfig.Debug.BotFireInterval
	if fireInterval > 0 and bot.fireTimer >= fireInterval then
		bot.fireTimer -= fireInterval
		local shotDirection = moveDir
		local origin = currentPos + shotDirection * 3
		ProjectileSystem.spawnProjectile(origin, shotDirection, ProjectileConfig.BaseSpeed, bot.key)
	end
end

local function onFixedStep(deltaTime)
	for _, bot in ipairs(DebugBots) do
		updateBot(bot, deltaTime)
	end
end

local DebugHarness = {}

function DebugHarness.start(count)
	if isRunning then
		return
	end

	local spawnCount = count or GameConfig.Debug.AutoSpawnBots or 0
	if spawnCount <= 0 then
		return
	end

	isRunning = true
	spawnBots(spawnCount)
	connections[#connections + 1] = GameLoopSignals.FixedStep:Connect(onFixedStep)
end

function DebugHarness.stop()
	if not isRunning then
		return
	end
	isRunning = false

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	clearBots()
end

return DebugHarness


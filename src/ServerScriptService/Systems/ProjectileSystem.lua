local ProjectileSystem = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameLoopSignals = require(Shared.Signals.GameLoopSignals)
local ProjectileConfig = require(Shared.Config.ProjectileConfig)

local prefabFolder = ServerStorage:FindFirstChild("Prefabs")
if not prefabFolder then
	prefabFolder = Instance.new("Folder")
	prefabFolder.Name = "Prefabs"
	prefabFolder.Parent = ServerStorage
end

local template = prefabFolder:FindFirstChild(ProjectileConfig.TemplateName)
if not template then
	template = Instance.new("Part")
	template.Name = ProjectileConfig.TemplateName
	template.Size = Vector3.new(1.2, 1.2, 1.2)
	template.Shape = Enum.PartType.Ball
	template.Anchored = true
	template.CanCollide = false
	template.Color = Color3.fromRGB(255, 62, 203)
	template.Material = Enum.Material.Neon
	template.Transparency = 0.15
	template.CastShadow = false
	template.Parent = prefabFolder
end

local projectilesFolder = workspace:FindFirstChild("BrainrotProjectiles")
if not projectilesFolder then
	projectilesFolder = Instance.new("Folder")
	projectilesFolder.Name = "BrainrotProjectiles"
	projectilesFolder.Parent = workspace
end

local activeProjectiles = {}
local freeProjectiles = {}
local isRunning = false
local fixedStepConnection

local function acquireProjectile()
	local projectile = table.remove(freeProjectiles)
	if projectile then
		projectile.Parent = projectilesFolder
		return projectile
	end

	local clone = template:Clone()
	clone.Parent = projectilesFolder
	return clone
end

local function recycleProjectile(entry)
	local instance = entry.instance
	instance.Parent = nil
	instance.CFrame = CFrame.new()
	instance.Anchored = true
	instance.AssemblyLinearVelocity = Vector3.zero
	freeProjectiles[#freeProjectiles + 1] = instance
end

local function simulateProjectiles(deltaTime)
	for index = #activeProjectiles, 1, -1 do
		local entry = activeProjectiles[index]
		entry.remainingLife -= deltaTime
		if entry.remainingLife <= 0 then
			recycleProjectile(entry)
			table.remove(activeProjectiles, index)
		else
			entry.position += entry.velocity * deltaTime
			entry.instance.CFrame = CFrame.new(entry.position)
		end
	end
end

function ProjectileSystem.spawnProjectile(origin, direction, speed, ownerId)
	local instance = acquireProjectile()
	local velocity = direction.Unit * (speed or ProjectileConfig.BaseSpeed)
	local entry = {
		instance = instance,
		position = origin,
		velocity = velocity,
		remainingLife = ProjectileConfig.BaseLifetime,
		ownerId = ownerId,
	}

	instance.CFrame = CFrame.new(origin)
	activeProjectiles[#activeProjectiles + 1] = entry
	return entry
end

function ProjectileSystem.getActiveCount()
	return #activeProjectiles
end

function ProjectileSystem.prewarm()
	local target = ProjectileConfig.PoolSize
	local current = #freeProjectiles
	if current >= target then
		return
	end
	for _ = current + 1, target do
		local instance = template:Clone()
		instance.Parent = nil
		freeProjectiles[#freeProjectiles + 1] = instance
	end
end

function ProjectileSystem.start()
	if isRunning then
		return
	end
	isRunning = true

	ProjectileSystem.prewarm()
	fixedStepConnection = GameLoopSignals.FixedStep:Connect(simulateProjectiles)
end

function ProjectileSystem.stop()
	if not isRunning then
		return
	end
	isRunning = false
	if fixedStepConnection then
		fixedStepConnection:Disconnect()
		fixedStepConnection = nil
	end
	for index = #activeProjectiles, 1, -1 do
		recycleProjectile(activeProjectiles[index])
		activeProjectiles[index] = nil
	end
end

return ProjectileSystem


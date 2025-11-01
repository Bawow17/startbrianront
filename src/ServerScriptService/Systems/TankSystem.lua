local TankSystem = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TankComponents = require(Shared.Components.TankComponents)
local GameLoopSignals = require(Shared.Signals.GameLoopSignals)

local tanksByPlayer = {}
local connections = {}
local isRunning = false

local TankFolder = workspace:FindFirstChild("BrainrotTanks")
if not TankFolder then
	TankFolder = Instance.new("Folder")
	TankFolder.Name = "BrainrotTanks"
	TankFolder.Parent = workspace
end

local function createShellForPlayer(player)
	local part = Instance.new("Part")
	part.Name = string.format("%s_Tank", player.Name)
	part.Size = Vector3.new(4, 1, 4)
	part.Anchored = true
	part.CanCollide = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = Color3.fromRGB(255, 181, 72)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = TankFolder
	return part
end

local function applyDrag(velocity, drag, deltaTime)
	local speed = velocity.Magnitude
	if speed <= 1e-3 then
		return Vector3.zero
	end
	local drop = math.min(speed, drag * deltaTime)
	return velocity * ((speed - drop) / speed)
end

local function flatten(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function updateFacing(tank)
	local input = tank.input
	local movement = tank.movement
	local aim = input.AimDirection
	if aim.Magnitude > 0.001 then
		movement.Facing = math.atan2(aim.X, aim.Z)
		return
	end

	local velocity = movement.Velocity
	local planarSpeed = Vector3.new(velocity.X, 0, velocity.Z)
	if planarSpeed.Magnitude > 0.001 then
		movement.Facing = math.atan2(planarSpeed.X, planarSpeed.Z)
	end
end

local function updateMovement(tank, deltaTime)
	local movement = tank.movement
	local input = tank.input
	local velocity = flatten(movement.Velocity)
	local moveDir = flatten(input.Move)

	if moveDir.Magnitude > 1 then
		moveDir = moveDir.Unit
	end

	if moveDir.Magnitude > 1e-3 then
		local desiredVelocity = moveDir * movement.MoveSpeed
		local deltaVelocity = desiredVelocity - velocity
		local maxStep = movement.Acceleration * deltaTime
		local deltaMag = deltaVelocity.Magnitude
		if deltaMag > maxStep then
			deltaVelocity = deltaVelocity.Unit * maxStep
		end
		velocity += deltaVelocity
	else
		velocity = applyDrag(velocity, movement.Drag, deltaTime)
	end

	movement.Velocity = Vector3.new(velocity.X, 0, velocity.Z)
	movement.Position += movement.Velocity * deltaTime

	updateFacing(tank)

	if tank.model then
		tank.model.CFrame = CFrame.new(movement.Position) * CFrame.Angles(0, movement.Facing, 0)
	end
end

local function onFixedStep(deltaTime)
	for _, tank in pairs(tanksByPlayer) do
		updateMovement(tank, deltaTime)
	end
end

local function onPlayerRemoving(player)
	local tank = tanksByPlayer[player]
	if not tank then
		return
	end
	if tank.model then
		tank.model:Destroy()
	end
	tanksByPlayer[player] = nil
end

local function onPlayerAdded(player)
	local shell = createShellForPlayer(player)
	local movement = TankComponents.createMovementComponent({
		Position = Vector3.new(math.random(-32, 32), 2, math.random(-32, 32)),
	})
	local health = TankComponents.createHealthComponent()
	local input = TankComponents.createInputState()

	shell.CFrame = CFrame.new(movement.Position)

	tanksByPlayer[player] = {
		player = player,
		model = shell,
		movement = movement,
		health = health,
		input = input,
	}
end

function TankSystem.applyInput(player, message)
	local tank = tanksByPlayer[player]
	if not tank then
		return
	end

	local move = message.Move
	if move then
		move = Vector3.new(move.X or 0, 0, move.Z or 0)
		if move.Magnitude > 1 then
			move = move.Unit
		end
		tank.input.Move = move
	end

	if message.AimDirection then
		local aim = Vector3.new(message.AimDirection.X or 0, 0, message.AimDirection.Z or 0)
		if aim.Magnitude > 0 then
			tank.input.AimDirection = aim.Unit
		end
	end

	if message.IsFiring ~= nil then
		tank.input.IsFiring = message.IsFiring and true or false
	end
end

function TankSystem.start()
	if isRunning then
		return
	end
	isRunning = true

	connections[#connections + 1] = Players.PlayerAdded:Connect(onPlayerAdded)
	connections[#connections + 1] = Players.PlayerRemoving:Connect(onPlayerRemoving)
	connections[#connections + 1] = GameLoopSignals.FixedStep:Connect(onFixedStep)

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

function TankSystem.stop()
	if not isRunning then
		return
	end
	isRunning = false

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	for player, tank in pairs(tanksByPlayer) do
		if tank.model then
			tank.model:Destroy()
		end
		tanksByPlayer[player] = nil
	end
end

return TankSystem


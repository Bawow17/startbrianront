local TankSystem = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")

local TankComponents = require(Shared.Components.TankComponents)
local GameLoopSignals = require(Shared.Signals.GameLoopSignals)
local InputEvents = require(RemotesFolder.InputEvents)
local TankModelLoader = require(Shared.TankModelLoader)

local tanksByKey = {}
local activeTanks = {}
local connections = {}
local isRunning = false

local TANK_FOLDER_NAME = "BrainrotTanks"
local TankFolder = workspace:FindFirstChild(TANK_FOLDER_NAME)
if not TankFolder then
	TankFolder = Instance.new("Folder")
	TankFolder.Name = TANK_FOLDER_NAME
	TankFolder.Parent = workspace
end

local function createShell(name, color)
	local part = Instance.new("Part")
	part.Name = string.format("%s_Tank", name)
	part.Size = Vector3.new(6, 6, 6)
	part.Anchored = true
	part.CanCollide = false
	part.Shape = Enum.PartType.Ball
	part.Transparency = 0.5
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color or Color3.fromRGB(255, 181, 72)
	part.Material = Enum.Material.ForceField
	return part
end

local function spawnTankRecord(key, options)
	options = options or {}
	local displayName = options.displayName
	if not displayName and typeof(key) == "Instance" and key:IsA("Player") then
		displayName = key.DisplayName
	end
	displayName = displayName or tostring(key)
	local tankType = options.tankType or "ToyTank"
	local spawnPosition = options.position or Vector3.new(math.random(-32, 32), 2, math.random(-32, 32))
	local movement = TankComponents.createMovementComponent({
		Position = spawnPosition,
	})
	local health = TankComponents.createHealthComponent(options.health)
	local input = TankComponents.createInputState()

	local tankModelData = nil
	local model = nil
	local playerOffset = Vector3.new(0, 5, 0)
	local barrels = {{Position = Vector3.new(0, 0, -3), Rotation = CFrame.new()}}
	local originalModelRotation = CFrame.new().Rotation -- Default rotation if no model

	if options.isBot then
		local shell = createShell(displayName, options.color)
		shell.Parent = TankFolder
		model = shell
	else
		tankModelData = TankModelLoader.loadTankModel(tankType)
		if tankModelData then
			model = tankModelData.Model
			-- Use player.Name for consistency with client lookup
			local playerName = typeof(key) == "Instance" and key:IsA("Player") and key.Name or displayName
			model.Name = string.format("%s_Tank", playerName)
			playerOffset = tankModelData.PlayerOffset
			barrels = tankModelData.Barrels
			-- Store original rotation from model template (before any positioning)
			originalModelRotation = tankModelData.OriginalRotation or CFrame.new().Rotation
			-- For players, parent to character when it's added (handled in attachCharacter)
			-- For now, parent to TankFolder temporarily
			model.Parent = TankFolder
		else
			warn("[TankSystem] Failed to load tank model:", tankType, "- player will not have a tank model")
			-- No fallback sphere for players - only bots get spheres
		end
	end

	-- Calculate spawn position for player root (PlayerPosition should align with movement.Position)
	-- The spawnCFrame is where the player root should be positioned
	-- This is simply the movement.Position since PlayerPosition should align with player root
	local spawnCFrame = CFrame.new(movement.Position)
	
	-- Position tank model in TankFolder (will be moved to character later)
	-- Calculate tank position so PlayerPosition part aligns with spawn position
	-- PlayerPosition world = PrimaryPart.CFrame * CFrame.new(playerOffset)
	-- We want PlayerPosition world = movement.Position
	-- So: PrimaryPart.CFrame = CFrame.new(movement.Position) * CFrame.new(-playerOffset)
	local playerOffsetCF = CFrame.new(playerOffset)
	local initialCFrame = CFrame.new(movement.Position) * playerOffsetCF:Inverse()
	
	if model then
		if model:IsA("Model") then
			local primary = model.PrimaryPart
			if primary then
				model:PivotTo(initialCFrame)
			else
				local fallback = model:FindFirstChildOfClass("BasePart")
				if fallback then
					model.PrimaryPart = fallback
					model:PivotTo(initialCFrame)
				end
			end
		else
			model.CFrame = initialCFrame
		end
	end

	local record = {
		key = key,
		player = options.player,
		model = model,
		movement = movement,
		health = health,
		input = input,
		isBot = options.isBot or false,
		connections = {},
		spawnCFrame = spawnCFrame,
		animationId = options.animationId,
		playerOffset = playerOffset,
		barrels = barrels,
		tankType = tankType,
		originalModelRotation = originalModelRotation, -- Store original rotation from model template
	}

	if model and model:IsA("Part") and options.color then
		model.Color = options.color
	end

	tanksByKey[key] = record

	if record.player then
		record.player:SetAttribute("TankAnimationId", record.animationId)
		record.player:SetAttribute("TankPlayerOffset", string.format("%f,%f,%f", playerOffset.X, playerOffset.Y, playerOffset.Z))
	end
	activeTanks[#activeTanks + 1] = record

	return record
end

local function destroyTank(record)
	if not record then
		return
	end
    if record.model then
		record.model:Destroy()
		record.model = nil
	end
	if record.characterRoot then
		record.characterRoot = nil
	end
	if record.character then
		record.character = nil
	end
	if record.humanoid then
		record.humanoid.AutoRotate = true
		record.humanoid = nil
	end
    if record.connections then
		for _, connection in ipairs(record.connections) do
			connection:Disconnect()
		end
		table.clear(record.connections)
	end
    if record.player then
        record.player:SetAttribute("TankAnimationId", nil)
    end
	tanksByKey[record.key] = nil
	for index = #activeTanks, 1, -1 do
		if activeTanks[index] == record then
			table.remove(activeTanks, index)
			break
		end
	end
end

local function syncModelToMovement(tank)
	local movement = tank.movement
	local cf = CFrame.new(movement.Position) * CFrame.Angles(0, movement.Facing, 0)
	if tank.model then
		if tank.model:IsA("Model") then
			local primary = tank.model.PrimaryPart
			if primary then
				tank.model:PivotTo(cf)
			else
				local fallback = tank.model:FindFirstChildOfClass("BasePart")
				if fallback then
					tank.model.PrimaryPart = fallback
					tank.model:PivotTo(cf)
				end
			end
		else
			tank.model.CFrame = cf
		end
	end
	return cf
end

local function updateTankModelPosition(tank, rootPos)
	-- Update tank model position to maintain structure relative to root
	-- Calculate where tank center should be: root position - PlayerPosition offset
	if not tank.model or not tank.model:IsA("Model") then
		return
	end
	
	local primary = tank.model.PrimaryPart
	if not primary or not tank.partOffsets or not tank.playerPositionOffset then
		return
	end
	
	local playerPositionOffset = tank.playerPositionOffset
	-- Get tank facing direction from movement state
	local movement = tank.movement
	local facing = movement.Facing or 0
	
	-- Get the model's original rotation from Studio (stored when model was loaded)
	-- This preserves how the model is oriented in Studio
	local originalRotation = tank.originalModelRotation or CFrame.new().Rotation
	-- Extract just the Y rotation from original rotation
	local _, originalY, _ = originalRotation:ToEulerAnglesXYZ()
	
	-- Calculate tank rotation: original model rotation + facing direction
	-- The facing is relative to world space, so we add it to the original rotation
	local tankRotation = CFrame.Angles(0, originalY + facing, 0)
	
	-- Rotate the offset by current facing direction to get world-space offset
	-- The offset is in object space (relative to PrimaryPart's initial rotation), so we need to rotate it
	local rotatedOffset = tankRotation * CFrame.new(playerPositionOffset)
	local worldOffset = rotatedOffset.Position
	
	-- Calculate tank center position: root - rotated offset, but Y=0
	-- PlayerPosition should align with root, so PrimaryPart = root - rotated offset
	local tankCenterPos = rootPos - worldOffset
	-- Account for PrimaryPart's pivot being at its center
	-- If pivot is at center, we need to offset by half the Y size to put bottom at Y=0
	local primarySizeY = primary.Size.Y
	local pivotOffsetY = primarySizeY / 2
	-- Set PrimaryPart pivot Y position so that bottom of PrimaryPart is at Y=0
	tankCenterPos = Vector3.new(tankCenterPos.X, pivotOffsetY, tankCenterPos.Z)
	
	-- Update PrimaryPart position and rotation to maintain Y=0 and match player facing
	local tankCenterCF = CFrame.new(tankCenterPos) * tankRotation
	primary.CFrame = tankCenterCF
	
	-- Update all other parts' positions relative to PrimaryPart to maintain model structure
	for part, offset in pairs(tank.partOffsets) do
		if part ~= primary then
			local partCF = primary.CFrame * offset
			part.CFrame = partCF
		end
	end
end

local function attachCharacter(record, character)
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = false
		record.humanoid = humanoid
	end

    local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not root then
		warn("[TankSystem] Character missing root part for", record.key)
		return
	end

	-- Initial positioning will be done after calculating offset and positioning tank
	-- For now, just set initial position from spawn
	-- Note: Client will take over root control via client-side prediction
	root.CFrame = record.spawnCFrame or CFrame.new(record.movement.Position)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.Anchored = true -- Client will also anchor it, but set here for initial state
	record.characterRoot = root
	record.character = character
	
	-- Initialize movement position from root position
	record.movement.Position = root.CFrame.Position
	
	-- Now move and position the tank model relative to the player root
	if record.model and not record.isBot and record.model.Parent == TankFolder then
		-- Step 1: Calculate PlayerPosition offset from tank center BEFORE moving tank
		local playerPosPart = nil
		local playerPositionOffset = nil -- Offset from tank center (PrimaryPart) to PlayerPosition
		
		if record.model:IsA("Model") then
			local primary = record.model.PrimaryPart
			if not primary then
				local fallback = record.model:FindFirstChildOfClass("BasePart")
				if fallback then
					record.model.PrimaryPart = fallback
					primary = fallback
				end
			end
			
			if primary then
				-- Find PlayerPosition part while tank is still in TankFolder
				playerPosPart = record.model:FindFirstChild("PlayerPosition")
				if playerPosPart and playerPosPart:IsA("BasePart") then
					-- Calculate offset from PrimaryPart (tank center) to PlayerPosition in object space
					local primaryToPlayerPos = primary.CFrame:ToObjectSpace(playerPosPart.CFrame)
					playerPositionOffset = primaryToPlayerPos.Position
					
					-- Store tank center rotation for later use
					record.tankCenterRotation = primary.CFrame.Rotation
				end
			end
		end
		
		-- Step 3: Move tank to character
		record.model.Parent = character
		
		-- Step 4: Position tank center correctly and adjust player root
		-- Tank center should be at Y=0 (ground level)
		-- PlayerPosition should align with player root
		-- If PlayerPosition is offsetY above tank center, then:
		--   - Tank center at (X, 0, Z)
		--   - Player root at tank center + offset = (X, offsetY, Z)
		--   - This ensures PlayerPosition aligns with player root
		if record.model:IsA("Model") then
			local primary = record.model.PrimaryPart
			if primary and playerPosPart and playerPositionOffset then
				-- Get spawn position X/Z from player root (Y will be adjusted)
				local spawnPos = root.CFrame.Position
				
				-- Calculate tank center position at ground level (Y=0)
				-- Use spawn X/Z, but set Y=0
				-- Account for PrimaryPart's pivot being at its center
				-- If pivot is at center, we need to offset by half the Y size to put bottom at Y=0
				local primarySizeY = primary.Size.Y
				local pivotOffsetY = primarySizeY / 2
				-- Set PrimaryPart pivot Y position so that bottom of PrimaryPart is at Y=0
				local tankCenterTargetPos = Vector3.new(spawnPos.X, pivotOffsetY, spawnPos.Z)
				
				-- Position tank center at calculated position (Y=0)
				-- Use the tank center's rotation that we stored before moving
				local tankCenterRotation = record.tankCenterRotation or primary.CFrame.Rotation
				local tankCenterCF = CFrame.new(tankCenterTargetPos) * tankCenterRotation
				
				-- Store relative positions of all parts to PrimaryPart BEFORE moving
				-- This allows us to maintain model structure when updating positions
				local partOffsets = {}
				for _, descendant in ipairs(record.model:GetDescendants()) do
					if descendant:IsA("BasePart") then
						local offset = primary.CFrame:ToObjectSpace(descendant.CFrame)
						partOffsets[descendant] = offset
					end
				end
				record.partOffsets = partOffsets
				record.playerPositionOffset = playerPositionOffset
				
				-- Position tank center at Y=0
				-- Anchor the PrimaryPart temporarily to prevent physics interference
				local _wasAnchored = primary.Anchored
				primary.Anchored = true
				
				-- Set PrimaryPart CFrame directly
				primary.CFrame = tankCenterCF
				
				-- Update all other parts' positions relative to PrimaryPart to maintain model structure
				for part, offset in pairs(partOffsets) do
					if part ~= primary then
						local partCF = primary.CFrame * offset
						part.CFrame = partCF
						part.Anchored = true
					end
				end
				
				-- Keep PrimaryPart anchored to maintain Y=0
				primary.Anchored = true
				
				-- Position player root relative to tank center
				-- If PlayerPosition IS PrimaryPart (offset 0,0,0), position root at same location
				-- Otherwise, position root at tank center + offset
				local adjustedRootPos
				if playerPositionOffset.Magnitude < 0.001 then
					-- PlayerPosition IS PrimaryPart - position root at same location as tank center
					adjustedRootPos = tankCenterTargetPos
				else
					-- PlayerPosition is offset from PrimaryPart
					adjustedRootPos = tankCenterTargetPos + playerPositionOffset
				end
				
				root.CFrame = CFrame.new(adjustedRootPos)
				
				-- Update the record's character root position
				record.characterRoot = root
				
				-- Initialize movement position from root position
				record.movement.Position = root.CFrame.Position
				
				-- No weld constraint - server handles all positioning manually
				-- Root is anchored and server controls its position
				root.Anchored = true
				
				-- Update tank model position immediately to ensure it's positioned correctly
				updateTankModelPosition(record, root.CFrame.Position)
				
				-- Anchor all tank parts to keep them together
				-- Server will update all parts' positions every frame to maintain model structure
				primary.Anchored = true
				
				-- Anchor all other tank parts to prevent them from falling
				-- We'll update their positions relative to root every frame
				for _, descendant in ipairs(record.model:GetDescendants()) do
					if descendant:IsA("BasePart") then
						descendant.CanTouch = false
						descendant.CanCollide = false
						-- Anchor all parts to keep them together
						descendant.Anchored = true
					end
				end
				
				-- Server will handle PlayerPosition alignment in update loop
			elseif primary then
				-- Fallback: position PrimaryPart relative to root if PlayerPosition part not found
				local playerOffset = record.playerOffset or Vector3.new(0, 0, 0)
				local rootPos = root.CFrame.Position
				local tankCenterPos = rootPos - playerOffset
				tankCenterPos = Vector3.new(tankCenterPos.X, 0, tankCenterPos.Z)
				local tankCenterCF = CFrame.new(tankCenterPos) * primary.CFrame.Rotation
				primary.CFrame = tankCenterCF
				primary.Anchored = true
				
				warn("[TankSystem] WARNING: PlayerPosition part not found, using PrimaryPart positioning")
			end
		end
	end
end

local function bindCharacter(record)
	if record.isBot or not record.player then
		return
	end

	local player = record.player
	local function onCharacterAdded(character)
		task.defer(function()
			attachCharacter(record, character)
		end)
	end

	record.connections[#record.connections + 1] = player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end
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

local function simulateTankPhysics(tank, deltaTime)
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
end

local function updateMovement(tank, deltaTime)
	local movement = tank.movement
	if tank.isBot then
		simulateTankPhysics(tank, deltaTime)
		updateFacing(tank)
		local cf = syncModelToMovement(tank)
		if tank.characterRoot then
			tank.characterRoot:PivotTo(cf)
			tank.characterRoot.AssemblyLinearVelocity = movement.Velocity
		end
	else
		-- Server is authoritative for character movement
		-- Apply Diep.io-style acceleration/drag physics server-side
		simulateTankPhysics(tank, deltaTime)
		updateFacing(tank)
		
		-- Server simulates physics for validation but does NOT update root or tank model directly
		-- Client handles all visual updates via client-side prediction for local player
		-- For other players: They will be updated by their own clients
		-- Server only simulates physics and sends state updates - no visual updates
		-- This prevents conflicts between server and client updates
	end
end

local function applyInputPayload(tank, message)
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

local function applyStatePayload(tank, state)
	-- Server is authoritative - don't apply client state directly
	-- State payload is only used for initial positioning or reconciliation
	-- Movement is calculated server-side from input
	if tank.isBot then
		-- Bots can use state payload
		local movement = tank.movement
		local statePosition = state.Position
		if typeof(statePosition) == "Vector3" then
			local position = statePosition
			movement.Position = Vector3.new(position.X, position.Y, position.Z)
		end
		local stateVelocity = state.Velocity
		if typeof(stateVelocity) == "Vector3" then
			local velocity = stateVelocity
			movement.Velocity = Vector3.new(velocity.X, 0, velocity.Z)
		end
		if typeof(state.Facing) == "number" then
			movement.Facing = state.Facing
		end
		syncModelToMovement(tank)
		if tank.characterRoot then
			tank.characterRoot.AssemblyLinearVelocity = Vector3.new(movement.Velocity.X, tank.characterRoot.AssemblyLinearVelocity.Y, movement.Velocity.Z)
		end
	end
	-- For players, server calculates movement from input - ignore state payload
end

local function onFixedStep(deltaTime)
	for index = 1, #activeTanks do
		updateMovement(activeTanks[index], deltaTime)
	end
end

local function onPlayerRemoving(player)
	destroyTank(tanksByKey[player])
end

local function onPlayerAdded(player)
	local record = spawnTankRecord(player, {
		player = player,
	})
	bindCharacter(record)
end

function TankSystem.applyInput(player, message)
	local tank = tanksByKey[player]
	if not tank then
		return
	end
	applyInputPayload(tank, message)
	if message.State then
		applyStatePayload(tank, message.State)
	end
end

function TankSystem.applyInputByKey(key, message)
	local tank = tanksByKey[key]
	if not tank then
		return
	end
	applyInputPayload(tank, message)
end

function TankSystem.spawnDebugBot(id, options)
	options = options or {}
	local key = string.format("BOT_%s", id)
	if tanksByKey[key] then
		return tanksByKey[key]
	end
	options.isBot = true
	options.displayName = options.displayName or key
	options.color = options.color or Color3.fromRGB(77, 201, 255)
	return spawnTankRecord(key, options)
end

function TankSystem.getActiveTanks()
	return activeTanks
end

function TankSystem.getTankByKey(key)
	return tanksByKey[key]
end

local function sendStateUpdates()
	-- Broadcast position/velocity/facing updates for all players at 60fps
	local updates = {}
	for _, tank in ipairs(activeTanks) do
		if tank.player and tank.movement then
			table.insert(updates, {
				PlayerId = tank.player.UserId,
				Position = tank.movement.Position,
				Velocity = tank.movement.Velocity,
				Facing = tank.movement.Facing or 0,
			})
		end
	end
	
	if #updates > 0 then
		InputEvents.TankStateUpdate:FireAllClients(updates)
	end
end

function TankSystem.start()
	if isRunning then
		return
	end
	isRunning = true

	connections[#connections + 1] = Players.PlayerAdded:Connect(onPlayerAdded)
	connections[#connections + 1] = Players.PlayerRemoving:Connect(onPlayerRemoving)
	connections[#connections + 1] = GameLoopSignals.FixedStep:Connect(function(deltaTime)
		onFixedStep(deltaTime)
		-- Send state updates after each fixed step (60fps)
		sendStateUpdates()
	end)
	connections[#connections + 1] = InputEvents.PlayerInput.OnServerEvent:Connect(function(player, payload)
		if typeof(payload) ~= "table" then
			return
		end
		TankSystem.applyInput(player, payload)
	end)

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

	for index = #activeTanks, 1, -1 do
		destroyTank(activeTanks[index])
	end
	table.clear(tanksByKey)
end

function TankSystem.removeTankByKey(key)
	destroyTank(tanksByKey[key])
end

return TankSystem


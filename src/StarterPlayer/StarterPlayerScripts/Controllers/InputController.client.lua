local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_SEND_INTERVAL = 1 / 15
local MAX_DELTA = 0.05

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remotes = require(remotesFolder:WaitForChild("InputEvents"))
local playerInputRemote = remotes.PlayerInput
local tankStateUpdateRemote = remotes.TankStateUpdate

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TankComponents = require(Shared.Components.TankComponents)
local movementDefaults = TankComponents.createMovementComponent()

local tankFolder = workspace:WaitForChild("BrainrotTanks")
local currentTank
local localTankVisual
local humanoid
local rootPart
local position
local velocity = Vector3.zero
local facing = 0
local baseHeight
local currentMoveDir = Vector3.zero
local currentAimDir = Vector3.new(0, 0, -1)
local shiftLocked = false

-- Client-side prediction state
local localTankPartOffsets = {} -- Store part offsets for local tank model
local localTankPlayerPositionOffset = nil -- Store PlayerPosition offset for local tank
local localTankOriginalRotation = CFrame.new().Rotation -- Store original rotation from model
local serverPosition = nil -- Server's authoritative position for reconciliation
local serverVelocity = Vector3.zero
local serverFacing = 0

local PLAYER_OFFSET = Vector3.new(0, 5, 0)
local PLAYER_OFFSET_CF = CFrame.new(PLAYER_OFFSET)

local function parsePlayerOffset(offsetString)
	if not offsetString or offsetString == "" then
		return PLAYER_OFFSET
	end
	local parts = {}
	for part in offsetString:gmatch("[^,]+") do
		table.insert(parts, tonumber(part))
	end
	if #parts == 3 then
		return Vector3.new(parts[1], parts[2], parts[3])
	end
	return PLAYER_OFFSET
end

local function getPlayerOffsetFromAttribute()
	local offsetString = player:GetAttribute("TankPlayerOffset")
	return parsePlayerOffset(offsetString)
end

local function applyShiftLock(enabled)
	shiftLocked = enabled
	if shiftLocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

local function onMouseBehaviorChanged()
	local current = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	shiftLocked = current
	UserInputService.MouseIconEnabled = not current
end

local moveBindings = {
	[Enum.KeyCode.W] = Vector3.new(0, 0, -1),
	[Enum.KeyCode.S] = Vector3.new(0, 0, 1),
	[Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
	[Enum.KeyCode.D] = Vector3.new(1, 0, 0),
	[Enum.KeyCode.Up] = Vector3.new(0, 0, -1),
	[Enum.KeyCode.Down] = Vector3.new(0, 0, 1),
	[Enum.KeyCode.Left] = Vector3.new(-1, 0, 0),
	[Enum.KeyCode.Right] = Vector3.new(1, 0, 0),
}

local moveState = {}
local isFiring = false
local sendAccumulator = 0
local lastPayload = nil
local EPSILON = 1e-4

local TANK_VISUAL_OFFSET = Vector3.new(0, 5, 0)

local DEFAULT_TANK_ANIMATION_ID = nil
local currentAnimationTrack
local currentAnimationId
local playerAttributeConnection
local characterAttributeConnection

local function cleanupLocalVisual()
	if currentTank then
		if currentTank:IsA("Model") then
			for _, part in ipairs(currentTank:GetDescendants()) do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = 0
				end
			end
		else
			currentTank.LocalTransparencyModifier = 0
		end
	end
	if localTankVisual then
		localTankVisual:Destroy()
		localTankVisual = nil
	end
end

local function updateLocalTankModelPosition(rootPos)
	-- Update tank model position to maintain structure relative to root
	-- Similar to server's updateTankModelPosition function
	if not currentTank or not currentTank:IsA("Model") then
		return
	end
	
	local primary = currentTank.PrimaryPart
	if not primary or not localTankPartOffsets or not localTankPlayerPositionOffset then
		return
	end
	
	local playerPositionOffset = localTankPlayerPositionOffset
	-- Get tank facing direction from client prediction
	-- Extract Y rotation from original rotation
	local _, originalY, _ = localTankOriginalRotation:ToEulerAnglesXYZ()
	local tankRotation = CFrame.Angles(0, originalY + facing, 0)
	
	-- Rotate the offset by current facing direction to get world-space offset
	local rotatedOffset = tankRotation * CFrame.new(playerPositionOffset)
	local worldOffset = rotatedOffset.Position
	
	-- Calculate tank center position: root - rotated offset, but Y=0
	local tankCenterPos = rootPos - worldOffset
	-- Account for PrimaryPart's pivot being at its center
	local primarySizeY = primary.Size.Y
	local pivotOffsetY = primarySizeY / 2
	tankCenterPos = Vector3.new(tankCenterPos.X, pivotOffsetY, tankCenterPos.Z)
	
	-- Update PrimaryPart position and rotation
	local tankCenterCF = CFrame.new(tankCenterPos) * tankRotation
	primary.CFrame = tankCenterCF
	
	-- Update all other parts' positions relative to PrimaryPart
	for part, offset in pairs(localTankPartOffsets) do
		if part ~= primary then
			local partCF = primary.CFrame * offset
			part.CFrame = partCF
		end
	end
end

local function createLocalTankVisual()
	if not rootPart then
		return
	end

	-- Store tank model offsets when creating visual
	if currentTank and currentTank:IsA("Model") then
		local primary = currentTank.PrimaryPart
		if primary then
			-- Store original rotation
			localTankOriginalRotation = primary.CFrame.Rotation
			
			-- Find PlayerPosition part and calculate offset
			local playerPosPart = currentTank:FindFirstChild("PlayerPosition")
			if playerPosPart and playerPosPart:IsA("BasePart") then
				local primaryToPlayerPos = primary.CFrame:ToObjectSpace(playerPosPart.CFrame)
				localTankPlayerPositionOffset = primaryToPlayerPos.Position
			end
			
			-- Store relative positions of all parts to PrimaryPart
			localTankPartOffsets = {}
			for _, descendant in ipairs(currentTank:GetDescendants()) do
				if descendant:IsA("BasePart") then
					local offset = primary.CFrame:ToObjectSpace(descendant.CFrame)
					localTankPartOffsets[descendant] = offset
				end
			end
		end
	end

	if currentTank then
		if currentTank:IsA("Model") then
			for _, part in ipairs(currentTank:GetDescendants()) do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = 1
				end
			end
		else
			currentTank.LocalTransparencyModifier = 1
		end
	end

	-- Hide server model from local player using LocalTransparencyModifier
	-- The server model is now a child of the player's character, so we just need to hide it
	-- and the tank will naturally follow the character
	if currentTank and currentTank:IsA("Model") then
		for _, part in ipairs(currentTank:GetDescendants()) do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = 1
			end
		end
	else
		-- No tank model available - don't create fallback sphere
		-- The server model should always exist for players
		warn("[InputController] No tank model found for local player")
	end
end

local function stopCurrentAnimation()
	if currentAnimationTrack then
		currentAnimationTrack:Stop(0.1)
		currentAnimationTrack:Destroy()
		currentAnimationTrack = nil
	end
end

local function normalizeAnimationId(animationId)
	if animationId == nil or animationId == "" then
		return nil
	end
	if typeof(animationId) == "number" then
		return "rbxassetid://" .. animationId
	elseif typeof(animationId) == "string" then
		if animationId:find("rbxassetid://") then
			return animationId
		end
		return "rbxassetid://" .. animationId
	end
	return nil
end

local function applyTankAnimation(animationId)
	if not humanoid then
		return
	end
	local normalized = normalizeAnimationId(animationId) or normalizeAnimationId(DEFAULT_TANK_ANIMATION_ID)
	if normalized == currentAnimationId then
		return
	end
	stopCurrentAnimation()
	currentAnimationId = normalized
	if not normalized then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local animation = Instance.new("Animation")
	animation.AnimationId = normalized
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0)
	track.TimePosition = 0
	track:AdjustSpeed(0)
	currentAnimationTrack = track
end

local function updateTankAnimationFromAttributes()
	local animationId = DEFAULT_TANK_ANIMATION_ID
	if player:GetAttribute("TankAnimationId") ~= nil then
		animationId = player:GetAttribute("TankAnimationId")
	end
	if humanoid and humanoid.Parent then
		local characterAnimation = humanoid.Parent:GetAttribute("TankAnimationId")
		if characterAnimation ~= nil then
			animationId = characterAnimation
		end
	end
	applyTankAnimation(animationId)
end

local function updateTankReference()
	local desiredName = string.format("%s_Tank", player.Name)
	-- Look for tank in player's character first, then fallback to BrainrotTanks folder
	local candidate = nil
	if player.Character then
		candidate = player.Character:FindFirstChild(desiredName)
	end
	if not candidate then
		candidate = tankFolder:FindFirstChild(desiredName)
	end
	
	if candidate ~= currentTank then
		cleanupLocalVisual()
		currentTank = candidate
		if currentTank then
			createLocalTankVisual()
			updateTankAnimationFromAttributes()
		end
	end
end

local function waitForTankModel()
	local desiredName = string.format("%s_Tank", player.Name)
	
	-- Check if already exists
	local tank = nil
	if player.Character then
		tank = player.Character:FindFirstChild(desiredName)
	end
	if not tank then
		tank = tankFolder:FindFirstChild(desiredName)
	end
	
	if tank then
		updateTankReference()
		return
	end
	
	-- Wait for tank model to be created in character
	local characterConnection
	local folderConnection
	
	local function cleanupConnections()
		if characterConnection then
			characterConnection:Disconnect()
			characterConnection = nil
		end
		if folderConnection then
			folderConnection:Disconnect()
			folderConnection = nil
		end
	end
	
	local function checkForTank(child)
		if child.Name == desiredName then
			cleanupConnections()
			updateTankReference()
		end
	end
	
	-- Listen for character added
	if player.Character then
		characterConnection = player.Character.ChildAdded:Connect(checkForTank)
	end
	
	-- Also listen to BrainrotTanks folder as fallback
	folderConnection = tankFolder.ChildAdded:Connect(checkForTank)
	
	-- Also check periodically in case it was already created
	task.spawn(function()
		for i = 1, 10 do
			task.wait(0.1)
			local found = nil
			if player.Character then
				found = player.Character:FindFirstChild(desiredName)
			end
			if not found then
				found = tankFolder:FindFirstChild(desiredName)
			end
			if found then
				cleanupConnections()
				updateTankReference()
				return
			end
		end
		-- If still not found after 1 second, warn
		local stillNotFound = nil
		if player.Character then
			stillNotFound = player.Character:FindFirstChild(desiredName)
		end
		if not stillNotFound then
			stillNotFound = tankFolder:FindFirstChild(desiredName)
		end
		if not stillNotFound then
			warn("[InputController] Tank model not found after waiting:", desiredName)
		end
		cleanupConnections()
	end)
end


local function onCharacterAdded(character)
	humanoid = character:FindFirstChildOfClass("Humanoid")
	rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart

	if humanoid then
		humanoid.AutoRotate = false
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		for _, track in ipairs(humanoid:GetPlayingAnimationTracks()) do
			track:Stop(0)
		end
	end

	local animateScript = character:FindFirstChild("Animate")
	if animateScript then
		animateScript.Disabled = true
	end

	local camera = workspace.CurrentCamera
	if camera and humanoid then
		camera.CameraSubject = humanoid
		camera.CameraType = Enum.CameraType.Custom
	end

	applyShiftLock(false)

	if rootPart then
		-- Client-side prediction: Client will update root part position
		-- Server validates and sends corrections when needed
		rootPart.CanTouch = false
		rootPart.CanCollide = false
		rootPart.Anchored = true -- Anchor for client-side control
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.CanTouch = false
			end
		end
		-- Initialize position tracking for input sending
		position = rootPart.CFrame.Position
		baseHeight = position.Y
		velocity = Vector3.zero
	end
	facing = 0
	currentMoveDir = Vector3.zero
	currentAimDir = Vector3.new(0, 0, -1)
	stopCurrentAnimation()

	updateTankReference()
	-- createLocalTankVisual will be called by updateTankReference if tank is found

	if playerAttributeConnection then
		playerAttributeConnection:Disconnect()
	end
	playerAttributeConnection = player:GetAttributeChangedSignal("TankAnimationId"):Connect(updateTankAnimationFromAttributes)

	if characterAttributeConnection then
		characterAttributeConnection:Disconnect()
	end
	characterAttributeConnection = character:GetAttributeChangedSignal("TankAnimationId"):Connect(updateTankAnimationFromAttributes)

	updateTankAnimationFromAttributes()
end

player.CharacterAdded:Connect(onCharacterAdded)
player.CharacterRemoving:Connect(function()
	stopCurrentAnimation()
	currentAnimationId = nil
	if playerAttributeConnection then
		playerAttributeConnection:Disconnect()
		playerAttributeConnection = nil
	end
	if characterAttributeConnection then
		characterAttributeConnection:Disconnect()
		characterAttributeConnection = nil
	end
	humanoid = nil
	rootPart = nil
	position = nil
	velocity = Vector3.zero
	baseHeight = nil
	applyShiftLock(false)
	cleanupLocalVisual()
end)
if player.Character then
	onCharacterAdded(player.Character)
end

tankFolder:GetPropertyChangedSignal("Parent"):Connect(updateTankReference)
waitForTankModel()

-- Also listen for character changes to update tank reference
player.CharacterAdded:Connect(function(character)
	character.ChildAdded:Connect(function(child)
		if child.Name == string.format("%s_Tank", player.Name) then
			updateTankReference()
		end
	end)
	
	character.ChildRemoved:Connect(function(child)
		if child == currentTank then
			cleanupLocalVisual()
			currentTank = nil
			updateTankAnimationFromAttributes()
		end
	end)
	
	waitForTankModel()
end)

if player.Character then
	player.Character.ChildAdded:Connect(function(child)
		if child.Name == string.format("%s_Tank", player.Name) then
			updateTankReference()
		end
	end)
	
	player.Character.ChildRemoved:Connect(function(child)
		if child == currentTank then
			cleanupLocalVisual()
			currentTank = nil
			updateTankAnimationFromAttributes()
		end
	end)
end

UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(onMouseBehaviorChanged)
onMouseBehaviorChanged()

tankFolder.ChildAdded:Connect(function(child)
	if child.Name == string.format("%s_Tank", player.Name) then
		updateTankReference()
	end
end)

tankFolder.ChildRemoved:Connect(function(child)
	if child == currentTank then
		cleanupLocalVisual()
		currentTank = nil
	end
end)

local function getMoveVector()
	local vertical = 0
	if moveState[Enum.KeyCode.W] or moveState[Enum.KeyCode.Up] then
		vertical += 1
	end
	if moveState[Enum.KeyCode.S] or moveState[Enum.KeyCode.Down] then
		vertical -= 1
	end

	local horizontal = 0
	if moveState[Enum.KeyCode.D] or moveState[Enum.KeyCode.Right] then
		horizontal += 1
	end
	if moveState[Enum.KeyCode.A] or moveState[Enum.KeyCode.Left] then
		horizontal -= 1
	end

	local camera = workspace.CurrentCamera
	if camera then
		local cf = camera.CFrame
		local forward = Vector3.new(-cf.ZVector.X, 0, -cf.ZVector.Z)
		if forward.Magnitude < EPSILON then
			forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		end
		if forward.Magnitude < EPSILON then
			forward = Vector3.new(0, 0, -1)
		else
			forward = forward.Unit
		end

		local right = Vector3.new(cf.XVector.X, 0, cf.XVector.Z)
		if right.Magnitude < EPSILON then
			right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
		end
		if right.Magnitude < EPSILON then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local camResult = forward * vertical + right * horizontal
		local camMagnitude = camResult.Magnitude
		if camMagnitude > EPSILON then
			return camResult.Unit
		end
	end

	local result = Vector3.zero
	for keyCode, direction in pairs(moveBindings) do
		if moveState[keyCode] then
			result += direction
		end
	end
	local magnitude = result.Magnitude
	if magnitude > EPSILON then
		return result / magnitude
	end
	return result
end

local function getAimDirection()
	local origin
	if position then
		origin = position
	elseif rootPart and rootPart.Parent then
		-- Player root is at the position (PlayerPosition aligns with root)
		origin = rootPart.CFrame.Position
	elseif currentTank then
		if currentTank:IsA("Model") then
			local primary = currentTank.PrimaryPart
			if primary then
				origin = primary.Position
			else
				local fallback = currentTank:FindFirstChildOfClass("BasePart")
				origin = fallback and fallback.Position or Vector3.new()
			end
		else
			origin = currentTank.Position
		end
	else
		origin = Vector3.new()
	end

	local camera = workspace.CurrentCamera
	if shiftLocked and camera then
		local look = camera.CFrame.LookVector
		local planar = Vector3.new(look.X, 0, look.Z)
		if planar.Magnitude > EPSILON then
			return planar.Unit
		end
	end

	if mouse then
		local hit = mouse.Hit
		if hit then
			local diff = hit.Position - origin
			local planar = Vector3.new(diff.X, 0, diff.Z)
			if planar.Magnitude > EPSILON then
				return planar.Unit
			end
		end
	end

	if camera then
		local look = camera.CFrame.LookVector
		local planar = Vector3.new(look.X, 0, look.Z)
		if planar.Magnitude > EPSILON then
			return planar.Unit
		end
	end

	return Vector3.new(0, 0, -1)
end

local function applyDragVector(vec, drag, deltaTime)
	local speed = vec.Magnitude
	if speed <= EPSILON then
		return Vector3.zero
	end
	local drop = math.min(speed, drag * deltaTime)
	return vec * ((speed - drop) / speed)
end

local function integrateMovement(deltaTime)
	if not rootPart or not rootPart.Parent then
		return
	end

	if not position then
		-- Player root is at the position (PlayerPosition aligns with root)
		position = rootPart.CFrame.Position
		baseHeight = position.Y
		velocity = Vector3.zero
	end

	deltaTime = math.min(deltaTime, MAX_DELTA)

	local moveDir = getMoveVector()
	local planarVelocity = velocity

	if moveDir.Magnitude > 1 then
		moveDir = moveDir.Unit
	end

	if moveDir.Magnitude > EPSILON then
		local desired = moveDir * movementDefaults.MoveSpeed
		local delta = desired - planarVelocity
		local maxStep = movementDefaults.Acceleration * deltaTime
		local deltaMag = delta.Magnitude
		if deltaMag > maxStep then
			delta = delta.Unit * maxStep
		end
		planarVelocity += delta
	else
		planarVelocity = applyDragVector(planarVelocity, movementDefaults.Drag, deltaTime)
	end

	velocity = Vector3.new(planarVelocity.X, 0, planarVelocity.Z)
	position += velocity * deltaTime

	if baseHeight then
		position = Vector3.new(position.X, baseHeight, position.Z)
	else
		baseHeight = position.Y
	end

	currentMoveDir = moveDir
	local aimDir = getAimDirection()
	currentAimDir = aimDir
	local aimDirection = aimDir.Magnitude > EPSILON and aimDir.Unit or Vector3.new(0, 0, -1)
	facing = math.atan2(-aimDirection.X, -aimDirection.Z)

	-- Client-side prediction: Apply movement updates immediately
	-- Server will validate and send corrections if needed
	if rootPart and rootPart.Parent then
		-- Ensure root is anchored for client-side control
		if not rootPart.Anchored then
			rootPart.Anchored = true
		end
		
		-- Update character root position with predicted position
		local characterCFrame = CFrame.lookAt(position, position + aimDirection)
		rootPart.CFrame = characterCFrame
		
		-- Update tank model position relative to root
		updateLocalTankModelPosition(position)
	end
end

local function reconcileWithServer()
	-- Tolerance-based reconciliation: only correct if difference > 1 stud
	if not serverPosition or not position then
		return
	end
	
	local difference = (serverPosition - position).Magnitude
	if difference > 1.0 then
		-- Smoothly lerp toward server position
		local lerpFactor = 0.15 -- Smooth correction factor
		position = position:Lerp(serverPosition, lerpFactor)
		velocity = velocity:Lerp(serverVelocity, lerpFactor)
		facing = facing + (serverFacing - facing) * lerpFactor
		
		-- Update root part position
		if rootPart and rootPart.Parent then
			local aimDirection = Vector3.new(math.sin(facing), 0, math.cos(facing))
			local characterCFrame = CFrame.lookAt(position, position + aimDirection)
			rootPart.CFrame = characterCFrame
			updateLocalTankModelPosition(position)
		end
	end
end

local function payloadChanged(newPayload)
	if not lastPayload then
		return true
	end
	if (newPayload.Move - lastPayload.Move).Magnitude > 0.05 then
		return true
	end
	if (newPayload.AimDirection - lastPayload.AimDirection).Magnitude > 0.05 then
		return true
	end
	if newPayload.IsFiring ~= lastPayload.IsFiring then
		return true
	end
	local newState = newPayload.State
	local lastState = lastPayload.State
	if newState and not lastState then
		return true
	elseif newState and lastState then
		if (newState.Position - lastState.Position).Magnitude > 0.1 then
			return true
		end
		if (newState.Velocity - lastState.Velocity).Magnitude > 0.1 then
			return true
		end
		if math.abs(newState.Facing - lastState.Facing) > 0.05 then
			return true
		end
	end
	return false
end

local function sendInput()
	local payload = {
		Move = currentMoveDir,
		AimDirection = currentAimDir,
		IsFiring = isFiring,
		State = position and {
			Position = Vector3.new(position.X, baseHeight or position.Y, position.Z),
			Velocity = velocity,
			Facing = facing,
		},
	}

	if payloadChanged(payload) then
		playerInputRemote:FireServer(payload)
		lastPayload = payload
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.LeftShift then
		applyShiftLock(not shiftLocked)
		return
	end
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		isFiring = true
	elseif moveBindings[input.KeyCode] then
		moveState[input.KeyCode] = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		isFiring = false
	elseif moveBindings[input.KeyCode] then
		moveState[input.KeyCode] = nil
	end
end)

-- Listen for server state updates
tankStateUpdateRemote.OnClientEvent:Connect(function(updates)
	if not updates or type(updates) ~= "table" then
		return
	end
	
	for _, update in ipairs(updates) do
		if update.PlayerId == player.UserId then
			-- This is the local player - store for reconciliation
			serverPosition = update.Position
			serverVelocity = update.Velocity
			serverFacing = update.Facing or 0
		else
			-- This is another player - handle interpolation (will implement next)
			-- TODO: Add other players interpolation
		end
	end
end)

RunService.RenderStepped:Connect(function(deltaTime)
	integrateMovement(deltaTime)
	
	-- Reconcile with server if needed
	reconcileWithServer()
	
	sendAccumulator += deltaTime
	if sendAccumulator >= REMOTE_SEND_INTERVAL then
		sendAccumulator = 0
		sendInput()
	end

	if (not currentTank or not currentTank.Parent) or (currentTank and rootPart and not localTankVisual) then
		updateTankReference()
	end
end)


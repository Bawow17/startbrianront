local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_SEND_INTERVAL = 1 / 60
local MAX_DELTA = 0.05

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remotes = require(remotesFolder:WaitForChild("InputEvents"))
local tankStateUpdateRemote = remotes.TankStateUpdate
local tankClientStateRemote = remotes.TankClientState

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
local lastAppliedFacing = nil -- Track last applied facing to avoid unnecessary updates
local MIN_FACING_CHANGE = math.rad(0.5)

-- Aim direction smoothing to prevent rapid flips
local MIN_AIM_DISTANCE = 1.0 -- Minimum distance for mouse hit to be valid
local MIN_PLANAR_MAGNITUDE = 0.01 -- Minimum planar magnitude to avoid unstable atan2

-- Client-side prediction state
local localTankPartOffsets = {} -- Store part offsets for local tank model
local localTankPlayerPositionOffset = nil -- Store PlayerPosition offset for local tank
local localTankOriginalRotation = CFrame.new().Rotation -- Store original rotation from model
local localTankFacingOffset = 0
local serverPosition = nil -- Server's authoritative position for reconciliation

local DEBUG_MOVEMENT = true
local DEBUG_REPORT_INTERVAL = 0.5

local debugLastReport = 0
local debugCurrentPredictionDiff = 0
local debugMaxPredictionDiff = 0
local debugCurrentServerDelta = 0
local debugMaxServerDelta = 0
local debugLastCorrectionDiff = 0
local debugCorrectionCount = 0

local inputSequence = 0

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
local EPSILON = 1e-4

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
	local baseRotation = localTankOriginalRotation
	local facingOffset = localTankFacingOffset or 0
	local tankRotation = CFrame.Angles(0, facing - facingOffset, 0) * baseRotation
	
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
			local baseLook = localTankOriginalRotation * Vector3.new(0, 0, -1)
			localTankFacingOffset = math.atan2(-baseLook.X, -baseLook.Z) + math.rad(90)
			
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

	-- Ensure the live server model is visible for the local player
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

	localTankVisual = currentTank
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
	-- Use rootPart position as origin for stability during movement
	-- This prevents rapid changes in origin from causing aim direction flips
	local origin
	if rootPart and rootPart.Parent then
		-- Use actual rendered position instead of predicted position for stability
		origin = rootPart.CFrame.Position
	elseif position then
		-- Fallback to predicted position if rootPart not available
		origin = position
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
			local planarDistance = planar.Magnitude
			-- Only use mouse hit if planar distance is far enough to avoid instability
			-- This prevents issues when mouse is pointing directly at/near player position
			if planarDistance > MIN_AIM_DISTANCE and planarDistance > MIN_PLANAR_MAGNITUDE then
				return planar.Unit
			end
			-- If too close, fall through to camera look vector to avoid instability
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
	
	-- Validate aim direction magnitude to prevent unstable calculations
	if aimDir.Magnitude < MIN_PLANAR_MAGNITUDE then
		-- Use previous aim direction if current one is too small
		aimDir = currentAimDir.Magnitude > MIN_PLANAR_MAGNITUDE and currentAimDir or Vector3.new(0, 0, -1)
	end
	
	-- Smooth aim direction during movement to prevent rapid flips
	-- Only smooth if we're moving and the direction change is significant
	local isMoving = moveDir.Magnitude > 0.01
	if isMoving and currentAimDir.Magnitude > MIN_PLANAR_MAGNITUDE and aimDir.Magnitude > MIN_PLANAR_MAGNITUDE then
		local currentUnit = currentAimDir.Unit
		local newUnit = aimDir.Unit
		-- Calculate angle between old and new direction
		local dot = currentUnit:Dot(newUnit)
		-- Clamp dot to valid range for acos
		dot = math.clamp(dot, -1, 1)
		local angle = math.acos(dot)
		
		-- If the angle change is large (>45 degrees), it might be a flip
		-- In that case, smooth it out during movement
		if angle > math.rad(45) then
			-- During movement, limit rapid direction changes
			-- Smooth towards new direction but prevent sudden flips
			local smoothFactor = 0.25 -- How quickly to adapt (lower = smoother, prevents flips)
			local smoothed = (currentUnit * (1 - smoothFactor) + newUnit * smoothFactor)
			-- Normalize the smoothed direction vector
			local smoothedMag = smoothed.Magnitude
			if smoothedMag > MIN_PLANAR_MAGNITUDE then
				aimDir = (smoothed / smoothedMag)
			end
		end
	end
	
	currentAimDir = aimDir
	local aimDirection = aimDir.Unit
	
	-- Calculate new facing angle only if aim direction is valid
	-- Check magnitude before using atan2 to prevent instability
	if aimDirection.Magnitude < 0.9 then
		-- Invalid direction, keep current facing
		aimDirection = Vector3.new(-math.sin(facing or 0), 0, -math.cos(facing or 0))
	else
		-- Calculate new facing angle
		local newFacing = math.atan2(-aimDirection.X, -aimDirection.Z)
		
		-- Normalize angle difference to prevent 180-degree flips
		-- If the difference is > π, wrap it to the shorter path
		if facing then
			local angleDiff = newFacing - facing
			-- Normalize angle difference to [-π, π]
			while angleDiff > math.pi do
				angleDiff -= 2 * math.pi
			end
			while angleDiff < -math.pi do
				angleDiff += 2 * math.pi
			end
			
			-- Ignore extremely large angle differences (likely errors)
			-- This prevents 180-degree flips from numerical instability
			if math.abs(angleDiff) < math.pi * 0.9 then
				-- Apply smooth transition to prevent sudden flips
				facing = facing + angleDiff
			end
			-- If angleDiff is > 0.9π, ignore it (likely a calculation error)
		else
			facing = newFacing
		end
	end
	
	-- Reconstruct aim direction from normalized facing angle to prevent flips
	-- facing = atan2(-aimDirection.X, -aimDirection.Z), so we reverse the signs
	-- This ensures consistency between facing angle and visual representation
	local normalizedAimDirection = Vector3.new(-math.sin(facing), 0, -math.cos(facing))

	-- Client-side prediction: Apply movement updates immediately
	-- Server will validate and send corrections if needed
	if rootPart and rootPart.Parent then
		if DEBUG_MOVEMENT then
			local actualPosition = rootPart.CFrame.Position
			local predictedDelta = (position - actualPosition).Magnitude
			debugCurrentPredictionDiff = predictedDelta
			if predictedDelta > debugMaxPredictionDiff then
				debugMaxPredictionDiff = predictedDelta
			end
			if serverPosition then
				local serverDelta = (position - serverPosition).Magnitude
				debugCurrentServerDelta = serverDelta
				if serverDelta > debugMaxServerDelta then
					debugMaxServerDelta = serverDelta
				end
				debugLastCorrectionDiff = serverDelta
				debugCorrectionCount = inputSequence
			end
		end
		-- Ensure root is anchored for client-side control
		if not rootPart.Anchored then
			rootPart.Anchored = true
		end
		
		-- Check if facing angle has changed significantly before updating rotation
		-- This prevents jitter from tiny floating-point changes
		local shouldUpdateRotation = true
		if lastAppliedFacing ~= nil then
			local facingDiff = math.abs(facing - lastAppliedFacing)
			-- Normalize to [-π, π]
			if facingDiff > math.pi then
				facingDiff = 2 * math.pi - facingDiff
			end
			-- Only update if change is significant
			if facingDiff < MIN_FACING_CHANGE then
				shouldUpdateRotation = false
			end
		end
		
		-- Only update rotation if it has changed significantly
		-- This prevents jitter from updating rotation every frame
		local newCFrame
		if shouldUpdateRotation then
			-- Update both position and rotation
			newCFrame = CFrame.lookAt(position, position + normalizedAimDirection)
			lastAppliedFacing = facing
		else
			-- Keep current rotation, only update position
			local currentRotation = rootPart.CFrame.Rotation
			newCFrame = CFrame.new(position) * currentRotation
		end
		
		rootPart.CFrame = newCFrame
		
		-- Update tank model position relative to root
		updateLocalTankModelPosition(position)
	end
end

local function sendInput(elapsedDelta)
	if not position then
		return
	end

	local payload = {
		Move = currentMoveDir,
		AimDirection = currentAimDir,
		IsFiring = isFiring,
		State = {
			Position = Vector3.new(position.X, baseHeight or position.Y, position.Z),
			Velocity = velocity,
			Facing = facing,
		},
	}

	inputSequence += 1
	payload.Sequence = inputSequence

	tankClientStateRemote:FireServer(payload)
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
			serverPosition = update.Position
		else
			-- Other players handled via server replication
		end
	end
end)

RunService.RenderStepped:Connect(function(deltaTime)
	integrateMovement(deltaTime)
	
	sendAccumulator += deltaTime
	while sendAccumulator >= REMOTE_SEND_INTERVAL do
		sendAccumulator -= REMOTE_SEND_INTERVAL
		sendInput(REMOTE_SEND_INTERVAL)
	end

	if (not currentTank or not currentTank.Parent) or (currentTank and rootPart and not localTankVisual) then
		updateTankReference()
	end

	if DEBUG_MOVEMENT and player then
		debugLastReport += deltaTime
		if debugLastReport >= DEBUG_REPORT_INTERVAL then
			debugLastReport -= DEBUG_REPORT_INTERVAL
			player:SetAttribute("DebugPredictionDiff", debugCurrentPredictionDiff)
			player:SetAttribute("DebugMaxPredictionDiff", debugMaxPredictionDiff)
			player:SetAttribute("DebugServerDelta", debugCurrentServerDelta)
			player:SetAttribute("DebugMaxServerDelta", debugMaxServerDelta)
			player:SetAttribute("DebugLastCorrectionDiff", debugLastCorrectionDiff)
			player:SetAttribute("DebugCorrectionCount", debugCorrectionCount)
			debugMaxPredictionDiff = debugCurrentPredictionDiff
			debugMaxServerDelta = debugCurrentServerDelta
		end
	end
end)


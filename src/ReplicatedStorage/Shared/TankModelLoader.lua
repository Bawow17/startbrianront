local TankModelLoader = {}

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TANKS_FOLDER_NAME = "Tanks"
local TANKS_PREFABS_PATH = "Prefabs/" .. TANKS_FOLDER_NAME

local function findTankModel(tankName)
	local prefabs = ServerStorage:FindFirstChild("Prefabs")
	if not prefabs then
		return nil
	end
	local tanks = prefabs:FindFirstChild(TANKS_FOLDER_NAME)
	if not tanks then
		return nil
	end
	return tanks:FindFirstChild(tankName)
end

local function extractPlayerPosition(model)
	local playerPosPart = model:FindFirstChild("PlayerPosition")
	if not playerPosPart or not playerPosPart:IsA("BasePart") then
		return Vector3.new(0, 5, 0)
	end
	local modelPrimary = model.PrimaryPart
	if not modelPrimary then
		return Vector3.new(0, 5, 0)
	end
	
	if modelPrimary == playerPosPart then
		return Vector3.new(0, 0, 0)
	end
	
	local modelCF = modelPrimary.CFrame
	local playerCF = playerPosPart.CFrame
	local offset = modelCF:ToObjectSpace(playerCF)
	return offset.Position
end

local function extractBarrels(model)
	local barrels = {}
	local modelPrimary = model.PrimaryPart
	if not modelPrimary then
		local fallback = model:FindFirstChildOfClass("BasePart")
		if fallback then
			model.PrimaryPart = fallback
			modelPrimary = fallback
		else
			return {{Position = Vector3.new(0, 0, -3), Rotation = CFrame.new(), Part = nil, BarrelObject = nil}}
		end
	end

	for _, child in ipairs(model:GetDescendants()) do
		if child.Name == "Barrel" then
			local barrelCF
			local barrelPart = child
			local isValid = false
			
			if child:IsA("BasePart") then
				barrelCF = child.CFrame
				isValid = true
			elseif child:IsA("Model") then
				local barrelPrimary = child.PrimaryPart or child:FindFirstChildOfClass("BasePart")
				if barrelPrimary then
					barrelCF = barrelPrimary.CFrame
					barrelPart = barrelPrimary
					isValid = true
				end
			end

			if isValid then
				local modelCF = modelPrimary.CFrame
				local offset = modelCF:ToObjectSpace(barrelCF)
				table.insert(barrels, {
					Position = offset.Position,
					Rotation = offset.Rotation,
					Part = barrelPart,
					BarrelObject = child,
				})
			end
		end
	end

	if #barrels == 0 then
		table.insert(barrels, {
			Position = Vector3.new(0, 0, -3),
			Rotation = CFrame.new(),
			Part = nil,
			BarrelObject = nil,
		})
	end
	return barrels
end

function TankModelLoader.loadTankModel(tankName)
	local modelTemplate = findTankModel(tankName)
	if not modelTemplate then
		warn("[TankModelLoader] Tank model not found:", tankName)
		return nil
	end

	local model = modelTemplate:Clone()
	
	-- Store the model's original rotation BEFORE any modifications
	-- This preserves how the model is oriented in Studio
	local originalRotation = CFrame.new()
	if model:IsA("Model") then
		local primary = model.PrimaryPart
		if primary then
			originalRotation = primary.CFrame.Rotation
		else
			local fallback = model:FindFirstChildOfClass("BasePart")
			if fallback then
				originalRotation = fallback.CFrame.Rotation
			end
		end
	end
	
	local playerOffset = extractPlayerPosition(model)
	local barrels = extractBarrels(model)

	for _, barrel in ipairs(barrels) do
		if barrel.Part then
			barrel.Part.CanTouch = false
			barrel.Part.CanCollide = false
		end
	end

	local playerPosPart = model:FindFirstChild("PlayerPosition")
	if playerPosPart then
		playerPosPart.Transparency = 1
		playerPosPart.CanTouch = false
		playerPosPart.CanCollide = false
	end

	return {
		Model = model,
		PlayerOffset = playerOffset,
		Barrels = barrels,
		OriginalRotation = originalRotation, -- Store original rotation from Studio
	}
end

function TankModelLoader.getAvailableTanks()
	local prefabs = ServerStorage:FindFirstChild("Prefabs")
	if not prefabs then
		return {}
	end
	local tanks = prefabs:FindFirstChild(TANKS_FOLDER_NAME)
	if not tanks then
		return {}
	end
	local available = {}
	for _, child in ipairs(tanks:GetChildren()) do
		if child:IsA("Model") then
			table.insert(available, child.Name)
		end
	end
	return available
end

return TankModelLoader

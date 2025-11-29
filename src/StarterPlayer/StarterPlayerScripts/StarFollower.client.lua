local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local REMOTE_FOLDER_NAME = "StarSystemRemotes"
local MAIN_UPDATE_EVENT_NAME = "MainStarUpdate"
local STAR_TEMPLATES_FOLDER = ReplicatedStorage:WaitForChild("StarVFXModels")

local remotes = ReplicatedStorage:WaitForChild(REMOTE_FOLDER_NAME)
local mainUpdate = remotes:WaitForChild(MAIN_UPDATE_EVENT_NAME)

local followers = {}

local function scaleModel(model, scale)
    if model.ScaleTo then
        local ok = pcall(function()
            model:ScaleTo(scale)
        end)
        if ok then
            return
        end
    end
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            p.Size = p.Size * scale
        end
    end
end

local function cleanupFollower(userId)
    local entry = followers[userId]
    if entry then
        if entry.instance and entry.instance.Parent then
            entry.instance:Destroy()
        end
        if entry.conn then
            entry.conn:Disconnect()
        end
    end
    followers[userId] = nil
end

local function attachFollower(player, starType)
    cleanupFollower(player.UserId)
    if not starType or starType == "" then
        return
    end

    local template = STAR_TEMPLATES_FOLDER:FindFirstChild(starType)
    if not template then
        return
    end

    local clone = template:Clone()
    scaleModel(clone, 0.33)

    for _, p in ipairs(clone:GetDescendants()) do
        if p:IsA("BasePart") then
            p.Anchored = false
            p.CanCollide = false
        end
    end
    clone.Name = string.format("%s_%sFollower", player.Name, starType)
    clone.Parent = workspace

    local conn
    local function attachToCharacter(character)
        if conn then
            conn:Disconnect()
            conn = nil
        end
        if not character then
            return
        end
        local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 3)
        if not root then
            return
        end

        local offset = Vector3.new(-2, 2.5, 2.5)
        local current = root.CFrame * CFrame.new(offset)
        clone:PivotTo(current)

        conn = RunService.RenderStepped:Connect(function(dt)
            if not root.Parent then
                cleanupFollower(player.UserId)
                return
            end
            local desired = root.CFrame * CFrame.new(offset)
            local blend = 1 - math.exp(-8 * math.clamp(dt, 0, 1)) -- smooth, time-based
            current = current:Lerp(desired, blend)
            clone:PivotTo(current)
        end)
    end

    attachToCharacter(player.Character)
    player.CharacterAdded:Connect(attachToCharacter)

    followers[player.UserId] = {
        instance = clone,
        conn = conn,
    }
end

mainUpdate.OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "table" then
        return
    end
    local userId = payload.userId
    local starType = payload.starType
    if not userId then
        return
    end
    local plr = Players:GetPlayerByUserId(userId)
    if not plr then
        return
    end
    attachFollower(plr, starType)
end)

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local PORTAL_NAME = "Void"
local HOLD_DURATION = 3
local TELEPORT_OFFSET_Y = 5

local function findPortals()
    local portals = {}
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Name == PORTAL_NAME then
            table.insert(portals, descendant)
        end
    end
    return portals
end

local portals = findPortals()
if #portals ~= 2 then
    warn(string.format("VoidPortalTeleport expected 2 parts named '%s' but found %d", PORTAL_NAME, #portals))
    return
end

local portalA, portalB = portals[1], portals[2]

local activeTouches = {
    [portalA] = {},
    [portalB] = {},
}
local pendingExit = {}

local function getPlayerFromHit(hit)
    local character = hit:FindFirstAncestorOfClass("Model")
    if not character then
        return
    end

    local player = Players:GetPlayerFromCharacter(character)
    if not player then
        return
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then
        return
    end

    return player, character, root
end

local function teleportPlayer(rootPart, destination)
    rootPart.CFrame = destination.CFrame + Vector3.new(0, TELEPORT_OFFSET_Y, 0)
end

local function clearTouch(portal, player)
    if activeTouches[portal] then
        activeTouches[portal][player] = nil
    end
end

local function handleTouch(portal, destinationPortal, hitPart)
    local player, _, rootPart = getPlayerFromHit(hitPart)
    if not player then
        return
    end

    local portalTouches = activeTouches[portal]
    if not portalTouches then
        return
    end

    if pendingExit[player] == portal then
        return
    end

    local info = portalTouches[player]
    if info then
        info.parts[hitPart] = true
        return
    end

    info = {
        parts = {
            [hitPart] = true,
        },
    }
    portalTouches[player] = info

    task.spawn(function()
        task.wait(HOLD_DURATION)
        if portalTouches[player] ~= info then
            return
        end

        if not next(info.parts) then
            portalTouches[player] = nil
            return
        end

        teleportPlayer(rootPart, destinationPortal)
        pendingExit[player] = destinationPortal
        portalTouches[player] = nil
    end)
end

local function handleTouchEnded(portal, hitPart)
    local player = Players:GetPlayerFromCharacter(hitPart:FindFirstAncestorOfClass("Model"))
    if not player then
        return
    end

    local portalTouches = activeTouches[portal]
    if not portalTouches then
        return
    end

    local info = portalTouches[player]
    if not info then
        if pendingExit[player] == portal then
            pendingExit[player] = nil
        end
        return
    end

    info.parts[hitPart] = nil
    if not next(info.parts) then
        portalTouches[player] = nil

        if pendingExit[player] == portal then
            pendingExit[player] = nil
        end
    end
end

portalA.Touched:Connect(function(hit)
    handleTouch(portalA, portalB, hit)
end)

portalB.Touched:Connect(function(hit)
    handleTouch(portalB, portalA, hit)
end)

portalA.TouchEnded:Connect(function(hit)
    handleTouchEnded(portalA, hit)
end)

portalB.TouchEnded:Connect(function(hit)
    handleTouchEnded(portalB, hit)
end)

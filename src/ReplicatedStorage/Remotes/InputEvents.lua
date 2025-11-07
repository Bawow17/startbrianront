local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	local folder = Instance.new("Folder")
	folder.Name = "Remotes"
	folder.Parent = ReplicatedStorage
	remotesFolder = folder
end

local function ensureRemote(name, class)
	local existing = remotesFolder:FindFirstChild(name)
	if existing then
		return existing
	end
	local remote = Instance.new(class)
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end

local InputEvents = {}

InputEvents.PlayerInput = ensureRemote("PlayerInput", "RemoteEvent")
InputEvents.TankStateUpdate = ensureRemote("TankStateUpdate", "RemoteEvent")
InputEvents.TankClientState = ensureRemote("TankClientState", "RemoteEvent")

return InputEvents



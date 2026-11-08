local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

local PlayerEye = require(game.ServerScriptService.Server.Objects.Replication.Core.PlayerEye)

-- CoreEvents is created here because the client waits on it before it can listen.
local CoreEvents = ReplicatedStorage:FindFirstChild("CoreEvents") :: Folder?
if not CoreEvents then
	CoreEvents = Instance.new("Folder")
	CoreEvents.Name = "CoreEvents"
	CoreEvents.Parent = ReplicatedStorage
end

local ReplicateEvent = CoreEvents:FindFirstChild("ReplicateEvent") :: RemoteEvent?
if not ReplicateEvent then
	local NewReplicateEvent = Instance.new("RemoteEvent")
	NewReplicateEvent.Name = "ReplicateEvent"
	NewReplicateEvent.Parent = CoreEvents
	ReplicateEvent = NewReplicateEvent
end

while true do
	for _, Player: Player in ipairs(Players:GetPlayers()) do
		local DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, Counts = PlayerEye.CullObjects(Player)
		if DeltaPositions and Counts then
			ReplicateEvent:FireClient(Player, DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, Counts)
		end
	end

	task.wait()
end


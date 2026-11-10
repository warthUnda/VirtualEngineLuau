--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players") :: Players
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Static References --
-- CoreEvents is created here because the client waits on it before it can listen.
local CoreEvents = ReplicatedStorage:FindFirstChild("CoreEvents") :: Folder?
if not CoreEvents then
	const NewCoreEvents = Instance.new("Folder")
	NewCoreEvents.Name = "CoreEvents"
	NewCoreEvents.Parent = ReplicatedStorage
	CoreEvents = NewCoreEvents
end

local ReplicateEvent = (CoreEvents :: Folder):FindFirstChild("ReplicateEvent") :: RemoteEvent?
if not ReplicateEvent then
	const NewReplicateEvent = Instance.new("RemoteEvent")
	NewReplicateEvent.Name = "ReplicateEvent"
	NewReplicateEvent.Parent = CoreEvents
	ReplicateEvent = NewReplicateEvent
end

-- Modules --
const PlayerEye = require(ServerScriptService.Server.Objects.Replication.Core.PlayerEye) :: ModuleScript

-- ============================================================================
-- 1. REPLICATION LOOP - BROADCASTS VISIBLE SNAPSHOTS TO CLIENTS
-- ============================================================================

while true do
	for _, Player: Player in ipairs(Players:GetPlayers()) do
		const DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, Counts =
			PlayerEye.CullObjects(Player)
		if DeltaPositions and Counts and Counts.EntityECSCount > 0 then
			(ReplicateEvent :: RemoteEvent):FireClient(
				Player,
				DeltaPositions,
				DeltaOrientations,
				DeltaVisuals,
				DeltaSizes,
				DeltaDirections,
				Counts
			)
		end
	end

	task.wait()
end

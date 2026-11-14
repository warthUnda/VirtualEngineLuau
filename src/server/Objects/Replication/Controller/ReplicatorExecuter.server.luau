--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const PlayerCuller = require(ServerScriptService.Server.Objects.Replication.Core.PlayerCuller)

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_EVENT_NAME = SystemsConfigs.ReplicateRemoteEventName :: string
const REPLICATION_TICK_INTERVAL = SystemsConfigs.ReplicationTickInterval :: number

-- Static References --
-- CoreEvents is created here because the client waits on it before it can listen.
local CoreEvents = ReplicatedStorage:FindFirstChild(CORE_EVENTS_FOLDER_NAME) :: Folder?
if not CoreEvents then
	const NewCoreEvents = Instance.new("Folder")
	NewCoreEvents.Name = CORE_EVENTS_FOLDER_NAME
	NewCoreEvents.Parent = ReplicatedStorage
	CoreEvents = NewCoreEvents
end

local ReplicateEvent = (CoreEvents :: Folder):FindFirstChild(REPLICATE_REMOTE_EVENT_NAME) :: RemoteEvent?
if not ReplicateEvent then
	const NewReplicateEvent = Instance.new("RemoteEvent")
	NewReplicateEvent.Name = REPLICATE_REMOTE_EVENT_NAME
	NewReplicateEvent.Parent = CoreEvents
	ReplicateEvent = NewReplicateEvent
end

-- ============================================================================
-- 1. REPLICATION LOOP - BROADCASTS VISIBLE SNAPSHOTS TO CLIENTS
-- ============================================================================

while true do
	for _, Player: Player in ipairs(Players:GetPlayers()) do
		const DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, DeltaProperties, Counts =
			PlayerCuller.CullObjects(Player)
		if DeltaPositions and Counts and Counts.EntityECSCount > 0 then
			(ReplicateEvent :: RemoteEvent):FireClient(
				Player,
				DeltaPositions,
				DeltaOrientations,
				DeltaVisuals,
				DeltaSizes,
				DeltaDirections,
				DeltaProperties,
				Counts
			)
		end
	end

	task.wait(REPLICATION_TICK_INTERVAL)
end

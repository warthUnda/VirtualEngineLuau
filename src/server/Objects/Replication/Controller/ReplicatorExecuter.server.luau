--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const PlayerCuller = require(ServerScriptService.Server.Objects.Replication.Core.PlayerCuller)
const PlayerFunctions = require(ServerScriptService.Server.Objects.Replication.Core.PlayerFunctions)

const ECSData = Storage.ECSData

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_EVENT_NAME = SystemsConfigs.ReplicateRemoteEventName :: string
const OBSERVER_REMOTE_EVENT_NAME = SystemsConfigs.ObserverRemoteEventName :: string
const REPLICATION_TICK_INTERVAL = SystemsConfigs.ReplicationTickInterval :: number

-- Static References --
-- CoreEvents is created here because the client waits on it before it can listen.
local CoreEvents = ReplicatedStorage:FindFirstChild(CORE_EVENTS_FOLDER_NAME) :: Folder?

local ReplicateEvent = (CoreEvents :: Folder):FindFirstChild(REPLICATE_REMOTE_EVENT_NAME) :: RemoteEvent?
local ObserverStateEvent = (CoreEvents :: Folder):FindFirstChild(OBSERVER_REMOTE_EVENT_NAME) :: UnreliableRemoteEvent?

(ObserverStateEvent :: UnreliableRemoteEvent).OnServerEvent:Connect(function(PlayerObject: Player, Payload: buffer)
	PlayerFunctions.UpdateObserverFromBuffer(PlayerObject, Payload, ECSData.GetCounts().EntityECSCount)
end)

-- ============================================================================
-- 1. REPLICATION LOOP - BROADCASTS VISIBLE SNAPSHOTS TO CLIENTS
-- ============================================================================

while true do
	for _, Player: Player in ipairs(Players:GetPlayers()) do
		const DeltaPositions, DeltaOrientations, DeltaVisuals, DeltaSizes, DeltaDirections, DeltaProperties, Counts =
			PlayerCuller.CullObjects(Player)

		if DeltaPositions and Counts and Counts.EntityECSCount > 0 then
			return
		end

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

	task.wait(REPLICATION_TICK_INTERVAL)
end

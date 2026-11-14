--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Modules --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const TextureTable = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Texture"):WaitForChild("TextureTable"))
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const PlayerCuller = require(ServerScriptService.Server.Objects.Replication.Core.PlayerCuller)
const PlayerFunctions = require(ServerScriptService.Server.Objects.Replication.Core.PlayerFunctions)

const ECSData = Storage.ECSData

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_EVENT_NAME = SystemsConfigs.ReplicateRemoteEventName :: string
const OBSERVER_REMOTE_EVENT_NAME = SystemsConfigs.ObserverRemoteEventName :: string
const TEXTURE_SYNC_REMOTE_EVENT_NAME = SystemsConfigs.TextureSyncRemoteEventName :: string
const REPLICATION_TICK_INTERVAL = SystemsConfigs.ReplicationTickInterval :: number

-- Static References --
-- Ensure CoreEvents and its 3 child RemoteEvents exist whether pre-placed in Studio or starting from a fresh Rojo tree.
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

local ObserverStateEvent = (CoreEvents :: Folder):FindFirstChild(OBSERVER_REMOTE_EVENT_NAME)
if not ObserverStateEvent then
	const NewObserverEvent = Instance.new("UnreliableRemoteEvent")
	NewObserverEvent.Name = OBSERVER_REMOTE_EVENT_NAME
	NewObserverEvent.Parent = CoreEvents
	ObserverStateEvent = NewObserverEvent
end

local TextureSyncEvent = (CoreEvents :: Folder):FindFirstChild(TEXTURE_SYNC_REMOTE_EVENT_NAME) :: RemoteEvent?
if not TextureSyncEvent then
	const NewTextureSyncEvent = Instance.new("RemoteEvent")
	NewTextureSyncEvent.Name = TEXTURE_SYNC_REMOTE_EVENT_NAME
	NewTextureSyncEvent.Parent = CoreEvents
	TextureSyncEvent = NewTextureSyncEvent
end

(ReplicateEvent :: RemoteEvent).OnServerEvent:Connect(function(PlayerObject: Player)
	PlayerFunctions.MarkClientReady(PlayerObject, ECSData.GetCounts().EntityECSCount)
end);

(ObserverStateEvent :: any).OnServerEvent:Connect(function(PlayerObject: Player, Payload: buffer)
	PlayerFunctions.UpdateObserverFromBuffer(PlayerObject, Payload, ECSData.GetCounts().EntityECSCount)
end);

(TextureSyncEvent :: RemoteEvent).OnServerEvent:Connect(function(PlayerObject: Player)
	(TextureSyncEvent :: RemoteEvent):FireClient(PlayerObject, TextureTable.ExportEntries())
end)

-- ============================================================================
-- 1. REPLICATION LOOP - BROADCASTS VISIBLE SNAPSHOTS TO CLIENTS
-- ============================================================================

while true do
	for _, Player: Player in ipairs(Players:GetPlayers()) do
		if not PlayerFunctions.IsClientReady(Player) then
			continue
		end

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

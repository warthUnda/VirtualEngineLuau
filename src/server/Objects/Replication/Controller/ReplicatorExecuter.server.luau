--!strict
--!native
--!optimize 2

-- Services --
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerScriptService = game:GetService("ServerScriptService")

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const TextureTable = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Texture"):WaitForChild("TextureTable"))
const PlayerCuller = require(ServerScriptService.Server.Objects.Replication.Core.PlayerCuller)
const PlayerFunctions = require(ServerScriptService.Server.Objects.Replication.Core.PlayerFunctions)

-- Storage --
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const ECSData = Storage.ECSData

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_EVENT_NAME = SystemsConfigs.ReplicateRemoteEventName :: string
const OBSERVER_REMOTE_EVENT_NAME = SystemsConfigs.ObserverRemoteEventName :: string
const TEXTURE_SYNC_REMOTE_EVENT_NAME = SystemsConfigs.TextureSyncRemoteEventName :: string
const REPLICATION_TICK_INTERVAL = SystemsConfigs.ReplicationTickInterval :: number

-- Remote Events --
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

const ReplicateRemote = ReplicateEvent :: RemoteEvent
const ObserverEventAny = ObserverStateEvent :: any
const TextureSyncRemote = TextureSyncEvent :: RemoteEvent

ReplicateRemote.OnServerEvent:Connect(function(PlayerObject: Player)
	PlayerFunctions.MarkClientReady(PlayerObject, ECSData.GetCounts().EntityECSCount)
end)

ObserverEventAny.OnServerEvent:Connect(function(PlayerObject: Player, Payload: buffer)
	PlayerFunctions.UpdateObserverFromBuffer(PlayerObject, Payload, ECSData.GetCounts().EntityECSCount)
end)

TextureSyncRemote.OnServerEvent:Connect(function(PlayerObject: Player)
	TextureSyncRemote:FireClient(PlayerObject, TextureTable.ExportEntries())
end)

-- Functions --
-- ============================================================================
-- 1. REPLICATION LOOP - BROADCASTS VISIBLE SNAPSHOTS TO CLIENTS
-- ============================================================================

while true do
	const EntityCount = ECSData.GetCounts().EntityECSCount :: number
	if EntityCount > 0 then
		PlayerFunctions.SyncEntityVersions(EntityCount)
	end

	for _, Player: Player in ipairs(Players:GetPlayers()) do
		if not PlayerFunctions.IsClientReady(Player) then
			continue
		end

		const DeltaPacket = PlayerCuller.CullObjects(Player, true)
		if DeltaPacket then
			ReplicateRemote:FireClient(Player, DeltaPacket)
		end
	end

	task.wait(REPLICATION_TICK_INTERVAL)
end

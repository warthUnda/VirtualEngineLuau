--!strict
--!native
--!optimize 2

--[=[
	@class ServerReplicationGateway
	Sole server-side network gateway managing CoreEvents and all 5 replication
	RemoteEvent / UnreliableRemoteEvent instances, bridging them to EventBus.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const ServerScriptService = game:GetService("ServerScriptService") :: ServerScriptService

-- Libraries --
const SystemsConfigs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SystemsConfigs"))
const EventBus = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("EventBus"))
const TextureTable = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Texture"):WaitForChild("TextureTable")
)
const PlayerFunctions = require(ServerScriptService.Server.Objects.Replication.Core.PlayerFunctions)

-- Storage --
const Storage = require(ServerScriptService.Server.Objects.ObjectsECS.Storage)
const ECSData = Storage.ECSData

-- Configs --
const CORE_EVENTS_FOLDER_NAME = SystemsConfigs.CoreEventsFolderName :: string
const REPLICATE_REMOTE_NAME = SystemsConfigs.ReplicateRemoteEventName :: string
const OBSERVER_REMOTE_NAME = SystemsConfigs.ObserverRemoteEventName :: string
const TEXTURE_SYNC_REMOTE_NAME = SystemsConfigs.TextureSyncRemoteEventName :: string
const PLAYER_STATE_REMOTE_NAME = SystemsConfigs.PlayerStateRemoteEventName :: string
const PLAYER_REGISTRY_REMOTE_NAME = SystemsConfigs.PlayerRegistryRemoteEventName :: string
const Events = EventBus.Events

export type ServerRemoteSet = {
	ReplicateRemote: RemoteEvent,
	TextureSyncRemote: RemoteEvent,
	PlayerRegistryRemote: RemoteEvent,
	ObserverStateRemote: UnreliableRemoteEvent,
	PlayerStateRemote: UnreliableRemoteEvent,
}

-- Tables --
local ServerReplicationGateway = {}

-- Functions --
-- ============================================================================
-- 1. SERVER COREEVENTS CREATION & EVENTBUS BRIDGE
-- ============================================================================

--[=[
	Finds or creates a RemoteEvent child inside CoreEvents.
	@param ParentFolder Folder -- CoreEvents container folder.
	@param EventName string -- Target RemoteEvent name.
	@return RemoteEvent -- Resolved or newly created RemoteEvent.
]=]
function ServerReplicationGateway.EnsureRemoteEvent(ParentFolder: Folder, EventName: string): RemoteEvent
	const Existing = ParentFolder:FindFirstChild(EventName)
	if Existing and Existing:IsA("RemoteEvent") then
		return Existing
	end
	const Created = Instance.new("RemoteEvent")
	Created.Name = EventName
	Created.Parent = ParentFolder
	return Created
end

--[=[
	Finds or creates an UnreliableRemoteEvent child inside CoreEvents.
	@param ParentFolder Folder -- CoreEvents container folder.
	@param EventName string -- Target UnreliableRemoteEvent name.
	@return UnreliableRemoteEvent -- Resolved or newly created UnreliableRemoteEvent.
]=]
function ServerReplicationGateway.EnsureUnreliableRemote(ParentFolder: Folder, EventName: string): UnreliableRemoteEvent
	const Existing = ParentFolder:FindFirstChild(EventName)
	if Existing and Existing:IsA("UnreliableRemoteEvent") then
		return Existing
	end
	const Created = Instance.new("UnreliableRemoteEvent")
	Created.Name = EventName
	Created.Parent = ParentFolder
	return Created
end

--[=[
	Initializes all 5 server replication remotes inside CoreEvents and binds inbound/outbound EventBus bridges.
	@return ServerRemoteSet -- Active server replication remotes.
]=]
function ServerReplicationGateway.InitializeGateway(): ServerRemoteSet
	local CoreEvents = ReplicatedStorage:FindFirstChild(CORE_EVENTS_FOLDER_NAME) :: Folder?
	if not CoreEvents then
		const NewFolder = Instance.new("Folder")
		NewFolder.Name = CORE_EVENTS_FOLDER_NAME
		NewFolder.Parent = ReplicatedStorage
		CoreEvents = NewFolder
	end

	const EventsFolder = CoreEvents :: Folder
	const ReplicateRemote = ServerReplicationGateway.EnsureRemoteEvent(EventsFolder, REPLICATE_REMOTE_NAME)
	const TextureSyncRemote = ServerReplicationGateway.EnsureRemoteEvent(EventsFolder, TEXTURE_SYNC_REMOTE_NAME)
	const PlayerRegistryRemote = ServerReplicationGateway.EnsureRemoteEvent(EventsFolder, PLAYER_REGISTRY_REMOTE_NAME)
	const ObserverStateRemote = ServerReplicationGateway.EnsureUnreliableRemote(EventsFolder, OBSERVER_REMOTE_NAME)
	const PlayerStateRemote = ServerReplicationGateway.EnsureUnreliableRemote(EventsFolder, PLAYER_STATE_REMOTE_NAME)

	ReplicateRemote.OnServerEvent:Connect(function(PlayerObject: Player)
		PlayerFunctions.MarkClientReady(PlayerObject, ECSData.GetCounts().EntityECSCount)
	end)

	ObserverStateRemote.OnServerEvent:Connect(function(PlayerObject: Player, Payload: buffer)
		PlayerFunctions.UpdateObserverFromBuffer(PlayerObject, Payload, ECSData.GetCounts().EntityECSCount)
	end)

	TextureSyncRemote.OnServerEvent:Connect(function(PlayerObject: Player)
		TextureSyncRemote:FireClient(PlayerObject, TextureTable.ExportEntries())
	end)

	PlayerStateRemote.OnServerEvent:Connect(function(PlayerObject: Player, Payload: buffer)
		EventBus.Emit(Events.ServerPlayerStateReceived, PlayerObject, Payload)
	end)

	PlayerRegistryRemote.OnServerEvent:Connect(function(PlayerObject: Player)
		EventBus.Emit(Events.ServerPlayerRegistryRequested, PlayerObject)
	end)

	EventBus.Subscribe(Events.ServerTexturesChanged, function(Entries: any)
		TextureSyncRemote:FireAllClients(Entries)
	end)

	EventBus.Subscribe(Events.ServerPlayerRegistryChanged, function(Entries: any)
		PlayerRegistryRemote:FireAllClients(Entries)
	end)

	EventBus.Subscribe(Events.ServerPlayerRegistryReply, function(TargetPlayer: Player, Entries: any)
		PlayerRegistryRemote:FireClient(TargetPlayer, Entries)
	end)

	return {
		ReplicateRemote = ReplicateRemote,
		TextureSyncRemote = TextureSyncRemote,
		PlayerRegistryRemote = PlayerRegistryRemote,
		ObserverStateRemote = ObserverStateRemote,
		PlayerStateRemote = PlayerStateRemote,
	}
end

return ServerReplicationGateway
